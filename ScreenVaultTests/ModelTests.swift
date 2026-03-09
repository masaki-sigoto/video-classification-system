import Testing
import Foundation
import SwiftData
@testable import ScreenVault

// MARK: - Asset モデルのテスト

@Suite("Asset モデル")
struct AssetModelTests {

    @Test("デフォルト初期化: assetID は空でない UUID 形式")
    func assetIDIsNonEmpty() {
        let asset = Asset(kind: .screenshot, sourceMode: .watch)
        #expect(!asset.assetID.isEmpty)
        // UUID パターン: 8-4-4-4-12
        let uuidPattern = #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"#
        let matched = (try? NSRegularExpression(pattern: uuidPattern))
            .flatMap { $0.firstMatch(in: asset.assetID, range: NSRange(asset.assetID.startIndex..., in: asset.assetID)) }
        #expect(matched != nil, "assetID は UUID 形式であること")
    }

    @Test("AssetKind 全種の初期化")
    func assetKindAllCases() {
        let kinds: [AssetKind] = [.screenshot, .screenRecording, .clipboard, .video, .text]
        for kind in kinds {
            let asset = Asset(kind: kind, sourceMode: .watch)
            #expect(asset.kind == kind)
        }
    }

    @Test("SourceMode 全種の初期化")
    func sourceModeAllCases() {
        let modes: [SourceMode] = [.watch, .capture, .clipboard, .manual]
        for mode in modes {
            let asset = Asset(kind: .screenshot, sourceMode: mode)
            #expect(asset.sourceMode == mode)
        }
    }

    @Test("sizeBytes が正しく設定される")
    func sizeBytesInitialization() {
        let asset = Asset(kind: .screenshot, sourceMode: .watch, sizeBytes: 4096)
        #expect(asset.sizeBytes == 4096)
    }

    @Test("デフォルトの sizeBytes は 0")
    func defaultSizeBytesIsZero() {
        let asset = Asset(kind: .screenshot, sourceMode: .watch)
        #expect(asset.sizeBytes == 0)
    }

    @Test("capturedAt はほぼ現在時刻")
    func capturedAtIsApproximatelyNow() {
        let before = Date()
        let asset = Asset(kind: .screenshot, sourceMode: .watch)
        let after = Date()
        #expect(asset.capturedAt >= before)
        #expect(asset.capturedAt <= after)
    }

    @Test("オプショナルフィールドの初期値は nil")
    func optionalFieldsAreNilByDefault() {
        let asset = Asset(kind: .screenshot, sourceMode: .watch)
        #expect(asset.localTempPath == nil)
        #expect(asset.originalPath == nil)
        #expect(asset.contentHashSHA256 == nil)
        #expect(asset.frontmostApp == nil)
        #expect(asset.captionText == nil)
        #expect(asset.ocrText == nil)
    }

    @Test("uploadTasks と tags は空で初期化される")
    func relationshipsAreEmptyByDefault() {
        let asset = Asset(kind: .screenshot, sourceMode: .watch)
        #expect(asset.uploadTasks.isEmpty)
        #expect(asset.tags.isEmpty)
    }

    @Test("AssetKind の rawValue は期待文字列")
    func assetKindRawValues() {
        #expect(AssetKind.screenshot.rawValue == "screenshot")
        #expect(AssetKind.screenRecording.rawValue == "screenRecording")
        #expect(AssetKind.clipboard.rawValue == "clipboard")
        #expect(AssetKind.video.rawValue == "video")
        #expect(AssetKind.text.rawValue == "text")
    }

    @Test("SourceMode の rawValue は期待文字列")
    func sourceModeRawValues() {
        #expect(SourceMode.watch.rawValue == "watch")
        #expect(SourceMode.capture.rawValue == "capture")
        #expect(SourceMode.clipboard.rawValue == "clipboard")
        #expect(SourceMode.manual.rawValue == "manual")
    }
}

