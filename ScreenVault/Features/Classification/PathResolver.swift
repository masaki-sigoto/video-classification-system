import Foundation
import OSLog

// MARK: - PathResolver

/// ClassificationResult と Asset からクラウド保存先パスとファイル名を生成するユーティリティ。
struct PathResolver {

    // MARK: - Constants

    /// デフォルトのフォルダパステンプレート
    static let defaultFolderTemplate = "Captures/{YYYY}/{YYYY-MM}/{Kind}/{App}/{Category}"

    // MARK: - Public API

    /// テンプレートからフォルダパスコンポーネント配列を生成する。
    ///
    /// プレースホルダ:
    /// - `{YYYY}`: キャプチャ年（例: "2025"）
    /// - `{YYYY-MM}`: キャプチャ年月（例: "2025-01"）
    /// - `{Kind}`: AssetKind を人間が読める名前に変換（例: "Screenshots"）
    /// - `{App}`: frontmostApp（未設定時は "Unknown"）
    /// - `{Category}`: ClassificationResult.category
    ///
    /// - Parameters:
    ///   - asset: パス生成対象の Asset
    ///   - result: ClassificationEngine から得た分類結果
    ///   - template: フォルダパステンプレート文字列。nil の場合 defaultFolderTemplate を使用
    /// - Returns: フォルダパスのコンポーネント配列（クラウド API の pathComponents に渡す）
    func resolveFolderPath(
        asset: Asset,
        result: ClassificationResult,
        template: String? = nil
    ) -> [String] {
        let templateString = template ?? PathResolver.defaultFolderTemplate
        let expanded = expandTemplate(templateString, asset: asset, result: result)

        // "/" で分割し、空コンポーネントを除去
        let components = expanded
            .components(separatedBy: "/")
            .map { sanitizeForCloud($0) }
            .filter { !$0.isEmpty }

        SVLogger.classification.debug("PathResolver: folder=\(components.joined(separator: "/"), privacy: .public) asset=\(asset.assetID, privacy: .public)")
        return components
    }

    /// ファイル名を生成する。
    ///
    /// 形式: `YYYY-MM-DD_HH-mm-ss_{Kind}_{App}_{ShortHash}.{ext}`
    ///
    /// - Parameter asset: ファイル名生成対象の Asset
    /// - Returns: クラウド互換文字に正規化されたファイル名
    func resolveFileName(asset: Asset) -> String {
        let dateStr = formatDateForFilename(asset.capturedAt)
        let kindStr = kindDisplayName(asset.kind)
        let appStr = sanitizeForCloud(asset.frontmostApp ?? "Unknown")
        let shortHash = shortHash(asset)
        let ext = fileExtension(asset)

        let name = "\(dateStr)_\(kindStr)_\(appStr)_\(shortHash).\(ext)"
        let sanitized = sanitizeForCloud(name)

        SVLogger.classification.debug("PathResolver: fileName=\(sanitized, privacy: .public) asset=\(asset.assetID, privacy: .public)")
        return sanitized
    }

    // MARK: - Private: Template expansion

    private func expandTemplate(_ template: String, asset: Asset, result: ClassificationResult) -> String {
        var expanded = template

        let replacements: [(placeholder: String, value: String)] = [
            ("{YYYY}", formatYear(asset.capturedAt)),
            ("{YYYY-MM}", formatYearMonth(asset.capturedAt)),
            ("{Kind}", kindDisplayName(asset.kind)),
            ("{App}", sanitizeForCloud(asset.frontmostApp ?? "Unknown")),
            ("{Category}", sanitizeForCloud(result.category))
        ]

        for (placeholder, value) in replacements {
            expanded = expanded.replacingOccurrences(of: placeholder, with: value)
        }

        return expanded
    }

    // MARK: - Private: Sanitization

    /// クラウドストレージ互換の文字列に正規化する。
    /// 禁止文字 `/\:*?"<>|` を `_` に置換し、連続スペースを整理する。
    func sanitizeForCloud(_ input: String) -> String {
        // クラウドストレージで禁止される文字を置換
        let forbiddenCharacters = CharacterSet(charactersIn: #"/\:*?"<>|"#)
        let sanitized = input.unicodeScalars
            .map { forbiddenCharacters.contains($0) ? "_" : Character($0) }
            .map { String($0) }
            .joined()

        // 先頭・末尾のスペースとドットを除去
        let trimmed = sanitized
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))

        // 空になった場合のフォールバック
        return trimmed.isEmpty ? "Unknown" : trimmed
    }

    // MARK: - Private: Kind display names

    private func kindDisplayName(_ kind: AssetKind) -> String {
        switch kind {
        case .screenshot:     return "Screenshots"
        case .screenRecording: return "ScreenRecordings"
        case .clipboard:      return "Clipboard"
        case .video:          return "Videos"
        case .text:           return "Text"
        }
    }

    // MARK: - Private: File extension

    private func fileExtension(_ asset: Asset) -> String {
        let path = asset.originalPath ?? asset.localTempPath ?? ""
        let ext = URL(fileURLWithPath: path).pathExtension
        if ext.isEmpty {
            // フォールバック: kind から推定
            switch asset.kind {
            case .screenshot:      return "png"
            case .screenRecording: return "mov"
            case .clipboard:       return "png"
            case .video:           return "mp4"
            case .text:            return "txt"
            }
        }
        return ext.lowercased()
    }

    // MARK: - Private: Short hash

    /// contentHashSHA256 の先頭 8 文字（なければ assetID の先頭 8 文字）
    private func shortHash(_ asset: Asset) -> String {
        let source = asset.contentHashSHA256 ?? asset.assetID
        return String(source.prefix(8))
    }

    // MARK: - Private: Date formatters

    private func formatYear(_ date: Date) -> String {
        let f = makeDateFormatter(format: "yyyy")
        return f.string(from: date)
    }

    private func formatYearMonth(_ date: Date) -> String {
        let f = makeDateFormatter(format: "yyyy-MM")
        return f.string(from: date)
    }

    private func formatDateForFilename(_ date: Date) -> String {
        let f = makeDateFormatter(format: "yyyy-MM-dd_HH-mm-ss")
        return f.string(from: date)
    }

    private func makeDateFormatter(format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = format
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        return formatter
    }
}
