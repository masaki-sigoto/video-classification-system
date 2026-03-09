import SwiftUI

@main
struct ScreenVaultApp: App {
    var body: some Scene {
        MenuBarExtra("ScreenVault", systemImage: "arrow.up.doc") {
            ContentView()
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }
}
