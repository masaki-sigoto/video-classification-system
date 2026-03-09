import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("ScreenVault")
                .font(.headline)

            Divider()

            Label("同期中", systemImage: "arrow.triangle.2.circlepath")

            Divider()

            Button("設定を開く...") {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }

            Button("終了") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding()
        .frame(width: 220)
    }
}
