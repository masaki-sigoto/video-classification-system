import Foundation
import SwiftData

// MARK: - ClassificationRule

/// 自動分類ルール。複数の条件（RuleCondition）とアクション（RuleAction）を持つ。
@Model
final class ClassificationRule {
    /// 一意識別子
    @Attribute(.unique) var ruleID: String
    /// ルール名（UI 表示用）
    var name: String
    /// 評価優先度。小さいほど先に評価される
    var priority: Int
    /// ルールの有効/無効フラグ
    var enabled: Bool
    /// レコード作成日時
    var createdAt: Date
    /// レコード最終更新日時
    var updatedAt: Date

    /// このルールに紐付く条件群（AND 条件）
    @Relationship(deleteRule: .cascade) var conditions: [RuleCondition]
    /// このルールに紐付くアクション群
    @Relationship(deleteRule: .cascade) var actions: [RuleAction]

    init(
        ruleID: String = UUID().uuidString,
        name: String,
        priority: Int = 100,
        enabled: Bool = true
    ) {
        self.ruleID = ruleID
        self.name = name
        self.priority = priority
        self.enabled = enabled
        self.createdAt = .now
        self.updatedAt = .now
        self.conditions = []
        self.actions = []
    }
}

// MARK: - RuleCondition

/// 分類ルールの判定条件。
@Model
final class RuleCondition {
    /// 一意識別子
    @Attribute(.unique) var conditionID: String
    /// 条件の種別
    var type: ConditionType
    /// 条件の値（キーワード文字列、正規表現、アプリ名、時刻範囲など）
    var value: String
    /// 紐付く分類ルール（逆参照）
    var rule: ClassificationRule?

    init(
        conditionID: String = UUID().uuidString,
        type: ConditionType,
        value: String
    ) {
        self.conditionID = conditionID
        self.type = type
        self.value = value
    }
}

/// 条件の判定種別
enum ConditionType: String, Codable, CaseIterable {
    /// ファイル名や OCR テキストに含まれるキーワード
    case keyword
    /// 正規表現パターン
    case regex
    /// フロントアプリ名（frontmostApp）
    case appName
    /// 時間帯（"HH:mm-HH:mm" 形式）
    case timeRange
    /// アセット種別（AssetKind.rawValue）
    case assetKind
}

// MARK: - RuleAction

/// 分類ルールが一致したときに実行するアクション。
@Model
final class RuleAction {
    /// 一意識別子
    @Attribute(.unique) var actionID: String
    /// 紐付く分類ルールの ID（ClassificationRule.ruleID に対応）
    var ruleID: String
    /// アクション種別
    var actionType: ActionType
    /// アクションに渡す値（カテゴリ名、フォルダパス、タグ名など）
    var actionValue: String
    /// 紐付く分類ルール（逆参照）
    var rule: ClassificationRule?

    init(
        actionID: String = UUID().uuidString,
        ruleID: String,
        actionType: ActionType,
        actionValue: String
    ) {
        self.actionID = actionID
        self.ruleID = ruleID
        self.actionType = actionType
        self.actionValue = actionValue
    }
}

/// アクションの種別
enum ActionType: String, Codable, CaseIterable {
    /// カテゴリを設定する（actionValue = カテゴリ名）
    case setCategory
    /// 保存先フォルダを設定する（actionValue = フォルダパステンプレート）
    case setFolder
    /// タグを追加する（actionValue = タグ名）
    case addTag
}
