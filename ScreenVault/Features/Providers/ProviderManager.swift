import Foundation
import SwiftData
import OSLog

// MARK: - ProviderManager

/// プロバイダアカウントのライフサイクル管理と、コネクタのファクトリ
@MainActor
final class ProviderManager: ObservableObject {

    // MARK: - Published state

    @Published private(set) var connectedAccounts: [ProviderAccount] = []

    // MARK: - Dependencies

    private let modelContext: ModelContext
    private let oauthManager: OAuthManager

    /// clientID 設定（本番では外部設定ファイルや Info.plist から取得する）
    /// ここでは構造体にまとめて管理
    struct ClientConfig {
        let clientID: String
        let redirectURI: String
        let scopes: [String]
    }

    private var clientConfigs: [ProviderType: ClientConfig] = [:]

    // MARK: - Active connectors cache (accountID → connector)

    private var connectorCache: [String: any ProviderConnector] = [:]

    // MARK: - Init

    init(modelContext: ModelContext, oauthManager: OAuthManager = .shared) {
        self.modelContext = modelContext
        self.oauthManager = oauthManager
        loadConnectedAccounts()
    }

    // MARK: - Configuration

    /// プロバイダの OAuth クライアント設定を登録する。
    /// アプリ起動時に App 層から呼ぶ。
    func registerClientConfig(_ config: ClientConfig, for provider: ProviderType) {
        clientConfigs[provider] = config
    }

    // MARK: - Public API

    /// 指定プロバイダへの接続（OAuth フロー実行 → アカウント保存）
    func connect(provider: ProviderType) async throws {
        SVLogger.provider.info("ProviderManager: connect \(provider.rawValue, privacy: .public)")

        guard let config = clientConfigs[provider] else {
            SVLogger.provider.error("ProviderManager: no client config for \(provider.rawValue, privacy: .public)")
            throw ScreenVaultError.unknown("クライアント設定が登録されていません: \(provider.rawValue)")
        }

        // OAuth フロー実行
        let tokens = try await oauthManager.startOAuthFlow(
            provider: provider,
            clientID: config.clientID,
            scopes: config.scopes,
            redirectURI: config.redirectURI
        )

        SVLogger.provider.info("ProviderManager: OAuth completed for \(provider.rawValue, privacy: .public)")

        // アカウントレコードを作成して保存
        let account = ProviderAccount(
            providerType: provider,
            userDisplay: displayName(from: tokens, provider: provider)
        )
        modelContext.insert(account)
        try modelContext.save()

        // コネクタを生成してキャッシュ
        if let connector = makeConnector(for: account, tokens: tokens, config: config) {
            connectorCache[account.accountID] = connector
        }

        connectedAccounts.append(account)
        SVLogger.provider.info("ProviderManager: account saved \(account.accountID, privacy: .public) provider=\(provider.rawValue, privacy: .public)")
    }

