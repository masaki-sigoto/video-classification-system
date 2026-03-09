import SwiftUI
import SwiftData
import OSLog

// MARK: - ClassificationSettingsView

/// 分類ルール設定タブ
/// - ルール一覧（ドラッグで優先順位変更）
/// - ルール追加 / 編集 / 削除
/// - OCR ON/OFF トグル（Phase 2 向けプレースホルダ）
struct ClassificationSettingsView: View {

    @Query(sort: \ClassificationRule.priority, order: .forward)
    private var rules: [ClassificationRule]

    @Environment(\.modelContext) private var modelContext

    @AppStorage("ocrEnabled") private var ocrEnabled: Bool = false

    @State private var editingRule: ClassificationRule? = nil
    @State private var showAddSheet: Bool = false

    private let logger = Logger(subsystem: "com.screenvault.app", category: "classificationSettings")

    var body: some View {
        VStack(spacing: 0) {
            // ルール一覧
            ruleList

            Divider()

            // OCR トグル
            ocrToggleRow
        }
        .sheet(isPresented: $showAddSheet) {
            RuleEditSheet(rule: nil) { newRule in
                addRule(newRule)
            }
        }
        .sheet(item: $editingRule) { rule in
            RuleEditSheet(rule: rule) { updated in
                saveRule(rule: rule, from: updated)
            }
        }
    }

    // MARK: - Rule List

