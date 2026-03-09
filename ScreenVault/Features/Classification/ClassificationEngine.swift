import Foundation
import SwiftData
import OSLog

// MARK: - ClassificationResult

/// 分類パイプラインの出力。
struct ClassificationResult {
    /// カテゴリ名（例: "Work", "Gaming", "Uncategorized"）
    var category: String
    /// フォルダパス（コンポーネント配列。PathResolver で生成した値を格納）
    var folderPath: String
    /// タグと信頼度のペア
    var tags: [(tag: String, confidence: Float)]
    /// 分類根拠の説明文（ログ・UI 用）
    var explanation: String
    /// どのステージで分類が確定したか
    var stage: ClassificationStage
}

/// 分類が確定したステージ
enum ClassificationStage: String {
    case kind     = "Stage0-Kind"
    case filename = "Stage1-Filename"
    case rule     = "Stage2-Rule"
}

// MARK: - ClassificationEngine

/// Asset を分類するパイプラインエンジン。
///
/// ステージ:
/// - Stage 0: AssetKind + 日時による基本カテゴリ付与
/// - Stage 1: macOS 標準ファイル名パース（スクリーンショット日時取得）
/// - Stage 2: SwiftData から取得したユーザールールを priority 順に評価
///
/// - Note: `modelContext` は MainActor 上で生成されたコンテキストを渡すこと。
///   `classify(asset:)` は MainActor から呼ぶことを前提とする。
final class ClassificationEngine: @unchecked Sendable {

    // MARK: - Dependencies

    private let modelContext: ModelContext

    // MARK: - Init

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Public API

    /// Asset を分類し、ClassificationResult を返す。
    func classify(asset: Asset) async -> ClassificationResult {
        SVLogger.classification.info("ClassificationEngine: classifying asset=\(asset.assetID, privacy: .public) kind=\(asset.kind.rawValue, privacy: .public)")

        // Stage 0: 種別 + 日時による基本分類
        var result = stage0_kindClassification(asset: asset)

        // Stage 1: ファイル名パース
        if let filenameParsed = stage1_filenameClassification(asset: asset) {
            // ファイル名から取得した情報でカテゴリ・フォルダを上書き
            result = filenameParsed
        }

        // Stage 2: ユーザールール評価
        if let ruleResult = stage2_ruleClassification(asset: asset, baseResult: result) {
            result = ruleResult
        }

        SVLogger.classification.info("ClassificationEngine: classified asset=\(asset.assetID, privacy: .public) category=\(result.category, privacy: .public) stage=\(result.stage.rawValue, privacy: .public)")
        return result
    }

    // MARK: - Stage 0: 種別判定

    private func stage0_kindClassification(asset: Asset) -> ClassificationResult {
        let category: String
        let tags: [(String, Float)]

        switch asset.kind {
        case .screenshot:
            category = "Screenshots"
            tags = [("screenshot", 1.0)]
        case .screenRecording:
            category = "ScreenRecordings"
            tags = [("recording", 1.0)]
        case .clipboard:
            category = "Clipboard"
            tags = [("clipboard", 1.0)]
        case .video:
            category = "Videos"
            tags = [("video", 1.0)]
        case .text:
            category = "Text"
            tags = [("text", 1.0)]
        }

        // 日時ベースのフォルダパス（プレースホルダは PathResolver で展開）
        let dateStr = formatDate(asset.capturedAt)
        let folderPath = "Captures/\(formatYear(asset.capturedAt))/\(formatYearMonth(asset.capturedAt))/\(category)"

        return ClassificationResult(
            category: category,
            folderPath: folderPath,
            tags: tags,
            explanation: "Stage0: kind=\(asset.kind.rawValue) capturedAt=\(dateStr)",
            stage: .kind
        )
    }

    // MARK: - Stage 1: ファイル名パース

