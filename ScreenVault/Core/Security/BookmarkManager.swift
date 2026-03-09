import Foundation
import OSLog

/// Security-Scoped Bookmark の保存・復元・アクセス管理。
///
/// App Sandbox 環境下でフォルダへの永続アクセス権を維持するために使用する。
/// ブックマークデータは UserDefaults に格納し、アプリ再起動後も復元できる。
final class BookmarkManager {

    // MARK: - プロパティ

    private let defaults: UserDefaults
    private let userDefaultsSuite: String

    // MARK: - 初期化

    /// - Parameter userDefaultsSuite: 使用する UserDefaults のスイート名（nil でスタンダードを使用）
    init(userDefaultsSuite: String? = nil) {
        if let suite = userDefaultsSuite {
            self.defaults = UserDefaults(suiteName: suite) ?? .standard
            self.userDefaultsSuite = suite
        } else {
            self.defaults = .standard
            self.userDefaultsSuite = "standard"
        }
    }

    // MARK: - ブックマークの保存

    /// 指定した URL の Security-Scoped Bookmark を UserDefaults に保存する。
    ///
    /// 呼び出す前に `startAccessing(url:)` でアクセスが開始済みである必要がある場合がある。
    /// - Parameters:
    ///   - url: ブックマーク化するフォルダまたはファイルの URL
    ///   - key: UserDefaults に保存するキー名
    /// - Throws: `BookmarkError.creationFailed` または `BookmarkError.saveFailed`
    func saveBookmark(for url: URL, key: String) throws {
        SVLogger.general.info("ブックマーク保存開始: key=\(key, privacy: .public), path=\(url.path, privacy: .sensitive)")

        let bookmarkData: Data
        do {
            bookmarkData = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            SVLogger.general.error("ブックマーク作成失敗: key=\(key, privacy: .public), error=\(error.localizedDescription, privacy: .public)")
            throw BookmarkError.creationFailed(url: url, underlying: error)
        }

        defaults.set(bookmarkData, forKey: bookmarkKey(for: key))
        SVLogger.general.info("ブックマーク保存完了: key=\(key, privacy: .public)")
    }

    // MARK: - ブックマークの復元

    /// 指定したキーのブックマークを解決し、アクセス可能な URL を返す。
    ///
    /// ブックマークが陳腐化（stale）している場合は自動的に再保存する。
    /// - Parameter key: UserDefaults に保存したキー名
    /// - Returns: 解決した URL。キーが存在しない場合は `nil`
    /// - Throws: `BookmarkError.resolutionFailed`
    func resolveBookmark(key: String) throws -> URL? {
        let storageKey = bookmarkKey(for: key)

        guard let bookmarkData = defaults.data(forKey: storageKey) else {
            SVLogger.general.debug("ブックマーク未登録: key=\(key, privacy: .public)")
            return nil
        }

        SVLogger.general.debug("ブックマーク解決開始: key=\(key, privacy: .public)")

        var isStale = false
        let resolvedURL: URL
        do {
            resolvedURL = try URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            SVLogger.general.error("ブックマーク解決失敗: key=\(key, privacy: .public), error=\(error.localizedDescription, privacy: .public)")
            throw BookmarkError.resolutionFailed(key: key, underlying: error)
        }

        // 陳腐化している場合は再保存して最新状態を維持する
        if isStale {
            SVLogger.general.warning("ブックマーク陳腐化を検出。再保存します: key=\(key, privacy: .public)")
            try saveBookmark(for: resolvedURL, key: key)
        }

        SVLogger.general.debug("ブックマーク解決完了: key=\(key, privacy: .public), path=\(resolvedURL.path, privacy: .sensitive)")
        return resolvedURL
    }

    // MARK: - アクセス制御

    /// Security-Scoped リソースへのアクセスを開始する。
    ///
    /// 使用後は必ず `stopAccessing(url:)` を呼ぶこと。
    /// - Parameter url: アクセスを開始する URL
    /// - Returns: アクセス開始に成功した場合は `true`
    @discardableResult
    func startAccessing(url: URL) -> Bool {
        let result = url.startAccessingSecurityScopedResource()
        if result {
            SVLogger.general.debug("セキュリティスコープアクセス開始: \(url.lastPathComponent, privacy: .public)")
        } else {
            SVLogger.general.warning("セキュリティスコープアクセス開始失敗: \(url.path, privacy: .sensitive)")
        }
        return result
    }

    /// Security-Scoped リソースへのアクセスを終了する。
    ///
    /// `startAccessing(url:)` で取得したアクセスを必ず解放すること。
    /// - Parameter url: アクセスを終了する URL
    func stopAccessing(url: URL) {
        url.stopAccessingSecurityScopedResource()
        SVLogger.general.debug("セキュリティスコープアクセス終了: \(url.lastPathComponent, privacy: .public)")
    }

    // MARK: - ブックマーク削除

    /// 指定したキーのブックマークデータを UserDefaults から削除する。
    /// - Parameter key: 削除するキー名
    func removeBookmark(key: String) {
        defaults.removeObject(forKey: bookmarkKey(for: key))
        SVLogger.general.info("ブックマーク削除: key=\(key, privacy: .public)")
    }

    // MARK: - プライベートヘルパー

    /// UserDefaults 内で衝突しないようにプレフィックスを付加したキーを生成する
    private func bookmarkKey(for key: String) -> String {
        "com.screenvault.bookmark.\(key)"
    }
}

// MARK: - BookmarkError

/// `BookmarkManager` が送出するエラー
enum BookmarkError: LocalizedError {
    case creationFailed(url: URL, underlying: Error)
    case resolutionFailed(key: String, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .creationFailed(let url, let underlying):
            return "ブックマーク作成エラー: \(url.lastPathComponent) — \(underlying.localizedDescription)"
        case .resolutionFailed(let key, let underlying):
            return "ブックマーク解決エラー: key=\(key) — \(underlying.localizedDescription)"
        }
    }
}