// MARK: - UploadTask モデルのテスト

@Suite("UploadTask モデル")
struct UploadTaskModelTests {

    @Test("デフォルト初期化のステータスは pending")
    func defaultStatusIsPending() {
        let task = UploadTask(accountID: "acc-001")
        #expect(task.status == .pending)
    }

    @Test("retryCount は 0 で初期化")
    func defaultRetryCountIsZero() {
        let task = UploadTask(accountID: "acc-001")
        #expect(task.retryCount == 0)
    }

    @Test("UploadStatus 遷移: pending → uploading → completed")
    func statusTransitionPendingToCompleted() {
        var task = UploadTask(accountID: "acc-001")
        #expect(task.status == .pending)

        task.status = .uploading
        #expect(task.status == .uploading)

        task.status = .completed
        #expect(task.status == .completed)
    }

    @Test("UploadStatus 遷移: pending → failed")
    func statusTransitionPendingToFailed() {
        var task = UploadTask(accountID: "acc-001")
        task.status = .failed
        #expect(task.status == .failed)
    }

    @Test("UploadStatus 遷移: pending → cancelled")
    func statusTransitionToCancelled() {
        var task = UploadTask(accountID: "acc-001")
        task.status = .cancelled
        #expect(task.status == .cancelled)
    }

    @Test("UploadStatus 全 rawValue")
    func uploadStatusRawValues() {
        #expect(UploadStatus.pending.rawValue == "pending")
        #expect(UploadStatus.uploading.rawValue == "uploading")
        #expect(UploadStatus.completed.rawValue == "completed")
        #expect(UploadStatus.failed.rawValue == "failed")
        #expect(UploadStatus.cancelled.rawValue == "cancelled")
    }

    @Test("accountID が正しく設定される")
    func accountIDIsSet() {
        let task = UploadTask(accountID: "test-account-id")
        #expect(task.accountID == "test-account-id")
    }
}

// MARK: - ProviderAccount モデルのテスト

@Suite("ProviderAccount モデル")
struct ProviderAccountModelTests {

    @Test("ProviderType 全種の初期化")
    func providerTypeAllCases() {
        for providerType in ProviderType.allCases {
            let account = ProviderAccount(providerType: providerType, userDisplay: "test@example.com")
            #expect(account.providerType == providerType)
        }
    }

    @Test("ProviderType rawValue")
    func providerTypeRawValues() {
        #expect(ProviderType.googleDrive.rawValue == "googleDrive")
        #expect(ProviderType.oneDrive.rawValue == "oneDrive")
        #expect(ProviderType.dropbox.rawValue == "dropbox")
        #expect(ProviderType.iCloud.rawValue == "iCloud")
    }

    @Test("userDisplay が正しく設定される")
    func userDisplayIsSet() {
        let account = ProviderAccount(providerType: .googleDrive, userDisplay: "user@gmail.com")
        #expect(account.userDisplay == "user@gmail.com")
    }

    @Test("createdAt はほぼ現在時刻")
    func createdAtIsApproximatelyNow() {
        let before = Date()
        let account = ProviderAccount(providerType: .dropbox, userDisplay: "user")
        let after = Date()
        #expect(account.createdAt >= before)
        #expect(account.createdAt <= after)
    }

    @Test("ProviderType.allCases は 4 件")
    func allCasesCount() {
        #expect(ProviderType.allCases.count == 4)
    }
}

// MARK: - OAuthToken モデルのテスト

@Suite("OAuthToken モデル")
struct OAuthTokenModelTests {

    @Test("過去の有効期限で isExpired が true")
    func isExpiredWhenPast() {
        let pastDate = Date(timeIntervalSinceNow: -3600) // 1時間前
        let token = OAuthToken(
            accountID: "acc-001",
            accessTokenRef: "key_access",
            refreshTokenRef: "key_refresh",
            expiresAt: pastDate
        )
        #expect(token.isExpired == true)
    }

