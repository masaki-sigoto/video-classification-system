import SwiftUI
import OSLog

// MARK: - CaptionPopover

/// キャプチャ直後に表示するキャプション入力ポップオーバー。
/// ユーザーが入力したテキストを `onSave` コールバックで Asset に反映する。
///
/// 使用例:
/// ```swift
/// Button("キャプチャ") { showCaption = true }
///   .popover(isPresented: $showCaption) {
///     CaptionPopover { caption in
///       asset.captionText = caption
///     }
///   }
/// ```
struct CaptionPopover: View {

    // MARK: - Callbacks

    /// "保存" ボタンが押されたときに呼ばれる。引数はユーザーが入力したテキスト（空の場合もある）
    var onSave: (String) -> Void
    /// "スキップ" ボタンまたは閉じるときに呼ばれる
    var onSkip: (() -> Void)?

    // MARK: - State

    @State private var captionText: String = ""
    @FocusState private var isTextFieldFocused: Bool
    @Environment(\.dismiss) private var dismiss

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            headerSection
            textInputSection
            actionButtons
        }
        .padding(20)
        .frame(width: 320)
        .onAppear {
            isTextFieldFocused = true
        }
    }

    // MARK: - Subviews

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("キャプションを追加")
                .font(.headline)
            Text("キャプチャ内容を説明するテキストを入力してください。スキップすることもできます。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var textInputSection: some View {
        TextField("例: ミーティングのメモ、エラー画面...", text: $captionText, axis: .vertical)
            .textFieldStyle(.roundedBorder)
            .lineLimit(3...6)
            .focused($isTextFieldFocused)
            .onSubmit {
                // Cmd+Return で保存
                saveCaption()
            }
    }

    private var actionButtons: some View {
        HStack {
            Button("スキップ") {
                SVLogger.ingest.info("CaptionPopover: skipped")
                onSkip?()
                dismiss()
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .keyboardShortcut(.escape, modifiers: [])

            Spacer()

            Button("保存") {
                saveCaption()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(captionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    // MARK: - Actions

    private func saveCaption() {
        let trimmed = captionText.trimmingCharacters(in: .whitespacesAndNewlines)
        SVLogger.ingest.info("CaptionPopover: saved caption (length=\(trimmed.count))")
        onSave(trimmed)
        dismiss()
    }
}

// MARK: - CaptionPopoverModifier

/// SwiftUI View に `.captionPopover()` モディファイアを追加するヘルパー
extension View {
    /// キャプションポップオーバーを表示するモディファイア
    /// - Parameters:
    ///   - isPresented: 表示状態のバインディング
    ///   - onSave: 保存時コールバック（入力テキスト）
    ///   - onSkip: スキップ時コールバック
    func captionPopover(
        isPresented: Binding<Bool>,
        onSave: @escaping (String) -> Void,
        onSkip: (() -> Void)? = nil
    ) -> some View {
        self.popover(isPresented: isPresented, arrowEdge: .bottom) {
            CaptionPopover(onSave: onSave, onSkip: onSkip)
        }
    }
}

// MARK: - Preview

#Preview("CaptionPopover") {
    VStack {
        Text("キャプチャ完了")
            .padding()
    }
    .frame(width: 400, height: 300)
    .sheet(isPresented: .constant(true)) {
        CaptionPopover(
            onSave: { text in
                print("saved: \(text)")
            },
            onSkip: {
                print("skipped")
            }
        )
    }
}
