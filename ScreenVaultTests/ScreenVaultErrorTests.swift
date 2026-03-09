import Testing
import Foundation
@testable import ScreenVault

// MARK: - ScreenVaultError テスト

@Suite("ScreenVaultError — エラー型テスト")
struct ScreenVaultErrorTests {

    // MARK: - errorDescription が nil でないこと

    @Test("authenticationFailed の errorDescription は nil でない")
    func authenticationFailedDescription() {
        let error = ScreenVaultError.authenticationFailed(provider: .googleDrive, reason: "invalid_grant")
        #expect(error.errorDescription != nil)
        #expect(!(error.errorDescription?.isEmpty ?? true))
    }

    @Test("uploadSessionExpired の errorDescription は nil でない")
    func uploadSessionExpiredDescription() {
        let error = ScreenVaultError.uploadSessionExpired(provider: .oneDrive)
        #expect(error.errorDescription != nil)
    }

    @Test("uploadFailed の errorDescription は nil でない")
    func uploadFailedDescription() {
        let error = ScreenVaultError.uploadFailed(taskID: "task-001", reason: "503 Service Unavailable")
        #expect(error.errorDescription != nil)
        #expect(error.errorDescription?.contains("task-001") ?? false)
    }

    @Test("rateLimited (retryAfter あり) の errorDescription は nil でない")
    func rateLimitedWithRetryAfterDescription() {
        let error = ScreenVaultError.rateLimited(retryAfter: 60.0)
        #expect(error.errorDescription != nil)
        // 秒数が含まれていること
        #expect(error.errorDescription?.contains("60") ?? false)
    }

    @Test("rateLimited (retryAfter なし) の errorDescription は nil でない")
    func rateLimitedWithoutRetryAfterDescription() {
        let error = ScreenVaultError.rateLimited(retryAfter: nil)
        #expect(error.errorDescription != nil)
    }

    @Test("networkUnavailable の errorDescription は nil でない")
    func networkUnavailableDescription() {
        let error = ScreenVaultError.networkUnavailable
        #expect(error.errorDescription != nil)
    }

    @Test("fileNotFound の errorDescription は nil でない")
    func fileNotFoundDescription() {
        let error = ScreenVaultError.fileNotFound(path: "/Users/test/missing.png")
        #expect(error.errorDescription != nil)
        #expect(error.errorDescription?.contains("missing.png") ?? false)
    }

    @Test("duplicateDetected の errorDescription は nil でない")
    func duplicateDetectedDescription() {
        let hash = "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890"
        let error = ScreenVaultError.duplicateDetected(hash: hash)
        #expect(error.errorDescription != nil)
        #expect(error.errorDescription?.contains(hash) ?? false)
    }

    @Test("classificationFailed の errorDescription は nil でない")
    func classificationFailedDescription() {
        let error = ScreenVaultError.classificationFailed(reason: "no matching rule")
        #expect(error.errorDescription != nil)
    }

    @Test("providerNotConnected の errorDescription は nil でない")
    func providerNotConnectedDescription() {
        let error = ScreenVaultError.providerNotConnected(accountID: "acc-123")
        #expect(error.errorDescription != nil)
        #expect(error.errorDescription?.contains("acc-123") ?? false)
    }

    @Test("unknown の errorDescription は nil でない")
    func unknownDescription() {
        let error = ScreenVaultError.unknown("unexpected error occurred")
        #expect(error.errorDescription != nil)
    }

    @Test("keychainError の errorDescription は nil でない")
    func keychainErrorDescription() {
        let underlying = NSError(domain: "TestError", code: -1, userInfo: [NSLocalizedDescriptionKey: "test error"])
        let error = ScreenVaultError.keychainError(underlying: underlying)
        #expect(error.errorDescription != nil)
    }

    @Test("bookmarkResolutionFailed の errorDescription は nil でない")
    func bookmarkResolutionFailedDescription() {
        let error = ScreenVaultError.bookmarkResolutionFailed(key: "watchFolder1")
        #expect(error.errorDescription != nil)
        #expect(error.errorDescription?.contains("watchFolder1") ?? false)
    }

