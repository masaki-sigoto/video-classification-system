import Foundation

/// ScreenVault アプリ全体で使用する型付きエラー定義。
///
/// Swift 6 の型付きエラー（typed throws）に対応した設計。
/// `LocalizedError` に準拠することで SwiftUI の `Alert` や
/// `errorMessage` に直接渡せる。
enum ScreenVaultError: LocalizedError {

    // MARK: - 認証関連

    /// OAuth 認証に失敗した
    case authenticationFailed(provider: ProviderType, reason: String)

    /// アクセストークンの有効期限が切れ、リフレッシュも失敗した
    case uploadSessionExpired(provider: ProviderType)

    // MARK: - アップロード関連

    /// アップロード処理が失敗した
    case uploadFailed(taskID: String, reason: String)

    /// API レート制限（429）に達した
    case rateLimited(retryAfter: TimeInterval?)

    // MARK: - ネットワーク関連

    /// ネットワーク接続が利用できない
    case networkUnavailable

    // MARK: - ファイル関連

    /// 指定したパスにファイルが見つからない
    case fileNotFound(path: String)

    /// 同一ハッシュのファイルがすでに存在する（重複検出）
    case duplicateDetected(hash: String)

    // MARK: - 分類関連

    /// 自動分類処理に失敗した
    case classificationFailed(reason: String)

    // MARK: - プロバイダ関連

    /// 指定アカウントのプロバイダが接続されていない
    case providerNotConnected(accountID: String)

    // MARK: - その他

    /// 汎用的な未分類エラー
    case unknown(String)

    // MARK: - セキュリティ関連

    /// Keychain 操作でエラーが発生した
    case keychainError(underlying: Error)

    /// Security-Scoped Bookmark の解決に失敗した
    case bookmarkResolutionFailed(key: String)

    // MARK: - LocalizedError

    var errorDescription: String? {
        switch self {
        case .authenticationFailed(let provider, let reason):
            return "[\(provider.rawValue)] 認証に失敗しました: \(reason)"

        case .uploadSessionExpired(let provider):
            return "[\(provider.rawValue)] アップロードセッションが失効しました。再接続してください。"

        case .uploadFailed(let taskID, let reason):
            return "アップロード失敗 (taskID: \(taskID)): \(reason)"

        case .rateLimited(let retryAfter):
            if let seconds = retryAfter {
                return "API レート制限に達しました。\(Int(seconds)) 秒後に再試行します。"
            } else {
                return "API レート制限に達しました。しばらく待ってから再試行してください。"
            }

        case .networkUnavailable:
            return "ネットワーク接続がありません。接続を確認してください。"

        case .fileNotFound(let path):
            return "ファイルが見つかりません: \(path)"

        case .duplicateDetected(let hash):
            return "同一ファイルが既に存在します (SHA-256: \(hash))"

        case .classificationFailed(let reason):
            return "自動分類に失敗しました: \(reason)"

        case .providerNotConnected(let accountID):
            return "プロバイダが接続されていません (accountID: \(accountID))"

        case .unknown(let message):
            return "エラー: \(message)"

        case .keychainError(let underlying):
            return "Keychain エラー: \(underlying.localizedDescription)"

        case .bookmarkResolutionFailed(let key):
            return "フォルダアクセス権の復元に失敗しました (key: \(key))。再度フォルダを選択してください。"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .authenticationFailed:
            return "設定画面からプロバイダの再接続を試みてください。"
        case .uploadSessionExpired:
            return "設定画面からプロバイダを再接続してください。"
        case .uploadFailed:
            return "ネットワーク接続を確認し、失敗タスク一覧から手動で再試行してください。"
        case .rateLimited(let retryAfter):
            if let seconds = retryAfter {
                return "\(Int(seconds)) 秒後に自動的に再試行します。"
            }
            return "しばらく待ってから再試行してください。"
        case .networkUnavailable:
            return "ネットワーク接続が回復すると自動的に再開します。"
        case .fileNotFound:
            return "ファイルが移動または削除されていないか確認してください。"
        case .duplicateDetected:
            return "設定の重複ポリシーを確認してください（スキップ / コピー / 上書き）。"
        case .classificationFailed:
            return "分類ルールの設定を確認してください。"
        case .providerNotConnected:
            return "設定画面でプロバイダを再接続してください。"
        case .unknown:
            return nil
        case .keychainError:
            return "アプリを再起動して再試行してください。問題が続く場合は再インストールをお試しください。"
        case .bookmarkResolutionFailed:
            return "設定画面で監視フォルダを再選択してください。"
        }
    }
}
