import Foundation
import SwiftData
import OSLog
import Combine

// MARK: - UploadQueue

/// アップロードタスクのキューを管理する actor ベースのスレッドセーフ実装。
///
/// - 並列アップロード上限: `maxConcurrent`（デフォルト 3）
/// - リトライ: 429 は Retry-After 尊重、5xx は指数バックオフ（最大 10 回）
/// - オフライン: NWPathMonitor でネットワーク復帰後に自動再開
@MainActor
final class UploadQueue: ObservableObject {

    // MARK: - Published state

    /// 現在アクティブ（uploading）なタスク
    @Published private(set) var activeTasks: [UploadTask] = []

    /// キュー待ち（pending）のタスク
    @Published private(set) var queuedTasks: [UploadTask] = []

    // MARK: - Configuration

    /// 同時アップロード上限数
    let maxConcurrent: Int

    // MARK: - Dependencies

    private let modelContext: ModelContext
    private let providerManager: ProviderManager
    private let networkMonitor: NetworkMonitor

    // MARK: - Internal state

    /// 実行中 Task ハンドル（taskID → Task）
    private var runningTasks: [String: Task<Void, Never>] = [:]

    /// ネットワーク監視サブスクリプション
    private var cancellables: Set<AnyCancellable> = []

    // MARK: - Init

    init(
        modelContext: ModelContext,
        providerManager: ProviderManager,
        networkMonitor: NetworkMonitor = NetworkMonitor(),
        maxConcurrent: Int = 3
    ) {
        self.modelContext = modelContext
        self.providerManager = providerManager
        self.networkMonitor = networkMonitor
        self.maxConcurrent = maxConcurrent

        loadPendingTasks()
        observeNetworkChanges()
    }

    // MARK: - Public API

    /// 新しいアップロードタスクをキューに追加する。
    func enqueue(asset: Asset, accountID: String, remoteFolderID: String) async {
        SVLogger.upload.info("UploadQueue: enqueue asset=\(asset.assetID, privacy: .public) account=\(accountID, privacy: .public)")

        let task = UploadTask(accountID: accountID)
        task.asset = asset
        task.remoteParentFolderID = remoteFolderID
        task.status = .pending

        modelContext.insert(task)
        do {
            try modelContext.save()
        } catch {
            SVLogger.upload.error("UploadQueue: failed to save new task: \(error.localizedDescription, privacy: .public)")
            return
        }

        queuedTasks.append(task)
        SVLogger.upload.info("UploadQueue: task enqueued taskID=\(task.taskID, privacy: .public)")

        await processQueue()
    }

    /// キューからタスクを取り出して実行する。空きスロットがある限り並列に実行する。
    func processQueue() async {
        guard networkMonitor.isConnected else {
            SVLogger.upload.info("UploadQueue: processQueue skipped - network unavailable")
            return
        }

        while activeTasks.count < maxConcurrent, let next = queuedTasks.first {
            queuedTasks.removeFirst()
            startTask(next)
        }
    }

    /// 失敗タスクを再試行キューに追加する。
    func retryTask(_ task: UploadTask) async {
        SVLogger.upload.info("UploadQueue: retry requested taskID=\(task.taskID, privacy: .public)")

        // 既存の実行中 Task があればキャンセル
        runningTasks[task.taskID]?.cancel()
        runningTasks.removeValue(forKey: task.taskID)
        activeTasks.removeAll { $0.taskID == task.taskID }

        // 状態リセット
        task.status = .pending
        task.retryCount = 0
        task.nextRetryAt = nil
        task.lastErrorCode = nil
        task.updatedAt = .now
        persistTask(task)

        queuedTasks.append(task)
        await processQueue()
    }

    /// タスクをキャンセルする。
    func cancelTask(_ task: UploadTask) async {
        SVLogger.upload.info("UploadQueue: cancel taskID=\(task.taskID, privacy: .public)")

        runningTasks[task.taskID]?.cancel()
        runningTasks.removeValue(forKey: task.taskID)
        activeTasks.removeAll { $0.taskID == task.taskID }
        queuedTasks.removeAll { $0.taskID == task.taskID }

        task.status = .cancelled
        task.updatedAt = .now
        persistTask(task)
    }

    // MARK: - Private: Task execution

    private func startTask(_ task: UploadTask) {
        SVLogger.upload.info("UploadQueue: start taskID=\(task.taskID, privacy: .public)")

        task.status = .uploading
        task.updatedAt = .now
        activeTasks.append(task)
        persistTask(task)

        let handle = Task { [weak self] in
            guard let self else { return }
            await self.executeWithRetry(task: task)
        }
        runningTasks[task.taskID] = handle
    }

