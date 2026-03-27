import CryptoKit
import Foundation
import OSLog

/// CryptoKit を使った SHA-256 ハッシュ計算ユーティリティ
enum HashHelper {

    // MARK: - Data からのハッシュ計算

    /// `Data` の SHA-256 ハッシュを小文字16進文字列で返す
    /// - Parameter data: ハッシュ対象のバイト列
    /// - Returns: 64 文字の小文字16進文字列
    static func sha256(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - ファイル URL からのハッシュ計算

    /// ファイルの SHA-256 ハッシュを小文字16進文字列で返す。
    /// 大容量ファイルに対応するためストリーミング読み込みを使用する。
    /// - Parameter fileURL: 読み取るファイルの URL（file:// スキーム）
    /// - Returns: 64 文字の小文字16進文字列
    /// - Throws: ファイルを開けない場合は `ScreenVaultError.fileNotFound` または `ScreenVaultError.hashComputationFailed`
    static func sha256(of fileURL: URL) throws -> String {
        SVLogger.general.debug("SHA-256 計算開始: \(fileURL.lastPathComponent, privacy: .public)")

        guard fileURL.isFileURL else {
            SVLogger.general.error("SHA-256: URL がファイルスキームではない: \(fileURL.absoluteString, privacy: .public)")
            throw HashComputationError.notAFileURL(fileURL)
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: fileURL)
        } catch {
            SVLogger.general.error("SHA-256: ファイルを開けない: \(error.localizedDescription, privacy: .public)")
            throw HashComputationError.cannotOpenFile(fileURL, underlying: error)
        }

        defer { try? handle.close() }

        // チャンクサイズ 4 MB でストリーミング計算
        let chunkSize = 4 * 1024 * 1024
        var hasher = SHA256()

        while true {
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: chunkSize) ?? Data()
            } catch {
                SVLogger.general.error("SHA-256: 読み取りエラー: \(error.localizedDescription, privacy: .public)")
                throw HashComputationError.readError(fileURL, underlying: error)
            }

            guard !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }

        let digest = hasher.finalize()
        let hex = digest.map { String(format: "%02x", $0) }.joined()

        SVLogger.general.debug("SHA-256 完了: \(fileURL.lastPathComponent, privacy: .public) → \(hex, privacy: .public)")
        return hex
    }
}

// MARK: - ハッシュ計算専用エラー型

/// `HashHelper` が送出するエラー
enum HashComputationError: LocalizedError {
    case notAFileURL(URL)
    case cannotOpenFile(URL, underlying: Error)
    case readError(URL, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .notAFileURL(let url):
            return "SHA-256 計算エラー: URL がファイルスキームではありません: \(url.absoluteString)"
        case .cannotOpenFile(let url, let underlying):
            return "SHA-256 計算エラー: ファイルを開けません: \(url.lastPathComponent) — \(underlying.localizedDescription)"
        case .readError(let url, let underlying):
            return "SHA-256 計算エラー: 読み取りに失敗しました: \(url.lastPathComponent) — \(underlying.localizedDescription)"
        }
    }
}
