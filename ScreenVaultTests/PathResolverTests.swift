import Testing
import Foundation
@testable import ScreenVault

// MARK: - PathResolver テスト

@Suite("PathResolver")
struct PathResolverTests {

    // MARK: - テンプレート展開のヘルパー

    /// 固定日時のアセットを作成する
    private func makeAsset(
        kind: AssetKind = .screenshot,
        capturedAt: Date,
        frontmostApp: String? = nil,
        contentHashSHA256: String? = nil
    ) -> Asset {
        let asset = Asset(kind: kind, sourceMode: .watch, capturedAt: capturedAt)
        asset.frontmostApp = frontmostApp
        asset.contentHashSHA256 = contentHashSHA256
        return asset
    }

    /// 2025-01-15 09:30:45 UTC の Date を返す
    private func makeDate_2025_01_15() -> Date {
        var comps = DateComponents()
        comps.year = 2025
        comps.month = 1
        comps.day = 15
        comps.hour = 9
        comps.minute = 30
        comps.second = 45
        comps.timeZone = TimeZone(identifier: "Asia/Tokyo")
        return Calendar(identifier: .gregorian).date(from: comps)!
    }

    private func makeBaseResult(category: String = "Screenshots") -> ClassificationResult {
        return ClassificationResult(
            category: category,
            folderPath: "",
            tags: [],
            explanation: "test",
            stage: .kind
        )
    }

    // MARK: - テンプレート展開の正しさ

    @Test("YYYY テンプレートが展開される")
    func yearTemplateExpansion() {
        let asset = makeAsset(capturedAt: makeDate_2025_01_15())
        let result = makeBaseResult()
        let expanded = PathResolver.expandFolderTemplate("Captures/{YYYY}/", asset: asset, result: result)
        #expect(expanded.contains("2025"))
    }

    @Test("MM テンプレートが展開される（ゼロ埋め）")
    func monthTemplateExpansion() {
        let asset = makeAsset(capturedAt: makeDate_2025_01_15())
        let result = makeBaseResult()
        let expanded = PathResolver.expandFolderTemplate("{MM}", asset: asset, result: result)
        #expect(expanded == "01")
    }

    @Test("DD テンプレートが展開される（ゼロ埋め）")
    func dayTemplateExpansion() {
        let asset = makeAsset(capturedAt: makeDate_2025_01_15())
        let result = makeBaseResult()
        let expanded = PathResolver.expandFolderTemplate("{DD}", asset: asset, result: result)
        #expect(expanded == "15")
    }

    @Test("YYYY-MM テンプレートが展開される")
    func yearMonthTemplateExpansion() {
        let asset = makeAsset(capturedAt: makeDate_2025_01_15())
        let result = makeBaseResult()
        let expanded = PathResolver.expandFolderTemplate("{YYYY-MM}", asset: asset, result: result)
        #expect(expanded == "2025-01")
    }

    @Test("Kind テンプレートが AssetKind に応じて展開される")
    func kindTemplateExpansion() {
        let date = makeDate_2025_01_15()
        let result = makeBaseResult()

        let screenshotAsset = makeAsset(kind: .screenshot, capturedAt: date)
        let expanded = PathResolver.expandFolderTemplate("{Kind}", asset: screenshotAsset, result: result)
        #expect(expanded == "Screenshots")

        let recordingAsset = makeAsset(kind: .screenRecording, capturedAt: date)
        let expanded2 = PathResolver.expandFolderTemplate("{Kind}", asset: recordingAsset, result: makeBaseResult(category: "ScreenRecordings"))
        #expect(expanded2 == "ScreenRecordings")
    }

    @Test("App テンプレートが frontmostApp に展開される")
    func appTemplateExpansion() {
        let asset = makeAsset(capturedAt: makeDate_2025_01_15(), frontmostApp: "Xcode")
        let result = makeBaseResult()
        let expanded = PathResolver.expandFolderTemplate("{App}", asset: asset, result: result)
        #expect(expanded == "Xcode")
    }

    @Test("App テンプレートが frontmostApp なしの場合 Unknown に展開される")
    func appTemplateExpansionWithNoApp() {
        let asset = makeAsset(capturedAt: makeDate_2025_01_15(), frontmostApp: nil)
        let result = makeBaseResult()
        let expanded = PathResolver.expandFolderTemplate("{App}", asset: asset, result: result)
        #expect(expanded == "Unknown")
    }

    @Test("Category テンプレートが result.category に展開される")
    func categoryTemplateExpansion() {
        let asset = makeAsset(capturedAt: makeDate_2025_01_15())
        let result = makeBaseResult(category: "Work")
        let expanded = PathResolver.expandFolderTemplate("{Category}", asset: asset, result: result)
        #expect(expanded == "Work")
    }