    /// macOS 標準スクリーンショット命名「スクリーンショット YYYY-MM-DD HH.mm.ss」をパースする。
    private func stage1_filenameClassification(asset: Asset) -> ClassificationResult? {
        guard let path = asset.originalPath ?? asset.localTempPath else { return nil }
        let filename = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent

        // パターン: "スクリーンショット 2025-01-15 09.30.45" または
        //           "Screenshot 2025-01-15 at 09.30.45" (英語 macOS)
        let patterns: [String] = [
            #"スクリーンショット (\d{4})-(\d{2})-(\d{2}) (\d{2})\.(\d{2})\.(\d{2})"#,
            #"Screenshot (\d{4})-(\d{2})-(\d{2}) at (\d{2})\.(\d{2})\.(\d{2})"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(
                      in: filename,
                      range: NSRange(filename.startIndex..., in: filename)
                  ),
                  match.numberOfRanges == 7
            else { continue }

            let groups = (1..<7).compactMap { i -> String? in
                guard let range = Range(match.range(at: i), in: filename) else { return nil }
                return String(filename[range])
            }
            guard groups.count == 6 else { continue }

            let year = groups[0], month = groups[1], day = groups[2]
            let hour = groups[3], minute = groups[4], second = groups[5]

            let folderPath = "Captures/\(year)/\(year)-\(month)/Screenshots"
            let explanation = "Stage1: macOS screenshot filename parsed \(year)-\(month)-\(day) \(hour):\(minute):\(second)"

            return ClassificationResult(
                category: "Screenshots",
                folderPath: folderPath,
                tags: [("screenshot", 1.0), ("macOS-screenshot", 0.9)],
                explanation: explanation,
                stage: .filename
            )
        }

