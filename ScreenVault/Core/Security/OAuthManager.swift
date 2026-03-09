import Foundation
import AuthenticationServices
import CryptoKit
import OSLog

// MARK: - OAuthTokens

/// OAuth 2.0 トークンセット
struct OAuthTokens: Codable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int          // 秒単位
    let tokenType: String       // 通常 "Bearer"

    /// 取得時刻から有効期限 Date を算出する
    func expirationDate(from referenceDate: Date = .now) -> Date {
        referenceDate.addingTimeInterval(TimeInterval(expiresIn))
    }

    enum CodingKeys: String, CodingKey {
        case accessToken  = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn    = "expires_in"
        case tokenType    = "token_type"
    }
}

// MARK: - Provider OAuth メタデータ

/// プロバイダごとの OAuth エンドポイント情報
struct OAuthProviderConfig {
    let authorizationEndpoint: URL
    let tokenEndpoint: URL
    let defaultScopes: [String]
}

extension ProviderType {
    var oauthConfig: OAuthProviderConfig {
        switch self {
        case .googleDrive:
            return OAuthProviderConfig(
                authorizationEndpoint: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
                tokenEndpoint: URL(string: "https://oauth2.googleapis.com/token")!,
                defaultScopes: ["https://www.googleapis.com/auth/drive.file", "openid", "profile", "email"]
            )
        case .oneDrive:
            return OAuthProviderConfig(
                authorizationEndpoint: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")!,
                tokenEndpoint: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!,
                defaultScopes: ["Files.ReadWrite.AppFolder", "offline_access", "User.Read"]
            )
        case .dropbox:
            return OAuthProviderConfig(
                authorizationEndpoint: URL(string: "https://www.dropbox.com/oauth2/authorize")!,
                tokenEndpoint: URL(string: "https://api.dropboxapi.com/oauth2/token")!,
                defaultScopes: ["files.content.write", "files.content.read", "account_info.read"]
            )
        case .iCloud:
            // iCloud は CloudKit / 独自フレームワーク経由のため OAuth は使わないが、型を合わせるためにダミーを用意
            return OAuthProviderConfig(
                authorizationEndpoint: URL(string: "https://appleid.apple.com/auth/authorize")!,
                tokenEndpoint: URL(string: "https://appleid.apple.com/auth/token")!,
                defaultScopes: []
            )
        }
    }

    /// Keychain に保存するときのキープレフィックス
    var keychainPrefix: String { "screenvault.oauth.\(rawValue)" }
}

// MARK: - OAuthManager

/// OAuth 2.0 + PKCE 認証フロー共通実装
final class OAuthManager: NSObject, @unchecked Sendable {

    // MARK: Singleton

    static let shared = OAuthManager()
    private override init() {}

    // MARK: - PKCE

