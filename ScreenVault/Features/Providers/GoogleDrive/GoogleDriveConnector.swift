import Foundation
import CryptoKit
import OSLog

// MARK: - Google Drive API 定数

private enum GoogleDriveAPI {
    static let authorizationEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
    static let tokenEndpoint = "https://oauth2.googleapis.com/token"
    static let filesEndpoint = "https://www.googleapis.com/drive/v3/files"
    static let uploadEndpoint = "https://www.googleapis.com/upload/drive/v3/files"
    static let scope = "https://www.googleapis.com/auth/drive.file"
    static let redirectURI = "com.screenvault.app:/oauth2callback/google"

    /// Resumable Upload チャンクサイズ（256KB の倍数、最大 5MB）
    static let chunkSize = 4 * 1024 * 1024  // 4 MB
    /// セッション URI の有効期限（1週間）
    static let sessionURITTL: TimeInterval = 7 * 24 * 60 * 60
}

// MARK: - Google Drive エラー

enum GoogleDriveError: Error, LocalizedError {
    case missingClientCredentials
    case authCodeNotReceived
    case tokenExchangeFailed(statusCode: Int, body: String)
    case tokenRefreshFailed(statusCode: Int, body: String)
    case folderCreateFailed(statusCode: Int, body: String)
    case uploadSessionCreateFailed(statusCode: Int, body: String)
    case uploadSessionExpired
    case chunkUploadFailed(statusCode: Int, body: String)
    case resumePositionQueryFailed(statusCode: Int)
    case fileMetadataFailed(statusCode: Int, body: String)
    case sharingFailed(statusCode: Int, body: String)
    case rateLimitExceeded(retryAfter: TimeInterval)
    case serverError(statusCode: Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingClientCredentials:
            return "Google Drive クライアントIDが設定されていません"
        case .authCodeNotReceived:
            return "認可コードが受信できませんでした"
        case .tokenExchangeFailed(let code, let body):
            return "トークン交換失敗 (HTTP \(code)): \(body)"
        case .tokenRefreshFailed(let code, let body):
            return "トークン更新失敗 (HTTP \(code)): \(body)"
        case .folderCreateFailed(let code, let body):
            return "フォルダ作成失敗 (HTTP \(code)): \(body)"
        case .uploadSessionCreateFailed(let code, let body):
            return "アップロードセッション作成失敗 (HTTP \(code)): \(body)"
        case .uploadSessionExpired:
            return "アップロードセッションが期限切れです"
        case .chunkUploadFailed(let code, let body):
            return "チャンクアップロード失敗 (HTTP \(code)): \(body)"
        case .resumePositionQueryFailed(let code):
            return "再開位置照会失敗 (HTTP \(code))"
        case .fileMetadataFailed(let code, let body):
            return "ファイルメタデータ取得失敗 (HTTP \(code)): \(body)"
        case .sharingFailed(let code, let body):
            return "共有設定失敗 (HTTP \(code)): \(body)"
        case .rateLimitExceeded(let retryAfter):
            return "レートリミット超過。\(Int(retryAfter))秒後に再試行してください"
        case .serverError(let code):
            return "サーバーエラー (HTTP \(code))"
        case .invalidResponse:
            return "無効なレスポンス"
        }
    }
}

// MARK: - GoogleDriveConnector

/// Google Drive プロバイダコネクタ
/// URLSession のみ使用（サードパーティSDK不使用）
final class GoogleDriveConnector: ProviderConnector, @unchecked Sendable {

    // MARK: ProviderConnector

    var providerType: ProviderType { .googleDrive }

    // MARK: - 設定

    /// OAuth クライアント ID（Info.plist の GD_CLIENT_ID キーから読み込む）
    private let clientID: String

    /// 紐付くアカウント ID
    let accountID: String

    // MARK: - 内部状態

    private let session: URLSession
    private let logger = SVLogger.provider

    // MARK: - Keychain キー

