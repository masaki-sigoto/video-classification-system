import Foundation
import SwiftData

/// キャプチャされたファイル（スクリーンショット/録画/クリップボード等）を表す
@Model
final class Asset {
    @Attribute(.unique) var assetID: String
    var kind: AssetKind
    var sourceMode: SourceMode
    var localTempPath: String?
    var originalPath: String?
    var contentHashSHA256: String?
    var capturedAt: Date
    var frontmostApp: String?
    var captionText: String?
    var ocrText: String?
    var sizeBytes: Int64

    @Relationship(deleteRule: .cascade) var uploadTasks: [UploadTask]
    @Relationship(deleteRule: .cascade) var tags: [AssetTag]

    init(
        assetID: String = UUID().uuidString,
        kind: AssetKind,
        sourceMode: SourceMode,
        capturedAt: Date = .now,
        sizeBytes: Int64 = 0
    ) {
        self.assetID = assetID
        self.kind = kind
        self.sourceMode = sourceMode
        self.capturedAt = capturedAt
        self.sizeBytes = sizeBytes
        self.uploadTasks = []
        self.tags = []
    }
}

enum AssetKind: String, Codable {
    case screenshot
    case screenRecording
    case clipboard
    case video
    case text
}

enum SourceMode: String, Codable {
    case watch
    case capture
    case clipboard
    case manual
}
