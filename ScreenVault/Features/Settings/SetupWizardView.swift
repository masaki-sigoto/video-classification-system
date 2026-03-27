import SwiftUI
import AppKit
import OSLog

// MARK: - SetupWizardView

/// 初回起動時に表示するセットアップウィザード（5ステップ）。
/// `@AppStorage("hasCompletedSetup")` で表示制御する。
///
/// ステップ:
///  1. ようこそ（アプリの説明）
///  2. Watch フォルダの選択
///  3. macOS スクリーンショット保存先変更のガイド
///  4. クラウド接続の選択（Google Drive / OneDrive / Dropbox）
///  5. 完了
struct SetupWizardView: View {

    // MARK: - AppStorage

    @AppStorage("hasCompletedSetup") private var hasCompletedSetup: Bool = false

    // MARK: - State

    @State private var currentStep: WizardStep = .welcome
    @State private var selectedWatchFolder: URL? = nil
    @State private var selectedProviders: Set<ProviderChoice> = []

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // ステップインジケーター
            stepIndicator
                .padding(.horizontal, 32)
                .padding(.top, 24)

            Divider()
                .padding(.top, 16)

            // ステップコンテンツ
            Group {
                switch currentStep {
                case .welcome:
                    WelcomeStepView()
                case .watchFolder:
                    WatchFolderStepView(selectedFolder: $selectedWatchFolder)
                case .screenshotGuide:
                    ScreenshotGuideStepView()
                case .cloudConnect:
                    CloudConnectStepView(selectedProviders: $selectedProviders)
                case .complete:
                    CompleteStepView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(32)

            Divider()

            // ナビゲーションボタン
            navigationButtons
                .padding(24)
        }
        .frame(width: 560, height: 480)
    }

    // MARK: - Step Indicator

    private var stepIndicator: some View {
        HStack(spacing: 0) {
            ForEach(WizardStep.allCases) { step in
                HStack(spacing: 0) {
                    Circle()
                        .fill(stepColor(for: step))
                        .frame(width: 28, height: 28)
                        .overlay {
                            if step < currentStep {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.white)
                                    .font(.caption.bold())
                            } else {
                                Text("\(step.index + 1)")
                                    .foregroundStyle(step == currentStep ? .white : .secondary)
                                    .font(.caption.bold())
                            }
                        }

                    if step != WizardStep.allCases.last {
                        Rectangle()
                            .fill(step < currentStep ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(height: 2)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private func stepColor(for step: WizardStep) -> Color {
        if step == currentStep { return .accentColor }
        if step < currentStep { return .accentColor }
        return Color.secondary.opacity(0.3)
    }

    // MARK: - Navigation Buttons

    private var navigationButtons: some View {
        HStack {
            if currentStep != .welcome {
                Button("戻る") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        currentStep = currentStep.previous ?? .welcome
                    }
                }
                .buttonStyle(.borderless)
            }

            Spacer()

            if currentStep == .complete {
                Button("始めましょう!") {
                    completeSetup()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: .command)
            } else {
                Button(currentStep == .cloudConnect ? "スキップ" : "次へ") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        currentStep = currentStep.next ?? .complete
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
    }

    // MARK: - Actions

    private func completeSetup() {
        SVLogger.general.info("SetupWizard: setup completed")
        hasCompletedSetup = true
    }
}

// MARK: - WizardStep

private enum WizardStep: Int, CaseIterable, Identifiable, Comparable {
    case welcome = 0
    case watchFolder = 1
    case screenshotGuide = 2
    case cloudConnect = 3
    case complete = 4

    var id: Int { rawValue }
    var index: Int { rawValue }

    var next: WizardStep? { WizardStep(rawValue: rawValue + 1) }
    var previous: WizardStep? { WizardStep(rawValue: rawValue - 1) }

    static func < (lhs: WizardStep, rhs: WizardStep) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - ProviderChoice

private enum ProviderChoice: String, CaseIterable, Identifiable {
    case googleDrive = "Google Drive"
    case oneDrive = "OneDrive"
    case dropbox = "Dropbox"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .googleDrive: return "arrow.triangle.2.circlepath.circle.fill"
        case .oneDrive:    return "cloud.fill"
        case .dropbox:     return "tray.and.arrow.up.fill"
        }
    }

    var iconColor: Color {
        switch self {
        case .googleDrive: return .blue
        case .oneDrive:    return .blue
        case .dropbox:     return Color(red: 0.007, green: 0.451, blue: 0.996)
        }
    }
}

// MARK: - Step 1: Welcome

private struct WelcomeStepView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 60))
                .foregroundStyle(Color.accentColor)

            VStack(spacing: 8) {
                Text("ScreenVault へようこそ")
                    .font(.largeTitle.bold())

                Text("スクリーンショットや画面録画を自動的にクラウドへ保存・分類するアプリです。")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 12) {
                FeatureRow(
                    icon: "folder.badge.plus",
                    title: "自動保存",
                    description: "指定フォルダの新しいファイルを自動検出してクラウドへ"
                )
                FeatureRow(
                    icon: "tag.fill",
                    title: "AI 分類",
                    description: "OCR・画像認識で内容を自動タグ付け・フォルダ振り分け"
                )
                FeatureRow(
                    icon: "icloud.fill",
                    title: "マルチクラウド",
                    description: "Google Drive・OneDrive・Dropbox に対応"
                )
            }
            .padding(.top, 8)
        }
    }
}