    /// code_verifier を生成する (RFC 7636 Section 4.1: 43-128 文字の URL-safe 文字列)
    private func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        let result = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard result == errSecSuccess else {
            // フォールバック: UUID ベース
            return UUID().uuidString.replacingOccurrences(of: "-", with: "")
        }
        // Base64URL encoding (パディングなし)
        return Data(bytes).base64URLEncodedString()
    }

    /// code_challenge = BASE64URL(SHA-256(ASCII(code_verifier)))
    private func codeChallenge(for verifier: String) -> String {
        let data = Data(verifier.utf8)
        let digest = SHA256.hash(data: data)
        return Data(digest).base64URLEncodedString()
    }

    // MARK: - OAuth フロー

    /// OAuth 2.0 + PKCE 認証フローを実行し、トークンを返す。
    /// - Parameters:
    ///   - provider: プロバイダの種類
    ///   - clientID: OAuth クライアント ID
    ///   - scopes: 要求スコープ (空の場合はプロバイダデフォルトを使用)
    ///   - redirectURI: リダイレクト URI（カスタムスキーム）
    /// - Returns: 取得した OAuthTokens
    @MainActor
    func startOAuthFlow(
        provider: ProviderType,
        clientID: String,
        scopes: [String],
        redirectURI: String
    ) async throws -> OAuthTokens {
        SVLogger.auth.info("OAuthManager: starting OAuth flow for \(provider.rawValue, privacy: .public)")

        let codeVerifier  = generateCodeVerifier()
        let codeChallenge = codeChallenge(for: codeVerifier)
        let state         = UUID().uuidString

        let config  = provider.oauthConfig
        let scopeList = scopes.isEmpty ? config.defaultScopes : scopes

        // 認可エンドポイント URL を構築
        var components = URLComponents(url: config.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type",            value: "code"),
            URLQueryItem(name: "client_id",                value: clientID),
            URLQueryItem(name: "redirect_uri",             value: redirectURI),
            URLQueryItem(name: "scope",                    value: scopeList.joined(separator: " ")),
            URLQueryItem(name: "state",                    value: state),
            URLQueryItem(name: "code_challenge",           value: codeChallenge),
            URLQueryItem(name: "code_challenge_method",    value: "S256"),
            URLQueryItem(name: "access_type",              value: "offline"),   // Google: リフレッシュトークン要求
            URLQueryItem(name: "prompt",                   value: "consent"),   // Google: 毎回同意画面を表示
            URLQueryItem(name: "token_access_type",        value: "offline"),   // Dropbox: リフレッシュトークン要求
        ]
        guard let authURL = components.url else {
            throw ScreenVaultError.oauthCallbackURLInvalid
        }

        SVLogger.auth.debug("OAuthManager: authorization URL built for \(provider.rawValue, privacy: .public)")

        // ASWebAuthenticationSession でブラウザ認証
        let callbackURL = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: self.scheme(from: redirectURI)
            ) { callbackURL, error in
                if let error {
                    if (error as NSError).code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                        continuation.resume(throwing: ScreenVaultError.oauthUserCancelled)
                    } else {
                        continuation.resume(throwing: error)
                    }
                    return
                }
                guard let url = callbackURL else {
                    continuation.resume(throwing: ScreenVaultError.oauthCallbackURLInvalid)
                    return
                }
                continuation.resume(returning: url)
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = true
            session.start()
        }

        // コールバック URL から認可コードと state を取り出す
        guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
              let returnedState = components.queryItems?.first(where: { $0.name == "state" })?.value,
              returnedState == state
        else {
            throw ScreenVaultError.oauthAuthorizationCodeMissing
        }

        SVLogger.auth.info("OAuthManager: authorization code obtained for \(provider.rawValue, privacy: .public)")

        // 認可コードをトークンに交換
        let tokens = try await exchangeCodeForTokens(
            provider: provider,
            code: code,
            codeVerifier: codeVerifier,
            clientID: clientID,
            redirectURI: redirectURI
        )

        // Keychain に保存
        try saveTokens(tokens, provider: provider, clientID: clientID)

        SVLogger.auth.info("OAuthManager: tokens saved for \(provider.rawValue, privacy: .public)")
        return tokens
    }

    /// アクセストークンをリフレッシュトークンで更新する。
    @MainActor
    func refreshAccessToken(
        provider: ProviderType,
        clientID: String,
        refreshToken: String
    ) async throws -> OAuthTokens {
        SVLogger.auth.info("OAuthManager: refreshing token for \(provider.rawValue, privacy: .public)")

        let config = provider.oauthConfig

        var body: [String: String] = [
            "grant_type":    "refresh_token",
            "refresh_token": refreshToken,
            "client_id":     clientID,
        ]

        // Dropbox はスコープを再指定する必要がある場合がある（必要に応じて追加）
        if provider == .dropbox {
            body["token_access_type"] = "offline"
        }

        let tokens = try await postTokenRequest(endpoint: config.tokenEndpoint, body: body)

        // Keychain を更新（リフレッシュ後は新しいリフレッシュトークンが返らないこともある）
        let updatedTokens: OAuthTokens
        if tokens.refreshToken != nil {
            // 新しいリフレッシュトークンが含まれていればそのまま使う
            updatedTokens = tokens
        } else {
            // リフレッシュトークンを引き継ぐ
            updatedTokens = OAuthTokens(
                accessToken: tokens.accessToken,
                refreshToken: refreshToken,
                expiresIn: tokens.expiresIn,
                tokenType: tokens.tokenType
            )
        }

        try saveTokens(updatedTokens, provider: provider, clientID: clientID)

        SVLogger.auth.info("OAuthManager: token refreshed for \(provider.rawValue, privacy: .public)")
        return updatedTokens
    }

    // MARK: - Keychain 操作

    private func keychainKey(for provider: ProviderType, suffix: String) -> String {
        "\(provider.keychainPrefix).\(suffix)"
    }

    func saveTokens(_ tokens: OAuthTokens, provider: ProviderType, clientID: String) throws {
        let encoder = JSONEncoder()
        let data = try encoder.encode(tokens)
        let key = keychainKey(for: provider, suffix: clientID)
        do {
            try KeychainHelper.save(key: key, data: data)
        } catch {
            throw ScreenVaultError.keychainSaveFailed(underlying: error)
        }
    }

    func loadTokens(provider: ProviderType, clientID: String) throws -> OAuthTokens? {
        let key = keychainKey(for: provider, suffix: clientID)
        do {
            guard let data = try KeychainHelper.load(key: key) else { return nil }
            return try JSONDecoder().decode(OAuthTokens.self, from: data)
        } catch let error as ScreenVaultError {
            throw error
        } catch {
            throw ScreenVaultError.keychainLoadFailed(underlying: error)
        }
    }

    func deleteTokens(provider: ProviderType, clientID: String) throws {
        let key = keychainKey(for: provider, suffix: clientID)
        try KeychainHelper.delete(key: key)
    }

    // MARK: - Private helpers

    /// 認可コードをアクセストークンに交換する
    private func exchangeCodeForTokens(
        provider: ProviderType,
        code: String,
        codeVerifier: String,
        clientID: String,
        redirectURI: String
    ) async throws -> OAuthTokens {
        let body: [String: String] = [
            "grant_type":    "authorization_code",
            "code":          code,
            "redirect_uri":  redirectURI,
            "client_id":     clientID,
            "code_verifier": codeVerifier,
        ]
        return try await postTokenRequest(endpoint: provider.oauthConfig.tokenEndpoint, body: body)
    }

    /// トークンエンドポイントに POST し、OAuthTokens を返す
    private func postTokenRequest(endpoint: URL, body: [String: String]) async throws -> OAuthTokens {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
            .map { "\($0.key)=\(percentEncoded($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "(empty)"
            SVLogger.auth.error("OAuthManager: token request failed status=\(statusCode) body=\(body, privacy: .private)")
            throw ScreenVaultError.oauthTokenRequestFailed(statusCode: statusCode, body: body)
        }

        do {
            return try JSONDecoder().decode(OAuthTokens.self, from: data)
        } catch {
            throw ScreenVaultError.oauthTokenDecodeFailed(underlying: error)
        }
    }

    private func percentEncoded(_ string: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }

    /// リダイレクト URI からカスタムスキームを取り出す
    private func scheme(from redirectURI: String) -> String {
        URL(string: redirectURI)?.scheme ?? "screenvault"
    }
}

// MARK: - ASWebAuthenticationPresentationContextProviding

extension OAuthManager: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // メインウィンドウを探す。見つからなければ新しいウィンドウを返す
        NSApplication.shared.windows.first { $0.isKeyWindow }
        ?? NSApplication.shared.windows.first
        ?? NSWindow()
    }
}

// MARK: - Data Base64URL helper

private extension Data {
    /// RFC 4648 Section 5 準拠の Base64URL エンコード（パディングなし）
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
