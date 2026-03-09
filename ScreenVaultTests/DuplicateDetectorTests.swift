import Testing
import Foundation
import SwiftData
@testable import ScreenVault

// MARK: - DuplicateDetector テスト

@Suite("DuplicateDetector")
@MainActor
struct DuplicateDetectorTests {

    /// テスト用インメモリ ModelContext を生成する
    private func makeContext() throws -> ModelContext {
        let container = try DatabaseContainer.makeInMemoryContainer()
        return ModelContext(container)
    }

    /// 既知のハッシュとサイズを持つ Asset を作成して保存する
    private func insertAsset(
        in context: ModelContext,
        hash: String,
        sizeBytes: Int64 = 1024
    ) throws -> Asset {
        let asset = Asset(kind: .screenshot, sourceMode: .watch, sizeBytes: sizeBytes)
        asset.contentHashSHA256 = hash
        context.insert(asset)
        try context.save()
        return asset
    }

    // MARK: - 重複検出（ハッシュ + サイズ）

    @Test("同じハッシュ+サイズ → duplicate を返す")
    func sameHashAndSizeReturnsDuplicate() throws {
        let context = try makeContext()
        let hash = "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890"
        let sizeBytes: Int64 = 2048

        let existing = try insertAsset(in: context, hash: hash, sizeBytes: sizeBytes)
        let checkResult = try DuplicateDetector.check(hash: hash, sizeBytes: sizeBytes, in: context)

        switch checkResult {
        case .unique:
            Issue.record("duplicate を返すはずなのに unique が返った")
        case .duplicate(let found):
            #expect(found.assetID == existing.assetID)
        }
    }

    @Test("異なるハッシュ → unique を返す")
    func differentHashReturnsUnique() throws {
        let context = try makeContext()
        let existingHash = "1111111111111111111111111111111111111111111111111111111111111111"
        let newHash      = "2222222222222222222222222222222222222222222222222222222222222222"

        _ = try insertAsset(in: context, hash: existingHash, sizeBytes: 1024)
        let result = try DuplicateDetector.check(hash: newHash, sizeBytes: 1024, in: context)

        switch result {
        case .unique:
            break // 期待通り
        case .duplicate:
            Issue.record("unique を返すはずなのに duplicate が返った")
        }
    }

    @Test("同じハッシュでもサイズが異なれば unique を返す")
    func sameHashDifferentSizeReturnsUnique() throws {
        let context = try makeContext()
        let hash = "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890"

        _ = try insertAsset(in: context, hash: hash, sizeBytes: 1024)
        let result = try DuplicateDetector.check(hash: hash, sizeBytes: 9999, in: context)

        switch result {
        case .unique:
            break // 期待通り（サイズが異なるため重複とみなさない）
        case .duplicate:
            Issue.record("サイズが異なるので unique を返すはずなのに duplicate が返った")
        }
    }

    @Test("DB が空のとき → unique を返す")
    func emptyDBReturnsUnique() throws {
        let context = try makeContext()
        let result = try DuplicateDetector.check(
            hash: "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
            sizeBytes: 512,
            in: context
        )

        switch result {
        case .unique:
            break // 期待通り
        case .duplicate:
            Issue.record("DB が空なので unique を返すはず")
        }
    }

    @Test("空のハッシュ文字列 → unique を返す（エラーなし）")
    func emptyHashReturnsUnique() throws {
        let context = try makeContext()
        let result = try DuplicateDetector.check(hash: "", sizeBytes: 1024, in: context)

        switch result {
        case .unique:
            break // 空ハッシュは検索しない
        case .duplicate:
            Issue.record("空ハッシュは unique を返すはず")
        }
    }

    // MARK: - ハッシュのみで重複検出

    @Test("checkByHash: 同じハッシュ → duplicate を返す")
    func checkByHashDuplicate() throws {
        let context = try makeContext()
        let hash = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"

        let existing = try insertAsset(in: context, hash: hash)
        let result = try DuplicateDetector.checkByHash(hash: hash, in: context)

        switch result {
        case .unique:
            Issue.record("duplicate を返すはず")
        case .duplicate(let found):
            #expect(found.assetID == existing.assetID)
        }
    }

    @Test("checkByHash: 異なるハッシュ → unique を返す")
    func checkByHashUnique() throws {
        let context = try makeContext()

        _ = try insertAsset(in: context, hash: "aaaa1111111111111111111111111111111111111111111111111111111111aa")
        let result = try DuplicateDetector.checkByHash(
            hash: "bbbb2222222222222222222222222222222222222222222222222222222222bb",
            in: context
        )

        switch result {
        case .unique:
            break
        case .duplicate:
            Issue.record("unique を返すはず")
        }
    }

    @Test("checkByHash: 空のハッシュ → unique を返す")
    func checkByHashEmptyReturnsUnique() throws {
        let context = try makeContext()
        let result = try DuplicateDetector.checkByHash(hash: "", in: context)

        switch result {
        case .unique:
            break
        case .duplicate:
            Issue.record("空ハッシュは unique を返すはず")
        }
    }

    // MARK: - 複数アセットが存在するケース

    @Test("複数アセットが存在するとき、ハッシュが一致するものを返す")
    func multipleAssetsReturnCorrectDuplicate() throws {
        let context = try makeContext()

        let hash1 = "1111111111111111111111111111111111111111111111111111111111111111"
        let hash2 = "2222222222222222222222222222222222222222222222222222222222222222"
        let targetHash = "3333333333333333333333333333333333333333333333333333333333333333"

        _ = try insertAsset(in: context, hash: hash1)
        _ = try insertAsset(in: context, hash: hash2)
        let target = try insertAsset(in: context, hash: targetHash, sizeBytes: 4096)

        let result = try DuplicateDetector.check(hash: targetHash, sizeBytes: 4096, in: context)

        switch result {
        case .unique:
            Issue.record("duplicate を返すはず")
        case .duplicate(let found):
            #expect(found.assetID == target.assetID)
        }
    }
}
