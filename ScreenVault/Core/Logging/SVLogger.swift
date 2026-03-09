import OSLog

/// ScreenVault 用ログカテゴリ
enum SVLogger {
    static let ingest = Logger(subsystem: "com.screenvault.app", category: "ingest")
    static let upload = Logger(subsystem: "com.screenvault.app", category: "upload")
    static let classification = Logger(subsystem: "com.screenvault.app", category: "classification")
    static let auth = Logger(subsystem: "com.screenvault.app", category: "auth")
    static let provider = Logger(subsystem: "com.screenvault.app", category: "provider")
    static let general = Logger(subsystem: "com.screenvault.app", category: "general")
}
