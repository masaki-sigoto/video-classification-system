import Foundation
import Network
import OSLog

// MARK: - NetworkMonitor

/// NWPathMonitor を使ってネットワーク状態を監視する ObservableObject。
///
/// 使用例:
/// ```swift
/// let monitor = NetworkMonitor()
/// monitor.$isConnected
///     .sink { connected in ... }
/// ```
@MainActor
final class NetworkMonitor: ObservableObject {

    // MARK: - Published

    /// ネットワークが利用可能かどうか
    @Published private(set) var isConnected: Bool = false

    /// セルラーなどコスト高の回線を使用しているかどうか
    @Published private(set) var isExpensive: Bool = false

    // MARK: - Private

    private let monitor: NWPathMonitor
    private let monitorQueue: DispatchQueue

    // MARK: - Init / Deinit

    init() {
        self.monitor = NWPathMonitor()
        self.monitorQueue = DispatchQueue(label: "com.screenvault.networkmonitor", qos: .utility)
        startMonitoring()
    }

    deinit {
        monitor.cancel()
    }

    // MARK: - Public API

    /// 監視を明示的に停止する（通常は deinit で自動停止）
    func stop() {
        monitor.cancel()
        SVLogger.upload.info("NetworkMonitor: stopped")
    }

    // MARK: - Private helpers

    private func startMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let connected = path.status == .satisfied
            let expensive = path.isExpensive

            Task { @MainActor in
                let wasConnected = self.isConnected
                self.isConnected = connected
                self.isExpensive = expensive

                if connected && !wasConnected {
                    SVLogger.upload.info("NetworkMonitor: network restored (expensive=\(expensive))")
                } else if !connected && wasConnected {
                    SVLogger.upload.info("NetworkMonitor: network lost")
                }
            }
        }

        monitor.start(queue: monitorQueue)
        SVLogger.upload.info("NetworkMonitor: started")
    }
}

// MARK: - DuplicateDetector

/// ローカル DB に同一ハッシュ+サイズのアセットが存在するかを検出するユーティリティ。
///
/// 使用例:
/// ```swift
/// let result = try await DuplicateDetector.check(hash: sha256, sizeBytes: fileSize, in: context)
/// switch result {
/// case .unique: // 新規ファイルとして処理
/// case .duplicate(let existing): // 既存アセットをスキップ
/// }
/// ```
enum DuplicateDetector {

    /// 重複チェック結果
    enum CheckResult {
        /// 重複なし（新規ファイル）
        case unique
        /// 重複あり（既存アセットを返す）
        case duplicate(existing: Asset)
    }

    /// 指定したハッシュ値とサイズで SwiftData を検索し、重複を判定する。
    ///
    /// - Parameters:
    ///   - hash: SHA-256 ハッシュ文字列（64文字小文字16進）
    ///   - sizeBytes: ファイルサイズ（バイト）
    ///   - context: 検索に使用する ModelContext（MainActor 上で生成されたもの）
    /// - Returns: 重複チェック結果（`.unique` または `.duplicate(existing:)`）
    @MainActor
    static func check(
        hash: String,
        sizeBytes: Int64,
        in context: ModelContext
    ) throws -> CheckResult {
        guard !hash.isEmpty else { return .unique }

        let descriptor = FetchDescriptor<Asset>(
            predicate: #Predicate<Asset> {
                $0.contentHashSHA256 == hash && $0.sizeBytes == sizeBytes
            }
        )

        let matches = try context.fetch(descriptor)
        if let existing = matches.first {
            SVLogger.upload.info("DuplicateDetector: duplicate detected hash=\(hash.prefix(8), privacy: .public) existing=\(existing.assetID, privacy: .public)")
            return .duplicate(existing: existing)
        }

        return .unique
    }

    /// ハッシュ値のみで重複を検索する（サイズ不明の場合に使用）。
    ///
    /// - Parameters:
    ///   - hash: SHA-256 ハッシュ文字列
    ///   - context: 検索に使用する ModelContext
    /// - Returns: 重複チェック結果
    @MainActor
    static func checkByHash(
        hash: String,
        in context: ModelContext
    ) throws -> CheckResult {
        guard !hash.isEmpty else { return .unique }

        let descriptor = FetchDescriptor<Asset>(
            predicate: #Predicate<Asset> { $0.contentHashSHA256 == hash }
        )

        let matches = try context.fetch(descriptor)
        if let existing = matches.first {
            SVLogger.upload.info("DuplicateDetector: duplicate detected (hash-only) hash=\(hash.prefix(8), privacy: .public)")
            return .duplicate(existing: existing)
        }

        return .unique
    }
}
