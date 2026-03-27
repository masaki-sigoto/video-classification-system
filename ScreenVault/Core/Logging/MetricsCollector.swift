import Foundation
import Combine
import SwiftData
import OSLog

// MARK: - DailyStats

/// 当日の集計データ
struct DailyStats: Sendable {
    /// 取り込み件数（今日 Asset が生成された件数）
    var ingestCount: Int
    /// アップロード成功数（今日 completed になった UploadTask 数）
    var uploadSuccess: Int
    /// アップロード失敗数（今日 failed になった UploadTask 数）
    var uploadFailed: Int
    /// 平均待ち時間（UploadTask の createdAt → updatedAt の平均秒数）
    var avgWaitSeconds: Double
    /// 総リトライ回数（今日の UploadTask の retryCount 合計）
    var retryCount: Int

    static var zero: DailyStats {
        DailyStats(
            ingestCount: 0,
            uploadSuccess: 0,
            uploadFailed: 0,
            avgWaitSeconds: 0,
            retryCount: 0
        )
    }
}

// MARK: - MetricsCollector

/// 取り込み・アップロードのメトリクスを集計する ObservableObject。
///
/// SwiftData の `ModelContext` を使ってデータを集計し、
/// `@Published var todayStats` を通じて UI に公開する。
///
/// - Note: ModelContext は MainActor 上で操作するため、`@MainActor` を付与する。
@MainActor
final class MetricsCollector: ObservableObject {

    // MARK: - Published

    /// 当日の集計データ（UI バインディング用）
    @Published private(set) var todayStats: DailyStats = .zero

    // MARK: - Dependencies

    private let modelContext: ModelContext

    // MARK: - Init

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Public API

    /// 当日のメトリクスを SwiftData から集計して `todayStats` を更新する。
    ///
    /// 重い処理ではないため MainActor 上で直接実行する。
    func refresh() {
        let stats = collectTodayStats()
        self.todayStats = stats
        SVLogger.general.info("""
            MetricsCollector: refresh 完了 \
            ingest=\(stats.ingestCount) \
            success=\(stats.uploadSuccess) \
            failed=\(stats.uploadFailed) \
            avgWait=\(String(format: "%.1f", stats.avgWaitSeconds))s \
            retry=\(stats.retryCount)
            """)
    }

    // MARK: - Private

    private func collectTodayStats() -> DailyStats {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
        guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else {
            return .zero
        }

        // 1. 取り込み件数（今日 capturedAt の Asset）
        let ingestCount = countIngestToday(startOfDay: startOfDay, endOfDay: endOfDay)

        // 2. アップロード成功/失敗数、待ち時間、リトライ
        let (uploadSuccess, uploadFailed, avgWait, retryCount) = collectUploadStats(
            startOfDay: startOfDay,
            endOfDay: endOfDay
        )

        return DailyStats(
            ingestCount: ingestCount,
            uploadSuccess: uploadSuccess,
            uploadFailed: uploadFailed,
            avgWaitSeconds: avgWait,
            retryCount: retryCount
        )
    }

    private func countIngestToday(startOfDay: Date, endOfDay: Date) -> Int {
        let descriptor = FetchDescriptor<Asset>(
            predicate: #Predicate<Asset> {
                $0.capturedAt >= startOfDay && $0.capturedAt < endOfDay
            }
        )
        let count = (try? modelContext.fetchCount(descriptor)) ?? 0
        return count
    }

    private func collectUploadStats(
        startOfDay: Date,
        endOfDay: Date
    ) -> (success: Int, failed: Int, avgWait: Double, retryCount: Int) {
        let descriptor = FetchDescriptor<UploadTask>(
            predicate: #Predicate<UploadTask> {
                $0.updatedAt >= startOfDay && $0.updatedAt < endOfDay
            }
        )

        guard let tasks = try? modelContext.fetch(descriptor) else {
            return (0, 0, 0, 0)
        }

        let successTasks = tasks.filter { $0.statusRawValue == UploadStatus.completed.rawValue }
        let failedTasks  = tasks.filter { $0.statusRawValue == UploadStatus.failed.rawValue }

        let success = successTasks.count
        let failed  = failedTasks.count

        // 平均待ち時間: createdAt → updatedAt の差分平均（完了タスクのみ）
        let avgWait: Double
        if successTasks.isEmpty {
            avgWait = 0
        } else {
            let totalWait = successTasks.reduce(0.0) { acc, task in
                acc + task.updatedAt.timeIntervalSince(task.createdAt)
            }
            avgWait = totalWait / Double(successTasks.count)
        }

        let retryCount = tasks.reduce(0) { $0 + $1.retryCount }

        return (success, failed, avgWait, retryCount)
    }
}
