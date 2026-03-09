import SwiftUI

// MARK: - SettingsView

/// 設定ウィンドウのルートビュー（600 × 500 pt）
struct SettingsView: View {

    @Environment(SyncViewModel.self) private var syncVM

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("一般", systemImage: "gear")
                }

            ProvidersSettingsView()
                .tabItem {
                    Label("クラウド接続", systemImage: "cloud")
                }

            ClassificationSettingsView()
                .tabItem {
                    Label("分類ルール", systemImage: "folder.badge.gearshape")
                }

            LogViewerView()
                .tabItem {
                    Label("ログ", systemImage: "doc.text.magnifyingglass")
                }

            FailedTasksView()
                .tabItem {
                    Label("失敗タスク", systemImage: "exclamationmark.circle")
                }
        }
        .frame(width: 600, height: 500)
    }
}