    private var accessTokenKey: String { "gd_access_\(accountID)" }
    private var refreshTokenKey: String { "gd_refresh_\(accountID)" }
    private var tokenExpiryKey: String { "gd_expiry_\(accountID)" }

    // MARK: - init

    init(accountID: String, session: URLSession = .shared) throws {
        guard let clientID = Bundle.main.object(forInfoDictionaryKey: "GD_CLIENT_ID") as? String,
              !clientID.isEmpty else {
            throw GoogleDriveError.missingClientCredentials
        }
        self.clientID = clientID
        self.accountID = accountID
        self.session = session
    }

    // MARK: - authenticate

    /// OAuth 2.0 認証を実行し、アクセストークン・リフレッシュトークンを Keychain に保存する。
    /// macOS では ASWebAuthenticationSession を利用するため、呼び出し元は MainActor で実行すること。
    func authenticate() async throws {
        logger.info("GoogleDrive: 認証開始 accountID=\(self.accountID)")

        let (codeVerifier, codeChallenge) = generatePKCE()
        let state = UUID().uuidString

        var components = URLComponents(string: GoogleDriveAPI.authorizationEndpoint)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: GoogleDriveAPI.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: GoogleDriveAPI.scope),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent")
        ]

        guard let authURL = components.url else { throw GoogleDriveError.invalidResponse }

        // ASWebAuthenticationSession でブラウザ認証
        let callbackURL = try await performWebAuth(url: authURL,
                                                   callbackScheme: "com.screenvault.app")

        guard let queryItems = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems,
              let code = queryItems.first(where: { $0.name == "code" })?.value else {
            throw GoogleDriveError.authCodeNotReceived
        }

        // 認可コードをトークンに交換
        try await exchangeCodeForTokens(code: code, codeVerifier: codeVerifier)
        logger.info("GoogleDrive: 認証完了 accountID=\(self.accountID)")
    }

    // MARK: - ensureFolder

    /// パスコンポーネントに対応するフォルダ階層をリモートに確保し、末端フォルダの ID を返す。
    /// RemoteFolderCache を利用してAPI呼び出しを最小化する。
    func ensureFolder(pathComponents: [String]) async throws -> String {
        var parentID = "root"
        var accumulatedPath = "googleDrive"

        for component in pathComponents {
            accumulatedPath += "/\(component)"
            let cacheKey = "\(accumulatedPath)"

            // キャッシュ確認
            if let cachedID = RemoteFolderCacheStore.shared.folderID(
                accountID: accountID, pathKey: cacheKey) {
                parentID = cachedID
                continue
            }

            // API でフォルダを検索または作成
            let folderID = try await findOrCreateFolder(
                name: component, parentID: parentID)
            RemoteFolderCacheStore.shared.setFolderID(
                accountID: accountID, pathKey: cacheKey, folderID: folderID)
            parentID = folderID
        }

        return parentID
    }

    // MARK: - uploadResumable

    /// Resumable Upload でファイルをアップロードし、リモートファイル ID を返す。
    func uploadResumable(fileURL: URL,
                         remoteFolderID: String,
                         fileName: String) async throws -> String {
        let fileSize = try fileSize(at: fileURL)
        logger.info("GoogleDrive: アップロード開始 file=\(fileName) size=\(fileSize)")

        // セッション URI を取得（または再作成）
        let sessionURI = try await createResumableUploadSession(
            fileName: fileName,
            mimeType: mimeType(for: fileURL),
            parentFolderID: remoteFolderID,
            fileSize: fileSize
        )

        // チャンク送信
        let remoteFileID = try await uploadChunks(
            fileURL: fileURL,
            sessionURI: sessionURI,
            fileSize: fileSize
        )

        logger.info("GoogleDrive: アップロード完了 remoteFileID=\(remoteFileID)")
        return remoteFileID
    }

    // MARK: - getRemoteHash

    /// files.get で md5Checksum を取得する。
    func getRemoteHash(remoteFileID: String) async throws -> String? {
        let token = try await validAccessToken()
        var components = URLComponents(string: "\(GoogleDriveAPI.filesEndpoint)/\(remoteFileID)")!
        components.queryItems = [URLQueryItem(name: "fields", value: "md5Checksum")]

        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        try handleStatusCode(statusCode, data: data)

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["md5Checksum"] as? String
    }

    // MARK: - setSharing

    /// permissions.create で共有設定を適用する。
    func setSharing(remoteFileID: String, policy: SharingPolicy) async throws {
        guard policy.isShared else {
            logger.debug("GoogleDrive: 共有なし設定、スキップ")
            return
        }

        let token = try await validAccessToken()
        let url = URL(string: "\(GoogleDriveAPI.filesEndpoint)/\(remoteFileID)/permissions")!

        let body: [String: Any] = [
            "type": gdSharingType(from: policy.scope),
            "role": gdRole(from: policy.role)
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        guard (200..<300).contains(statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw GoogleDriveError.sharingFailed(statusCode: statusCode, body: body)
        }

        logger.info("GoogleDrive: 共有設定完了 remoteFileID=\(remoteFileID)")
    }
}

