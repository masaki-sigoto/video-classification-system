import SwiftUI
import SwiftData
import OSLog

// MARK: - ProvidersSettingsView

/// クラウド接続設定タブ
/// - 接続済みプロバイダ一覧（アイコン + 表示名 + 接続状態）
/// - 接続 / 切断 ボタン
struct ProvidersSettingsView: View {

    @Query private var accounts: [ProviderAccount]
    @Environment(\.modelContext) private var modelContext

    private let logger = Logger(subsystem: "com.screenvault.app", category: "providersSettings")

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            List {
                Section("接続済みプロバイダ") {
                    if accounts.isEmpty {
                        Text("接続しているプロバイダはありません")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(accounts) { account in
                            ProviderAccountRow(account: account) {
                                disconnect(account: account)
                            }
                        }
                    }
                }

                Section("プロバイダを接続") {
                    ForEach(availableProviders, id: \.self) { provider in
                        ConnectProviderRow(provider: provider) {
                            connect(provider: provider)
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
        .padding()
    }

    // MARK: - Helpers

    private var availableProviders: [ProviderType] {
        let connected = Set(accounts.map(\.providerType))
        return ProviderType.allCases.filter { !connected.contains($0) }
    }

    private func connect(provider: ProviderType) {
        logger.info("プロバイダ接続開始: \(provider.rawValue, privacy: .public)")
        // OAuth フローは OAuthManager 経由で実装（Phase 1.4-1.6 で本実装）
        // ここでは UI の雛形として ProviderAccount を仮挿入する
        let account = ProviderAccount(
            providerType: provider,
            userDisplay: "認証待ち..."
        )
        modelContext.insert(account)
        do {
            try modelContext.save()
        } catch {
            logger.error("ProviderAccount 保存失敗: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func disconnect(account: ProviderAccount) {
        logger.info("プロバイダ切断: \(account.providerType.rawValue, privacy: .public)")
        modelContext.delete(account)
        do {
            try modelContext.save()
        } catch {
            logger.error("ProviderAccount 削除失敗: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - ProviderAccountRow

private struct ProviderAccountRow: View {
    let account: ProviderAccount
    let onDisconnect: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            providerIcon(for: account.providerType)

            VStack(alignment: .leading, spacing: 2) {
                Text(account.providerType.displayName)
                    .font(.body.bold())
                Text(account.userDisplay)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // 接続状態バッジ
            Text("接続済み")
                .font(.caption)
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.green, in: Capsule())

            Button("切断") {
                onDisconnect()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - ConnectProviderRow

private struct ConnectProviderRow: View {
    let provider: ProviderType
    let onConnect: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            providerIcon(for: provider)

            Text(provider.displayName)
                .font(.body)
                .foregroundStyle(.secondary)

            Spacer()

            Button("接続...") {
                onConnect()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Provider Icon Helper

private func providerIcon(for provider: ProviderType) -> some View {
    Image(systemName: provider.systemImageName)
        .font(.title2)
        .foregroundStyle(provider.iconColor)
        .frame(width: 32)
}

// MARK: - ProviderType Extensions

extension ProviderType {
    var displayName: String {
        switch self {
        case .googleDrive: return "Google Drive"
        case .oneDrive:    return "OneDrive"
        case .dropbox:     return "Dropbox"
        case .iCloud:      return "iCloud Drive"
        }
    }

    var systemImageName: String {
        switch self {
        case .googleDrive: return "globe"
        case .oneDrive:    return "cloud"
        case .dropbox:     return "shippingbox"
        case .iCloud:      return "icloud"
        }
    }

    var iconColor: Color {
        switch self {
        case .googleDrive: return .blue
        case .oneDrive:    return .blue
        case .dropbox:     return Color(red: 0.0, green: 0.47, blue: 1.0)
        case .iCloud:      return .blue
        }
    }
}
