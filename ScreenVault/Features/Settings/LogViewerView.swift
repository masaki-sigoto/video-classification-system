import SwiftUI
import SwiftData
import OSLog
import UniformTypeIdentifiers

// MARK: - LogViewerView

/// 監査ログ閲覧タブ（直近 100 件、レベルフィルタ付き）
struct LogViewerView: View {

    @Query(sort: \AuditLog.at, order: .reverse)
    private var allLogs: [AuditLog]

    @State private var selectedLevel: LogLevel? = nil
    @State private var exportDocument: LogExportDocument? = nil
    @State private var showExporter = false

    private let logger = Logger(subsystem: "com.screenvault.app", category: "logViewer")

    // MARK: - Computed

    private var filteredLogs: [AuditLog] {
        let recent = allLogs.prefix(100)
        guard let level = selectedLevel else { return Array(recent) }
        return recent.filter { $0.level == level }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            logList
        }
        .fileExporter(
            isPresented: $showExporter,
            document: exportDocument,
            contentType: .plainText,
            defaultFilename: "ScreenVault-logs-\(formattedDate)"
        ) { result in
            switch result {
            case .success:
                logger.info("ログエクスポート成功")
            case .failure(let error):
                logger.error("ログエクスポート失敗: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text("ログ")
                .font(.headline)

            Spacer()

            Picker("フィルタ", selection: $selectedLevel) {
                Text("すべて").tag(Optional<LogLevel>.none)
                Divider()
                Text("情報").tag(Optional<LogLevel>.some(.info))
                Text("警告").tag(Optional<LogLevel>.some(.warning))
                Text("エラー").tag(Optional<LogLevel>.some(.error))
            }
            .pickerStyle(.menu)
            .frame(width: 100)
            .labelsHidden()

            Button {
                copyLogs()
            } label: {
                Label("コピー", systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("表示中のログをクリップボードにコピー")

            Button {
                exportLogs()
            } label: {
                Label("エクスポート", systemImage: "arrow.down.doc")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("ログをテキストファイルとして保存")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Log List

    private var logList: some View {
        Group {
            if filteredLogs.isEmpty {
                ContentUnavailableView(
                    "ログがありません",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("フィルタを変更するか、しばらく操作してみてください")
                )
            } else {
                List(filteredLogs) { entry in
                    LogEntryRow(entry: entry)
                        .listRowSeparator(.visible)
                }
                .listStyle(.inset)
            }
        }
    }

    // MARK: - Actions

    private func copyLogs() {
        let text = filteredLogs.map { formatLogLine($0) }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        logger.info("ログをクリップボードにコピー: \(filteredLogs.count) 件")
    }

    private func exportLogs() {
        let text = filteredLogs.map { formatLogLine($0) }.joined(separator: "\n")
        exportDocument = LogExportDocument(content: text)
        showExporter = true
    }

    private func formatLogLine(_ entry: AuditLog) -> String {
        let dateStr = ISO8601DateFormatter().string(from: entry.at)
        return "[\(dateStr)] [\(entry.level.rawValue.uppercased())] [\(entry.eventType)] \(entry.messageRedacted)"
    }

    private var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}

// MARK: - LogEntryRow

private struct LogEntryRow: View {
    let entry: AuditLog

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // レベルバッジ
            Text(entry.level.shortLabel)
                .font(.caption.monospaced())
                .foregroundStyle(entry.level.badgeTextColor)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(entry.level.badgeColor, in: RoundedRectangle(cornerRadius: 4))
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(Self.dateFormatter.string(from: entry.at))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)

                    Text(entry.eventType)
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                }

                Text(entry.messageRedacted)
                    .font(.body)
                    .lineLimit(3)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - LogLevel Extensions

extension LogLevel {
    var shortLabel: String {
        switch self {
        case .debug:   return "DBG"
        case .info:    return "INF"
        case .warning: return "WRN"
        case .error:   return "ERR"
        }
    }

    var badgeColor: Color {
        switch self {
        case .debug:   return Color.secondary.opacity(0.2)
        case .info:    return Color.blue.opacity(0.15)
        case .warning: return Color.orange.opacity(0.2)
        case .error:   return Color.red.opacity(0.2)
        }
    }

    var badgeTextColor: Color {
        switch self {
        case .debug:   return .secondary
        case .info:    return .blue
        case .warning: return .orange
        case .error:   return .red
        }
    }
}

// MARK: - LogExportDocument

struct LogExportDocument: FileDocument {
    static var readableContentTypes: [UTType] = [.plainText]

    let content: String

    init(content: String) {
        self.content = content
    }

    init(configuration: ReadConfiguration) throws {
        if let data = configuration.file.regularFileContents,
           let str = String(data: data, encoding: .utf8) {
            content = str
        } else {
            content = ""
        }
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data = content.data(using: .utf8) ?? Data()
        return FileWrapper(regularFileWithContents: data)
    }
}
