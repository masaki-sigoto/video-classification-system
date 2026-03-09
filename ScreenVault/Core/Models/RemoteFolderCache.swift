import Foundation
import SwiftData

/// クラウドプロバイダのリモートフォルダ ID をキャッシュするモデル。
/// フォルダパス文字列（folderPathKey）から実際のリモートフォルダ ID を引くために使う。
@Model
final class RemoteFolderCache {
    /// 一意識別子
    @Attribute(.unique) var cacheID: String
    /// 紐付くプロバイダアカウントの ID（ProviderAccount.accountID に対応）
    var accountID: String
    /// アプリ内で管理するフォルダパスのキー
    /// 例: "googleDrive/Captures/2025/2025-01/Screenshot/Safari/Work/"
    var folderPathKey: String
    /// クラウドプロバイダが割り当てたフォルダの実 ID
    var remoteFolderID: String
    /// キャッシュの最終更新日時
    var updatedAt: Date

    init(
        cacheID: String = UUID().uuidString,
        accountID: String,
        folderPathKey: String,
        remoteFolderID: String
    ) {
        self.cacheID = cacheID
        self.accountID = accountID
        self.folderPathKey = folderPathKey
        self.remoteFolderID = remoteFolderID
        self.updatedAt = .now
    }
}