    /// リトライロジックを含む実行ループ
    private func executeWithRetry(task: UploadTask) async {
        let maxRetry = 10
        let baseDelay: TimeInterval = 1.0

        while task.retryCount <= maxRetry {
            guard !Task.isCancelled else {
                SVLogger.upload.info("UploadQueue: task cancelled mid-retry taskID=\(task.taskID, privacy: .public)")
                return
            }

            do {
                let remoteFileID = try await performUpload(task: task)

                // 成功
                await MainActor.run {
                    task.status = .completed
                    task.remoteFileID = remoteFileID
                    task.updatedAt = .now
                    self.activeTasks.removeAll { $0.taskID == task.taskID }
                    self.runningTasks.removeValue(forKey: task.taskID)
                    self.persistTask(task)
                    SVLogger.upload.info("UploadQueue: completed taskID=\(task.taskID, privacy: .public) remoteFileID=\(remoteFileID, privacy: .public)")
                }

                await processQueue()
                return

            } catch let error as ScreenVaultError {
                let shouldRetry = await handleUploadError(error, task: task, maxRetry: maxRetry)
                if !shouldRetry { return }

            } catch {
                SVLogger.upload.error("UploadQueue: unexpected error taskID=\(task.taskID, privacy: .public): \(error.localizedDescription, privacy: .public)")
                await MainActor.run {
                    task.status = .failed
                    task.lastErrorCode = "unexpected"
                    task.updatedAt = .now
                    self.activeTasks.removeAll { $0.taskID == task.taskID }
                    self.runningTasks.removeValue(forKey: task.taskID)
                    self.persistTask(task)
                }
                await processQueue()
                return
            }

            // 次の試行まで待機
            if let nextRetry = task.nextRetryAt {
                let delay = max(0, nextRetry.timeIntervalSinceNow)
                SVLogger.upload.info("UploadQueue: waiting \(delay, format: .fixed(precision: 1))s before retry taskID=\(task.taskID, privacy: .public)")
                try? await Task.sleep(for: .seconds(delay))
            } else {
                // 指数バックオフ: 1, 2, 4, 8, ... 秒（上限 512 秒）
                let retryIndex = min(task.retryCount, 9)
                let delay = min(baseDelay * pow(2.0, Double(retryIndex)), 512.0)
                SVLogger.upload.info("UploadQueue: exponential backoff \(delay, format: .fixed(precision: 1))s taskID=\(task.taskID, privacy: .public) retry=\(task.retryCount)")
                try? await Task.sleep(for: .seconds(delay))
            }
        }

        // 最大リトライ超過
        await MainActor.run {
            task.status = .failed
            task.lastErrorCode = "max_retry_exceeded"
            task.updatedAt = .now
            self.activeTasks.removeAll { $0.taskID == task.taskID }
            self.runningTasks.removeValue(forKey: task.taskID)
            self.persistTask(task)
            SVLogger.upload.error("UploadQueue: max retry exceeded taskID=\(task.taskID, privacy: .public)")
        }
        await processQueue()
    }