    @Test("未来の有効期限で isExpired が false")
    func isExpiredWhenFuture() {
        let futureDate = Date(timeIntervalSinceNow: 3600) // 1時間後
        let token = OAuthToken(
            accountID: "acc-001",
            accessTokenRef: "key_access",
            refreshTokenRef: "key_refresh",
            expiresAt: futureDate
        )
        #expect(token.isExpired == false)
    }

    @Test("残り 3 分で needsRefresh が true")
    func needsRefreshWhenLessThan5Minutes() {
        let nearFuture = Date(timeIntervalSinceNow: 180) // 3分後
        let token = OAuthToken(
            accountID: "acc-001",
            accessTokenRef: "key_access",
            refreshTokenRef: "key_refresh",
            expiresAt: nearFuture
        )
        #expect(token.needsRefresh == true)
    }

    @Test("残り 10 分で needsRefresh が false")
    func needsRefreshWhenMoreThan5Minutes() {
        let safeFuture = Date(timeIntervalSinceNow: 600) // 10分後
        let token = OAuthToken(
            accountID: "acc-001",
            accessTokenRef: "key_access",
            refreshTokenRef: "key_refresh",
            expiresAt: safeFuture
        )
        #expect(token.needsRefresh == false)
    }

    @Test("有効期限ちょうど 5 分前は needsRefresh が true")
    func needsRefreshAtExactly5Minutes() {
        // 5分後 = 条件: expiresAt <= Date(timeIntervalSinceNow: 5 * 60) なので true
        let exactly5Min = Date(timeIntervalSinceNow: 5 * 60)
        let token = OAuthToken(
            accountID: "acc-001",
            accessTokenRef: "key_access",
            refreshTokenRef: "key_refresh",
            expiresAt: exactly5Min
        )
        #expect(token.needsRefresh == true)
    }
}

// MARK: - ClassificationRule モデルのテスト

@Suite("ClassificationRule モデル")
struct ClassificationRuleModelTests {

    @Test("デフォルト初期化: enabled は true、priority は 100")
    func defaultValues() {
        let rule = ClassificationRule(name: "テストルール")
        #expect(rule.enabled == true)
        #expect(rule.priority == 100)
        #expect(rule.name == "テストルール")
    }

    @Test("conditions と actions は空で初期化")
    func relationshipsAreEmpty() {
        let rule = ClassificationRule(name: "ルール1")
        #expect(rule.conditions.isEmpty)
        #expect(rule.actions.isEmpty)
    }

    @Test("ConditionType 全種の rawValue")
    func conditionTypeRawValues() {
        #expect(ConditionType.keyword.rawValue == "keyword")
        #expect(ConditionType.regex.rawValue == "regex")
        #expect(ConditionType.appName.rawValue == "appName")
        #expect(ConditionType.timeRange.rawValue == "timeRange")
        #expect(ConditionType.assetKind.rawValue == "assetKind")
    }

    @Test("ActionType 全種の rawValue")
    func actionTypeRawValues() {
        #expect(ActionType.setCategory.rawValue == "setCategory")
        #expect(ActionType.setFolder.rawValue == "setFolder")
        #expect(ActionType.addTag.rawValue == "addTag")
    }

    @Test("RuleCondition の初期化")
    func ruleConditionInitialization() {
        let condition = RuleCondition(type: .keyword, value: "Xcode")
        #expect(condition.type == .keyword)
        #expect(condition.value == "Xcode")
        #expect(!condition.conditionID.isEmpty)
    }

    @Test("RuleAction の初期化")
    func ruleActionInitialization() {
        let action = RuleAction(ruleID: "rule-001", actionType: .setCategory, actionValue: "Development")
        #expect(action.actionType == .setCategory)
        #expect(action.actionValue == "Development")
        #expect(action.ruleID == "rule-001")
    }

    @Test("ConditionType.allCases は 5 件")
    func conditionTypeAllCasesCount() {
        #expect(ConditionType.allCases.count == 5)
    }