        return nil
    }

    // MARK: - Stage 2: ユーザールール

    /// SwiftData からルールを取得し、priority 順に評価する。最初にマッチしたルールの action を適用。
    private func stage2_ruleClassification(
        asset: Asset,
        baseResult: ClassificationResult
    ) -> ClassificationResult? {
        // SwiftData フェッチは MainActor 上で実行
        let rules: [ClassificationRule]
        do {
            let descriptor = FetchDescriptor<ClassificationRule>(
                predicate: #Predicate { $0.enabled == true },
                sortBy: [SortDescriptor(\.priority)]
            )
            rules = try modelContext.fetch(descriptor)
        } catch {
            SVLogger.classification.error("ClassificationEngine: failed to fetch rules: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        for rule in rules {
            guard evaluateConditions(rule.conditions, asset: asset) else { continue }

            // ルールにマッチ: アクションを適用
            var result = baseResult
            result.stage = .rule
            result.explanation = "Stage2: matched rule '\(rule.name)' (id=\(rule.ruleID))"

            for action in rule.actions {
                switch action.actionType {
                case .setCategory:
                    result.category = action.actionValue
                case .setFolder:
                    result.folderPath = action.actionValue
                case .addTag:
                    if !result.tags.contains(where: { $0.tag == action.actionValue }) {
                        result.tags.append((tag: action.actionValue, confidence: 1.0))
                    }
                }
            }

            SVLogger.classification.info("ClassificationEngine: rule matched '\(rule.name, privacy: .public)' for asset=\(asset.assetID, privacy: .public)")
            return result
        }

        return nil
    }

    /// ルールの全条件（AND）を評価する。すべて true の場合のみ true。
    private func evaluateConditions(_ conditions: [RuleCondition], asset: Asset) -> Bool {
        guard !conditions.isEmpty else { return false }

        return conditions.allSatisfy { condition in
            evaluateCondition(condition, asset: asset)
        }
    }

    private func evaluateCondition(_ condition: RuleCondition, asset: Asset) -> Bool {
        switch condition.type {
        case .keyword:
            // captionText / ocrText / originalPath のいずれかにキーワードが含まれるか
            let keyword = condition.value.lowercased()
            let searchTargets = [
                asset.captionText?.lowercased(),
                asset.ocrText?.lowercased(),
                asset.originalPath?.lowercased()
            ].compactMap { $0 }
            return searchTargets.contains { $0.contains(keyword) }

        case .regex:
            // 正規表現マッチ（captionText / ocrText / originalPath）
            guard let regex = try? NSRegularExpression(pattern: condition.value, options: .caseInsensitive) else {
                SVLogger.classification.warning("ClassificationEngine: invalid regex '\(condition.value, privacy: .public)'")
                return false
            }
            let targets = [asset.captionText, asset.ocrText, asset.originalPath].compactMap { $0 }
            return targets.contains { text in
                let range = NSRange(text.startIndex..., in: text)
                return regex.firstMatch(in: text, range: range) != nil
            }

        case .appName:
            // frontmostApp が条件値と一致するか（大文字小文字無視）
            guard let appName = asset.frontmostApp else { return false }
            return appName.lowercased() == condition.value.lowercased()

        case .assetKind:
            // AssetKind.rawValue と一致するか
            return asset.kind.rawValue == condition.value

        case .timeRange:
            // "HH:mm-HH:mm" 形式の時間帯チェック
            return evaluateTimeRange(condition.value, date: asset.capturedAt)
        }
    }

    /// "HH:mm-HH:mm" 形式の時間帯に date が含まれるか判定する。
    private func evaluateTimeRange(_ value: String, date: Date) -> Bool {
        let parts = value.split(separator: "-")
        guard parts.count == 2 else { return false }

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")

        guard let startTime = formatter.date(from: String(parts[0])),
              let endTime = formatter.date(from: String(parts[1]))
        else { return false }

        // 現在時刻の「時分」のみ比較するため、同一日付ベースに正規化
        let calendar = Calendar.current
        let now = calendar.dateComponents([.hour, .minute], from: date)
        let startComponents = calendar.dateComponents([.hour, .minute], from: startTime)
        let endComponents = calendar.dateComponents([.hour, .minute], from: endTime)

        let nowMinutes = (now.hour ?? 0) * 60 + (now.minute ?? 0)
        let startMinutes = (startComponents.hour ?? 0) * 60 + (startComponents.minute ?? 0)
        let endMinutes = (endComponents.hour ?? 0) * 60 + (endComponents.minute ?? 0)

        if startMinutes <= endMinutes {
            return nowMinutes >= startMinutes && nowMinutes <= endMinutes
        } else {
            // 日をまたぐ場合（例: 22:00-02:00）
            return nowMinutes >= startMinutes || nowMinutes <= endMinutes
        }
    }

    // MARK: - Date formatting helpers

    private func formatDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        return formatter.string(from: date)
    }

    private func formatYear(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }

    private func formatYearMonth(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }

    // MARK: - Stage 0 static helper

    /// `AssetKind` に対応するリモートフォルダ名を返す（PathResolver / テスト用）
    static func folderName(for kind: AssetKind) -> String {
        switch kind {
        case .screenshot:      return "Screenshots"
        case .screenRecording: return "ScreenRecordings"
        case .clipboard:       return "Clipboard"
        case .video:           return "Videos"
        case .text:            return "Text"
        }
    }
}

// MARK: - PathResolver

/// ClassificationResult をもとにリモートフォルダパスとファイル名を生成するユーティリティ。
///
/// テンプレート変数:
/// - `{YYYY}`: キャプチャ年（4桁）
/// - `{MM}`: キャプチャ月（2桁）
/// - `{DD}`: キャプチャ日（2桁）
/// - `{HH}`: キャプチャ時（2桁）
/// - `{mm}`: キャプチャ分（2桁）
/// - `{ss}`: キャプチャ秒（2桁）
/// - `{Kind}`: AssetKind のフォルダ名（例: Screenshots）
/// - `{App}`: フロントアプリ名（なければ "Unknown"）
/// - `{Category}`: 分類カテゴリ（なければ "Uncategorized"）
/// - `{YYYY-MM}`: 年月（例: "2025-01"）
enum PathResolver {

    // MARK: - テンプレート展開

