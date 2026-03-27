import Foundation
import AuthenticationServices

/// ASWebAuthenticationSession の presentationContext を提供する共有クラス。
/// Google Drive / OneDrive / Dropbox コネクタから共通で利用する。
final class OAuthPresentationContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding, @unchecked Sendable {
    static let shared = OAuthPresentationContextProvider()
    private override init() {}

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApplication.shared.keyWindow ?? NSWindow()
    }
}

/// OAuth 2.0 ブラウザ認証のユーティリティ。
/// ASWebAuthenticationSession を使ってコールバック URL を返す。
enum OAuthWebAuth {

    /// @MainActor コンテキストでブラウザ認証を実行し、コールバック URL を返す。
    @MainActor
    static func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let authSession = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackScheme
            ) { callbackURL, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let callbackURL = callbackURL {
                    continuation.resume(returning: callbackURL)
                } else {
                    continuation.resume(throwing: OAuthWebAuthError.callbackURLMissing)
                }
            }
            authSession.presentationContextProvider = OAuthPresentationContextProvider.shared
            authSession.prefersEphemeralWebBrowserSession = true
            authSession.start()
        }
    }
}

enum OAuthWebAuthError: Error, LocalizedError {
    case callbackURLMissing

    var errorDescription: String? {
        "OAuth コールバック URL が受信できませんでした"
    }
}