    /// エラー種別に応じたハンドリング。続行すべきなら true を返す。
    @MainActor
    private func handleUploadError(
        _ error: ScreenVaultError,
        task: UploadTask,
        maxRetry: Int
    ) async -> Bool {
        switch error {
        case .rateLimited(let retryAfter):
            // 429: Retry-After 尊重
            let delay = retryAfter ?? 60.0
            task.lastErrorCode = "429"
            task.nextRetryAt = Date(timeIntervalSinceNow: delay)
            task.retryCount += 1
            task.updatedAt = .now
            persistTask(task)
            SVLogger.upload.warning("UploadQueue: rate limited, retry after \(delay, format: .fixed(precision: 1))s taskID=\(task.taskID, privacy: .public)")
            return task.retryCount <= maxRetry

        case .uploadSessionExpired:
            // セッション期限切れ: セッション参照をクリアして再試行
            task.uploadSessionRef = nil
            task.lastErrorCode = "session_expired"
            task.retryCount += 1
            task.nextRetryAt = nil // すぐ再試行
            task.updatedAt = .now
            persistTask(task)
            SVLogger.upload.warning("UploadQueue: session expired, will recreate session taskID=\(task.taskID, privacy: .public)")
            return task.retryCount <= maxRetry

        case .networkUnavailable:
            // ネットワーク断: 復帰を待つ（processQueue は observe で再呼び出し）
            task.lastErrorCode = "network_unavailable"
            task.status = .pending
            task.updatedAt = .now
            activeTasks.removeAll { $0.taskID == task.taskID }
            runningTasks.removeValue(forKey: task.taskID)
            queuedTasks.insert(task, at: 0) // 先頭に戻す
            persistTask(task)
            SVLogger.upload.warning("UploadQueue: network unavailable, task re-queued taskID=\(task.taskID, privacy: .public)")
            return false

        case .uploadFailed(_, let reason):
            // 5xx 系: 指数バックオフ
            task.lastErrorCode = "upload_failed"
            task.retryCount += 1
            task.nextRetryAt = nil // バックオフは executeWithRetry で計算
            task.updatedAt = .now
            persistTask(task)
            SVLogger.upload.warning("UploadQueue: upload failed (\(reason, privacy: .public)) retry=\(task.retryCount) taskID=\(task.taskID, privacy: .public)")
            return task.retryCount <= maxRetry

        default:
            // その他のエラー: 失敗として確定
            task.status = .failed
            task.lastErrorCode = error.errorDescription ?? "unknown"
            task.updatedAt = .now
            activeTasks.removeAll { $0.taskID == task.taskID }
            runningTasks.removeValue(forKey: task.taskID)
            persistTask(task)
            SVLogger.upload.error("UploadQueue: non-retryable error taskID=\(task.taskID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// 実際のアップロードを実行し、リモートファイル ID を返す。
    private func performUpload(task: UploadTask) async throws -> String {
        guard let asset = task.asset else {
            throw ScreenVaultError.uploadFailed(taskID: task.taskID, reason: "asset が nil")
        }

        guard let connector = providerManager.connector(for: task.accountID) else {
            throw ScreenVaultError.providerNotConnected(accountID: task.accountID)
        }

        guard let pathString = asset.localTempPath ?? asset.originalPath else {
            throw ScreenVaultError.fileNotFound(path: "(no path)")
        }

        let fileURL = URL(fileURLWithPath: pathString)
        let remoteFolderID = task.remoteParentFolderID ?? "root"

        // ファイル名は PathResolver で生成（ここでは簡易実装）
        let fileName = fileURL.lastPathComponent

        SVLogger.upload.info("UploadQueue: uploading \(fileName, privacy: .public) to folderID=\(remoteFolderID, privacy: .public) taskID=\(task.taskID, privacy: .public)")

        let remoteFileID = try await connector.uploadResumable(
            fileURL: fileURL,
            remoteFolderID: remoteFolderID,
            fileName: fileName
        )

        return remoteFileID
    }

    // MARK: - Private: Persistence helpers

    private func persistTask(_ task: UploadTask) {
        do {
            try modelContext.save()
        } catch {
            SVLogger.upload.error("UploadQueue: failed to persist task \(task.taskID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Private: Startup

    /// 起動時に未完了タスク（pending / uploading）を復元する
    private func loadPendingTasks() {
        // completed / failed / cancelled 以外のタスクを取得
        // SwiftData の #Predicate で OR が使えない場合があるため、
        // 全タスクを取得してフィルタリングする
        let descriptor = FetchDescriptor<UploadTask>(
            sortBy: [SortDescriptor(\.createdAt)]
        )
        do {
            let allTasks = try modelContext.fetch(descriptor)
            let incompleteTasks = allTasks.filter {
                $0.status == .pending || $0.status == .uploading
            }
            // uploading 状態で残ったものは pending に戻す（再起動対応）
            for task in incompleteTasks where task.status == .uploading {
                task.status = .pending
                task.updatedAt = .now
            }
            try modelContext.save()
            queuedTasks = incompleteTasks
            SVLogger.upload.info("UploadQueue: loaded \(incompleteTasks.count) pending tasks from store")
        } catch {
            SVLogger.upload.error("UploadQueue: failed to load pending tasks: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Private: Network observation

    private func observeNetworkChanges() {
        networkMonitor.$isConnected
            .receive(on: RunLoop.main)
            .sink { [weak self] isConnected in
                guard let self else { return }
                if isConnected {
                    SVLogger.upload.info("UploadQueue: network restored, resuming queue")
                    Task { @MainActor in
                        await self.processQueue()
                    }
                }
            }
            .store(in: &cancellables)
    }
}
