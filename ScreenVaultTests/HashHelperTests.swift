import Testing
import Foundation
@testable import ScreenVault

// MARK: - HashHelper テスト

@Suite("HashHelper — SHA-256 ハッシュ計算")
struct HashHelperTests {

    // MARK: - Data からのハッシュ計算

    @Test("既知のデータに対するハッシュ値の検証")
    func knownDataHash() {
        // echo -n "hello" | shasum -a 256
        // 2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824
        let data = Data("hello".utf8)
        let hash = HashHelper.sha256(of: data)
        #expect(hash == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
    }

    @Test("別の既知データのハッシュ検証（ScreenVault）")
    func knownDataHashScreenVault() {
        // echo -n "ScreenVault" | shasum -a 256
        let data = Data("ScreenVault".utf8)
        let hash = HashHelper.sha256(of: data)
        // 64 文字の小文字16進文字列であることを確認
        #expect(hash.count == 64)
        #expect(hash == hash.lowercased())
        // 16進文字のみで構成されていること
        let hexChars = CharacterSet(charactersIn: "0123456789abcdef")
        #expect(hash.unicodeScalars.allSatisfy { hexChars.contains($0) })
    }

    @Test("空データのハッシュは既知値と一致する")
    func emptyDataHash() {
        // echo -n "" | shasum -a 256
        // e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
        let data = Data()
        let hash = HashHelper.sha256(of: data)
        #expect(hash == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test("同一データ → 同一ハッシュ（冪等性）")
    func sameDataProducesSameHash() {
        let data = Data("reproducible test data 12345".utf8)
        let hash1 = HashHelper.sha256(of: data)
        let hash2 = HashHelper.sha256(of: data)
        #expect(hash1 == hash2)
    }

    @Test("異なるデータ → 異なるハッシュ")
    func differentDataProducesDifferentHash() {
        let data1 = Data("data-alpha".utf8)
        let data2 = Data("data-beta".utf8)
        let hash1 = HashHelper.sha256(of: data1)
        let hash2 = HashHelper.sha256(of: data2)
        #expect(hash1 != hash2)
    }

    @Test("ハッシュは常に 64 文字")
    func hashIsAlways64Characters() {
        let samples = ["", "a", "hello world", String(repeating: "x", count: 1000)]
        for sample in samples {
            let hash = HashHelper.sha256(of: Data(sample.utf8))
            #expect(hash.count == 64, "'\(sample)' のハッシュは 64 文字でなければならない")
        }
    }

    @Test("ハッシュは小文字16進文字のみで構成される")
    func hashContainsOnlyLowercaseHex() {
        let data = Data("test data for hex check".utf8)
        let hash = HashHelper.sha256(of: data)
        let hexChars = CharacterSet(charactersIn: "0123456789abcdef")
        let allHex = hash.unicodeScalars.allSatisfy { hexChars.contains($0) }
        #expect(allHex)
    }

    @Test("1 バイト差のデータでも異なるハッシュ")
    func singleByteDifferenceProducesDifferentHash() {
        var bytes1 = [UInt8](repeating: 0, count: 32)
        var bytes2 = [UInt8](repeating: 0, count: 32)
        bytes2[16] = 1 // 1 バイトだけ変更

        let hash1 = HashHelper.sha256(of: Data(bytes1))
        let hash2 = HashHelper.sha256(of: Data(bytes2))
        #expect(hash1 != hash2)
    }

    // MARK: - ファイル URL からのハッシュ計算

    @Test("ファイルからのハッシュ計算: 既知コンテンツと一致する")
    func fileHashMatchesDataHash() throws {
        // 一時ファイルを作成してハッシュを比較
        let content = Data("file content for hash test".utf8)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HashHelperTest_\(UUID().uuidString).txt")

        try content.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let fileHash = try HashHelper.sha256(of: tempURL)
        let dataHash = HashHelper.sha256(of: content)

        #expect(fileHash == dataHash)
    }

    @Test("空ファイルのハッシュは既知値と一致する")
    func emptyFileHash() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HashHelperEmptyTest_\(UUID().uuidString).txt")

        try Data().write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let hash = try HashHelper.sha256(of: tempURL)
        #expect(hash == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test("非ファイル URL は HashComputationError を投げる")
    func nonFileURLThrows() {
        let httpURL = URL(string: "https://example.com/file.txt")!
        #expect(throws: HashComputationError.self) {
            _ = try HashHelper.sha256(of: httpURL)
        }
    }

    @Test("存在しないファイルは HashComputationError を投げる")
    func nonExistentFileThrows() {
        let nonExistentURL = URL(fileURLWithPath: "/tmp/nonexistent_file_screenvault_\(UUID().uuidString).txt")
        #expect(throws: HashComputationError.self) {
            _ = try HashHelper.sha256(of: nonExistentURL)
        }
    }

    @Test("大きなファイルもハッシュできる（チャンク処理の確認）")
    func largeFileHash() throws {
        // 8 MB のデータ（チャンクサイズ 4 MB を超えてストリーミングが動作することを確認）
        let chunkSize = 4 * 1024 * 1024
        let data = Data(repeating: 0xAB, count: chunkSize * 2)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HashHelperLargeTest_\(UUID().uuidString).bin")

        try data.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let fileHash = try HashHelper.sha256(of: tempURL)
        let dataHash = HashHelper.sha256(of: data)
        #expect(fileHash == dataHash)
    }
}