    // MARK: - recoverySuggestion の存在確認

    @Test("authenticationFailed の recoverySuggestion は nil でない")
    func authenticationFailedRecovery() {
        let error = ScreenVaultError.authenticationFailed(provider: .dropbox, reason: "token_expired")
        #expect(error.recoverySuggestion != nil)
    }

    @Test("uploadSessionExpired の recoverySuggestion は nil でない")
    func uploadSessionExpiredRecovery() {
        let error = ScreenVaultError.uploadSessionExpired(provider: .googleDrive)
        #expect(error.recoverySuggestion != nil)
    }

    @Test("uploadFailed の recoverySuggestion は nil でない")
    func uploadFailedRecovery() {
        let error = ScreenVaultError.uploadFailed(taskID: "t-001", reason: "timeout")
        #expect(error.recoverySuggestion != nil)
    }

    @Test("rateLimited (retryAfter あり) の recoverySuggestion は nil でない")
    func rateLimitedWithRetryAfterRecovery() {
        let error = ScreenVaultError.rateLimited(retryAfter: 30.0)
        #expect(error.recoverySuggestion != nil)
        #expect(error.recoverySuggestion?.contains("30") ?? false)
    }

    @Test("networkUnavailable の recoverySuggestion は nil でない")
    func networkUnavailableRecovery() {
        let error = ScreenVaultError.networkUnavailable
        #expect(error.recoverySuggestion != nil)
    }

    @Test("fileNotFound の recoverySuggestion は nil でない")
    func fileNotFoundRecovery() {
        let error = ScreenVaultError.fileNotFound(path: "/tmp/test.png")
        #expect(error.recoverySuggestion != nil)
    }

    @Test("duplicateDetected の recoverySuggestion は nil でない")
    func duplicateDetectedRecovery() {
        let error = ScreenVaultError.duplicateDetected(hash: "abc123")
        #expect(error.recoverySuggestion != nil)
    }

    @Test("classificationFailed の recoverySuggestion は nil でない")
    func classificationFailedRecovery() {
        let error = ScreenVaultError.classificationFailed(reason: "no rules")
        #expect(error.recoverySuggestion != nil)
    }

    @Test("providerNotConnected の recoverySuggestion は nil でない")
    func providerNotConnectedRecovery() {
        let error = ScreenVaultError.providerNotConnected(accountID: "acc-xyz")
        #expect(error.recoverySuggestion != nil)
    }

    @Test("unknown の recoverySuggestion は nil（回復策なし）")
    func unknownRecoveryIsNil() {
        let error = ScreenVaultError.unknown("some message")
        // unknown は recoverySuggestion = nil
        #expect(error.recoverySuggestion == nil)
    }

    @Test("keychainError の recoverySuggestion は nil でない")
    func keychainErrorRecovery() {
        let underlying = NSError(domain: "KeychainTest", code: -25300)
        let error = ScreenVaultError.keychainError(underlying: underlying)
        #expect(error.recoverySuggestion != nil)
    }

    @Test("bookmarkResolutionFailed の recoverySuggestion は nil でない")
    func bookmarkResolutionFailedRecovery() {
        let error = ScreenVaultError.bookmarkResolutionFailed(key: "folder-key")
        #expect(error.recoverySuggestion != nil)
    }

    // MARK: - Provider 全種での確認

    @Test("authenticationFailed は全 ProviderType で errorDescription を返す")
    func authenticationFailedAllProviders() {
        for provider in ProviderType.allCases {
            let error = ScreenVaultError.authenticationFailed(provider: provider, reason: "test")
            #expect(error.errorDescription != nil, "\(provider.rawValue) の errorDescription が nil")
            #expect(error.errorDescription?.contains(provider.rawValue) ?? false,
                    "\(provider.rawValue) が errorDescription に含まれていない")
        }
    }
}
