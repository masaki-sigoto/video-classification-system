import Foundation
import OSLog

/// FSEvents を使ってフォルダを監視し、新規ファイルを AsyncStream で通知する
final class FolderWatcher: ObservableObject, @unchecked Sendable {

    // MARK: - Public state

    @Published private(set) var isWatching: Bool = false
    @Published private(set) var watchedURL: URL?

    // MARK: - Private

    private var eventStream: FSEventStreamRef?
    private let stabilizationInterval: TimeInterval
    /// ファイルパス → (前回サイズ, タイマー)
    private var pendingFiles: [String: (size: Int64, timer: DispatchWorkItem)] = [:]
    private let queue = DispatchQueue(label: "com.screenvault.folderwatcher", qos: .utility)

    private var continuations: [UUID: AsyncStream<URL>.Continuation] = [:]
    private let continuationsLock = NSLock()

    // MARK: - Init

    /// - Parameter stabilizationInterval: ファイルサイズが変化しなくなってから確定とみなすまでの秒数（デフォルト: 1秒）
    init(stabilizationInterval: TimeInterval = 1.0) {
        self.stabilizationInterval = stabilizationInterval
    }

    deinit {
        stopWatching()
    }

    // MARK: - Public API

    /// 新規ファイルを通知する AsyncStream を返す。
    /// `startWatching(url:)` を呼ぶ前でも登録できる。
    func newFileStream() -> AsyncStream<URL> {
        AsyncStream { continuation in
            let id = UUID()
            continuationsLock.lock()
            continuations[id] = continuation
            continuationsLock.unlock()

            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.continuationsLock.lock()
                self.continuations.removeValue(forKey: id)
                self.continuationsLock.unlock()
            }
        }
    }

    /// 指定フォルダの監視を開始する。
    /// 既に監視中の場合は一旦停止してから再開する。
    func startWatching(url: URL) {
        stopWatching()

        SVLogger.ingest.info("FolderWatcher: start watching \(url.path, privacy: .public)")

        let pathsToWatch = [url.path] as CFArray
        // passUnretained: FolderWatcher は呼び出し元が強参照を保持する前提。
        // stopWatching() でストリームを解放するため、コールバック実行中に self が解放されることはない。
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            fsEventCallback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventsCurrentEventId),
            0.5,   // latency (秒)
            flags
        ) else {
            SVLogger.ingest.error("FolderWatcher: FSEventStreamCreate failed for \(url.path, privacy: .public)")
            return
        }

        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)

        eventStream = stream
        watchedURL = url

        DispatchQueue.main.async { [weak self] in
            self?.isWatching = true
        }
        SVLogger.ingest.info("FolderWatcher: now watching \(url.path, privacy: .public)")
    }

    /// 監視を停止する。
    func stopWatching() {
        guard let stream = eventStream else { return }

        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        eventStream = nil

        // 未確定のタイマーをすべてキャンセル
        // FSEventStreamStop の後は queue からの新規コールバックは届かないため
        // queue.async でキャンセルを投入して安全にクリアする
        queue.async { [weak self] in
            guard let self else { return }
            for (_, item) in self.pendingFiles {
                item.timer.cancel()
            }
            self.pendingFiles.removeAll()
        }

        DispatchQueue.main.async { [weak self] in
            self?.isWatching = false
            self?.watchedURL = nil
        }
        SVLogger.ingest.info("FolderWatcher: stopped watching")
    }

    // MARK: - Internal: イベント処理

    /// FSEvents コールバックから呼ばれる（queue 上で実行）
    fileprivate func handleEvents(paths: [String], flags: [FSEventStreamEventFlags]) {
        for (path, flag) in zip(paths, flags) {
            // ディレクトリ自体の変更は無視
            guard (flag & UInt32(kFSEventStreamEventFlagItemIsDir)) == 0 else { continue }
            // 削除イベントは無視
            guard (flag & UInt32(kFSEventStreamEventFlagItemRemoved)) == 0 else { continue }
            // .DS_Store など隠しファイルは無視
            guard !path.hasSuffix(".DS_Store") else { continue }

            let isCreated = (flag & UInt32(kFSEventStreamEventFlagItemCreated)) != 0
            let isModified = (flag & UInt32(kFSEventStreamEventFlagItemModified)) != 0

            guard isCreated || isModified else { continue }

            scheduleStabilizationCheck(for: path)
        }
    }

    // MARK: - ファイル安定化検出

    private func scheduleStabilizationCheck(for path: String) {
        // 既存タイマーをキャンセル
        pendingFiles[path]?.timer.cancel()

        let currentSize = fileSize(at: path)

        let workItem = DispatchWorkItem { [weak self] in
            self?.confirmStabilization(path: path, expectedSize: currentSize)
        }

        pendingFiles[path] = (size: currentSize, timer: workItem)
        queue.asyncAfter(
            deadline: .now() + stabilizationInterval,
            execute: workItem
        )
    }

    private func confirmStabilization(path: String, expectedSize: Int64) {
        let currentSize = fileSize(at: path)
        guard currentSize == expectedSize, currentSize >= 0 else {
            // サイズが変化していたら再スケジュール
            scheduleStabilizationCheck(for: path)
            return
        }

        pendingFiles.removeValue(forKey: path)

        let url = URL(fileURLWithPath: path)
        SVLogger.ingest.info("FolderWatcher: stable file detected \(path, privacy: .public) (\(currentSize) bytes)")

        // すべての continuation に通知
        continuationsLock.lock()
        let conts = Array(continuations.values)
        continuationsLock.unlock()

        for cont in conts {
            cont.yield(url)
        }
    }

    // MARK: - Helpers

    private func fileSize(at path: String) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return (attrs?[.size] as? Int64) ?? -1
    }
}

// MARK: - FSEvents C コールバック

private func fsEventCallback(
    _ stream: ConstFSEventStreamRef,
    _ clientCallBackInfo: UnsafeMutableRawPointer?,
    _ numEvents: Int,
    _ eventPaths: UnsafeMutableRawPointer,
    _ eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    _ eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let info = clientCallBackInfo else { return }
    let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()

    guard let cfPaths = eventPaths as? NSArray as? [String] else { return }

    var flagsArray: [FSEventStreamEventFlags] = []
    for i in 0 ..< numEvents {
        flagsArray.append(eventFlags[i])
    }

    watcher.handleEvents(paths: cfPaths, flags: flagsArray)
}
