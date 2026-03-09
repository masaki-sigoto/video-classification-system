import Testing
import Foundation
import SwiftData
@testable import ScreenVault

// MARK: - ClassificationEngine テスト

@Suite("ClassificationEngine")
struct ClassificationEngineTests {

    // MARK: - Stage 0: AssetKind → フォルダ名

    @Suite("Stage 0: folderName(for:)")
    struct Stage0Tests {

        @Test("screenshot → Screenshots")
        func screenshotFolderName() {
            #expect(ClassificationEngine.folderName(for: .screenshot) == "Screenshots")
        }

        @Test("screenRecording → ScreenRecordings")
        func screenRecordingFolderName() {
            #expect(ClassificationEngine.folderName(for: .screenRecording) == "ScreenRecordings")
        }

        @Test("clipboard → Clipboard")
        func clipboardFolderName() {
            #expect(ClassificationEngine.folderName(for: .clipboard) == "Clipboard")
        }

        @Test("video → Videos")
        func videoFolderName() {
            #expect(ClassificationEngine.folderName(for: .video) == "Videos")
        }

        @Test("text → Text")
        func textFolderName() {
            #expect(ClassificationEngine.folderName(for: .text) == "Text")
        }

        @Test("全 AssetKind でフォルダ名が空でない")
        func allKindsHaveNonEmptyFolderName() {
            let kinds: [AssetKind] = [.screenshot, .screenRecording, .clipboard, .video, .text]
            for kind in kinds {
                let name = ClassificationEngine.folderName(for: kind)
                #expect(!name.isEmpty, "\(kind.rawValue) のフォルダ名が空")
            }
        }
    }

    // MARK: - Stage 1: macOS 標準スクリーンショット名パース

    @Suite("Stage 1: 分類エンジン（インメモリ DB 使用）")
    @MainActor
    struct Stage1Tests {

        /// インメモリコンテナを生成してエンジンを初期化
        private func makeEngine() throws -> (ClassificationEngine, ModelContext) {
            let container = try DatabaseContainer.makeInMemoryContainer()
            let context = ModelContext(container)
            let engine = ClassificationEngine(modelContext: context)
            return (engine, context)
        }

        @Test("日本語スクリーンショット名から category=Screenshots が返る")
        func japaneseScreenshotNameClassification() async throws {
            let (engine, context) = try makeEngine()

            let asset = Asset(kind: .screenshot, sourceMode: .watch)
            asset.originalPath = "/Users/test/スクリーンショット 2025-01-15 09.30.45.png"
            context.insert(asset)

            let result = await engine.classify(asset: asset)
            #expect(result.category == "Screenshots")
            #expect(result.stage == .filename)
        }

        @Test("英語スクリーンショット名から category=Screenshots が返る")
        func englishScreenshotNameClassification() async throws {
            let (engine, context) = try makeEngine()

            let asset = Asset(kind: .screenshot, sourceMode: .watch)
            asset.originalPath = "/Users/test/Screenshot 2025-03-10 at 14.22.30.png"
            context.insert(asset)

            let result = await engine.classify(asset: asset)
            #expect(result.category == "Screenshots")
            #expect(result.stage == .filename)
        }

        @Test("動画ファイルは Stage 0 で ScreenRecordings に分類される")
        func videoFileClassification() async throws {
            let (engine, context) = try makeEngine()

            let asset = Asset(kind: .screenRecording, sourceMode: .watch)
            asset.originalPath = "/Users/test/recording.mov"
            context.insert(asset)

            let result = await engine.classify(asset: asset)
            #expect(result.category == "ScreenRecordings")
            #expect(result.stage == .kind)
        }

        @Test("folderPath にはキャプチャ年が含まれる")
        func folderPathContainsYear() async throws {
            let (engine, context) = try makeEngine()

            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
            var comps = DateComponents()
            comps.year = 2025
            comps.month = 6
            comps.day = 15
            let capturedAt = calendar.date(from: comps)!

            let asset = Asset(kind: .screenshot, sourceMode: .watch, capturedAt: capturedAt)
            context.insert(asset)

            let result = await engine.classify(asset: asset)
            #expect(result.folderPath.contains("2025"))
        }
    }

    // MARK: - Stage 2: ルールマッチング

    @Suite("Stage 2: ルールマッチング")
    @MainActor
    struct Stage2Tests {

        private func makeEngineWithContext() throws -> (ClassificationEngine, ModelContext) {
            let container = try DatabaseContainer.makeInMemoryContainer()
            let context = ModelContext(container)
            let engine = ClassificationEngine(modelContext: context)
            return (engine, context)
        }

        @Test("keyword 条件マッチ: captionText にキーワードが含まれる")
        func keywordMatchOnCaptionText() async throws {
            let (engine, context) = try makeEngineWithContext()

            // ルールを作成
            let rule = ClassificationRule(name: "Xcode ルール", priority: 1)
            let condition = RuleCondition(type: .keyword, value: "Xcode")
            let action = RuleAction(ruleID: rule.ruleID, actionType: .setCategory, actionValue: "Development")

            rule.conditions = [condition]
            rule.actions = [action]
            context.insert(rule)

            let asset = Asset(kind: .screenshot, sourceMode: .watch)
            asset.captionText = "Xcode のスクリーンショット"
            context.insert(asset)
            try context.save()

            let result = await engine.classify(asset: asset)
            #expect(result.category == "Development")
            #expect(result.stage == .rule)
        }