// MARK: - Private: OAuth

private extension GoogleDriveConnector {

    /// ASWebAuthenticationSession を使ってブラウザ認証を行い、コールバック URL を返す。
    @MainActor
    func performWebAuth(url: URL, callbackScheme: String) async throws -> URL {
        try await OAuthWebAuth.authenticate(url: url, callbackScheme: callbackScheme)
    }

    /// 認可コードをアクセストークン・リフレッシュトークンに交換する。
    func exchangeCodeForTokens(code: String, codeVerifier: String) async throws {
        var request = URLRequest(url: URL(string: GoogleDriveAPI.tokenEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded",
                         forHTTPHeaderField: "Content-Type")

        let params = [
            "code": code,
            "client_id": clientID,
            "redirect_uri": GoogleDriveAPI.redirectURI,
            "grant_type": "authorization_code",
            "code_verifier": codeVerifier
        ]
        request.httpBody = params
            .map { "\($0.key)=\(rfc3986Encoded($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        guard (200..<300).contains(statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw GoogleDriveError.tokenExchangeFailed(statusCode: statusCode, body: body)
        }

        try saveTokens(from: data)
    }

    /// リフレッシュトークンを使ってアクセストークンを更新する。
    func refreshAccessToken() async throws {
        guard let refreshData = try KeychainHelper.load(key: refreshTokenKey),
              let refreshToken = String(data: refreshData, encoding: .utf8) else {
            // リフレッシュトークンがない場合は再認証が必要
            throw GoogleDriveError.tokenRefreshFailed(statusCode: 0, body: "No refresh token")
        }

        var request = URLRequest(url: URL(string: GoogleDriveAPI.tokenEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded",
                         forHTTPHeaderField: "Content-Type")

        let params = [
            "refresh_token": refreshToken,
            "client_id": clientID,
            "grant_type": "refresh_token"
        ]
        request.httpBody = params
            .map { "\($0.key)=\(rfc3986Encoded($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await retryWithBackoff {
            try await self.session.data(for: request)
        }
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        guard (200..<300).contains(statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw GoogleDriveError.tokenRefreshFailed(statusCode: statusCode, body: body)
        }

        try saveTokens(from: data, preserveRefreshToken: true)
        logger.info("GoogleDrive: アクセストークン更新完了")
    }

    /// 有効なアクセストークンを返す。期限切れなら更新する。
    func validAccessToken() async throws -> String {
        // 有効期限確認
        if let expiryData = try KeychainHelper.load(key: tokenExpiryKey),
           let expiryString = String(data: expiryData, encoding: .utf8),
           let expiry = Double(expiryString) {
            let expiryDate = Date(timeIntervalSince1970: expiry)
            if expiryDate > Date(timeIntervalSinceNow: 5 * 60) {
                // まだ有効
                if let tokenData = try KeychainHelper.load(key: accessTokenKey),
                   let token = String(data: tokenData, encoding: .utf8) {
                    return token
                }
            }
        }
        // 期限切れ or 未取得 → リフレッシュ
        try await refreshAccessToken()

        guard let tokenData = try KeychainHelper.load(key: accessTokenKey),
              let token = String(data: tokenData, encoding: .utf8) else {
            throw GoogleDriveError.tokenRefreshFailed(statusCode: 0, body: "Token not found after refresh")
        }
        return token
    }

    /// レスポンス JSON からトークンを解析して Keychain に保存する。
    func saveTokens(from data: Data, preserveRefreshToken: Bool = false) throws {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String,
              let expiresIn = json["expires_in"] as? Double else {
            throw GoogleDriveError.invalidResponse
        }

        try KeychainHelper.save(key: accessTokenKey,
                                data: accessToken.data(using: .utf8)!)
        let expiryTimestamp = Date().timeIntervalSince1970 + expiresIn
        try KeychainHelper.save(key: tokenExpiryKey,
                                data: "\(expiryTimestamp)".data(using: .utf8)!)

        if !preserveRefreshToken,
           let refreshToken = json["refresh_token"] as? String {
            try KeychainHelper.save(key: refreshTokenKey,
                                    data: refreshToken.data(using: .utf8)!)
        }
    }

    /// PKCE code_verifier と code_challenge（S256）を生成する。
    func generatePKCE() -> (verifier: String, challenge: String) {
        var buffer = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, buffer.count, &buffer)
        let verifier = Data(buffer).base64URLEncoded()

        // CryptoKit を使って SHA-256 ハッシュを計算
        let verifierData = Data(verifier.utf8)
        let hash = SHA256.hash(data: verifierData)
        let challenge = Data(hash).base64URLEncoded()
        return (verifier, challenge)
    }
}

// MARK: - Private: フォルダ管理

private extension GoogleDriveConnector {

