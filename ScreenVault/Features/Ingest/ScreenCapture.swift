import Foundation
import ScreenCaptureKit
import CoreGraphics
import CoreMedia
import AppKit
import AVFoundation
import OSLog

// MARK: - ScreenCapture

/// ScreenCaptureKit を使用してスクリーンショット・画面録画を行うクラス。
/// macOS 14.0+ 必須。
final class ScreenCapture: NSObject, @unchecked Sendable {

    // MARK: - Private State

    /// 現在進行中の SCStream（録画中のみ非 nil）
    private var activeStream: SCStream?
    /// 録画出力先の一時ファイル URL
    private var recordingOutputURL: URL?
    /// 録画ライター
    private var recordingWriter: RecordingWriter?
    /// 並行アクセスを保護するシリアルキュー
    private let queue = DispatchQueue(label: "com.screenvault.screencapture", qos: .userInitiated)

    // MARK: - Public API

    /// 画面全体のスクリーンショットを PNG データとして取得する。
    /// - Returns: PNG 形式の画像データ
    func captureScreen() async throws -> Data {
        SVLogger.ingest.info("ScreenCapture: captureScreen started")

        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        guard let display = content.displays.first else {
            SVLogger.ingest.error("ScreenCapture: no display available")
            throw ScreenCaptureError.noDisplayAvailable
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.width = display.width
        config.height = display.height

        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )

        guard let pngData = cgImageToPNGData(image) else {
            SVLogger.ingest.error("ScreenCapture: failed to convert CGImage to PNG")
            throw ScreenCaptureError.imageConversionFailed
        }

        SVLogger.ingest.info("ScreenCapture: captureScreen completed, size=\(pngData.count) bytes")
        return pngData
    }

    /// フロントウィンドウを PNG データとして取得する。
    /// - Returns: PNG 形式の画像データ
    func captureWindow() async throws -> Data {
        SVLogger.ingest.info("ScreenCapture: captureWindow started")

        let frontApp = NSWorkspace.shared.frontmostApplication
        SVLogger.ingest.debug(
            "ScreenCapture: frontmost app=\(frontApp?.localizedName ?? "unknown", privacy: .public)"
        )

        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )

        // フロントアプリのウィンドウを取得
        let targetWindows: [SCWindow]
        if let frontApp {
            targetWindows = content.windows.filter { window in
                window.owningApplication?.bundleIdentifier == frontApp.bundleIdentifier
                    && window.isOnScreen
                    && window.frame.width > 0
                    && window.frame.height > 0
            }
        } else {
            targetWindows = content.windows.filter {
                $0.isOnScreen && $0.frame.width > 0 && $0.frame.height > 0
            }
        }

        guard let targetWindow = targetWindows.first else {
            SVLogger.ingest.error("ScreenCapture: no suitable window found")
            throw ScreenCaptureError.noWindowAvailable
        }

        // ウィンドウ単体をキャプチャするフィルタ（desktopIndependentWindow を使用）
        let filter = SCContentFilter(desktopIndependentWindow: targetWindow)
        let config = SCStreamConfiguration()
        config.pixelFormat = kCVPixelFormatType_32BGRA
        let windowFrame = targetWindow.frame
        config.width = Int(windowFrame.width)
        config.height = Int(windowFrame.height)

        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )

        guard let pngData = cgImageToPNGData(image) else {
            SVLogger.ingest.error("ScreenCapture: failed to convert CGImage to PNG")
            throw ScreenCaptureError.imageConversionFailed
        }

        SVLogger.ingest.info(
            "ScreenCapture: captureWindow completed, size=\(pngData.count) bytes"
        )
        return pngData
    }

    /// 画面録画を開始する。
    /// - Parameter url: 録画データの書き出し先一時ファイル URL（.mov 推奨）
    func startRecording(to url: URL) async throws {
        SVLogger.ingest.info(
            "ScreenCapture: startRecording to \(url.lastPathComponent, privacy: .public)"
        )

        guard activeStream == nil else {
            SVLogger.ingest.warning("ScreenCapture: recording already in progress")
            throw ScreenCaptureError.alreadyRecording
        }

        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        guard let display = content.displays.first else {
            SVLogger.ingest.error("ScreenCapture: no display available for recording")
            throw ScreenCaptureError.noDisplayAvailable
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let streamConfig = SCStreamConfiguration()
        // Retina ディスプレイでは 2x で出力
        streamConfig.width = display.width * 2
        streamConfig.height = display.height * 2
        streamConfig.pixelFormat = kCVPixelFormatType_32BGRA
        streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: 30) // 30fps

        let writer = RecordingWriter(
            outputURL: url,
            width: display.width * 2,
            height: display.height * 2
        )
        try writer.prepare()

        let stream = SCStream(filter: filter, configuration: streamConfig, delegate: nil)
        try stream.addStreamOutput(writer, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()

        self.activeStream = stream
        self.recordingOutputURL = url
        self.recordingWriter = writer

        SVLogger.ingest.info("ScreenCapture: recording started")
    }

    /// 録画を停止し、書き出したファイルの URL を返す。
    /// - Returns: 書き出し完了した動画ファイルの URL
    func stopRecording() async throws -> URL {
        SVLogger.ingest.info("ScreenCapture: stopRecording requested")

        guard let stream = activeStream else {
            SVLogger.ingest.error("ScreenCapture: no active recording to stop")
            throw ScreenCaptureError.notRecording
        }

        try await stream.stopCapture()
        let outputURL = recordingOutputURL

        // ライターを終了してファイルを確定する
        await recordingWriter?.finish()

        activeStream = nil
        recordingOutputURL = nil
        recordingWriter = nil

        guard let url = outputURL else {
            throw ScreenCaptureError.recordingOutputMissing
        }

        SVLogger.ingest.info(
            "ScreenCapture: recording stopped, output=\(url.lastPathComponent, privacy: .public)"
        )
        return url
    }

    // MARK: - Private Helpers

    /// CGImage を PNG の Data に変換する
    private func cgImageToPNGData(_ cgImage: CGImage) -> Data? {
        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        return bitmapRep.representation(using: .png, properties: [:])
    }
}

