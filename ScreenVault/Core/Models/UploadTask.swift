import Foundation
import SwiftData

/// クラウドへのアップロードタスクを表す
@Model
final class UploadTask {
    @Attribute(.unique) var taskID: String
    var asset: Asset?
    var accountID: String
    var remoteParentFolderID: String?
    var remoteFileID: String?
    var uploadSessionRef: String?
    /// SwiftData 永続化用（String で保存）
    var statusRawValue: String
    var retryCount: Int
    var nextRetryAt: Date?
    var lastErrorCode: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        taskID: String = UUID().uuidString,
        accountID: String,
        statusRawValue: String = "pending"
    ) {
        self.taskID = taskID
        self.accountID = accountID
        self.statusRawValue = statusRawValue
        self.retryCount = 0
        self.createdAt = .now
        self.updatedAt = .now
    }
}

// MARK: - Status helpers

extension UploadTask {
    func setStatus(_ newStatus: UploadStatus) {
        statusRawValue = newStatus.rawValue
    }

    func hasStatus(_ status: UploadStatus) -> Bool {
        statusRawValue == status.rawValue
    }
}

// MARK: - UploadStatus

/// アップロード状態を表す値型。
/// - RawRepresentable に準拠しない（SwiftData マクロが enum 扱いするのを防止）
/// - @Model クラスの stored property にはしない（statusRawValue: String を使用）
struct UploadStatus: Codable, Equatable, Hashable, Sendable {
    let rawValue: String

    static let pending   = UploadStatus(rawValue: "pending")
    static let uploading = UploadStatus(rawValue: "uploading")
    static let completed = UploadStatus(rawValue: "completed")
    static let failed    = UploadStatus(rawValue: "failed")
    static let cancelled = UploadStatus(rawValue: "cancelled")
}