    /// リモートでフォルダを検索し、なければ作成する。
    func findOrCreateFolder(name: String, parentID: String) async throws -> String {
        let token = try await validAccessToken()

        // まず既存フォルダを検索
        let escapedName = name.replacingOccurrences(of: "'", with: "\\'")
        var components = URLComponents(string: GoogleDriveAPI.filesEndpoint)!
        components.queryItems = [
            URLQueryItem(name: "q", value: "mimeType='application/vnd.google-apps.folder' and name='\(escapedName)' and '\(parentID)' in parents and trashed=false"),
            URLQueryItem(name: "fields", value: "files(id,name)"),
            URLQueryItem(name: "spaces", value: "drive")
        ]

        var searchRequest = URLRequest(url: components.url!)
        searchRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (searchData, searchResponse) = try await session.data(for: searchRequest)
        let searchStatus = (searchResponse as? HTTPURLResponse)?.statusCode ?? 0
        try handleStatusCode(searchStatus, data: searchData)

        if let json = try JSONSerialization.jsonObject(with: searchData) as? [String: Any],
           let files = json["files"] as? [[String: Any]],
           let firstFile = files.first,
           let folderID = firstFile["id"] as? String {
            logger.debug("GoogleDrive: 既存フォルダ発見 name=\(name) id=\(folderID)")
            return folderID
        }

        // 見つからなければ作成
        return try await createFolder(name: name, parentID: parentID, token: token)
    }

