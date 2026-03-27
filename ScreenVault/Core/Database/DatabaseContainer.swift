import Foundation
import OSLog
import SwiftData

/// ScreenVault の SwiftData ModelContainer を管理するシングルトン。
///
/// アプリ起動時に `DatabaseContainer.shared` を参照して
/// `ModelContainer` を取得し、SwiftUI の `.modelContainer()` モディファイアに渡す。
///
/// - Note: 全 `@Model` クラスをここに登録すること。登録漏れがあると
///   コンテキストへの挿入時にクラッシュする。
final class DatabaseContainer: @unchecked Sendable {

    // MARK: - シングルトン

    /// アプリ全体で共有する DatabaseContainer インスタンス
    static let shared = DatabaseContainer()

    // MARK: - プロパティ

    /// SwiftData の ModelContainer
    let container: ModelContainer

    // MARK: - 初期化

    private init() {
        do {
            let schema = Schema([
                Asset.self,
                AssetTag.self,
                UploadTask.self,
                ProviderAccount.self,
                OAuthToken.self,
                RemoteFolderCache.self,
                ClassificationRule.self,
                RuleCondition.self,
                RuleAction.self,
                AuditLog.self,
            ])

            let configuration = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: false,
                allowsSave: true,
                groupContainer: .none,
                cloudKitDatabase: .none
            )

            self.container = try ModelContainer(
                for: schema,
                configurations: configuration
            )

            SVLogger.general.info("DatabaseContainer: ModelContainer 初期化完了")
        } catch {
            // ModelContainer の初期化失敗はアプリが動作不能になる致命的エラー
            SVLogger.general.critical("DatabaseContainer: ModelContainer 初期化失敗 — \(error.localizedDescription, privacy: .public)")
            fatalError("SwiftData ModelContainer の初期化に失敗しました: \(error)")
        }
    }

    // MARK: - インメモリコンテナ（テスト用）

    /// ユニットテスト用のインメモリ ModelContainer を生成して返す。
    ///
    /// - Returns: データがディスクに永続化されない ModelContainer
    /// - Throws: ModelContainer 生成に失敗した場合
    static func makeInMemoryContainer() throws -> ModelContainer {
        let schema = Schema([
            Asset.self,
            AssetTag.self,
            UploadTask.self,
            ProviderAccount.self,
            OAuthToken.self,
            RemoteFolderCache.self,
            ClassificationRule.self,
            RuleCondition.self,
            RuleAction.self,
            AuditLog.self,
        ])

        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true
        )

        return try ModelContainer(
            for: schema,
            configurations: configuration
        )
    }
}