private struct FeatureRow: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .frame(width: 24)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Step 2: Watch Folder

private struct WatchFolderStepView: View {
    @Binding var selectedFolder: URL?

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 48))
                .foregroundStyle(Color.accentColor)

            VStack(spacing: 8) {
                Text("監視フォルダの選択")
                    .font(.title2.bold())
                Text("スクリーンショットや録画が保存されるフォルダを選択してください。\nデスクトップや「ピクチャ」フォルダが一般的です。")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let folder = selectedFolder {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(folder.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                .padding(12)
                .background(Color.green.opacity(0.1))
                .cornerRadius(8)
            }

            Button("フォルダを選択...") {
                selectFolder()
            }
            .buttonStyle(.bordered)

            Text("後から設定画面で変更・追加できます。")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private func selectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "監視フォルダを選択"
        panel.message = "スクリーンショットや録画が保存されるフォルダを選択してください。"
        panel.prompt = "選択"

        if panel.runModal() == .OK {
            selectedFolder = panel.url
            SVLogger.general.info(
                "SetupWizard: watch folder selected \(panel.url?.lastPathComponent ?? "", privacy: .public)"
            )
        }
    }
}

// MARK: - Step 3: Screenshot Guide

private struct ScreenshotGuideStepView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                .font(.system(size: 48))
                .foregroundStyle(Color.accentColor)

            VStack(spacing: 8) {
                Text("スクリーンショット保存先の変更")
                    .font(.title2.bold())

                Text("macOS のスクリーンショット保存先を ScreenVault の監視フォルダに変更すると、自動的に取り込まれます。")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 12) {
                GuideStep(number: 1, text: "Shift + Command + 5 を押す")
                GuideStep(number: 2, text: "画面下に表示されたツールバーの「オプション」をクリック")
                GuideStep(number: 3, text: "「保存先」→「その他の場所...」を選択")
                GuideStep(number: 4, text: "ScreenVault の監視フォルダを選択して「選択」をクリック")
            }
            .padding(16)
            .background(Color.secondary.opacity(0.08))
            .cornerRadius(10)

            Button("スクリーンショットツールを開く") {
                openScreenshotTool()
            }
            .buttonStyle(.bordered)
        }
    }

    private func openScreenshotTool() {
        // macOS の Screenshot.app を起動
        let screenshotURL = URL(fileURLWithPath: "/System/Applications/Utilities/Screenshot.app")
        NSWorkspace.shared.open(screenshotURL)
        SVLogger.general.info("SetupWizard: opened Screenshot.app")
    }
}

private struct GuideStep: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Color.accentColor)
                .clipShape(Circle())
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Step 4: Cloud Connect

private struct CloudConnectStepView: View {
    @Binding var selectedProviders: Set<ProviderChoice>

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "icloud.and.arrow.up.fill")
                .font(.system(size: 48))
                .foregroundStyle(Color.accentColor)

            VStack(spacing: 8) {
                Text("クラウドサービスを接続")
                    .font(.title2.bold())
                Text("使用するクラウドサービスを選択してください。\n後から設定画面で追加・削除できます。")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 8) {
                ForEach(ProviderChoice.allCases) { provider in
                    ProviderToggleRow(
                        provider: provider,
                        isSelected: selectedProviders.contains(provider)
                    ) {
                        if selectedProviders.contains(provider) {
                            selectedProviders.remove(provider)
                        } else {
                            selectedProviders.insert(provider)
                        }
                    }
                }
            }

            Text("今はスキップして、後から設定画面で接続することもできます。")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
    }
}

private struct ProviderToggleRow: View {
    let provider: ProviderChoice
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 12) {
                Image(systemName: provider.iconName)
                    .font(.title2)
                    .foregroundStyle(provider.iconColor)
                    .frame(width: 32)

                Text(provider.rawValue)
                    .font(.body)
                    .foregroundStyle(.primary)

                Spacer()

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .font(.title3)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(isSelected ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.05))
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Step 5: Complete

private struct CompleteStepView: View {
    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
                .symbolEffect(.bounce, value: true)

            VStack(spacing: 8) {
                Text("準備完了!")
                    .font(.largeTitle.bold())

                Text("ScreenVault の設定が完了しました。\nメニューバーのアイコンからいつでも設定を変更できます。")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 10) {
                TipRow(icon: "keyboard", text: "Cmd+Shift+1〜4 でキャプチャ・録画を操作")
                TipRow(icon: "menubar.rectangle", text: "メニューバーアイコンで同期状態を確認")
                TipRow(icon: "gear", text: "設定画面でルール・フォルダをカスタマイズ")
            }
            .padding(16)
            .background(Color.secondary.opacity(0.08))
            .cornerRadius(10)
        }
    }
}

private struct TipRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .frame(width: 20)
                .foregroundStyle(Color.accentColor)
            Text(text)
                .font(.callout)
        }
    }
}

// MARK: - Preview

#Preview("SetupWizard") {
    SetupWizardView()
}