    /// Google Drive にフォルダを作成する。
    func createFolder(name: String, parentID: String, token: String) async throws -> String {
        var request = URLRequest(url: URL(string: GoogleDriveAPI.filesEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let metadata: [String: Any] = [
            "name": name,
            "mimeType": "application/vnd.google-apps.folder",
            "parents": [parentID]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: metadata)

        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        guard (200..<300).contains(statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw GoogleDriveError.folderCreateFailed(statusCode: statusCode, body: body)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let folderID = json["id"] as? String else {
            throw GoogleDriveError.invalidResponse
        }

        logger.info("GoogleDrive: フォルダ作成完了 name=\(name) id=\(folderID)")
        return folderID
    }
}

// MARK: - Private: Resumable Upload

private extension GoogleDriveConnector {

    /// Resumable Upload セッション URI を取得する。
    func createResumableUploadSession(fileName: String,
                                      mimeType: String,
                                      parentFolderID: String,
                                      fileSize: Int) async throws -> URL {
        let token = try await validAccessToken()

        let components = URLComponents(string: "\(GoogleDriveAPI.uploadEndpoint)?uploadType=resumable")!
        let sessionURL = components.url!

        var request = URLRequest(url: sessionURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(mimeType, forHTTPHeaderField: "X-Upload-Content-Type")
        request.setValue("\(fileSize)", forHTTPHeaderField: "X-Upload-Content-Length")

        let metadata: [String: Any] = [
            "name": fileName,
            "parents": [parentFolderID]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: metadata)

        let (data, response) = try await session.data(for: request)
        let httpResponse = response as? HTTPURLResponse
        let statusCode = httpResponse?.statusCode ?? 0

        guard (200..<300).contains(statusCode),
              let locationString = httpResponse?.value(forHTTPHeaderField: "Location"),
              let locationURL = URL(string: locationString) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw GoogleDriveError.uploadSessionCreateFailed(statusCode: statusCode, body: body)
        }

        logger.debug("GoogleDrive: アップロードセッション作成完了")
        return locationURL
    }

    /// ファイルをチャンクに分割してアップロードする。
    func uploadChunks(fileURL: URL,
                      sessionURI: URL,
                      fileSize: Int) async throws -> String {
        let fileHandle = try FileHandle(forReadingFrom: fileURL)
        defer { try? fileHandle.close() }

        var offset = 0
        let chunkSize = GoogleDriveAPI.chunkSize

        while offset < fileSize {
            let remainingBytes = fileSize - offset
            let currentChunkSize = min(chunkSize, remainingBytes)

            try fileHandle.seek(toOffset: UInt64(offset))
            guard let chunkData = try fileHandle.read(upToCount: currentChunkSize) else {
                break
            }

            var request = URLRequest(url: sessionURI)
            request.httpMethod = "PUT"
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            let rangeEnd = offset + chunkData.count - 1
            request.setValue("bytes \(offset)-\(rangeEnd)/\(fileSize)",
                             forHTTPHeaderField: "Content-Range")
            request.httpBody = chunkData

            let (data, response) = try await retryWithBackoff {
                try await self.session.data(for: request)
            }
            let httpResponse = response as? HTTPURLResponse
            let statusCode = httpResponse?.statusCode ?? 0

            // 200/201: 完了
            if statusCode == 200 || statusCode == 201 {
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let fileID = json["id"] as? String else {
                    throw GoogleDriveError.invalidResponse
                }
                return fileID
            }

            // 308: Resume Incomplete（次のチャンクへ）
            if statusCode == 308 {
                if let rangeHeader = httpResponse?.value(forHTTPHeaderField: "Range"),
                   let lastByte = Int(rangeHeader.components(separatedBy: "-").last ?? "") {
                    offset = lastByte + 1
                } else {
                    offset += chunkData.count
                }
                logger.debug("GoogleDrive: チャンク送信完了 offset=\(offset)/\(fileSize)")
                continue
            }

            // 410: セッション期限切れ → 再作成
            if statusCode == 410 {
                throw GoogleDriveError.uploadSessionExpired
            }

            // その他エラー
            let body = String(data: data, encoding: .utf8) ?? ""
            throw GoogleDriveError.chunkUploadFailed(statusCode: statusCode, body: body)
        }

        throw GoogleDriveError.invalidResponse
    }

    /// セッション URI に対して再開位置を問い合わせる。
    func queryResumePosition(sessionURI: URL, fileSize: Int) async throws -> Int {
        var request = URLRequest(url: sessionURI)
        request.httpMethod = "PUT"
        request.setValue("bytes */\(fileSize)", forHTTPHeaderField: "Content-Range")
        request.setValue("0", forHTTPHeaderField: "Content-Length")

        let (_, response) = try await session.data(for: request)
        let httpResponse = response as? HTTPURLResponse
        let statusCode = httpResponse?.statusCode ?? 0

        // 308: 部分完了
        if statusCode == 308 {
            guard let rangeHeader = httpResponse?.value(forHTTPHeaderField: "Range"),
                  let lastByte = Int(rangeHeader.components(separatedBy: "-").last ?? "") else {
                return 0  // まだ 0 バイトも送れていない
            }
            return lastByte + 1
        }

        // 200/201: すでに完了（想定外だが許容）
        if statusCode == 200 || statusCode == 201 { return fileSize }

        throw GoogleDriveError.resumePositionQueryFailed(statusCode: statusCode)
    }
}

// MARK: - Private: ユーティリティ

private extension GoogleDriveConnector {

    /// HTTP ステータスコードに応じてエラーを投げる。
    func handleStatusCode(_ statusCode: Int, data: Data) throws {
        switch statusCode {
        case 200..<300:
            return
        case 401:
            // 呼び出し元で refreshAccessToken 後にリトライする
            throw GoogleDriveError.tokenRefreshFailed(statusCode: 401, body: "Unauthorized")
        case 429:
            let retry: TimeInterval = 60
            throw GoogleDriveError.rateLimitExceeded(retryAfter: retry)
        case 500..<600:
            throw GoogleDriveError.serverError(statusCode: statusCode)
        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw GoogleDriveError.fileMetadataFailed(statusCode: statusCode, body: body)
        }
    }

    /// 指数バックオフ付きリトライ。
    /// 429 の場合は Retry-After を尊重する。
    func retryWithBackoff<T>(
        maxAttempts: Int = 3,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        var attempt = 0
        var delay: TimeInterval = 1.0

        while true {
            do {
                return try await operation()
            } catch GoogleDriveError.rateLimitExceeded(let retryAfter) {
                attempt += 1
                if attempt >= maxAttempts { throw GoogleDriveError.rateLimitExceeded(retryAfter: retryAfter) }
                logger.warning("GoogleDrive: レートリミット。\(Int(retryAfter))秒待機 attempt=\(attempt)")
                try await Task.sleep(nanoseconds: UInt64(retryAfter * 1_000_000_000))
            } catch GoogleDriveError.serverError(let code) {
                attempt += 1
                if attempt >= maxAttempts { throw GoogleDriveError.serverError(statusCode: code) }
                logger.warning("GoogleDrive: サーバーエラー HTTP\(code)。\(delay)秒待機 attempt=\(attempt)")
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                delay = min(delay * 2, 60)
            } catch {
                throw error
            }
        }
    }

    /// ファイルサイズを返す。
    func fileSize(at url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.size] as? Int) ?? 0
    }

    /// URL の拡張子から MIME タイプを推定する。
    func mimeType(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "mp4": return "video/mp4"
        case "mov": return "video/quicktime"
        case "pdf": return "application/pdf"
        default: return "application/octet-stream"
        }
    }

    /// RFC 3986 準拠のパーセントエンコード（unreserved characters のみ許可）。
    func rfc3986Encoded(_ string: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }

    /// SharingScope を Google Drive の type 文字列に変換する。
    func gdSharingType(from scope: SharingScope) -> String {
        switch scope {
        case .owner: return "user"
        case .organization: return "domain"
        case .anyone: return "anyone"
        }
    }

    /// SharingRole を Google Drive の role 文字列に変換する。
    func gdRole(from role: SharingRole) -> String {
        switch role {
        case .viewer: return "reader"
        case .editor: return "writer"
        }
    }
}

// MARK: - Data+Base64URL

private extension Data {
    /// Base64 URL エンコード（パディングなし）
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// RemoteFolderCacheStore は ScreenVault/Features/Providers/RemoteFolderCacheStore.swift で定義