    private var ruleList: some View {
        List {
            Section {
                if rules.isEmpty {
                    Text("分類ルールがありません。「追加」ボタンで作成してください。")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 8)
                } else {
                    ForEach(rules) { rule in
                        ClassificationRuleRow(rule: rule) {
                            editingRule = rule
                        } onDelete: {
                            deleteRule(rule)
                        }
                    }
                    .onMove(perform: moveRules)
                }
            } header: {
                HStack {
                    Text("ルール（優先順位順）")
                    Spacer()
                    Button {
                        showAddSheet = true
                    } label: {
                        Label("追加", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .listStyle(.inset)
    }

    // MARK: - OCR Toggle

    private var ocrToggleRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Toggle("OCR テキスト認識を使用する", isOn: $ocrEnabled)
                Text("Phase 2 で実装予定 — 有効にするとアップロード前に画像内テキストを抽出して分類に活用します")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .disabled(true) // Phase 2 まではプレースホルダとして無効
    }

    // MARK: - CRUD

    private func addRule(_ draft: RuleDraft) {
        let rule = ClassificationRule(
            name: draft.name,
            priority: (rules.last?.priority ?? 0) + 10,
            enabled: draft.enabled
        )
        for cond in draft.conditions {
            let condition = RuleCondition(type: cond.type, value: cond.value)
            condition.rule = rule
            rule.conditions.append(condition)
        }
        for act in draft.actions {
            let action = RuleAction(ruleID: rule.ruleID, actionType: act.actionType, actionValue: act.actionValue)
            action.rule = rule
            rule.actions.append(action)
        }
        modelContext.insert(rule)
        trySave()
        logger.info("分類ルール追加: \(draft.name, privacy: .public)")
    }

    private func saveRule(rule: ClassificationRule, from draft: RuleDraft) {
        rule.name = draft.name
        rule.enabled = draft.enabled
        rule.updatedAt = .now
        trySave()
        logger.info("分類ルール更新: \(draft.name, privacy: .public)")
    }

    private func deleteRule(_ rule: ClassificationRule) {
        modelContext.delete(rule)
        trySave()
        logger.info("分類ルール削除: \(rule.name, privacy: .public)")
    }

    private func moveRules(from source: IndexSet, to destination: Int) {
        var reordered = rules
        reordered.move(fromOffsets: source, toOffset: destination)
        for (index, rule) in reordered.enumerated() {
            rule.priority = (index + 1) * 10
        }
        trySave()
    }

    private func trySave() {
        do {
            try modelContext.save()
        } catch {
            logger.error("保存失敗: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - ClassificationRuleRow

private struct ClassificationRuleRow: View {
    let rule: ClassificationRule
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            // 有効/無効インジケータ
            Circle()
                .fill(rule.enabled ? Color.green : Color.secondary)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(rule.name)
                    .font(.body)
                    .foregroundStyle(rule.enabled ? .primary : .secondary)
                Text(ruleDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("編集") { onEdit() }
                .buttonStyle(.borderless)
                .controlSize(.small)

            Button(role: .destructive) { onDelete() } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        .padding(.vertical, 2)
    }

    private var ruleDescription: String {
        let condCount = rule.conditions.count
        let actCount = rule.actions.count
        return "条件 \(condCount) 件 / アクション \(actCount) 件"
    }
}

// MARK: - RuleDraft（編集用一時データ）

struct RuleDraft {
    var name: String = ""
    var enabled: Bool = true
    var conditions: [ConditionDraft] = []
    var actions: [ActionDraft] = []
}

struct ConditionDraft: Identifiable {
    var id = UUID()
    var type: ConditionType = .keyword
    var value: String = ""
}

struct ActionDraft: Identifiable {
    var id = UUID()
    var actionType: ActionType = .setCategory
    var actionValue: String = ""
}

// MARK: - RuleEditSheet

struct RuleEditSheet: View {
    let rule: ClassificationRule?
    let onSave: (RuleDraft) -> Void

    @State private var draft: RuleDraft
    @Environment(\.dismiss) private var dismiss

    init(rule: ClassificationRule?, onSave: @escaping (RuleDraft) -> Void) {
        self.rule = rule
        self.onSave = onSave

        if let rule {
            _draft = State(initialValue: RuleDraft(
                name: rule.name,
                enabled: rule.enabled,
                conditions: rule.conditions.map {
                    ConditionDraft(type: $0.type, value: $0.value)
                },
                actions: rule.actions.map {
                    ActionDraft(actionType: $0.actionType, actionValue: $0.actionValue)
                }
            ))
        } else {
            _draft = State(initialValue: RuleDraft())
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // タイトル
            HStack {
                Text(rule == nil ? "ルールを追加" : "ルールを編集")
                    .font(.headline)
                Spacer()
            }
            .padding()

            Divider()

            Form {
                // 基本情報
                Section("基本情報") {
                    TextField("ルール名", text: $draft.name)
                    Toggle("有効", isOn: $draft.enabled)
                }

                // 条件
                Section {
                    ForEach($draft.conditions) { $cond in
                        ConditionRow(cond: $cond) {
                            draft.conditions.removeAll { $0.id == cond.id }
                        }
                    }
                    Button {
                        draft.conditions.append(ConditionDraft())
                    } label: {
                        Label("条件を追加", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                } header: {
                    Text("条件（AND 評価）")
                }

                // アクション
                Section {
                    ForEach($draft.actions) { $act in
                        ActionRow(act: $act) {
                            draft.actions.removeAll { $0.id == act.id }
                        }
                    }
                    Button {
                        draft.actions.append(ActionDraft())
                    } label: {
                        Label("アクションを追加", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                } header: {
                    Text("アクション")
                }
            }
            .formStyle(.grouped)

            Divider()

            // フッターボタン
            HStack {
                Button("キャンセル") { dismiss() }
                    .keyboardShortcut(.escape)
                Spacer()
                Button("保存") {
                    onSave(draft)
                    dismiss()
                }
                .keyboardShortcut(.return)
                .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(width: 460, height: 520)
    }
}

// MARK: - ConditionRow

private struct ConditionRow: View {
    @Binding var cond: ConditionDraft
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Picker("種別", selection: $cond.type) {
                ForEach(ConditionType.allCases, id: \.self) { type in
                    Text(type.label).tag(type)
                }
            }
            .labelsHidden()
            .frame(width: 120)

            TextField(cond.type.placeholder, text: $cond.value)
                .textFieldStyle(.roundedBorder)

            Button(role: .destructive) { onDelete() } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - ActionRow

private struct ActionRow: View {
    @Binding var act: ActionDraft
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Picker("種別", selection: $act.actionType) {
                ForEach(ActionType.allCases, id: \.self) { type in
                    Text(type.label).tag(type)
                }
            }
            .labelsHidden()
            .frame(width: 130)

            TextField(act.actionType.placeholder, text: $act.actionValue)
                .textFieldStyle(.roundedBorder)

            Button(role: .destructive) { onDelete() } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - ConditionType Extension

extension ConditionType {
    var label: String {
        switch self {
        case .keyword:   return "キーワード"
        case .regex:     return "正規表現"
        case .appName:   return "アプリ名"
        case .timeRange: return "時間帯"
        case .assetKind: return "ファイル種別"
        }
    }

    var placeholder: String {
        switch self {
        case .keyword:   return "例: 議事録"
        case .regex:     return "例: \\d{4}-\\d{2}"
        case .appName:   return "例: Xcode"
        case .timeRange: return "例: 09:00-18:00"
        case .assetKind: return "例: screenshot"
        }
    }
}

// MARK: - ActionType Extension

extension ActionType {
    var label: String {
        switch self {
        case .setCategory: return "カテゴリ設定"
        case .setFolder:   return "フォルダ設定"
        case .addTag:      return "タグ追加"
        }
    }

    var placeholder: String {
        switch self {
        case .setCategory: return "例: 仕事"
        case .setFolder:   return "例: 仕事/資料"
        case .addTag:      return "例: 重要"
        }
    }
}