        @Test("keyword 条件: 大文字小文字を区別しない")
        func keywordMatchIsCaseInsensitive() async throws {
            let (engine, context) = try makeEngineWithContext()

            let rule = ClassificationRule(name: "safari ルール", priority: 1)
            let condition = RuleCondition(type: .keyword, value: "safari")
            let action = RuleAction(ruleID: rule.ruleID, actionType: .setCategory, actionValue: "Browser")
            rule.conditions = [condition]
            rule.actions = [action]
            context.insert(rule)

            let asset = Asset(kind: .screenshot, sourceMode: .watch)
            asset.captionText = "Safari でWebを閲覧中"
            context.insert(asset)
            try context.save()

            let result = await engine.classify(asset: asset)
            #expect(result.category == "Browser")
        }

        @Test("regex 条件マッチ: 正規表現でマッチする")
        func regexMatchOnOcrText() async throws {
            let (engine, context) = try makeEngineWithContext()

            let rule = ClassificationRule(name: "エラーログ ルール", priority: 1)
            let condition = RuleCondition(type: .regex, value: #"Error\s*:"#)
            let action = RuleAction(ruleID: rule.ruleID, actionType: .addTag, actionValue: "error-log")
            rule.conditions = [condition]
            rule.actions = [action]
            context.insert(rule)

            let asset = Asset(kind: .screenshot, sourceMode: .watch)
            asset.ocrText = "Fatal Error: Null pointer exception"
            context.insert(asset)
            try context.save()

            let result = await engine.classify(asset: asset)
            let hasTag = result.tags.contains { $0.tag == "error-log" }
            #expect(hasTag)
        }

        @Test("appName 条件マッチ: frontmostApp が一致する")
        func appNameMatch() async throws {
            let (engine, context) = try makeEngineWithContext()

            let rule = ClassificationRule(name: "Xcode アプリルール", priority: 1)
            let condition = RuleCondition(type: .appName, value: "Xcode")
            let action = RuleAction(ruleID: rule.ruleID, actionType: .setCategory, actionValue: "Development")
            rule.conditions = [condition]
            rule.actions = [action]
            context.insert(rule)

            let asset = Asset(kind: .screenshot, sourceMode: .watch)
            asset.frontmostApp = "Xcode"
            context.insert(asset)
            try context.save()

            let result = await engine.classify(asset: asset)
            #expect(result.category == "Development")
        }

        @Test("appName 条件: 大文字小文字を区別しない（lowercased 比較）")
        func appNameMatchIsCaseInsensitive() async throws {
            let (engine, context) = try makeEngineWithContext()

            let rule = ClassificationRule(name: "小文字 xcode", priority: 1)
            let condition = RuleCondition(type: .appName, value: "xcode") // 小文字
            let action = RuleAction(ruleID: rule.ruleID, actionType: .setCategory, actionValue: "Development")
            rule.conditions = [condition]
            rule.actions = [action]
            context.insert(rule)

            let asset = Asset(kind: .screenshot, sourceMode: .watch)
            asset.frontmostApp = "Xcode" // 大文字始まり
            context.insert(asset)
            try context.save()

            // evaluateCondition の appName は lowercased() 比較のため、大文字小文字を区別せずマッチする
            let result = await engine.classify(asset: asset)
            #expect(result.category == "Development")
        }

        @Test("ルールの priority 順に評価される（低い値が優先）")
        func rulesEvaluatedByPriority() async throws {
            let (engine, context) = try makeEngineWithContext()

            // priority: 10 の高優先ルール
            let highPriorityRule = ClassificationRule(name: "高優先", priority: 10)
            let condition1 = RuleCondition(type: .keyword, value: "test")
            let action1 = RuleAction(ruleID: highPriorityRule.ruleID, actionType: .setCategory, actionValue: "HighPriority")
            highPriorityRule.conditions = [condition1]
            highPriorityRule.actions = [action1]

            // priority: 50 の低優先ルール
            let lowPriorityRule = ClassificationRule(name: "低優先", priority: 50)
            let condition2 = RuleCondition(type: .keyword, value: "test")
            let action2 = RuleAction(ruleID: lowPriorityRule.ruleID, actionType: .setCategory, actionValue: "LowPriority")
            lowPriorityRule.conditions = [condition2]
            lowPriorityRule.actions = [action2]

            context.insert(lowPriorityRule) // 低優先を先にINSERT
            context.insert(highPriorityRule) // 高優先を後にINSERT

            let asset = Asset(kind: .screenshot, sourceMode: .watch)
            asset.captionText = "test screenshot"
            context.insert(asset)
            try context.save()

            let result = await engine.classify(asset: asset)
            // priority 10 が先に評価されるため HighPriority になるはず
            #expect(result.category == "HighPriority")
        }

        @Test("disabled なルールはスキップされる")
        func disabledRuleIsSkipped() async throws {
            let (engine, context) = try makeEngineWithContext()

            let rule = ClassificationRule(name: "無効ルール", priority: 1, enabled: false)
            let condition = RuleCondition(type: .keyword, value: "test")
            let action = RuleAction(ruleID: rule.ruleID, actionType: .setCategory, actionValue: "ShouldNotMatch")
            rule.conditions = [condition]
            rule.actions = [action]
            context.insert(rule)

            let asset = Asset(kind: .screenshot, sourceMode: .watch)
            asset.captionText = "test keyword"
            context.insert(asset)
            try context.save()

            let result = await engine.classify(asset: asset)
            #expect(result.category != "ShouldNotMatch")
        }

        @Test("ルールがマッチしない場合は Stage 0 または Stage 1 の結果を返す")
        func noMatchReturnsBaseResult() async throws {
            let (engine, context) = try makeEngineWithContext()

            let asset = Asset(kind: .screenshot, sourceMode: .watch)
            context.insert(asset)

            let result = await engine.classify(asset: asset)
            // ルールがなければ Stage 0 の結果
            #expect(result.stage == .kind || result.stage == .filename)
            #expect(!result.folderPath.isEmpty)
        }
    }
}
