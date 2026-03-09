import Foundation

/// RemoteFolderCache のインメモリキャッシュ。
/// フォルダパスキーからリモートフォルダ ID を高速に引くために使う。
/// 実際のプロダクションコードでは SwiftData（RemoteFolderCache）経由で永続化する。
/// 全プロバイダコネクタから共有で利用する。
final class RemoteFolderCacheStore {
    static let shared = RemoteFolderCacheStore()
    private var cache: [String: String] = [:]
    private let lock = NSLock()
    private init() {}

    /// アカウント ID とパスキーからフォルダ ID を返す。
    func folderID(accountID: String, pathKey: String) -> String? {
        lock.withLock { cache["\(accountID):\(pathKey)"] }
    }

    /// アカウント ID とパスキーに対してフォルダ ID を保存する。
    func setFolderID(accountID: String, pathKey: String, folderID: String) {
        lock.withLock { cache["\(accountID):\(pathKey)"] = folderID }
    }

    /// 特定アカウントのキャッシュをクリアする（アカウント切断時）。
    func clearCache(for accountID: String) {
        lock.withLock {
            cache = cache.filter { !$0.key.hasPrefix("\(accountID):") }
        }
    }
}
