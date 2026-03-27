import Foundation
import CryptoKit
import OSLog

// MARK: - Microsoft Graph API 定数

private enum MicrosoftGraphAPI {
    static let authorizationEndpoint = "https://login.microsoftonline.com/common/oauth2/v2.0/authorize"
    static let tokenEndpoint = "https://login.microsoftonline.com/common/oauth2/v2.0/token"
    static let graphBaseURL = "https://graph.microsoft.com/v1.0"
    static let driveRootPath = "\(graphBaseURL)/me/drive"
    static let appRootPath = "\(graphBaseURL)/me/drive/special/approot"

    /// スコープ（Files.ReadWrite.AppFolder + offline_access）
    static let scope = "Files.ReadWrite.AppFolder offline_access"
    static let redirectURI = "com.screenvault.app:/oauth2callback/onedrive"

    /// チャンクサイズ（320 KB の倍数）
    static let chunkSize = 4 * 320 * 1024  // 1.25 MB (320KB x 4)
}

// MARK: - OneDrive エラー

enum OneDriveError: Error, LocalizedError {
    case missingClientCredentials
    case authCodeNotReceived
    case tokenExchangeFailed(statusCode: Int, body: String)
    case tokenRefreshFailed(statusCode: Int, body: String)
    case folderCreateFailed(statusCode: Int, body: String)
    case uploadSessionCreateFailed(statusCode: Int, body: String)
    case uploadSessionExpired
    case chunkUploadFailed(statusCode: Int, body: String)
    case fileMetadataFailed(statusCode: Int, body: String)
    case sharingFailed(statusCode: Int, body: String)
    case rateLimitExceeded(retryAfter: TimeInterval)
    case serverError(statusCode: Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingClientCredentials:
            return "OneDrive クライアントIDが設定されていません"
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
        case .fileMetadataFailed(let code, let body):
            return "ファイルメタデータ取得失敗 (HTTP \(code)): \(body)"
        case .sharingFailed(let code, let body):
            return "共有リンク作成失敗 (HTTP \(code)): \(body)"
        case .rateLimitExceeded(let retryAfter):
            return "レートリミット超過。\(Int(retryAfter))秒後に再試行してください"
        case .serverError(let code):
            return "サーバーエラー (HTTP \(code))"
        case .invalidResponse:
            return "無効なレスポンス"
        }
    }
}

// MARK: - アップロードセッション情報

private struct OneDriveUploadSession {
    let uploadURL: URL
    let expirationDateTime: Date

    /// セッションが有効かどうか（5分前に期限切れとみなす）
    var isValid: Bool {
        expirationDateTime > Date(timeIntervalSinceNow: 5 * 60)
    }
}

// MARK: - OneDriveConnector

/// OneDrive（Microsoft Graph）プロバイダコネクタ
/// URLSession のみ使用（MSAL SDK 不使用）
final class OneDriveConnector: ProviderConnector, @unchecked Sendable {

    // MARK: ProviderConnector

    var providerType: ProviderType { .oneDrive }

    // MARK: - 設定

    /// OAuth クライアント ID（Info.plist の OD_CLIENT_ID キーから読み込む）
    private let clientID: String

    /// 紐付くアカウント ID
    let accountID: String

    // MARK: - 内部状態

    private let session: URLSession
    private let logger = SVLogger.provider

    // MARK: - Keychain キー

    private var accessTokenKey: String { "od_access_\(accountID)" }
    private var refreshTokenKey: String { "od_refresh_\(accountID)" }
    private var tokenExpiryKey: String { "od_expiry_\(accountID)" }

    // MARK: - init

    init(accountID: String, session: URLSession = .shared) throws {
        guard let clientID = Bundle.main.object(forInfoDictionaryKey: "OD_CLIENT_ID") as? String,
              !clientID.isEmpty else {
            throw OneDriveError.missingClientCredentials
        }
        self.clientID = clientID
        self.accountID = accountID
        self.session = session
    }

    // MARK: - authenticate

