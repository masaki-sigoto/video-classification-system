import Foundation
import CryptoKit
import OSLog

// MARK: - Dropbox API 定数

private enum DropboxAPI {
    static let authorizationEndpoint = "https://www.dropbox.com/oauth2/authorize"
    static let tokenEndpoint = "https://api.dropboxapi.com/oauth2/token"
    static let apiBaseURL = "https://api.dropboxapi.com/2"
    static let contentBaseURL = "https://content.dropboxapi.com/2"

    // エンドポイント
    static let createFolderURL = "\(apiBaseURL)/files/create_folder_v2"
    static let uploadURL = "\(contentBaseURL)/files/upload"
    static let uploadSessionStartURL = "\(contentBaseURL)/files/upload_session/start"
    static let uploadSessionAppendURL = "\(contentBaseURL)/files/upload_session/append_v2"
    static let uploadSessionFinishURL = "\(contentBaseURL)/files/upload_session/finish"
    static let getMetadataURL = "\(apiBaseURL)/files/get_metadata"
    static let sharingURL = "\(apiBaseURL)/sharing/create_shared_link_with_settings"

    static let scope = "files.content.write files.content.read sharing.write"
    static let redirectURI = "com.screenvault.app:/oauth2callback/dropbox"

    /// 直接アップロードの上限（150MB）
    static let directUploadLimit = 150 * 1024 * 1024

    /// セッションアップロードのチャンクサイズ（4MB）
    static let chunkSize = 4 * 1024 * 1024

    /// セッション最大有効期間（7日）
    static let sessionMaxTTL: TimeInterval = 7 * 24 * 60 * 60
}

// MARK: - Dropbox エラー

