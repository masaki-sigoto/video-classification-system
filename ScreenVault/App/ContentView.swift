import SwiftUI
import SwiftData
import OSLog

// MARK: - ContentView

/// メニューバーウィンドウのメインビュー（幅 280pt 固定）
struct ContentView: View {

    @Environment(SyncViewModel.self) private var syncVM
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openSettings) private var openSettings

    private let logger = Logger(subsystem: "com.screenvault.app", category: "menuBar")

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
            Divider()
            statsSection
            Divider()
            actionsSection
            if syncVM.failedTaskCount > 0 {
                Divider()
                failedTasksRow
            }
            Divider()
            quitRow
        }
        .frame(width: 280)
        .onAppear {
            syncVM.refreshStats(modelContext: modelContext)
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 8) {
            syncStateIcon
            VStack(alignment: .leading, spacing: 2) {
                Text("ScreenVault")
                    .font(.headline)
                Text(syncVM.syncState.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var syncStateIcon: some View {
        switch syncVM.syncState {
        case .syncing:
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(.blue)
                .symbolEffect(.rotate, isActive: true)
        case .paused:
            Image(systemName: "pause.circle.fill")
                .foregroundStyle(.orange)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        case .idle:
            Image(systemName: "arrow.up.doc.on.clipboard")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Stats

    private var statsSection: some View {
        HStack {
            Label("本日 \(syncVM.todayIngestCount) 件", systemImage: "calendar")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Actions

    private var actionsSection: some View {
        VStack(spacing: 0) {
            if syncVM.syncState == .paused {
                menuButton(title: "同期を再開", systemImage: "play.circle") {
                    syncVM.resumeSync()
                    logger.info("ユーザーが同期を再開")
                }
            } else {
                menuButton(title: "同期を一時停止", systemImage: "pause.circle") {
                    syncVM.pauseSync()
                    logger.info("ユーザーが同期を一時停止")
                }
            }

            menuButton(title: "設定を開く...", systemImage: "gear") {
                openSettings()
                logger.info("ユーザーが設定画面を開いた")
            }
        }
    }

    // MARK: - Failed Tasks

    private var failedTasksRow: some View {
        menuButton(
            title: "失敗タスク: \(syncVM.failedTaskCount) 件",
            systemImage: "exclamationmark.circle.fill",
            role: nil,
            tint: .red
        ) {
            openSettings()
            logger.info("ユーザーが失敗タスク確認のため設定を開いた")
        }
    }

    // MARK: - Quit

    private var quitRow: some View {
        menuButton(title: "終了", systemImage: "power", role: .destructive) {
            logger.info("ユーザーがアプリを終了")
            NSApplication.shared.terminate(nil)
        }
    }

    // MARK: - Helpers

    private func menuButton(
        title: String,
        systemImage: String,
        role: ButtonRole? = nil,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Group {
                if let tint {
                    Label(title, systemImage: systemImage)
                        .foregroundStyle(tint)
                } else {
                    Label(title, systemImage: systemImage)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .hoverHighlight()
    }
}

// MARK: - View Modifiers

private extension View {
    /// ホバー時にハイライト表示
    func hoverHighlight() -> some View {
        modifier(HoverHighlightModifier())
    }
}

private struct HoverHighlightModifier: ViewModifier {
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? Color.primary.opacity(0.08) : Color.clear)
            )
            .onHover { isHovered = $0 }
    }
}
