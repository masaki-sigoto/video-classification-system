import Foundation
import SwiftData

/// クラウドプロバイダのアカウント情報
@Model
final class ProviderAccount {
    @Attribute(.unique) var accountID: String
    var providerType: ProviderType
    var userDisplay: String
    var scopeLevel: String?
    var createdAt: Date

    init(
        accountID: String = UUID().uuidString,
        providerType: ProviderType,
        userDisplay: String
    ) {
        self.accountID = accountID
        self.providerType = providerType
        self.userDisplay = userDisplay
        self.createdAt = .now
    }
}

enum ProviderType: String, Codable, CaseIterable {
    case googleDrive
    case oneDrive
    case dropbox
    case iCloud
}