enum DropboxError: Error, LocalizedError {
    case missingClientCredentials
    case authCodeNotReceived
    case tokenExchangeFailed(statusCode: Int, body: String)
    case tokenRefreshFailed(statusCode: Int, body: String)
    case folderCreateFailed(statusCode: Int, body: String)
    case uploadFailed(statusCode: Int, body: String)
    case sessionStartFailed(statusCode: Int, body: String)
    case sessionAppendFailed(statusCode: Int, body: String)
    case sessionFinishFailed(statusCode: Int, body: String)
    case sessionExpired
    case metadataFailed(statusCode: Int, body: String)
    case sharingFailed(statusCode: Int, body: String)
    case rateLimitExceeded(retryAfter: TimeInterval)
    case serverError(statusCode: Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingClientCredentials:
            return "Dropbox クライアントIDが設定されていません"
        case .authCodeNotReceived:
            return "認可コードが受信できませんでした"
        case .tokenExchangeFailed(let code, let body):
            return "トークン交換失敗 (HTTP \(code)): \(body)"
        case .tokenRefreshFailed(let code, let body):
            return "トークン更新失敗 (HTTP \(code)): \(body)"
        case .folderCreateFailed(let code, let body):
            return "フォルダ作成失敗 (HTTP \(code)): \(body)"
        case .uploadFailed(let code, let body):
            return "アップロード失敗 (HTTP \(code)): \(body)"
        case .sessionStartFailed(let code, let body):
            return "セッション開始失敗 (HTTP \(code)): \(body)"
        case .sessionAppendFailed(let code, let body):
            return "セッション追記失敗 (HTTP \(code)): \(body)"
        case .sessionFinishFailed(let code, let body):
            return "セッション完了失敗 (HTTP \(code)): \(body)"
        case .sessionExpired:
            return "アップロードセッションが期限切れです（7日を超えました）"
        case .metadataFailed(let code, let body):
            return "メタデータ取得失敗 (HTTP \(code)): \(body)"
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

// MARK: - DropboxConnector

/// Dropbox プロバイダコネクタ
/// URLSession のみ使用（サードパーティSDK不使用）
final class DropboxConnector: ProviderConnector, @unchecked Sendable {

    // MARK: ProviderConnector

    var providerType: ProviderType { .dropbox }

    // MARK: - 設定

    /// OAuth クライアント ID（Info.plist の DBX_APP_KEY キーから読み込む）
    private let appKey: String

    /// 紐付くアカウント ID
    let accountID: String

    // MARK: - 内部状態

    private let session: URLSession
    private let logger = SVLogger.provider

    // MARK: - Keychain キー

    private var accessTokenKey: String { "dbx_access_\(accountID)" }
    private var refreshTokenKey: String { "dbx_refresh_\(accountID)" }
    private var tokenExpiryKey: String { "dbx_expiry_\(accountID)" }

    // MARK: - init

    init(accountID: String, session: URLSession = .shared) throws {
        guard let appKey = Bundle.main.object(forInfoDictionaryKey: "DBX_APP_KEY") as? String,
              !appKey.isEmpty else {
            throw DropboxError.missingClientCredentials
        }
        self.appKey = appKey
        self.accountID = accountID
        self.session = session
    }

    // MARK: - authenticate

    /// OAuth 2.0 + PKCE 認証（token_access_type=offline でリフレッシュトークンも取得）
    func authenticate() async throws {
        logger.info("Dropbox: 認証開始 accountID=\(self.accountID)")

        let (codeVerifier, codeChallenge) = generatePKCE()
        let state = UUID().uuidString

        var components = URLComponents(string: DropboxAPI.authorizationEndpoint)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: appKey),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: DropboxAPI.redirectURI),
            URLQueryItem(name: "scope", value: DropboxAPI.scope),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "token_access_type", value: "offline")
        ]

        guard let authURL = components.url else { throw DropboxError.invalidResponse }

        let callbackURL = try await performWebAuth(url: authURL,
                                                   callbackScheme: "com.screenvault.app")

        guard let queryItems = URLComponents(url: callbackURL,
                                             resolvingAgainstBaseURL: false)?.queryItems,
              let code = queryItems.first(where: { $0.name == "code" })?.value else {
            throw DropboxError.authCodeNotReceived
        }

        try await exchangeCodeForTokens(code: code, codeVerifier: codeVerifier)
        logger.info("Dropbox: 認証完了 accountID=\(self.accountID)")
    }

    // MARK: - ensureFolder

    /// /files/create_folder_v2 でフォルダ階層を確保する。
    func ensureFolder(pathComponents: [String]) async throws -> String {
        var accumulatedPath = ""
        var resultPath = ""

        for component in pathComponents {
            accumulatedPath += "/\(component)"
            let cacheKey = "dropbox\(accumulatedPath)"

            if let cachedID = RemoteFolderCacheStore.shared.folderID(
                accountID: accountID, pathKey: cacheKey) {
                resultPath = cachedID
                continue
            }

            let remotePath = try await findOrCreateFolder(path: accumulatedPath)
            RemoteFolderCacheStore.shared.setFolderID(
                accountID: accountID, pathKey: cacheKey, folderID: remotePath)
            resultPath = remotePath
        }

        return resultPath
    }

    // MARK: - uploadResumable

    /// 150MB 以下は /files/upload、150MB 超は upload_session を使う。
    func uploadResumable(fileURL: URL,
                         remoteFolderID: String,
                         fileName: String) async throws -> String {
        let fileSize = try fileSizeOf(url: fileURL)
        let remotePath = "\(remoteFolderID)/\(fileName)"

        logger.info("Dropbox: アップロード開始 file=\(fileName) size=\(fileSize)")

        if fileSize <= DropboxAPI.directUploadLimit {
            return try await directUpload(fileURL: fileURL, remotePath: remotePath)
        } else {
            return try await sessionUpload(fileURL: fileURL,
                                           remotePath: remotePath,
                                           fileSize: fileSize)
        }
    }

    // MARK: - getRemoteHash

    /// Dropbox content_hash を取得する。
    /// Dropbox は /files/get_metadata でコンテンツハッシュを返す。
    func getRemoteHash(remoteFileID: String) async throws -> String? {
        let token = try await validAccessToken()
        var request = URLRequest(url: URL(string: DropboxAPI.getMetadataURL)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "path": remoteFileID,
            "include_media_info": false
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        guard (200..<300).contains(statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            throw DropboxError.metadataFailed(statusCode: statusCode, body: bodyStr)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json["content_hash"] as? String
    }

    // MARK: - setSharing

    /// /sharing/create_shared_link_with_settings で共有リンクを作成する。
    func setSharing(remoteFileID: String, policy: SharingPolicy) async throws {
        guard policy.isShared else {
            logger.debug("Dropbox: 共有なし設定、スキップ")
            return
        }

        let token = try await validAccessToken()
        var request = URLRequest(url: URL(string: DropboxAPI.sharingURL)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var settings: [String: Any] = [
            "access": dbxAccessLevel(from: policy.role)
        ]
        if policy.scope == .anyone {
            settings["audience"] = "public"
        } else if policy.scope == .organization {
            settings["audience"] = "team"
        } else {
            settings["audience"] = "no_one"
        }

        let body: [String: Any] = [
            "path": remoteFileID,
            "settings": settings
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        // 409 は "shared_link_already_exists" → 既存リンクがあれば許容
        if statusCode == 409 {
            logger.info("Dropbox: 共有リンク既存。スキップ")
            return
        }

        guard (200..<300).contains(statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            throw DropboxError.sharingFailed(statusCode: statusCode, body: bodyStr)
        }

        logger.info("Dropbox: 共有リンク作成完了 path=\(remoteFileID)")
    }
}

// MARK: - Private: OAuth

private extension DropboxConnector {

    @MainActor
    func performWebAuth(url: URL, callbackScheme: String) async throws -> URL {
        try await OAuthWebAuth.authenticate(url: url, callbackScheme: callbackScheme)
    }

    func exchangeCodeForTokens(code: String, codeVerifier: String) async throws {
        var request = URLRequest(url: URL(string: DropboxAPI.tokenEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded",
                         forHTTPHeaderField: "Content-Type")

        let params: [String: String] = [
            "code": code,
            "grant_type": "authorization_code",
            "client_id": appKey,
            "redirect_uri": DropboxAPI.redirectURI,
            "code_verifier": codeVerifier
        ]
        request.httpBody = formEncode(params)

        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        guard (200..<300).contains(statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw DropboxError.tokenExchangeFailed(statusCode: statusCode, body: body)
        }

        try saveTokens(from: data)
    }

    func refreshAccessToken() async throws {
        guard let refreshData = try KeychainHelper.load(key: refreshTokenKey),
              let refreshToken = String(data: refreshData, encoding: .utf8) else {
            throw DropboxError.tokenRefreshFailed(statusCode: 0, body: "No refresh token")
        }

        var request = URLRequest(url: URL(string: DropboxAPI.tokenEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded",
                         forHTTPHeaderField: "Content-Type")

        let params: [String: String] = [
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
            "client_id": appKey
        ]
        request.httpBody = formEncode(params)

        let (data, response) = try await retryWithBackoff {
            try await self.session.data(for: request)
        }
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        guard (200..<300).contains(statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw DropboxError.tokenRefreshFailed(statusCode: statusCode, body: body)
        }

        try saveTokens(from: data, preserveRefreshToken: true)
        logger.info("Dropbox: アクセストークン更新完了")
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
            throw DropboxError.tokenRefreshFailed(statusCode: 0, body: "Token not found")
        }
        return token
    }

    func saveTokens(from data: Data, preserveRefreshToken: Bool = false) throws {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String else {
            throw DropboxError.invalidResponse
        }

        try KeychainHelper.save(key: accessTokenKey,
                                data: accessToken.data(using: .utf8)!)

        if let expiresIn = json["expires_in"] as? Double {
            let expiry = Date().timeIntervalSince1970 + expiresIn
            try KeychainHelper.save(key: tokenExpiryKey,
                                    data: "\(expiry)".data(using: .utf8)!)
        }

        if !preserveRefreshToken,
           let refreshToken = json["refresh_token"] as? String {
            try KeychainHelper.save(key: refreshTokenKey,
                                    data: refreshToken.data(using: .utf8)!)
        }
    }

    func generatePKCE() -> (verifier: String, challenge: String) {
        var buffer = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, buffer.count, &buffer)
        let verifier = Data(buffer).base64URLEncoded()

        let verifierData = Data(verifier.utf8)
        let hash = SHA256.hash(data: verifierData)
        let challenge = Data(hash).base64URLEncoded()
        return (verifier, challenge)
    }
}

// MARK: - Private: フォルダ管理

private extension DropboxConnector {

    func findOrCreateFolder(path: String) async throws -> String {
        let token = try await validAccessToken()
        var request = URLRequest(url: URL(string: DropboxAPI.createFolderURL)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "path": path,
            "autorename": false
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        // 200: 作成成功
        if (200..<300).contains(statusCode) {
            logger.info("Dropbox: フォルダ作成完了 path=\(path)")
            return path
        }

        // 409: フォルダが既に存在する場合も成功とみなす
        if statusCode == 409,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any],
           let tag = error[".tag"] as? String,
           tag == "path",
           let pathError = error["path"] as? [String: Any],
           let pathTag = pathError[".tag"] as? String,
           pathTag == "conflict" {
            logger.debug("Dropbox: フォルダ既存 path=\(path)")
            return path
        }

        let bodyStr = String(data: data, encoding: .utf8) ?? ""
        throw DropboxError.folderCreateFailed(statusCode: statusCode, body: bodyStr)
    }
}

// MARK: - Private: アップロード

private extension DropboxConnector {

    /// 150MB 以下のファイルを直接アップロードする。
    /// URLSession.upload(for:fromFile:) を使い、メモリに全データを乗せない。
    func directUpload(fileURL: URL, remotePath: String) async throws -> String {
        let token = try await validAccessToken()

        var request = URLRequest(url: URL(string: DropboxAPI.uploadURL)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        let apiArgs: [String: Any] = [
            "path": remotePath,
            "mode": "overwrite",
            "autorename": true,
            "mute": false
        ]
        let apiArgsJSON = try JSONSerialization.data(withJSONObject: apiArgs)
        let apiArgsString = String(data: apiArgsJSON, encoding: .utf8) ?? "{}"
        request.setValue(apiArgsString, forHTTPHeaderField: "Dropbox-API-Arg")

        let (data, response) = try await retryWithBackoff {
            try await self.session.upload(for: request, fromFile: fileURL)
        }
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        guard (200..<300).contains(statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String else {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            throw DropboxError.uploadFailed(statusCode: statusCode, body: bodyStr)
        }

        logger.info("Dropbox: 直接アップロード完了 path=\(remotePath) id=\(id)")
        return id
    }

    /// upload_session/start → append → finish でファイルをアップロードする。
    func sessionUpload(fileURL: URL,
                       remotePath: String,
                       fileSize: Int) async throws -> String {
        let sessionID = try await startUploadSession()
        logger.debug("Dropbox: セッション開始 sessionID=\(sessionID)")

        let fileHandle = try FileHandle(forReadingFrom: fileURL)
        defer { try? fileHandle.close() }

        var offset = 0
        let chunkSize = DropboxAPI.chunkSize
        let sessionStartTime = Date()

        // 最終チャンク以外は append
        while offset + chunkSize < fileSize {
            // セッション最大7日の確認
            if Date().timeIntervalSince(sessionStartTime) > DropboxAPI.sessionMaxTTL {
                throw DropboxError.sessionExpired
            }

            try fileHandle.seek(toOffset: UInt64(offset))
            guard let chunkData = try fileHandle.read(upToCount: chunkSize) else {
                break
            }

            try await appendToSession(sessionID: sessionID,
                                      offset: offset,
                                      data: chunkData)
            offset += chunkData.count
            logger.debug("Dropbox: チャンク追記 offset=\(offset)/\(fileSize)")
        }

        // 最終チャンクを読み込んで finish
        try fileHandle.seek(toOffset: UInt64(offset))
        let finalChunkData = try fileHandle.read(upToCount: fileSize - offset) ?? Data()

        let remoteID = try await finishSession(sessionID: sessionID,
                                               offset: offset,
                                               finalData: finalChunkData,
                                               remotePath: remotePath)
        logger.info("Dropbox: セッションアップロード完了 id=\(remoteID)")
        return remoteID
    }

    /// upload_session/start でセッションを開始する。
    func startUploadSession() async throws -> String {
        let token = try await validAccessToken()
        var request = URLRequest(url: URL(string: DropboxAPI.uploadSessionStartURL)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        let apiArgs: [String: Any] = ["close": false]
        let apiArgsJSON = try JSONSerialization.data(withJSONObject: apiArgs)
        request.setValue(String(data: apiArgsJSON, encoding: .utf8) ?? "{}",
                         forHTTPHeaderField: "Dropbox-API-Arg")
        request.httpBody = Data()  // 空ボディでセッション開始

        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        guard (200..<300).contains(statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessionID = json["session_id"] as? String else {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            throw DropboxError.sessionStartFailed(statusCode: statusCode, body: bodyStr)
        }

        return sessionID
    }

    /// upload_session/append_v2 でチャンクを追記する。
    func appendToSession(sessionID: String, offset: Int, data chunkData: Data) async throws {
        let token = try await validAccessToken()
        var request = URLRequest(url: URL(string: DropboxAPI.uploadSessionAppendURL)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        let cursor: [String: Any] = [
            "session_id": sessionID,
            "offset": offset
        ]
        let apiArgs: [String: Any] = [
            "cursor": cursor,
            "close": false
        ]
        let apiArgsJSON = try JSONSerialization.data(withJSONObject: apiArgs)
        request.setValue(String(data: apiArgsJSON, encoding: .utf8) ?? "{}",
                         forHTTPHeaderField: "Dropbox-API-Arg")
        request.httpBody = chunkData

        let (data, response) = try await retryWithBackoff {
            try await self.session.data(for: request)
        }
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        guard statusCode == 200 else {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            throw DropboxError.sessionAppendFailed(statusCode: statusCode, body: bodyStr)
        }
    }

    /// upload_session/finish でセッションを完了し、ファイル ID を返す。
    func finishSession(sessionID: String,
                       offset: Int,
                       finalData: Data,
                       remotePath: String) async throws -> String {
        let token = try await validAccessToken()
        var request = URLRequest(url: URL(string: DropboxAPI.uploadSessionFinishURL)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        let cursor: [String: Any] = [
            "session_id": sessionID,
            "offset": offset
        ]
        let commitInfo: [String: Any] = [
            "path": remotePath,
            "mode": "overwrite",
            "autorename": true,
            "mute": false
        ]
        let apiArgs: [String: Any] = [
            "cursor": cursor,
            "commit": commitInfo
        ]
        let apiArgsJSON = try JSONSerialization.data(withJSONObject: apiArgs)
        request.setValue(String(data: apiArgsJSON, encoding: .utf8) ?? "{}",
                         forHTTPHeaderField: "Dropbox-API-Arg")
        request.httpBody = finalData

        let (data, response) = try await retryWithBackoff {
            try await self.session.data(for: request)
        }
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        guard (200..<300).contains(statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String else {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            throw DropboxError.sessionFinishFailed(statusCode: statusCode, body: bodyStr)
        }

        return id
    }
}

// MARK: - Private: Dropbox content_hash

/// Dropbox content_hash の計算。
/// ファイルを 4MB ブロックに分割し、各ブロックの SHA-256 を連結して再度 SHA-256 を計算する。
extension DropboxConnector {
    static func computeContentHash(data: Data) -> String {
        let blockSize = 4 * 1024 * 1024
        var blockHashes = Data()

        var offset = 0
        while offset < data.count {
            let end = min(offset + blockSize, data.count)
            let block = data[offset..<end]
            let blockHash = SHA256.hash(data: block)
            blockHashes.append(contentsOf: blockHash)
            offset = end
        }

        let finalHash = SHA256.hash(data: blockHashes)
        return finalHash.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Private: ユーティリティ

private extension DropboxConnector {

    func retryWithBackoff<T>(
        maxAttempts: Int = 3,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        var attempt = 0
        var delay: TimeInterval = 1.0

        while true {
            do {
                return try await operation()
            } catch DropboxError.rateLimitExceeded(let retryAfter) {
                attempt += 1
                if attempt >= maxAttempts { throw DropboxError.rateLimitExceeded(retryAfter: retryAfter) }
                logger.warning("Dropbox: レートリミット。\(Int(retryAfter))秒待機 attempt=\(attempt)")
                try await Task.sleep(nanoseconds: UInt64(retryAfter * 1_000_000_000))
            } catch DropboxError.serverError(let code) {
                attempt += 1
                if attempt >= maxAttempts { throw DropboxError.serverError(statusCode: code) }
                logger.warning("Dropbox: サーバーエラー HTTP\(code)。\(delay)秒待機 attempt=\(attempt)")
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

    func dbxAccessLevel(from role: SharingRole) -> String {
        switch role {
        case .viewer: return "viewer"
        case .editor: return "editor"
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
