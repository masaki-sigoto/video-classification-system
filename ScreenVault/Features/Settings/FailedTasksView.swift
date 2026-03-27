import SwiftUI
import SwiftData
import OSLog

// MARK: - FailedTasksView

/// 失敗したアップロードタスク一覧タブ
/// - ファイル名、エラー内容、リトライ回数を表示
/// - 「再試行」「キャンセル」ボタン
struct FailedTasksView: View {

    @Query(sort: \UploadTask.updatedAt, order: .reverse)
    private var allTasks: [UploadTask]

    private var failedTasks: [UploadTask] {
        return allTasks.filter { $0.statusRawValue == "failed" }
    }

    @Environment(\.modelContext) private var modelContext
    @Environment(SyncViewModel.self) private var syncVM

    private let logger = Logger(subsystem: "com.screenvault.app", category: "failedTasks")

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            taskList
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack {
            Text("失敗タスク")
                .font(.headline)
            if !failedTasks.isEmpty {
                Text("(\(failedTasks.count) 件)")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !failedTasks.isEmpty {
                Button {
                    retryAll()
                } label: {
                    Label("すべて再試行", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Task List

    private var taskList: some View {
        Group {
            if failedTasks.isEmpty {
                ContentUnavailableView(
                    "失敗したタスクはありません",
                    systemImage: "checkmark.circle",
                    description: Text("すべてのアップロードが正常に完了しています")
                )
            } else {
                List(failedTasks) { task in
                    FailedTaskRow(
                        task: task,
                        onRetry: { retry(task: task) },
                        onCancel: { cancel(task: task) }
                    )
                    .listRowSeparator(.visible)
                }
                .listStyle(.inset)
            }
        }
    }

    // MARK: - Actions

    private func retry(task: UploadTask) {
        task.setStatus(.pending)
        task.updatedAt = .now
        trySave()
        syncVM.refreshStats(modelContext: modelContext)
        logger.info("タスク再試行: \(task.taskID, privacy: .public)")
    }

    private func cancel(task: UploadTask) {
        task.setStatus(.cancelled)
        task.updatedAt = .now
        trySave()
        syncVM.refreshStats(modelContext: modelContext)
        logger.info("タスクキャンセル: \(task.taskID, privacy: .public)")
    }

    private func retryAll() {
        for task in failedTasks {
            task.setStatus(.pending)
            task.updatedAt = .now
        }
        trySave()
        syncVM.refreshStats(modelContext: modelContext)
        logger.info("全失敗タスクを再試行: \(failedTasks.count) 件")
    }

    private func trySave() {
        do {
            try modelContext.save()
        } catch {
            logger.error("タスク保存失敗: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - FailedTaskRow

private struct FailedTaskRow: View {
    let task: UploadTask
    let onRetry: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // アイコン
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .font(.title3)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                // ファイル名
                Text(fileName)
                    .font(.body.bold())
                    .lineLimit(1)

                // エラー内容
                if let errorCode = task.lastErrorCode {
                    HStack(spacing: 4) {
                        Text("エラー:")
                            .foregroundStyle(.secondary)
                        Text(errorCode)
                            .foregroundStyle(.red)
                    }
                    .font(.caption)
                }

                // リトライ回数・更新日時
                HStack(spacing: 8) {
                    Label("リトライ \(task.retryCount) 回", systemImage: "arrow.counterclockwise")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(task.updatedAt, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // 次回リトライ予定
                if let nextRetry = task.nextRetryAt {
                    Label("次回: \(nextRetry, style: .time)", systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Spacer()

            // アクションボタン
            VStack(spacing: 6) {
                Button("再試行") { onRetry() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                Button("キャンセル", role: .destructive) { onCancel() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 6)
    }

    private var fileName: String {
        // Asset の originalPath または localTempPath からファイル名を取得
        if let path = task.asset?.originalPath ?? task.asset?.localTempPath {
            return URL(filePath: path).lastPathComponent
        }
        return "不明なファイル（\(task.taskID.prefix(8))）"
    }
}
