import Foundation
import SwiftData
import CryptoKit
import UniformTypeIdentifiers
import OSLog

// MARK: - IngestPipeline

/// FolderWatcher からの通知を受け取り、Asset を生成・保存するパイプライン
final class IngestPipeline: @unchecked Sendable {

    // MARK: - Dependencies

    private let modelContext: ModelContext

    // MARK: - Init

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Public API

    /// ファイルを処理して Asset を生成・保存する。
    /// - Parameters:
    ///   - fileURL: 処理するファイルの URL
    ///   - sourceMode: 取り込み元モード（watch / capture / manual 等）
    /// - Returns: 生成・保存された Asset
    @MainActor
    func process(fileURL: URL, sourceMode: SourceMode) async throws -> Asset {
        SVLogger.ingest.info("IngestPipeline: processing \(fileURL.lastPathComponent, privacy: .public)")

        // 1. ファイルメタデータ抽出
        let metadata = try extractMetadata(from: fileURL)
        SVLogger.ingest.debug("IngestPipeline: metadata extracted kind=\(metadata.kind.rawValue, privacy: .public) size=\(metadata.sizeBytes)")

        // 2. SHA-256 ハッシュ計算（重複検出用 — バックグラウンドスレッドで実行）
        let sha256Hash = try await computeSHA256(fileURL: fileURL)
        SVLogger.ingest.debug("IngestPipeline: SHA-256 computed for \(fileURL.lastPathComponent, privacy: .public)")

        // 3. 重複チェック（同じハッシュが既に存在する場合はスキップ）
        let descriptor = FetchDescriptor<Asset>(
            predicate: #Predicate { $0.contentHashSHA256 == sha256Hash }
        )
        if let existing = try modelContext.fetch(descriptor).first {
            SVLogger.ingest.info("IngestPipeline: duplicate detected, skipping \(fileURL.lastPathComponent, privacy: .public) existing=\(existing.assetID, privacy: .public)")
            return existing
        }

        // 4. SwiftData に Asset 保存
        let asset = Asset(
            kind: metadata.kind,
            sourceMode: sourceMode,
            capturedAt: metadata.capturedAt,
            sizeBytes: metadata.sizeBytes
        )
        asset.originalPath      = fileURL.path
        asset.localTempPath     = fileURL.path
        asset.contentHashSHA256 = sha256Hash

        modelContext.insert(asset)
        try modelContext.save()

        SVLogger.ingest.info("IngestPipeline: asset saved \(asset.assetID, privacy: .public) kind=\(asset.kind.rawValue, privacy: .public)")

        // 5. 分類パイプラインへ引き渡し（Phase 1.8 で実装予定）
        scheduleClassification(for: asset)

        return asset
    }

    // MARK: - Metadata extraction

    private struct FileMetadata {
        let kind: AssetKind
        let sizeBytes: Int64
        let capturedAt: Date
        let contentType: UTType?
    }

    private func extractMetadata(from url: URL) throws -> FileMetadata {
        let resourceValues = try url.resourceValues(
            forKeys: [.fileSizeKey, .contentModificationDateKey, .contentTypeKey]
        )

        let sizeBytes   = Int64(resourceValues.fileSize ?? 0)
        let capturedAt  = resourceValues.contentModificationDate ?? .now
        let contentType = resourceValues.contentType

        let kind = assetKind(for: url, contentType: contentType)

        return FileMetadata(
            kind: kind,
            sizeBytes: sizeBytes,
            capturedAt: capturedAt,
            contentType: contentType
        )
    }

    /// UTI とファイル拡張子から AssetKind を判定する
    private func assetKind(for url: URL, contentType: UTType?) -> AssetKind {
        // 動画系
        if let type = contentType, type.conforms(to: .movie) || type.conforms(to: .video) {
            // macOS スクリーンレコーディングは通常 .mov
            let ext = url.pathExtension.lowercased()
            if ext == "mov" || ext == "mp4" {
                return .screenRecording
            }
            return .video
        }

        // 画像系（スクリーンショット）
        if let type = contentType, type.conforms(to: .image) {
            return .screenshot
        }

        // テキスト系
        if let type = contentType, type.conforms(to: .text) {
            return .text
        }

        // 拡張子ベースのフォールバック
        switch url.pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "tiff", "heic", "bmp", "webp":
            return .screenshot
        case "mov", "mp4", "m4v", "avi", "mkv":
            return .screenRecording
        case "txt", "md", "rtf":
            return .text
        default:
            return .screenshot
        }
    }

    // MARK: - SHA-256 ハッシュ計算

    /// ファイルをストリーミング読み込みしながら SHA-256 を計算する（メモリ効率的）
    private func computeSHA256(fileURL: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            let bufferSize = 1024 * 1024 // 1 MB チャンク
            guard let stream = InputStream(url: fileURL) else {
                throw ScreenVaultError.unknown("SHA-256: ファイルを開けません: \(fileURL.path)")
            }

            stream.open()
            defer { stream.close() }

            var hasher = SHA256()
            var buffer = [UInt8](repeating: 0, count: bufferSize)

            while stream.hasBytesAvailable {
                let bytesRead = stream.read(&buffer, maxLength: bufferSize)
                if bytesRead < 0 {
                    throw ScreenVaultError.unknown("SHA-256: ストリーム読み込みエラー")
                }
                if bytesRead == 0 { break }
                hasher.update(data: Data(buffer[0 ..< bytesRead]))
            }

            let digest = hasher.finalize()
            return digest.map { String(format: "%02x", $0) }.joined()
        }.value
    }

    // MARK: - 分類パイプライン（スタブ）

    /// 分類パイプラインへの引き渡し（Phase 1.8 で本実装）
    private func scheduleClassification(for asset: Asset) {
        // Phase 1.8 実装まではログのみ
        SVLogger.ingest.info("IngestPipeline: classification scheduled for \(asset.assetID, privacy: .public) [stub - Phase 1.8]")
    }
}

// MARK: - FolderWatcher との統合ヘルパー

extension IngestPipeline {
    /// FolderWatcher の newFileStream() を監視し、順次 process する。
    /// Task がキャンセルされるまでループする。
    func startConsuming(from watcher: FolderWatcher, sourceMode: SourceMode = .watch) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let stream = watcher.newFileStream()
            for await fileURL in stream {
                guard !Task.isCancelled else { break }
                do {
                    _ = try await self.process(fileURL: fileURL, sourceMode: sourceMode)
                } catch {
                    SVLogger.ingest.error("IngestPipeline: failed to process \(fileURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }
}
