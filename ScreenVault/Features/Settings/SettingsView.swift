import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("一般", systemImage: "gear")
                }

            ProvidersSettingsView()
                .tabItem {
                    Label("クラウド接続", systemImage: "cloud")
                }

            ClassificationSettingsView()
                .tabItem {
                    Label("分類ルール", systemImage: "folder.badge.gearshape")
                }
        }
        .frame(width: 500, height: 400)
    }
}

struct GeneralSettingsView: View {
    var body: some View {
        Text("一般設定")
            .padding()
    }
}

struct ProvidersSettingsView: View {
    var body: some View {
        Text("クラウド接続設定")
            .padding()
    }
}

struct ClassificationSettingsView: View {
    var body: some View {
        Text("分類ルール設定")
            .padding()
    }
}
