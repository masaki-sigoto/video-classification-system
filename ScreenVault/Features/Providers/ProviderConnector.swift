import Foundation

/// クラウドプロバイダの共通インターフェース
protocol ProviderConnector: Sendable {
    var providerType: ProviderType { get }

    /// OAuth認証を開始し、トークンをKeychainに格納する
    func authenticate() async throws

    /// 必要なフォルダ階層をリモートに確保し、フォルダIDを返す
    func ensureFolder(pathComponents: [String]) async throws -> String

    /// 再開可能アップロードを実行する
    func uploadResumable(fileURL: URL, remoteFolderID: String, fileName: String) async throws -> String

    /// 共有設定（オプション）
    func setSharing(remoteFileID: String, policy: SharingPolicy) async throws

    /// リモートファイルのハッシュを取得（重複検出用）
    func getRemoteHash(remoteFileID: String) async throws -> String?
}

struct SharingPolicy: Sendable {
    var isShared: Bool
    var scope: SharingScope
    var role: SharingRole

    static let privateOnly = SharingPolicy(isShared: false, scope: .owner, role: .viewer)
}

enum SharingScope: String, Sendable {
    case owner
    case organization
    case anyone
}

enum SharingRole: String, Sendable {
    case viewer
    case editor
}
