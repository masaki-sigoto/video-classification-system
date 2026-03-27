import SwiftUI
import OSLog
import AppKit

// MARK: - GeneralSettingsView

/// 一般設定タブ
/// - Watch フォルダの追加/削除
/// - ファイル命名テンプレート
/// - ローカルファイル後処理
/// - 通知ON/OFF
struct GeneralSettingsView: View {

    // MARK: - Stored Preferences

    @AppStorage("watchFolderBookmarks") private var watchFolderBookmarksData: Data = Data()
    @AppStorage("namingTemplate") private var namingTemplate: String =
        "{YYYY}-{MM}-{DD}_{HH}-{mm}-{ss}_{Kind}_{App}_{ShortHash}"
    @AppStorage("localFilePostProcess") private var localFilePostProcess: LocalPostProcess = .keep
    @AppStorage("notificationsEnabled") private var notificationsEnabled: Bool = true

    // MARK: - State

    @State private var watchFolderPaths: [String] = []
    @State private var showTemplateHelp = false

    private let logger = Logger(subsystem: "com.screenvault.app", category: "generalSettings")

    // MARK: - Body

    var body: some View {
        Form {
            // -- Watch フォルダ --
            Section("Watch フォルダ") {
                watchFolderList
                addFolderButton
            }

            // -- ファイル命名テンプレート --
            Section {
                LabeledContent("命名テンプレート") {
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("テンプレート", text: $namingTemplate)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                        Button("テンプレート変数を表示") {
                            showTemplateHelp.toggle()
                        }
                        .font(.caption)
                        .buttonStyle(.link)
                        if showTemplateHelp {
                            templateHelpView
                        }
                    }
                }
            } header: {
                Text("ファイル命名")
            }

            // -- ローカルファイル後処理 --
            Section("ローカルファイルの後処理") {
                Picker("取り込み後の元ファイル", selection: $localFilePostProcess) {
                    ForEach(LocalPostProcess.allCases, id: \.self) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.radioGroup)
            }

            // -- 通知 --
            Section("通知") {
                Toggle("アップロード完了・失敗を通知する", isOn: $notificationsEnabled)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            loadWatchFolderPaths()
        }
    }

    // MARK: - Watch Folder List

    private var watchFolderList: some View {
        Group {
            if watchFolderPaths.isEmpty {
                Text("監視フォルダが設定されていません")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                ForEach(watchFolderPaths, id: \.self) { path in
                    HStack {
                        Image(systemName: "folder")
                            .foregroundStyle(Color.accentColor)
                        Text(path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button {
                            removeWatchFolder(path: path)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                        .help("このフォルダの監視を解除")
                    }
                }
            }
        }
    }

    private var addFolderButton: some View {
        Button {
            selectWatchFolder()
        } label: {
            Label("フォルダを追加...", systemImage: "plus")
        }
    }

    // MARK: - Template Help

    private var templateHelpView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("使用可能な変数:")
                .font(.caption.bold())
            templateHelpRow("{YYYY}", description: "年（4桁）")
            templateHelpRow("{MM}", description: "月（2桁）")
            templateHelpRow("{DD}", description: "日（2桁）")
            templateHelpRow("{HH}", description: "時（2桁）")
            templateHelpRow("{mm}", description: "分（2桁）")
            templateHelpRow("{ss}", description: "秒（2桁）")
            templateHelpRow("{Kind}", description: "アセット種別")
            templateHelpRow("{App}", description: "フロントアプリ名")
            templateHelpRow("{ShortHash}", description: "ハッシュ（8文字）")
        }
        .padding(8)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
        .font(.caption)
    }

    private func templateHelpRow(_ variable: String, description: String) -> some View {
        HStack(spacing: 4) {
            Text(variable)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Color.accentColor)
            Text("—")
                .foregroundStyle(.secondary)
            Text(description)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private func selectWatchFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "監視フォルダとして選択"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let path = url.path(percentEncoded: false)
        guard !watchFolderPaths.contains(path) else { return }

        watchFolderPaths.append(path)
        saveWatchFolderPaths()
        logger.info("Watch フォルダ追加: \(path, privacy: .public)")
    }

    private func removeWatchFolder(path: String) {
        watchFolderPaths.removeAll { $0 == path }
        saveWatchFolderPaths()
        logger.info("Watch フォルダ削除: \(path, privacy: .public)")
    }

    private func saveWatchFolderPaths() {
        if let data = try? JSONEncoder().encode(watchFolderPaths) {
            watchFolderBookmarksData = data
        }
    }

    private func loadWatchFolderPaths() {
        guard !watchFolderBookmarksData.isEmpty else { return }
        if let paths = try? JSONDecoder().decode([String].self, from: watchFolderBookmarksData) {
            watchFolderPaths = paths
        }
    }
}

// MARK: - LocalPostProcess

enum LocalPostProcess: String, CaseIterable, Codable {
    case keep    = "keep"
    case move    = "move"
    case delete  = "delete"

    var label: String {
        switch self {
        case .keep:   return "そのまま保持する"
        case .move:   return "バックアップフォルダへ移動する"
        case .delete: return "アップロード後に削除する"
        }
    }
}
