import Foundation
import SwiftData

/// 監査ログエントリ
@Model
final class AuditLog {
    @Attribute(.unique) var logID: String
    var at: Date
    var level: LogLevel
    var eventType: String
    var entityID: String?
    var messageRedacted: String

    init(
        logID: String = UUID().uuidString,
        eventType: String,
        entityID: String? = nil,
        messageRedacted: String,
        level: LogLevel = .info
    ) {
        self.logID = logID
        self.at = .now
        self.level = level
        self.eventType = eventType
        self.entityID = entityID
        self.messageRedacted = messageRedacted
    }
}

enum LogLevel: String, Codable {
    case debug
    case info
    case warning
    case error
}
