import Foundation
import Vision
import CoreML
import CoreImage
import OSLog

// MARK: - ImageClassifier

/// Vision フレームワークの組み込み画像分類モデルを使用して
/// 画像のカテゴリを推定するクラス。
///
/// - `VNClassifyImageRequest` で Apple 組み込みモデルを使用（追加モデル不要）
/// - カスタムモデルの差し込みポイント（`VNCoreMLRequest`）を用意
/// - 上位3件のラベルと信頼度を返す
final class ImageClassifier: @unchecked Sendable {

    // MARK: - Configuration

    /// 返す最大ラベル件数
    private let topK: Int
    /// 信頼度の下限閾値（これ未満のラベルは除外）
    private let confidenceThreshold: Float
    /// カスタム CoreML モデル（nilの場合は組み込みモデルを使用）
    private var customMLModel: VNCoreMLModel?

    // MARK: - Init

    /// - Parameters:
    ///   - topK: 返すラベルの上限件数（デフォルト 3）
    ///   - confidenceThreshold: 信頼度の下限閾値（デフォルト 0.05）
    init(topK: Int = 3, confidenceThreshold: Float = 0.05) {
        self.topK = topK
        self.confidenceThreshold = confidenceThreshold
    }

    // MARK: - Custom Model (拡張ポイント)

    /// カスタム CoreML モデルを設定する。
    /// 設定後は `VNCoreMLRequest` を使用してカスタムモデルで分類する。
    /// - Parameter mlModel: CoreML モデル（`MLModel` インスタンス）
    func setCustomModel(_ mlModel: MLModel) throws {
        self.customMLModel = try VNCoreMLModel(for: mlModel)
        SVLogger.classification.info("ImageClassifier: custom CoreML model configured")
    }

    /// カスタムモデルを解除し、組み込みモデルに戻す。
    func clearCustomModel() {
        customMLModel = nil
        SVLogger.classification.info("ImageClassifier: reverted to built-in classification model")
    }

    // MARK: - Public API

    /// 画像ファイルを分類して、ラベルと信頼度のリストを返す。
    /// - Parameter imageURL: 対象画像のファイル URL
    /// - Returns: (label: ラベル名, confidence: 0.0〜1.0) の上位 K 件
    func classify(imageURL: URL) async throws -> [(label: String, confidence: Float)] {
        SVLogger.classification.info(
            "ImageClassifier: classify from file \(imageURL.lastPathComponent, privacy: .public)"
        )

        guard let cgImage = loadCGImage(from: imageURL) else {
            throw ImageClassifierError.imageLoadFailed(imageURL.path)
        }

        return try await performClassification(on: cgImage)
    }

    /// 画像データを分類して、ラベルと信頼度のリストを返す。
    /// - Parameter imageData: PNG/TIFF/JPEG などの画像データ
    /// - Returns: (label: ラベル名, confidence: 0.0〜1.0) の上位 K 件
    func classify(imageData: Data) async throws -> [(label: String, confidence: Float)] {
        SVLogger.classification.info(
            "ImageClassifier: classify from data size=\(imageData.count) bytes"
        )

        guard let cgImage = loadCGImage(from: imageData) else {
            throw ImageClassifierError.imageLoadFailed("<memory data>")
        }

        return try await performClassification(on: cgImage)
    }

    // MARK: - Private: Classification

    private func performClassification(
        on cgImage: CGImage
    ) async throws -> [(label: String, confidence: Float)] {
        if let customModel = customMLModel {
            return try await classifyWithCoreMLModel(customModel, on: cgImage)
        } else {
            return try await classifyWithBuiltInModel(on: cgImage)
        }
    }