    /// Microsoft identity platform を使った OAuth 2.0 認証。
    /// ASWebAuthenticationSession でブラウザ認証を実行する。
    func authenticate() async throws {
        logger.info("OneDrive: 認証開始 accountID=\(self.accountID)")

        let (codeVerifier, codeChallenge) = generatePKCE()
        let state = UUID().uuidString

        var components = URLComponents(string: MicrosoftGraphAPI.authorizationEndpoint)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: MicrosoftGraphAPI.redirectURI),
            URLQueryItem(name: "scope", value: MicrosoftGraphAPI.scope),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "response_mode", value: "query")
        ]

        guard let authURL = components.url else { throw OneDriveError.invalidResponse }

        let callbackURL = try await performWebAuth(url: authURL,
                                                   callbackScheme: "com.screenvault.app")

        guard let queryItems = URLComponents(url: callbackURL,
                                             resolvingAgainstBaseURL: false)?.queryItems,
              let code = queryItems.first(where: { $0.name == "code" })?.value else {
            throw OneDriveError.authCodeNotReceived
        }

        try await exchangeCodeForTokens(code: code, codeVerifier: codeVerifier)
        logger.info("OneDrive: 認証完了 accountID=\(self.accountID)")
    }

    // MARK: - ensureFolder

    /// approot 配下にフォルダ階層を確保し、末端フォルダの ID を返す。
    func ensureFolder(pathComponents: [String]) async throws -> String {
        var accumulatedPath = "oneDrive"
        // approot 直下から順にフォルダを確保する
        var currentAPIPath = "\(MicrosoftGraphAPI.appRootPath)"

        for component in pathComponents {
            accumulatedPath += "/\(component)"
            let cacheKey = accumulatedPath

            if let cachedID = RemoteFolderCacheStore.shared.folderID(
                accountID: accountID, pathKey: cacheKey) {
                // キャッシュヒット：次のパスで API パスを更新
                currentAPIPath = "\(MicrosoftGraphAPI.driveRootPath)/items/\(cachedID)"
                continue
            }

            let folderID = try await findOrCreateFolder(
                name: component, parentAPIPath: currentAPIPath)
            RemoteFolderCacheStore.shared.setFolderID(
                accountID: accountID, pathKey: cacheKey, folderID: folderID)
            currentAPIPath = "\(MicrosoftGraphAPI.driveRootPath)/items/\(folderID)"
        }

        // 最後のフォルダ ID を取得
        let finalPathKey = "oneDrive/\(pathComponents.joined(separator: "/"))"
        if let id = RemoteFolderCacheStore.shared.folderID(
            accountID: accountID, pathKey: finalPathKey) {
            return id
        }
        throw OneDriveError.invalidResponse
    }

    // MARK: - uploadResumable

    /// createUploadSession → チャンク PUT でファイルをアップロードする。
    func uploadResumable(fileURL: URL,
                         remoteFolderID: String,
                         fileName: String) async throws -> String {
        let fileSize = try fileSizeOf(url: fileURL)
        logger.info("OneDrive: アップロード開始 file=\(fileName) size=\(fileSize)")

        var uploadSession = try await createUploadSession(
            folderItemID: remoteFolderID, fileName: fileName)

        let remoteFileID = try await uploadChunks(
            fileURL: fileURL,
            session: &uploadSession,
            fileSize: fileSize,
            fileName: fileName,
            folderItemID: remoteFolderID
        )

        logger.info("OneDrive: アップロード完了 remoteFileID=\(remoteFileID)")
        return remoteFileID
    }

    // MARK: - getRemoteHash

    /// hashes.quickXorHash を取得する。
    func getRemoteHash(remoteFileID: String) async throws -> String? {
        let token = try await validAccessToken()
        let url = URL(string: "\(MicrosoftGraphAPI.driveRootPath)/items/\(remoteFileID)?$select=file")!

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        try handleStatusCode(statusCode, data: data)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let file = json["file"] as? [String: Any],
              let hashes = file["hashes"] as? [String: Any] else {
            return nil
        }
        return hashes["quickXorHash"] as? String
    }

    // MARK: - setSharing

    /// createLink で共有リンクを作成する。
    func setSharing(remoteFileID: String, policy: SharingPolicy) async throws {
        guard policy.isShared else {
            logger.debug("OneDrive: 共有なし設定、スキップ")
            return
        }

        let token = try await validAccessToken()
        let url = URL(string: "\(MicrosoftGraphAPI.driveRootPath)/items/\(remoteFileID)/createLink")!

        let body: [String: Any] = [
            "type": odLinkType(from: policy.role),
            "scope": odScope(from: policy.scope)
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        guard (200..<300).contains(statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            throw OneDriveError.sharingFailed(statusCode: statusCode, body: bodyStr)
        }

        logger.info("OneDrive: 共有リンク作成完了 remoteFileID=\(remoteFileID)")
    }
}

