import Foundation
import Vision
import CoreImage
import OSLog

// MARK: - OCRClassifier

/// Vision フレームワークを使用して画像からテキストを抽出し、
/// 分類ルールに基づいてタグを付与するクラス。
///
/// - OCR ON/OFF は UserDefaults "ocrEnabled" キーで制御
/// - 日本語・英語を同時認識（revision 3 以降推奨）
final class OCRClassifier: @unchecked Sendable {

    // MARK: - UserDefaults Keys

    static let ocrEnabledKey = "ocrEnabled"

    // MARK: - Properties

    /// OCR が有効かどうか（UserDefaults から読み込む）
    var isOCREnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.ocrEnabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.ocrEnabledKey) }
    }

    // MARK: - Init

    init() {}

    // MARK: - Public API: Text Extraction

    /// 画像ファイルから日本語・英語のテキストを抽出する。
    /// - Parameter imageURL: 対象画像のファイル URL
    /// - Returns: 抽出されたテキスト（改行区切り）
    func extractText(from imageURL: URL) async throws -> String {
        guard isOCREnabled else {
            SVLogger.classification.info("OCRClassifier: OCR is disabled, skipping")
            return ""
        }

        SVLogger.classification.info(
            "OCRClassifier: extractText from file \(imageURL.lastPathComponent, privacy: .public)"
        )

        guard let cgImage = loadCGImage(from: imageURL) else {
            throw OCRClassifierError.imageLoadFailed(imageURL.path)
        }

        return try await performOCR(on: cgImage)
    }

    /// 画像データから日本語・英語のテキストを抽出する。
    /// - Parameter imageData: PNG/TIFF/JPEG などの画像データ
    /// - Returns: 抽出されたテキスト（改行区切り）
    func extractText(from imageData: Data) async throws -> String {
        guard isOCREnabled else {
            SVLogger.classification.info("OCRClassifier: OCR is disabled, skipping")
            return ""
        }

        SVLogger.classification.info(
            "OCRClassifier: extractText from data size=\(imageData.count) bytes"
        )

        guard let cgImage = loadCGImage(from: imageData) else {
            throw OCRClassifierError.imageLoadFailed("<memory data>")
        }

        return try await performOCR(on: cgImage)
    }

    // MARK: - Public API: Classification

    /// 抽出テキストを分類ルールに照らし合わせてタグと信頼度を返す。
    /// - Parameters:
    ///   - text: OCR で抽出したテキスト
    ///   - rules: 適用する分類ルール群
    /// - Returns: (tag: タグ名, confidence: 0.0〜1.0) のリスト
    func classify(
        text: String,
        rules: [ClassificationRule]
    ) -> [(tag: String, confidence: Float)] {
        guard !text.isEmpty else { return [] }

        SVLogger.classification.info(
            "OCRClassifier: classifying text (length=\(text.count))"
        )

        var results: [(tag: String, confidence: Float)] = []
        let normalizedText = text.lowercased()

        for rule in rules where rule.enabled {
            for condition in rule.conditions {
                let matchScore = evaluateCondition(condition, against: normalizedText)
                guard matchScore > 0 else { continue }

                // マッチした場合、ルールのアクションをタグとして返す
                for action in rule.actions where action.actionType == .addTag {
                    let tag = action.actionValue
                    // 既に同タグがあれば信頼度を更新（最大値採用）
                    if let index = results.firstIndex(where: { $0.tag == tag }) {
                        if matchScore > results[index].confidence {
                            results[index] = (tag: tag, confidence: matchScore)
                        }
                    } else {
                        results.append((tag: tag, confidence: matchScore))
                    }
                }
            }
        }

        // 信頼度の高い順にソート
        let sorted = results.sorted { $0.confidence > $1.confidence }
        SVLogger.classification.info(
            "OCRClassifier: classified \(sorted.count) tag(s)"
        )
        return sorted
    }

    // MARK: - Private: OCR

    private func performOCR(on cgImage: CGImage) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    SVLogger.classification.error(
                        "OCRClassifier: VNRecognizeTextRequest error: \(error.localizedDescription, privacy: .public)"
                    )
                    continuation.resume(throwing: OCRClassifierError.visionRequestFailed(error))
                    return
                }

                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let extractedLines = observations.compactMap { observation in
                    // topCandidates(1) は信頼度最高の候補を返す
                    observation.topCandidates(1).first?.string
                }
                let fullText = extractedLines.joined(separator: "\n")

                SVLogger.classification.info(
                    "OCRClassifier: extracted \(extractedLines.count) text line(s)"
                )
                continuation.resume(returning: fullText)
            }

            // 日本語・英語の両言語を認識
            request.recognitionLanguages = ["ja-JP", "en-US"]
            // 精度優先モード
            request.recognitionLevel = .accurate
            // 言語補正を有効化（誤認識を減らす）
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                SVLogger.classification.error(
                    "OCRClassifier: VNImageRequestHandler.perform failed: \(error.localizedDescription, privacy: .public)"
                )
                continuation.resume(throwing: OCRClassifierError.visionRequestFailed(error))
            }
        }
    }

    // MARK: - Private: Image Loading

    private func loadCGImage(from url: URL) -> CGImage? {
        guard let dataProvider = CGDataProvider(url: url as CFURL) else { return nil }
        // まず PNG を試し、次に JPEG を試みる（汎用対応）
        if let image = CGImage(
            pngDataProviderSource: dataProvider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) {
            return image
        }
        if let image = CGImage(
            jpegDataProviderSource: dataProvider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) {
            return image
        }
        // CIImage 経由でその他形式に対応
        let ciImage = CIImage(contentsOf: url)
        return ciImage.flatMap { cgImageFromCIImage($0) }
    }

    private func loadCGImage(from data: Data) -> CGImage? {
        guard let dataProvider = CGDataProvider(data: data as CFData) else { return nil }
        if let image = CGImage(
            pngDataProviderSource: dataProvider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) {
            return image
        }
        if let image = CGImage(
            jpegDataProviderSource: dataProvider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) {
            return image
        }
        let ciImage = CIImage(data: data)
        return ciImage.flatMap { cgImageFromCIImage($0) }
    }

    private func cgImageFromCIImage(_ ciImage: CIImage) -> CGImage? {
        let context = CIContext(options: [.useSoftwareRenderer: false])
        return context.createCGImage(ciImage, from: ciImage.extent)
    }

    // MARK: - Private: Condition Evaluation

    /// 条件をテキストに対して評価し、0.0〜1.0 の一致スコアを返す。
    /// 一致しない場合は 0.0
    private func evaluateCondition(
        _ condition: RuleCondition,
        against text: String
    ) -> Float {
        switch condition.type {
        case .keyword:
            let keyword = condition.value.lowercased()
            guard !keyword.isEmpty else { return 0.0 }
            return text.contains(keyword) ? 1.0 : 0.0

        case .regex:
            guard !condition.value.isEmpty,
                  let regex = try? NSRegularExpression(
                    pattern: condition.value,
                    options: [.caseInsensitive]
                  ) else { return 0.0 }
            let range = NSRange(text.startIndex..., in: text)
            let matchCount = regex.numberOfMatches(in: text, range: range)
            // 複数マッチは信頼度を上げる（上限 1.0）
            return matchCount > 0 ? min(Float(matchCount) * 0.3 + 0.7, 1.0) : 0.0

        case .appName, .timeRange, .assetKind:
            // OCR テキスト分類ではアプリ名・時間帯・種別条件は対象外
            return 0.0
        }
    }
}

// MARK: - OCRClassifierError

enum OCRClassifierError: LocalizedError {
    case imageLoadFailed(String)
    case visionRequestFailed(Error)

    var errorDescription: String? {
        switch self {
        case .imageLoadFailed(let path):
            return "画像の読み込みに失敗しました: \(path)"
        case .visionRequestFailed(let error):
            return "OCR 処理に失敗しました: \(error.localizedDescription)"
        }
    }
}