    /// フォルダパステンプレートを展開する。
    ///
    /// - Parameters:
    ///   - template: テンプレート文字列（例: `"Captures/{YYYY}/{YYYY-MM}/{Kind}/{App}/{Category}/"`）
    ///   - asset: 対象アセット
    ///   - result: 分類結果
    /// - Returns: 展開済みのフォルダパス
    static func expandFolderTemplate(
        _ template: String,
        asset: Asset,
        result: ClassificationResult
    ) -> String {
        let vars = makeVariables(asset: asset, result: result)
        var expanded = template
        // 長いキーを先に置換して部分置換の誤動作を防ぐ
        let sortedKeys = vars.keys.sorted { $0.count > $1.count }
        for key in sortedKeys {
            expanded = expanded.replacingOccurrences(of: "{\(key)}", with: sanitize(vars[key] ?? ""))
        }
        return expanded
    }

    /// ファイル名を生成する。
    ///
    /// フォーマット: `YYYY-MM-DD_HH-mm-ss_{Kind}_{App}_{ShortHash}.{ext}`
    ///
    /// - Parameters:
    ///   - asset: 対象アセット
    ///   - result: 分類結果
    ///   - originalExtension: 元ファイルの拡張子（ドットなし。例: "png"）
    /// - Returns: 生成されたファイル名
    static func makeFilename(
        asset: Asset,
        result: ClassificationResult,
        originalExtension: String
    ) -> String {
        let vars = makeVariables(asset: asset, result: result)

        let datePart = "\(vars["YYYY"] ?? "0000")-\(vars["MM"] ?? "00")-\(vars["DD"] ?? "00")"
        let timePart = "\(vars["HH"] ?? "00")-\(vars["mm"] ?? "00")-\(vars["ss"] ?? "00")"
        let kindPart = sanitize(ClassificationEngine.folderName(for: asset.kind))
        let appPart  = sanitize(asset.frontmostApp ?? "Unknown")
        let shortHashStr = shortHash(from: asset.contentHashSHA256 ?? asset.assetID)
        let ext = originalExtension.isEmpty ? "bin" : originalExtension

        return "\(datePart)_\(timePart)_\(kindPart)_\(appPart)_\(shortHashStr).\(ext)"
    }

    // MARK: - ShortHash

    /// コンテンツハッシュから先頭 8 文字の ShortHash を生成する。
    ///
    /// - Parameter hashOrID: SHA-256 ハッシュ文字列または任意の識別子
    /// - Returns: 8 文字の小文字16進文字列（入力が空なら "00000000"）
    static func shortHash(from hashOrID: String) -> String {
        guard !hashOrID.isEmpty else { return "00000000" }
        return String(hashOrID.prefix(8)).lowercased()
    }

    // MARK: - Sanitize

    /// ファイル名・フォルダ名に使えない特殊文字を `_` に置換する。
    ///
    /// 置換対象: `/`, `:`, `\`, `*`, `?`, `"`, `<`, `>`, `|`, 制御文字
    /// - Parameter input: 入力文字列
    /// - Returns: 正規化された文字列
    static func sanitize(_ input: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\*?\"<>|")
            .union(.controlCharacters)
        let sanitized = String(input.unicodeScalars.map { scalar -> Character in
            forbidden.contains(scalar) ? "_" : Character(scalar)
        })
        return sanitized.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Private

    private static func makeVariables(asset: Asset, result: ClassificationResult) -> [String: String] {
        let calendar = Calendar.current
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: asset.capturedAt
        )

        let yyyy = String(format: "%04d", components.year ?? 0)
        let mm   = String(format: "%02d", components.month ?? 0)
        let dd   = String(format: "%02d", components.day ?? 0)
        let hh   = String(format: "%02d", components.hour ?? 0)
        let min  = String(format: "%02d", components.minute ?? 0)
        let ss   = String(format: "%02d", components.second ?? 0)

        return [
            "YYYY-MM": "\(yyyy)-\(mm)",
            "YYYY": yyyy,
            "MM": mm,
            "DD": dd,
            "HH": hh,
            "mm": min,
            "ss": ss,
            "Kind": ClassificationEngine.folderName(for: asset.kind),
            "App": asset.frontmostApp ?? "Unknown",
            "Category": result.category.isEmpty ? "Uncategorized" : result.category,
        ]
    }
}
