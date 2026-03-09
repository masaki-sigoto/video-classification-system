import Foundation
import SwiftData
import OSLog

// MARK: - DuplicateResult

/// 重複検出の結果
enum DuplicateResult: Equatable {
    /// 重複なし（ユニークなファイル）
    case unique
    /// 重複あり
    case duplicate(existingAssetID: String)
}

// MARK: - DuplicatePolicy

/// 重複検出時の振る舞いポリシー
enum DuplicatePolicy: String, Codable, CaseIterable {
    /// 重複ファイルはアップロードをスキップする
    case skip
    /// 重複でもコピー（別ファイルとしてアップロード）する
    case copy
    /// 常にアップロードする（重複チェックを行わない）
    case alwaysUpload
}

// MARK: - DuplicateDetector

/// ローカル SwiftData 内の既存 Asset と照合して重複を検出する。
///
/// 判定キー: `(sizeBytes, contentHashSHA256)` の組み合わせ。
/// SHA-256 が等しいだけでなく、ファイルサイズも一致する場合に重複と判定する。
final class DuplicateDetector {

    // MARK: - Public API

    /// 指定した Asset が context 内に既に存在するかを判定する。
    ///
    /// - Parameters:
    ///   - asset: 判定対象の Asset
    ///   - context: 照合先の SwiftData ModelContext
    /// - Returns: DuplicateResult
    func isDuplicate(asset: Asset, in context: ModelContext) -> DuplicateResult {
        // contentHashSHA256 が未計算の場合は重複判定不可能 → unique 扱い
        guard let hash = asset.contentHashSHA256, !hash.isEmpty else {
            SVLogger.upload.debug("DuplicateDetector: no hash for asset=\(asset.assetID, privacy: .public), treating as unique")
            return .unique
        }

        let size = asset.sizeBytes
        let assetID = asset.assetID

        // (sizeBytes, contentHashSHA256) で既存 Asset を検索
        // 自分自身 (assetID が同じ) は除外する
        let descriptor = FetchDescriptor<Asset>(
            predicate: #Predicate { existing in
                existing.contentHashSHA256 == hash &&
                existing.sizeBytes == size &&
                existing.assetID != assetID
            }
        )

        do {
            let results = try context.fetch(descriptor)
            if let existing = results.first {
                SVLogger.upload.info("DuplicateDetector: duplicate found asset=\(assetID, privacy: .public) existing=\(existing.assetID, privacy: .public) hash=\(hash.prefix(16), privacy: .public)")
                return .duplicate(existingAssetID: existing.assetID)
            }
        } catch {
            SVLogger.upload.error("DuplicateDetector: fetch error for asset=\(assetID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            // フェッチエラー時は安全のため unique 扱い
        }

        SVLogger.upload.debug("DuplicateDetector: unique asset=\(assetID, privacy: .public)")
        return .unique
    }

    /// ポリシーに基づいてアップロードを続行すべきかを判定する。
    ///
    /// - Parameters:
    ///   - result: isDuplicate の結果
    ///   - policy: 重複時のポリシー
    /// - Returns: アップロードを続行すべき場合 true
    func shouldUpload(result: DuplicateResult, policy: DuplicatePolicy) -> Bool {
        switch policy {
        case .alwaysUpload:
            return true

        case .skip:
            switch result {
            case .unique:
                return true
            case .duplicate:
                SVLogger.upload.info("DuplicateDetector: skipping upload due to policy=skip")
                return false
            }

        case .copy:
            // copy ポリシーでは重複でもアップロードする
            return true
        }
    }
}