// MARK: - Private: OAuth

private extension OneDriveConnector {

    @MainActor
    func performWebAuth(url: URL, callbackScheme: String) async throws -> URL {
        try await OAuthWebAuth.authenticate(url: url, callbackScheme: callbackScheme)
    }

    func exchangeCodeForTokens(code: String, codeVerifier: String) async throws {
        var request = URLRequest(url: URL(string: MicrosoftGraphAPI.tokenEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded",
                         forHTTPHeaderField: "Content-Type")

        let params: [String: String] = [
            "client_id": clientID,
            "code": code,
            "redirect_uri": MicrosoftGraphAPI.redirectURI,
            "grant_type": "authorization_code",
            "code_verifier": codeVerifier,
            "scope": MicrosoftGraphAPI.scope
        ]
        request.httpBody = formEncode(params)

        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        guard (200..<300).contains(statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OneDriveError.tokenExchangeFailed(statusCode: statusCode, body: body)
        }

        try saveTokens(from: data)
    }

    func refreshAccessToken() async throws {
        guard let refreshData = try KeychainHelper.load(key: refreshTokenKey),
              let refreshToken = String(data: refreshData, encoding: .utf8) else {
            throw OneDriveError.tokenRefreshFailed(statusCode: 0, body: "No refresh token")
        }

        var request = URLRequest(url: URL(string: MicrosoftGraphAPI.tokenEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded",
                         forHTTPHeaderField: "Content-Type")

        let params: [String: String] = [
            "client_id": clientID,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
            "redirect_uri": MicrosoftGraphAPI.redirectURI,
            "scope": MicrosoftGraphAPI.scope
        ]
        request.httpBody = formEncode(params)

        let (data, response) = try await retryWithBackoff {
            try await self.session.data(for: request)
        }
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        guard (200..<300).contains(statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OneDriveError.tokenRefreshFailed(statusCode: statusCode, body: body)
        }

        try saveTokens(from: data)
        logger.info("OneDrive: アクセストークン更新完了")
    }

    func validAccessToken() async throws -> String {
        if let expiryData = try KeychainHelper.load(key: tokenExpiryKey),
           let expiryString = String(data: expiryData, encoding: .utf8),
           let expiry = Double(expiryString) {
            let expiryDate = Date(timeIntervalSince1970: expiry)
            if expiryDate > Date(timeIntervalSinceNow: 5 * 60),
               let tokenData = try KeychainHelper.load(key: accessTokenKey),
               let token = String(data: tokenData, encoding: .utf8) {
                return token
            }
        }
        try await refreshAccessToken()
        guard let tokenData = try KeychainHelper.load(key: accessTokenKey),
              let token = String(data: tokenData, encoding: .utf8) else {
            throw OneDriveError.tokenRefreshFailed(statusCode: 0, body: "Token not found")
        }
        return token
    }

    func saveTokens(from data: Data) throws {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String,
              let expiresIn = json["expires_in"] as? Double else {
            throw OneDriveError.invalidResponse
        }
        try KeychainHelper.save(key: accessTokenKey,
                                data: accessToken.data(using: .utf8)!)
        let expiry = Date().timeIntervalSince1970 + expiresIn
        try KeychainHelper.save(key: tokenExpiryKey,
                                data: "\(expiry)".data(using: .utf8)!)
        if let refreshToken = json["refresh_token"] as? String {
            try KeychainHelper.save(key: refreshTokenKey,
                                    data: refreshToken.data(using: .utf8)!)
        }
    }

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

private extension OneDriveConnector {

    func findOrCreateFolder(name: String, parentAPIPath: String) async throws -> String {
        let token = try await validAccessToken()

        // /children で既存フォルダを検索
        let childrenURL = URL(string: "\(parentAPIPath):/\(name):")!
        var searchRequest = URLRequest(url: childrenURL)
        searchRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (searchData, searchResponse) = try await session.data(for: searchRequest)
        let searchStatus = (searchResponse as? HTTPURLResponse)?.statusCode ?? 0

        if searchStatus == 200,
           let json = try? JSONSerialization.jsonObject(with: searchData) as? [String: Any],
           let folderID = json["id"] as? String {
            logger.debug("OneDrive: 既存フォルダ発見 name=\(name) id=\(folderID)")
            return folderID
        }

        // 存在しない場合は作成
        return try await createFolder(name: name, parentAPIPath: parentAPIPath, token: token)
    }

    func createFolder(name: String, parentAPIPath: String, token: String) async throws -> String {
        let childrenURL = URL(string: "\(parentAPIPath)/children")!
        var request = URLRequest(url: childrenURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "name": name,
            "folder": [:] as [String: Any],
            "@microsoft.graph.conflictBehavior": "rename"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        guard (200..<300).contains(statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let folderID = json["id"] as? String else {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            throw OneDriveError.folderCreateFailed(statusCode: statusCode, body: bodyStr)
        }

        logger.info("OneDrive: フォルダ作成完了 name=\(name) id=\(folderID)")
        return folderID
    }
}

// MARK: - Private: Resumable Upload

private extension OneDriveConnector {

    func createUploadSession(folderItemID: String, fileName: String) async throws -> OneDriveUploadSession {
        let token = try await validAccessToken()
        let escapedName = fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileName
        let url = URL(string: "\(MicrosoftGraphAPI.driveRootPath)/items/\(folderItemID):/\(escapedName):/createUploadSession")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "item": [
                "@microsoft.graph.conflictBehavior": "rename",
                "name": fileName
            ] as [String: Any]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        guard (200..<300).contains(statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let uploadURLString = json["uploadUrl"] as? String,
              let uploadURL = URL(string: uploadURLString),
              let expirationString = json["expirationDateTime"] as? String else {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            throw OneDriveError.uploadSessionCreateFailed(statusCode: statusCode, body: bodyStr)
        }

        let expiration = ISO8601DateFormatter().date(from: expirationString) ?? Date(timeIntervalSinceNow: 86400)
        return OneDriveUploadSession(uploadURL: uploadURL, expirationDateTime: expiration)
    }

    func uploadChunks(fileURL: URL,
                      session uploadSession: inout OneDriveUploadSession,
                      fileSize: Int,
                      fileName: String,
                      folderItemID: String) async throws -> String {
        let fileHandle = try FileHandle(forReadingFrom: fileURL)
        defer { try? fileHandle.close() }

        var offset = 0
        let chunkSize = MicrosoftGraphAPI.chunkSize

        while offset < fileSize {
            // セッションの有効期限確認
            if !uploadSession.isValid {
                logger.warning("OneDrive: アップロードセッション期限切れ。再作成します")
                uploadSession = try await createUploadSession(
                    folderItemID: folderItemID, fileName: fileName)
                // 再開位置を問い合わせる
                offset = try await queryResumePosition(uploadSession: uploadSession,
                                                       fileSize: fileSize)
            }

            let remainingBytes = fileSize - offset
            let currentChunkSize = min(chunkSize, remainingBytes)

            try fileHandle.seek(toOffset: UInt64(offset))
            guard let chunkData = try fileHandle.read(upToCount: currentChunkSize) else {
                break
            }

            // OneDrive では uploadUrl への PUT に Authorization ヘッダーを含めない
            var request = URLRequest(url: uploadSession.uploadURL)
            request.httpMethod = "PUT"
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            let rangeEnd = offset + chunkData.count - 1
            request.setValue("bytes \(offset)-\(rangeEnd)/\(fileSize)",
                             forHTTPHeaderField: "Content-Range")
            request.setValue("\(chunkData.count)", forHTTPHeaderField: "Content-Length")
            request.httpBody = chunkData

            let (data, response) = try await retryWithBackoff {
                try await self.session.data(for: request)
            }
            let httpResponse = response as? HTTPURLResponse
            let statusCode = httpResponse?.statusCode ?? 0

            // 201/200: 完了
            if statusCode == 201 || statusCode == 200 {
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let fileID = json["id"] as? String else {
                    throw OneDriveError.invalidResponse
                }
                return fileID
            }

            // 202: Accepted（継続）
            if statusCode == 202 {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let nextRanges = json["nextExpectedRanges"] as? [String],
                   let firstRange = nextRanges.first,
                   let nextStart = Int(firstRange.components(separatedBy: "-").first ?? "") {
                    offset = nextStart
                } else {
                    offset += chunkData.count
                }
                logger.debug("OneDrive: チャンク送信完了 offset=\(offset)/\(fileSize)")
                continue
            }

            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            throw OneDriveError.chunkUploadFailed(statusCode: statusCode, body: bodyStr)
        }

        throw OneDriveError.invalidResponse
    }

    func queryResumePosition(uploadSession: OneDriveUploadSession, fileSize: Int) async throws -> Int {
        // GET uploadURL でアップロード状態を確認
        var request = URLRequest(url: uploadSession.uploadURL)
        request.httpMethod = "GET"

        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        if statusCode == 200,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let nextRanges = json["nextExpectedRanges"] as? [String],
           let firstRange = nextRanges.first,
           let nextStart = Int(firstRange.components(separatedBy: "-").first ?? "") {
            return nextStart
        }

        return 0
    }
}

// MARK: - Private: ユーティリティ

private extension OneDriveConnector {

    func handleStatusCode(_ statusCode: Int, data: Data) throws {
        switch statusCode {
        case 200..<300:
            return
        case 401:
            throw OneDriveError.tokenRefreshFailed(statusCode: 401, body: "Unauthorized")
        case 429:
            throw OneDriveError.rateLimitExceeded(retryAfter: 60)
        case 500..<600:
            throw OneDriveError.serverError(statusCode: statusCode)
        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OneDriveError.fileMetadataFailed(statusCode: statusCode, body: body)
        }
    }

    func retryWithBackoff<T>(
        maxAttempts: Int = 3,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        var attempt = 0
        var delay: TimeInterval = 1.0

        while true {
            do {
                return try await operation()
            } catch OneDriveError.rateLimitExceeded(let retryAfter) {
                attempt += 1
                if attempt >= maxAttempts { throw OneDriveError.rateLimitExceeded(retryAfter: retryAfter) }
                logger.warning("OneDrive: レートリミット。\(Int(retryAfter))秒待機 attempt=\(attempt)")
                try await Task.sleep(nanoseconds: UInt64(retryAfter * 1_000_000_000))
            } catch OneDriveError.serverError(let code) {
                attempt += 1
                if attempt >= maxAttempts { throw OneDriveError.serverError(statusCode: code) }
                logger.warning("OneDrive: サーバーエラー HTTP\(code)。\(delay)秒待機 attempt=\(attempt)")
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                delay = min(delay * 2, 60)
            } catch {
                throw error
            }
        }
    }

    func fileSizeOf(url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.size] as? Int) ?? 0
    }

    func formEncode(_ params: [String: String]) -> Data? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return params.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)
    }

    func odLinkType(from role: SharingRole) -> String {
        switch role {
        case .viewer: return "view"
        case .editor: return "edit"
        }
    }

    func odScope(from scope: SharingScope) -> String {
        switch scope {
        case .owner: return "users"
        case .organization: return "organization"
        case .anyone: return "anonymous"
        }
    }
}

// MARK: - Data+Base64URL

private extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

