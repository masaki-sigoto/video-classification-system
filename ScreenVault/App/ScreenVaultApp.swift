import SwiftUI
import SwiftData
import OSLog

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Properties

    private let logger = Logger(subsystem: "com.screenvault.app", category: "appDelegate")

    /// 同期状態に応じてメニューバーアイコンを変更するためのコールバック
    var onSyncStateChange: ((SyncState) -> Void)?

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info("ScreenVault applicationDidFinishLaunching")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // メニューバーアプリなのでウィンドウを閉じてもアプリ終了しない
        return false
    }
}

// MARK: - SyncState

/// メニューバーアイコン・同期状態の列挙
enum SyncState: String, Equatable {
    case syncing    // 同期中
    case paused     // 一時停止
    case error      // エラー
    case idle       // 未接続/アイドル

    /// SF Symbols アイコン名
    var systemImage: String {
        switch self {
        case .syncing: return "arrow.triangle.2.circlepath"
        case .paused:  return "pause.circle"
        case .error:   return "exclamationmark.triangle"
        case .idle:    return "arrow.up.doc.on.clipboard"
        }
    }

    /// 状態ラベル
    var label: String {
        switch self {
        case .syncing: return "同期中"
        case .paused:  return "一時停止中"
        case .error:   return "エラー"
        case .idle:    return "未接続"
        }
    }
}

// MARK: - SyncViewModel

/// メニューバーと設定画面全体で共有する同期状態 ViewModel
@MainActor
@Observable
final class SyncViewModel {

    // MARK: - Sync state

    var syncState: SyncState = .idle
    var todayIngestCount: Int = 0
    var failedTaskCount: Int = 0

    // MARK: - Actions

    func pauseSync() {
        SVLogger.general.info("SyncViewModel: 同期を一時停止")
        syncState = .paused
    }

    func resumeSync() {
        SVLogger.general.info("SyncViewModel: 同期を再開")
        syncState = .syncing
    }

    /// SwiftData から今日の取り込み件数と失敗タスク件数を更新する
    func refreshStats(modelContext: ModelContext) {
        do {
            // 本日の取り込み件数
            let startOfDay = Calendar.current.startOfDay(for: Date())
            let assetDescriptor = FetchDescriptor<Asset>(
                predicate: #Predicate { $0.capturedAt >= startOfDay }
            )
            todayIngestCount = try modelContext.fetchCount(assetDescriptor)

            // 失敗タスク件数
            let failedDescriptor = FetchDescriptor<UploadTask>(
                predicate: #Predicate { $0.status == UploadStatus.failed }
            )
            failedTaskCount = try modelContext.fetchCount(failedDescriptor)
        } catch {
            SVLogger.general.error("SyncViewModel: stats 更新失敗 — \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - ScreenVaultApp

@main
struct ScreenVaultApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @State private var syncVM = SyncViewModel()

    var body: some Scene {
        // メニューバー常駐
        MenuBarExtra {
            ContentView()
                .environment(syncVM)
                .modelContainer(DatabaseContainer.shared.container)
        } label: {
            Label("ScreenVault", systemImage: syncVM.syncState.systemImage)
        }
        .menuBarExtraStyle(.window)

        // 設定ウィンドウ
        Settings {
            SettingsView()
                .environment(syncVM)
                .modelContainer(DatabaseContainer.shared.container)
        }
    }
}
