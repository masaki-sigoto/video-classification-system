import Foundation
import SwiftData

/// OAuth 2.0 トークン情報。
/// 実際のトークン文字列は Keychain に格納し、ここではキー名のみ保持する。
@Model
final class OAuthToken {
    /// 一意識別子
    @Attribute(.unique) var tokenID: String
    /// 紐付くプロバイダアカウントの ID（ProviderAccount.accountID に対応）
    var accountID: String
    /// Keychain に保存されたアクセストークンのキー名
    var accessTokenRef: String
    /// Keychain に保存されたリフレッシュトークンのキー名
    var refreshTokenRef: String
    /// アクセストークンの有効期限
    var expiresAt: Date
    /// レコード作成日時
    var createdAt: Date
    /// レコード最終更新日時
    var updatedAt: Date

    init(
        tokenID: String = UUID().uuidString,
        accountID: String,
        accessTokenRef: String,
        refreshTokenRef: String,
        expiresAt: Date
    ) {
        self.tokenID = tokenID
        self.accountID = accountID
        self.accessTokenRef = accessTokenRef
        self.refreshTokenRef = refreshTokenRef
        self.expiresAt = expiresAt
        self.createdAt = .now
        self.updatedAt = .now
    }

    /// アクセストークンが有効期限切れかどうかを判定する
    var isExpired: Bool {
        expiresAt <= .now
    }

    /// 有効期限まで余裕があるかどうか（5分未満なら期限切れ扱い）
    var needsRefresh: Bool {
        expiresAt <= Date(timeIntervalSinceNow: 5 * 60)
    }
}