    /// 指定アカウントの切断（Keychain 削除 + SwiftData レコード削除）
    func disconnect(accountID: String) async throws {
        SVLogger.provider.info("ProviderManager: disconnect \(accountID, privacy: .public)")

        guard let account = connectedAccounts.first(where: { $0.accountID == accountID }) else {
            throw ScreenVaultError.providerNotConnected(accountID: accountID)
        }

        let provider = account.providerType

        // Keychain トークン削除（エラーは警告ログのみ）
        if let config = clientConfigs[provider] {
            do {
                try oauthManager.deleteTokens(provider: provider, clientID: config.clientID)
            } catch {
                SVLogger.provider.warning("ProviderManager: failed to delete tokens for \(accountID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        // コネクタキャッシュ削除
        connectorCache.removeValue(forKey: accountID)

        // SwiftData レコード削除
        modelContext.delete(account)
        try modelContext.save()

        connectedAccounts.removeAll { $0.accountID == accountID }
        SVLogger.provider.info("ProviderManager: disconnected \(accountID, privacy: .public)")
    }

    /// 指定アカウントのコネクタを返す。
    /// キャッシュに無ければ Keychain からトークンを復元して生成する。
    func connector(for accountID: String) -> (any ProviderConnector)? {
        // キャッシュヒット
        if let cached = connectorCache[accountID] {
            return cached
        }

        // Keychain からトークンを復元
        guard let account = connectedAccounts.first(where: { $0.accountID == accountID }),
              let config = clientConfigs[account.providerType]
        else {
            SVLogger.provider.warning("ProviderManager: connector not found for \(accountID, privacy: .public)")
            return nil
        }

        do {
            guard let tokens = try oauthManager.loadTokens(
                provider: account.providerType,
                clientID: config.clientID
            ) else {
                SVLogger.provider.warning("ProviderManager: no tokens in Keychain for \(accountID, privacy: .public)")
                return nil
            }
            let connector = makeConnector(for: account, tokens: tokens, config: config)
            if let connector {
                connectorCache[accountID] = connector
            }
            return connector
        } catch {
            SVLogger.provider.error("ProviderManager: failed to load tokens for \(accountID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Private helpers

    /// SwiftData から接続済みアカウントを読み込む
    private func loadConnectedAccounts() {
        do {
            let descriptor = FetchDescriptor<ProviderAccount>(
                sortBy: [SortDescriptor(\.createdAt)]
            )
            connectedAccounts = try modelContext.fetch(descriptor)
            SVLogger.provider.info("ProviderManager: loaded \(self.connectedAccounts.count) accounts")
        } catch {
            SVLogger.provider.error("ProviderManager: failed to load accounts: \(error.localizedDescription, privacy: .public)")
            connectedAccounts = []
        }
    }

    /// プロバイダごとのコネクタを生成するファクトリメソッド
    private func makeConnector(
        for account: ProviderAccount,
        tokens: OAuthTokens,
        config: ClientConfig
    ) -> (any ProviderConnector)? {
        switch account.providerType {
        case .googleDrive:
            return GoogleDriveConnector(
                account: account,
                tokens: tokens,
                clientID: config.clientID,
                redirectURI: config.redirectURI
            )
        case .oneDrive:
            return OneDriveConnector(
                account: account,
                tokens: tokens,
                clientID: config.clientID,
                redirectURI: config.redirectURI
            )
        case .dropbox:
            return DropboxConnector(
                account: account,
                tokens: tokens,
                clientID: config.clientID,
                redirectURI: config.redirectURI
            )
        case .iCloud:
            // iCloud は CloudKit ベースのため OAuth コネクタは不要
            SVLogger.provider.info("ProviderManager: iCloud connector is handled natively")
            return nil
        }
    }

    /// トークンからユーザー表示名を導出する（簡易実装、本番では userinfo エンドポイントを叩く）
    private func displayName(from tokens: OAuthTokens, provider: ProviderType) -> String {
        "\(provider.rawValue)-account"
    }
}

// MARK: - Stub コネクタ実装
// Phase 1.4〜1.6 で本実装に差し替える。
// ProviderConnector プロトコルを満たすための最小スタブ。

// MARK: GoogleDriveConnector

final class GoogleDriveConnector: ProviderConnector, @unchecked Sendable {
    let providerType: ProviderType = .googleDrive

    private let account: ProviderAccount
    private var tokens: OAuthTokens
    private let clientID: String
    private let redirectURI: String

    init(account: ProviderAccount, tokens: OAuthTokens, clientID: String, redirectURI: String) {
        self.account = account
        self.tokens = tokens
        self.clientID = clientID
        self.redirectURI = redirectURI
    }

    func authenticate() async throws {
        SVLogger.provider.info("GoogleDriveConnector: authenticate (re-auth) for \(self.account.accountID, privacy: .public)")
        let newTokens = try await OAuthManager.shared.startOAuthFlow(
            provider: .googleDrive,
            clientID: clientID,
            scopes: [],
            redirectURI: redirectURI
        )
        tokens = newTokens
    }

    func ensureFolder(pathComponents: [String]) async throws -> String {
        SVLogger.provider.info("GoogleDriveConnector: ensureFolder \(pathComponents.joined(separator: "/"), privacy: .public)")
        // Phase 1.4 で実装
        throw ScreenVaultError.unknown("GoogleDrive: ensureFolder は Phase 1.4 で実装予定")
    }

    func uploadResumable(fileURL: URL, remoteFolderID: String, fileName: String) async throws -> String {
        SVLogger.provider.info("GoogleDriveConnector: uploadResumable \(fileName, privacy: .public)")
        throw ScreenVaultError.unknown("GoogleDrive: uploadResumable は Phase 1.4 で実装予定")
    }

    func setSharing(remoteFileID: String, policy: SharingPolicy) async throws {
        SVLogger.provider.info("GoogleDriveConnector: setSharing \(remoteFileID, privacy: .public)")
        throw ScreenVaultError.unknown("GoogleDrive: setSharing は Phase 1.4 で実装予定")
    }

    func getRemoteHash(remoteFileID: String) async throws -> String? {
        SVLogger.provider.info("GoogleDriveConnector: getRemoteHash \(remoteFileID, privacy: .public)")
        throw ScreenVaultError.unknown("GoogleDrive: getRemoteHash は Phase 1.4 で実装予定")
    }
}

// MARK: OneDriveConnector

final class OneDriveConnector: ProviderConnector, @unchecked Sendable {
    let providerType: ProviderType = .oneDrive

    private let account: ProviderAccount
    private var tokens: OAuthTokens
    private let clientID: String
    private let redirectURI: String

    init(account: ProviderAccount, tokens: OAuthTokens, clientID: String, redirectURI: String) {
        self.account = account
        self.tokens = tokens
        self.clientID = clientID
        self.redirectURI = redirectURI
    }

    func authenticate() async throws {
        let newTokens = try await OAuthManager.shared.startOAuthFlow(
            provider: .oneDrive,
            clientID: clientID,
            scopes: [],
            redirectURI: redirectURI
        )
        tokens = newTokens
    }

    func ensureFolder(pathComponents: [String]) async throws -> String {
        throw ScreenVaultError.unknown("OneDrive: ensureFolder は Phase 1.5 で実装予定")
    }

    func uploadResumable(fileURL: URL, remoteFolderID: String, fileName: String) async throws -> String {
        throw ScreenVaultError.unknown("OneDrive: uploadResumable は Phase 1.5 で実装予定")
    }

    func setSharing(remoteFileID: String, policy: SharingPolicy) async throws {
        throw ScreenVaultError.unknown("OneDrive: setSharing は Phase 1.5 で実装予定")
    }

    func getRemoteHash(remoteFileID: String) async throws -> String? {
        throw ScreenVaultError.unknown("OneDrive: getRemoteHash は Phase 1.5 で実装予定")
    }
}

// MARK: DropboxConnector

final class DropboxConnector: ProviderConnector, @unchecked Sendable {
    let providerType: ProviderType = .dropbox

    private let account: ProviderAccount
    private var tokens: OAuthTokens
    private let clientID: String
    private let redirectURI: String

    init(account: ProviderAccount, tokens: OAuthTokens, clientID: String, redirectURI: String) {
        self.account = account
        self.tokens = tokens
        self.clientID = clientID
        self.redirectURI = redirectURI
    }

    func authenticate() async throws {
        let newTokens = try await OAuthManager.shared.startOAuthFlow(
            provider: .dropbox,
            clientID: clientID,
            scopes: [],
            redirectURI: redirectURI
        )
        tokens = newTokens
    }

    func ensureFolder(pathComponents: [String]) async throws -> String {
        throw ScreenVaultError.unknown("Dropbox: ensureFolder は Phase 1.6 で実装予定")
    }

    func uploadResumable(fileURL: URL, remoteFolderID: String, fileName: String) async throws -> String {
        throw ScreenVaultError.unknown("Dropbox: uploadResumable は Phase 1.6 で実装予定")
    }

    func setSharing(remoteFileID: String, policy: SharingPolicy) async throws {
        throw ScreenVaultError.unknown("Dropbox: setSharing は Phase 1.6 で実装予定")
    }

    func getRemoteHash(remoteFileID: String) async throws -> String? {
        throw ScreenVaultError.unknown("Dropbox: getRemoteHash は Phase 1.6 で実装予定")
    }
}
