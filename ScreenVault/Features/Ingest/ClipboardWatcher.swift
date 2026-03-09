import Foundation
import AppKit
import UniformTypeIdentifiers
import Combine
import OSLog

// MARK: - ClipboardContent

/// クリップボードから検出されたコンテンツの種別
enum ClipboardContent: Sendable {
    /// PNG または TIFF などの画像データ
    case image(Data, UTType)
    /// テキストデータ
    case text(String)
}

// MARK: - ClipboardWatcher

/// NSPasteboard の changeCount をポーリングしてクリップボード変化を検出するクラス。
///
/// - 監視間隔はデフォルト 2 秒（省電力設計）
/// - 画像（PNG/TIFF）とテキストを検出して `contentStream` に流す
/// - App がバックグラウンドでもタイマーは維持されるが、負荷は最小限
@MainActor
final class ClipboardWatcher: ObservableObject {

    // MARK: - Public State

    @Published private(set) var isWatching: Bool = false

    // MARK: - Public Stream

    /// クリップボード変化を通知する AsyncStream のコンティニュエーション
    private var continuation: AsyncStream<ClipboardContent>.Continuation?

    /// クリップボードに新しいコンテンツが検出されたときに流れる AsyncStream
    lazy var contentStream: AsyncStream<ClipboardContent> = {
        AsyncStream<ClipboardContent> { [weak self] continuation in
            self?.continuation = continuation
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.continuation = nil
                }
            }
        }
    }()

    // MARK: - Private

    /// ポーリングタイマー
    private var pollingTimer: Timer?
    /// 前回チェック時の changeCount
    private var lastChangeCount: Int
    /// ポーリング間隔（秒）
    private let pollingInterval: TimeInterval
    /// NSPasteboard の参照（テスト用にオーバーライド可能）
    private let pasteboard: NSPasteboard

    // MARK: - Init

    init(
        pollingInterval: TimeInterval = 2.0,
        pasteboard: NSPasteboard = .general
    ) {
        self.pollingInterval = pollingInterval
        self.pasteboard = pasteboard
        self.lastChangeCount = pasteboard.changeCount
    }

    // MARK: - Public API

    /// クリップボード監視を開始する。
    func startWatching() {
        guard !isWatching else {
            SVLogger.ingest.warning("ClipboardWatcher: already watching")
            return
        }

        SVLogger.ingest.info(
            "ClipboardWatcher: start watching (interval=\(self.pollingInterval)s)"
        )
        lastChangeCount = pasteboard.changeCount

        pollingTimer = Timer.scheduledTimer(
            withTimeInterval: pollingInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkPasteboard()
            }
        }
        // バックグラウンドでもタイマーを維持するために RunLoop に追加
        RunLoop.current.add(pollingTimer!, forMode: .common)

        isWatching = true
    }

    /// クリップボード監視を停止する。
    func stopWatching() {
        pollingTimer?.invalidate()
        pollingTimer = nil
        isWatching = false
        continuation?.finish()
        SVLogger.ingest.info("ClipboardWatcher: stopped watching")
    }

    /// クリップボードの現在のコンテンツを即座に取得する（手動トリガー用）。
    /// 監視中でなくても呼び出し可能。
    func captureCurrentContent() -> ClipboardContent? {
        return extractContent(from: pasteboard)
    }

    // MARK: - Private Polling

    private func checkPasteboard() {
        let currentCount = pasteboard.changeCount
        guard currentCount != lastChangeCount else { return }

        lastChangeCount = currentCount
        SVLogger.ingest.debug("ClipboardWatcher: changeCount changed to \(currentCount)")

        if let content = extractContent(from: pasteboard) {
            continuation?.yield(content)
        }
    }

    // MARK: - Content Extraction

    /// NSPasteboard からコンテンツを抽出する。
    /// 優先度: PNG > TIFF > テキスト
    private func extractContent(from pasteboard: NSPasteboard) -> ClipboardContent? {
        // PNG 画像を試みる
        if let pngData = pasteboard.data(forType: .png) {
            SVLogger.ingest.info(
                "ClipboardWatcher: detected PNG image, size=\(pngData.count) bytes"
            )
            return .image(pngData, .png)
        }

        // TIFF 画像を試みる
        if let tiffData = pasteboard.data(forType: .tiff) {
            SVLogger.ingest.info(
                "ClipboardWatcher: detected TIFF image, size=\(tiffData.count) bytes"
            )
            return .image(tiffData, .tiff)
        }

        // テキストを試みる
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            SVLogger.ingest.info(
                "ClipboardWatcher: detected text, length=\(text.count) chars"
            )
            return .text(text)
        }

        // 他の画像形式を確認（JPEG など）
        if let types = pasteboard.types {
            for type in types {
                if let utType = UTType(type.rawValue),
                   utType.conforms(to: .image),
                   let imageData = pasteboard.data(forType: type) {
                    SVLogger.ingest.info(
                        "ClipboardWatcher: detected image type=\(type.rawValue, privacy: .public)"
                    )
                    return .image(imageData, utType)
                }
            }
        }

        SVLogger.ingest.debug("ClipboardWatcher: no supported content found in pasteboard")
        return nil
    }

}