    /// Apple 組み込みの VNClassifyImageRequest を使用した分類
    private func classifyWithBuiltInModel(
        on cgImage: CGImage
    ) async throws -> [(label: String, confidence: Float)] {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNClassifyImageRequest { request, error in
                if let error {
                    SVLogger.classification.error(
                        "ImageClassifier: VNClassifyImageRequest error: \(error.localizedDescription, privacy: .public)"
                    )
                    continuation.resume(throwing: ImageClassifierError.visionRequestFailed(error))
                    return
                }

                let observations = (request.results as? [VNClassificationObservation]) ?? []
                let results = observations
                    .filter { $0.confidence >= self.confidenceThreshold }
                    .prefix(self.topK)
                    .map { (label: $0.identifier, confidence: $0.confidence) }

                SVLogger.classification.info(
                    "ImageClassifier: built-in model returned \(results.count) label(s)"
                )
                for item in results {
                    SVLogger.classification.debug(
                        "ImageClassifier: label=\(item.label, privacy: .public) confidence=\(item.confidence)"
                    )
                }

                continuation.resume(returning: Array(results))
            }

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                SVLogger.classification.error(
                    "ImageClassifier: handler.perform failed: \(error.localizedDescription, privacy: .public)"
                )
                continuation.resume(throwing: ImageClassifierError.visionRequestFailed(error))
            }
        }
    }

    /// カスタム VNCoreMLModel を使用した分類（拡張ポイント）
    private func classifyWithCoreMLModel(
        _ model: VNCoreMLModel,
        on cgImage: CGImage
    ) async throws -> [(label: String, confidence: Float)] {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNCoreMLRequest(model: model) { request, error in
                if let error {
                    SVLogger.classification.error(
                        "ImageClassifier: VNCoreMLRequest error: \(error.localizedDescription, privacy: .public)"
                    )
                    continuation.resume(throwing: ImageClassifierError.visionRequestFailed(error))
                    return
                }

                // VNClassificationObservation に対応するモデルの場合
                if let observations = request.results as? [VNClassificationObservation] {
                    let results = observations
                        .filter { $0.confidence >= self.confidenceThreshold }
                        .prefix(self.topK)
                        .map { (label: $0.identifier, confidence: $0.confidence) }

                    SVLogger.classification.info(
                        "ImageClassifier: CoreML model returned \(results.count) label(s)"
                    )
                    continuation.resume(returning: Array(results))
                    return
                }

                // その他の結果型は空として返す（カスタムモデル依存）
                SVLogger.classification.warning(
                    "ImageClassifier: CoreML model returned unsupported result type"
                )
                continuation.resume(returning: [])
            }

            request.imageCropAndScaleOption = .centerCrop

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                SVLogger.classification.error(
                    "ImageClassifier: CoreML handler.perform failed: \(error.localizedDescription, privacy: .public)"
                )
                continuation.resume(throwing: ImageClassifierError.visionRequestFailed(error))
            }
        }
    }

    // MARK: - Private: Image Loading

    private func loadCGImage(from url: URL) -> CGImage? {
        // CGDataProvider 経由
        guard let dataProvider = CGDataProvider(url: url as CFURL) else { return nil }

        if let image = CGImage(
            pngDataProviderSource: dataProvider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) { return image }

        if let image = CGImage(
            jpegDataProviderSource: dataProvider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) { return image }

        // CIImage 経由でその他形式（HEIC, TIFF 等）に対応
        return ciImageToCGImage(CIImage(contentsOf: url))
    }

    private func loadCGImage(from data: Data) -> CGImage? {
        guard let dataProvider = CGDataProvider(data: data as CFData) else { return nil }

        if let image = CGImage(
            pngDataProviderSource: dataProvider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) { return image }

        if let image = CGImage(
            jpegDataProviderSource: dataProvider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) { return image }

        return ciImageToCGImage(CIImage(data: data))
    }

    private func ciImageToCGImage(_ ciImage: CIImage?) -> CGImage? {
        guard let ciImage else { return nil }
        let context = CIContext(options: [.useSoftwareRenderer: false])
        return context.createCGImage(ciImage, from: ciImage.extent)
    }
}

// MARK: - ImageClassifierError

enum ImageClassifierError: LocalizedError {
    case imageLoadFailed(String)
    case visionRequestFailed(Error)
    case modelConfigurationFailed(String)

    var errorDescription: String? {
        switch self {
        case .imageLoadFailed(let path):
            return "画像の読み込みに失敗しました: \(path)"
        case .visionRequestFailed(let error):
            return "画像分類に失敗しました: \(error.localizedDescription)"
        case .modelConfigurationFailed(let reason):
            return "モデルの設定に失敗しました: \(reason)"
        }
    }
}