// MARK: - ScreenCaptureError

enum ScreenCaptureError: LocalizedError {
    case noDisplayAvailable
    case noWindowAvailable
    case imageConversionFailed
    case alreadyRecording
    case notRecording
    case recordingOutputMissing
    case writerSetupFailed(String)

    var errorDescription: String? {
        switch self {
        case .noDisplayAvailable:
            return "利用可能なディスプレイがありません。"
        case .noWindowAvailable:
            return "キャプチャ可能なウィンドウが見つかりません。"
        case .imageConversionFailed:
            return "画像の変換に失敗しました。"
        case .alreadyRecording:
            return "既に録画中です。"
        case .notRecording:
            return "録画が開始されていません。"
        case .recordingOutputMissing:
            return "録画出力ファイルのパスが不明です。"
        case .writerSetupFailed(let reason):
            return "録画ライターの初期化に失敗しました: \(reason)"
        }
    }
}

// MARK: - RecordingWriter

/// SCStreamOutput を実装して CMSampleBuffer を AVAssetWriter でファイルに書き出すクラス
private final class RecordingWriter: NSObject, SCStreamOutput, @unchecked Sendable {

    private let outputURL: URL
    private let videoWidth: Int
    private let videoHeight: Int

    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var sessionStarted = false
    /// バッファの排他制御
    private let lock = NSLock()

    init(outputURL: URL, width: Int, height: Int) {
        self.outputURL = outputURL
        self.videoWidth = width
        self.videoHeight = height
        super.init()
    }

    /// AVAssetWriter を準備する（startRecording から呼ぶ）
    func prepare() throws {
        let writer: AVAssetWriter
        do {
            // 既存ファイルがあれば削除
            if FileManager.default.fileExists(atPath: outputURL.path) {
                try FileManager.default.removeItem(at: outputURL)
            }
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        } catch {
            throw ScreenCaptureError.writerSetupFailed(error.localizedDescription)
        }

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: videoWidth,
            AVVideoHeightKey: videoHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 8_000_000, // 8 Mbps
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = true
        // 画面キャプチャは上下が正常なので変換不要
        input.transform = CGAffineTransform.identity

        writer.add(input)
        guard writer.startWriting() else {
            throw ScreenCaptureError.writerSetupFailed(
                writer.error?.localizedDescription ?? "startWriting returned false"
            )
        }

        self.assetWriter = writer
        self.videoInput = input
    }

    // MARK: - SCStreamOutput

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen else { return }
        guard CMSampleBufferIsValid(sampleBuffer) else { return }
        guard let writer = assetWriter, writer.status == .writing else { return }
        guard let input = videoInput else { return }

        lock.lock()
        defer { lock.unlock() }

        if !sessionStarted {
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            writer.startSession(atSourceTime: pts)
            sessionStarted = true
            SVLogger.ingest.debug("RecordingWriter: session started")
        }

        if input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
        }
    }

    /// 書き込みを完了してファイルを確定する
    func finish() async {
        guard let writer = assetWriter, writer.status == .writing else { return }
        videoInput?.markAsFinished()
        await writer.finishWriting()
        SVLogger.ingest.info(
            "RecordingWriter: file finalized at \(self.outputURL.lastPathComponent, privacy: .public)"
        )
    }
}
