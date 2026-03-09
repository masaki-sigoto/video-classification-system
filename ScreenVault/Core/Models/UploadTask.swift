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
    var status: UploadStatus
    var retryCount: Int
    var nextRetryAt: Date?
    var lastErrorCode: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        taskID: String = UUID().uuidString,
        accountID: String,
        status: UploadStatus = .pending
    ) {
        self.taskID = taskID
        self.accountID = accountID
        self.status = status
        self.retryCount = 0
        self.createdAt = .now
        self.updatedAt = .now
    }
}

enum UploadStatus: String, Codable {
    case pending
    case uploading
    case completed
    case failed
    case cancelled
}
