import Foundation
import AppKit
import Combine
import OSLog

// MARK: - HotkeyAction

/// ホットキーに紐付くアクション種別
enum HotkeyAction: String, CaseIterable {
    case captureScreen    = "captureScreen"
    case captureWindow    = "captureWindow"
    case toggleRecording  = "toggleRecording"
    case captureClipboard = "captureClipboard"

    var defaultKeyEquivalent: HotkeyBinding {
        switch self {
        case .captureScreen:
            return HotkeyBinding(keyCode: 18, modifiers: [.command, .shift]) // Cmd+Shift+1
        case .captureWindow:
            return HotkeyBinding(keyCode: 19, modifiers: [.command, .shift]) // Cmd+Shift+2
        case .toggleRecording:
            return HotkeyBinding(keyCode: 20, modifiers: [.command, .shift]) // Cmd+Shift+3
        case .captureClipboard:
            return HotkeyBinding(keyCode: 21, modifiers: [.command, .shift]) // Cmd+Shift+4
        }
    }

    var displayName: String {
        switch self {
        case .captureScreen:    return "スクリーンショット"
        case .captureWindow:    return "ウィンドウキャプチャ"
        case .toggleRecording:  return "録画開始/停止"
        case .captureClipboard: return "クリップボード取り込み"
        }
    }
}

// MARK: - HotkeyBinding

/// キーコードと修飾キーの組み合わせを表す値型
struct HotkeyBinding: Codable, Equatable {
    /// CGKeyCode に相当する仮想キーコード（数字キー 1 = 18, 2 = 19, 3 = 20, 4 = 21）
    var keyCode: UInt16
    /// 修飾キーフラグ（NSEvent.ModifierFlags の rawValue を保存）
    var modifierFlags: UInt

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifierFlags = modifiers.rawValue
    }

    var modifiers: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifierFlags)
    }

    /// UserDefaults への保存キー
    static func defaultsKey(for action: HotkeyAction) -> String {
        "hotkey_\(action.rawValue)"
    }
}

// MARK: - HotkeyManager

/// グローバルホットキーを管理するクラス。
/// `NSEvent.addGlobalMonitorForEvents` を使用してシステム全体のキー入力を監視する。
/// ホットキーがトリガーされると `actionPublisher` にイベントを流す。
@MainActor
final class HotkeyManager: ObservableObject {

    // MARK: - Published

    @Published private(set) var isEnabled: Bool = false

    // MARK: - Public Publisher

    /// ホットキーが押されたときに HotkeyAction を発行する
    let actionPublisher = PassthroughSubject<HotkeyAction, Never>()

    // MARK: - Private

    /// グローバルモニターのトークン（解除に使用）
    private var globalMonitor: Any?
    /// アクション → バインディング のマッピング（ユーザーカスタマイズ込み）
    private var bindings: [HotkeyAction: HotkeyBinding] = [:]

    // MARK: - Init

    init() {
        loadBindings()
    }

    // MARK: - Public API

    /// グローバルホットキー監視を開始する。
    /// Accessibility 権限が必要。
    func startMonitoring() {
        guard globalMonitor == nil else {
            SVLogger.ingest.warning("HotkeyManager: already monitoring")
            return
        }

        SVLogger.ingest.info("HotkeyManager: starting global hotkey monitor")

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleKeyEvent(event)
            }
        }

        isEnabled = true
        SVLogger.ingest.info("HotkeyManager: global hotkey monitor started")
    }

    /// グローバルホットキー監視を停止する。
    func stopMonitoring() {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
        isEnabled = false
        SVLogger.ingest.info("HotkeyManager: global hotkey monitor stopped")
    }

    /// ホットキーのバインディングを更新し、UserDefaults に永続化する。
    func updateBinding(_ binding: HotkeyBinding, for action: HotkeyAction) {
        bindings[action] = binding
        saveBinding(binding, for: action)
        SVLogger.ingest.info(
            "HotkeyManager: binding updated for \(action.rawValue, privacy: .public)"
        )
    }

    /// 指定アクションの現在のバインディングを取得する。
    func binding(for action: HotkeyAction) -> HotkeyBinding {
        bindings[action] ?? action.defaultKeyEquivalent
    }

    // MARK: - Key Event Handling

    private func handleKeyEvent(_ event: NSEvent) {
        let pressedKeyCode = event.keyCode
        let pressedModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        for action in HotkeyAction.allCases {
            let binding = bindings[action] ?? action.defaultKeyEquivalent
            let requiredModifiers = binding.modifiers.intersection(.deviceIndependentFlagsMask)

            if pressedKeyCode == binding.keyCode && pressedModifiers == requiredModifiers {
                SVLogger.ingest.info(
                    "HotkeyManager: hotkey triggered action=\(action.rawValue, privacy: .public)"
                )
                actionPublisher.send(action)
                break
            }
        }
    }

    // MARK: - UserDefaults Persistence

    private func loadBindings() {
        for action in HotkeyAction.allCases {
            let key = HotkeyBinding.defaultsKey(for: action)
            if let data = UserDefaults.standard.data(forKey: key),
               let binding = try? JSONDecoder().decode(HotkeyBinding.self, from: data) {
                bindings[action] = binding
            } else {
                // UserDefaults に保存がなければデフォルトを使用
                bindings[action] = action.defaultKeyEquivalent
            }
        }
        SVLogger.ingest.info("HotkeyManager: bindings loaded")
    }

    private func saveBinding(_ binding: HotkeyBinding, for action: HotkeyAction) {
        let key = HotkeyBinding.defaultsKey(for: action)
        if let data = try? JSONEncoder().encode(binding) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

}