    @Test("複合テンプレートが正しく展開される")
    func complexTemplateExpansion() {
        let asset = makeAsset(capturedAt: makeDate_2025_01_15(), frontmostApp: "Safari")
        let result = makeBaseResult(category: "Browser")
        let template = "Captures/{YYYY}/{YYYY-MM}/{Kind}/{App}/{Category}/"
        let expanded = PathResolver.expandFolderTemplate(template, asset: asset, result: result)
        #expect(expanded == "Captures/2025/2025-01/Screenshots/Safari/Browser/")
    }

    // MARK: - ファイル名の特殊文字正規化

    @Test("スラッシュを含むアプリ名が sanitize される")
    func sanitizeSlashInAppName() {
        let sanitized = PathResolver.sanitize("App/Name")
        #expect(!sanitized.contains("/"))
        #expect(sanitized == "App_Name")
    }

    @Test("コロンを含む文字列が sanitize される")
    func sanitizeColon() {
        let sanitized = PathResolver.sanitize("Time: 12:30")
        #expect(!sanitized.contains(":"))
    }

    @Test("空文字列の sanitize は空文字列を返す")
    func sanitizeEmpty() {
        let sanitized = PathResolver.sanitize("")
        #expect(sanitized.isEmpty)
    }

    @Test("正常な文字列は変更されない")
    func sanitizeNormalString() {
        let input = "Xcode Development"
        let sanitized = PathResolver.sanitize(input)
        #expect(sanitized == input)
    }

    @Test("先頭末尾の空白がトリムされる")
    func sanitizeTrimWhitespace() {
        let sanitized = PathResolver.sanitize("  Xcode  ")
        #expect(sanitized == "Xcode")
    }

    // MARK: - ShortHash の長さ

    @Test("ShortHash は 8 文字")
    func shortHashIs8Characters() {
        let sha256 = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        let shortHash = PathResolver.shortHash(from: sha256)
        #expect(shortHash.count == 8)
    }

    @Test("ShortHash は SHA-256 の先頭 8 文字")
    func shortHashIsFirst8Characters() {
        let sha256 = "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890"
        let shortHash = PathResolver.shortHash(from: sha256)
        #expect(shortHash == "abcdef12")
    }

    @Test("空文字列の ShortHash は 00000000")
    func emptyStringShortHash() {
        let shortHash = PathResolver.shortHash(from: "")
        #expect(shortHash == "00000000")
    }

    @Test("ShortHash は常に小文字")
    func shortHashIsLowercase() {
        let sha256 = "ABCDEF1234567890ABCDEF1234567890ABCDEF1234567890ABCDEF1234567890"
        let shortHash = PathResolver.shortHash(from: sha256)
        #expect(shortHash == shortHash.lowercased())
    }

    @Test("8 文字未満の入力は全体が ShortHash になる")
    func shortHashWithShortInput() {
        let input = "abc"
        let shortHash = PathResolver.shortHash(from: input)
        #expect(shortHash.count <= 8)
        #expect(shortHash == "abc")
    }

    // MARK: - makeFilename のテスト

    @Test("生成ファイル名は期待フォーマットに一致する")
    func makeFilenameFormat() {
        let asset = makeAsset(
            kind: .screenshot,
            capturedAt: makeDate_2025_01_15(),
            frontmostApp: "Safari",
            contentHashSHA256: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890"
        )
        let result = makeBaseResult(category: "Screenshots")
        let filename = PathResolver.makeFilename(asset: asset, result: result, originalExtension: "png")

        // フォーマット: YYYY-MM-DD_HH-mm-ss_{Kind}_{App}_{ShortHash}.{ext}
        #expect(filename.hasPrefix("2025-01-15_"))
        #expect(filename.contains("_Screenshots_"))
        #expect(filename.contains("_Safari_"))
        #expect(filename.hasSuffix(".png"))
        // ShortHash が含まれる
        #expect(filename.contains("abcdef12"))
    }

    @Test("拡張子が空の場合は bin が使われる")
    func makeFilenameWithEmptyExtension() {
        let asset = makeAsset(capturedAt: makeDate_2025_01_15())
        let result = makeBaseResult()
        let filename = PathResolver.makeFilename(asset: asset, result: result, originalExtension: "")
        #expect(filename.hasSuffix(".bin"))
    }

    @Test("frontmostApp が nil の場合は Unknown が使われる")
    func makeFilenameWithNoApp() {
        let asset = makeAsset(capturedAt: makeDate_2025_01_15(), frontmostApp: nil)
        let result = makeBaseResult()
        let filename = PathResolver.makeFilename(asset: asset, result: result, originalExtension: "png")
        #expect(filename.contains("_Unknown_"))
    }
}