    @Test("ActionType.allCases は 3 件")
    func actionTypeAllCasesCount() {
        #expect(ActionType.allCases.count == 3)
    }
}

// MARK: - AuditLog モデルのテスト

@Suite("AuditLog モデル")
struct AuditLogModelTests {

    @Test("デフォルトのログレベルは info")
    func defaultLogLevelIsInfo() {
        let log = AuditLog(eventType: "test.event", messageRedacted: "テストメッセージ")
        #expect(log.level == .info)
    }

    @Test("LogLevel 全種の rawValue")
    func logLevelRawValues() {
        #expect(LogLevel.debug.rawValue == "debug")
        #expect(LogLevel.info.rawValue == "info")
        #expect(LogLevel.warning.rawValue == "warning")
        #expect(LogLevel.error.rawValue == "error")
    }

    @Test("error レベルを指定して初期化できる")
    func initWithErrorLevel() {
        let log = AuditLog(eventType: "upload.failed", messageRedacted: "失敗", level: .error)
        #expect(log.level == .error)
    }

    @Test("entityID が nil の場合でも初期化できる")
    func entityIDCanBeNil() {
        let log = AuditLog(eventType: "app.launch", messageRedacted: "起動")
        #expect(log.entityID == nil)
    }

    @Test("entityID を指定して初期化できる")
    func entityIDIsSet() {
        let log = AuditLog(eventType: "asset.created", entityID: "asset-123", messageRedacted: "作成")
        #expect(log.entityID == "asset-123")
    }

    @Test("at はほぼ現在時刻")
    func atIsApproximatelyNow() {
        let before = Date()
        let log = AuditLog(eventType: "test", messageRedacted: "msg")
        let after = Date()
        #expect(log.at >= before)
        #expect(log.at <= after)
    }
}

// MARK: - AssetTag モデルのテスト

@Suite("AssetTag モデル")
struct AssetTagModelTests {

    @Test("デフォルトの confidence は 1.0")
    func defaultConfidenceIsOne() {
        let tag = AssetTag(tag: "screenshot")
        #expect(tag.confidence == 1.0)
    }

    @Test("confidence を指定して初期化")
    func customConfidence() {
        let tag = AssetTag(tag: "work", confidence: 0.85)
        #expect(tag.tag == "work")
        #expect(abs(tag.confidence - 0.85) < 0.001)
    }

    @Test("confidence は 0.0 〜 1.0 の範囲を設定できる")
    func confidenceRange() {
        let minTag = AssetTag(tag: "low", confidence: 0.0)
        let maxTag = AssetTag(tag: "high", confidence: 1.0)
        #expect(minTag.confidence == 0.0)
        #expect(maxTag.confidence == 1.0)
    }
}

// MARK: - RemoteFolderCache モデルのテスト

@Suite("RemoteFolderCache モデル")
struct RemoteFolderCacheModelTests {

    @Test("正しく初期化される")
    func initialization() {
        let cache = RemoteFolderCache(
            accountID: "acc-001",
            folderPathKey: "googleDrive/Captures/2025/2025-01/Screenshots",
            remoteFolderID: "remote-folder-abc123"
        )
        #expect(cache.accountID == "acc-001")
        #expect(cache.folderPathKey == "googleDrive/Captures/2025/2025-01/Screenshots")
        #expect(cache.remoteFolderID == "remote-folder-abc123")
        #expect(!cache.cacheID.isEmpty)
    }

    @Test("updatedAt はほぼ現在時刻")
    func updatedAtIsApproximatelyNow() {
        let before = Date()
        let cache = RemoteFolderCache(
            accountID: "acc-001",
            folderPathKey: "path/key",
            remoteFolderID: "folder-id"
        )
        let after = Date()
        #expect(cache.updatedAt >= before)
        #expect(cache.updatedAt <= after)
    }
}
