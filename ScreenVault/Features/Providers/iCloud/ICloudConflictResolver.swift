import Foundation
import OSLog

// MARK: - ConflictResolutionPolicy

/// iCloud Drive の競合解決ポリシー。
///
/// TN2336「Handling iCloud Drive Document Conflicts」に準拠した三種類のポリシーを定義します。
enum ConflictResolutionPolicy {
    /// 現在のバージョン（Current Version）を保持し、競合バージョンを削除する。
    case keepCurrent
    /// 変更日時が最新のバージョンを保持し、他を削除する。
    case keepNewest
    /// すべてのバージョンを保持する。競合バージョンに連番サフィックスを付けて別ファイルとして保存する。
    case keepBoth
}

// MARK: - ICloudConflictError

/// 競合解決で発生するエラー。
enum ICloudConflictError: LocalizedError {
    case coordinatorError(NSError)
    case moveError(URL, URL, Error)
    case removeVersionError(URL, Error)

    var errorDescription: String? {
        switch self {
        case .coordinatorError(let error):
            return "iCloud 競合解決: NSFileCoordinator エラー: \(error.localizedDescription)"
        case .moveError(let src, let dst, let error):
            return "iCloud 競合解決: 移動失敗 \(src.lastPathComponent) → \(dst.lastPathComponent): \(error.localizedDescription)"
        case .removeVersionError(let url, let error):
            return "iCloud 競合解決: バージョン削除失敗 \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }
}

// MARK: - ICloudConflictResolver

/// iCloud Drive の競合バージョンを検出・解決するクラス。
///
/// Apple Technical Note TN2336 に準拠した実装です。
/// - `NSFileVersion.unresolvedConflictVersionsOfItem(at:)` で未解決の競合を検出
/// - ポリシーに従い勝者バージョンを決定
/// - `NSFileVersion.removeOtherVersionsOfItem(at:)` で不要バージョンを削除
/// - 競合が解決済みであることを `version.isResolved = true` でマーク
final class ICloudConflictResolver {

    // MARK: - Properties

    private let fileCoordinator: ICloudFileCoordinator
    private let logger = SVLogger.provider

    // MARK: - Init

    init(fileCoordinator: ICloudFileCoordinator = ICloudFileCoordinator()) {
        self.fileCoordinator = fileCoordinator
    }

    // MARK: - Conflict Detection

    /// 指定 URL のファイルに未解決の競合が存在するかを返す。
    ///
    /// - Parameter url: 検査対象のファイル URL
    /// - Returns: 競合バージョンが存在する場合は `true`
    func hasConflicts(at url: URL) -> Bool {
        guard let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: url) else {
            return false
        }
        return !versions.isEmpty
    }

    // MARK: - Conflict Resolution

    /// 指定 URL の競合バージョンを指定ポリシーで解決する。
    ///
    /// 解決処理の流れ:
    /// 1. 未解決の競合バージョンを取得
    /// 2. ポリシーに従って勝者バージョンを選択
    /// 3. 必要に応じてファイルを保存
    /// 4. 全競合バージョンを `isResolved = true` に設定
    /// 5. 不要バージョンを `NSFileVersion.removeOtherVersionsOfItem(at:)` で削除
    ///
    /// - Parameters:
    ///   - url: 競合が発生しているファイルの URL
    ///   - policy: 解決ポリシー
    /// - Throws: 競合解決に失敗した場合
    func resolveConflicts(at url: URL, policy: ConflictResolutionPolicy) async throws {
        guard let conflictVersions = NSFileVersion.unresolvedConflictVersionsOfItem(at: url),
              !conflictVersions.isEmpty else {
            logger.debug("iCloudConflictResolver: 競合なし url=\(url.lastPathComponent, privacy: .public)")
            return
        }

        logger.info(
            "iCloudConflictResolver: 競合検出 url=\(url.lastPathComponent, privacy: .public)"
            + " conflictCount=\(conflictVersions.count)"
        )

        switch policy {
        case .keepCurrent:
            try await resolveKeepCurrent(url: url, conflictVersions: conflictVersions)

        case .keepNewest:
            try await resolveKeepNewest(url: url, conflictVersions: conflictVersions)

        case .keepBoth:
            try await resolveKeepBoth(url: url, conflictVersions: conflictVersions)
        }

        logger.info("iCloudConflictResolver: 競合解決完了 url=\(url.lastPathComponent, privacy: .public) policy=\(String(describing: policy), privacy: .public)")
    }

    // MARK: - Private: keepCurrent

    /// 現在のバージョンを保持し、競合バージョンを破棄する。
    private func resolveKeepCurrent(
        url: URL,
        conflictVersions: [NSFileVersion]
    ) async throws {
        // 全競合バージョンを解決済みとしてマーク
        markResolved(conflictVersions)

        // 不要バージョンを削除
        try removeOtherVersions(at: url)

        logger.debug("iCloudConflictResolver: keepCurrent 完了 url=\(url.lastPathComponent, privacy: .public)")
    }

    // MARK: - Private: keepNewest

    /// 変更日時が最新のバージョンを現在ファイルとして採用し、他を削除する。
    private func resolveKeepNewest(
        url: URL,
        conflictVersions: [NSFileVersion]
    ) async throws {
        // 現在バージョンの変更日時
        let currentModDate = modificationDate(of: url) ?? .distantPast

        // 競合バージョンから最新のものを選択
        let newestConflict = conflictVersions
            .max { ($0.modificationDate ?? .distantPast) < ($1.modificationDate ?? .distantPast) }

        let conflictNewestDate = newestConflict?.modificationDate ?? .distantPast

        if conflictNewestDate > currentModDate, let winner = newestConflict {
            // 競合バージョンが最新 → 現在ファイルに上書き
            logger.info(
                "iCloudConflictResolver: keepNewest - 競合バージョンが新しい、置換します"
                + " url=\(url.lastPathComponent, privacy: .public)"
            )
            try await replaceCurrentFile(url: url, with: winner)
        }
        // 現在バージョンが最新の場合は何もしない（keepCurrent と同じ）

        // 全競合バージョンを解決済みとしてマーク
        markResolved(conflictVersions)

        // 不要バージョンを削除
        try removeOtherVersions(at: url)
    }

    // MARK: - Private: keepBoth

    /// 競合バージョンすべてを別名ファイルとして保存し、競合を解決済みにマークする。
    private func resolveKeepBoth(
        url: URL,
        conflictVersions: [NSFileVersion]
    ) async throws {
        let baseName = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let parentDir = url.deletingLastPathComponent()

        for (index, conflictVersion) in conflictVersions.enumerated() {
            // 競合バージョンを読み込む
            guard let versionURL = conflictVersion.url else {
                logger.warning("iCloudConflictResolver: 競合バージョンの URL が nil index=\(index)")
                continue
            }

            // 保存先の命名: "{baseName}_conflict_{n}.{ext}"
            let conflictFileName: String
            if ext.isEmpty {
                conflictFileName = "\(baseName)_conflict_\(index + 1)"
            } else {
                conflictFileName = "\(baseName)_conflict_\(index + 1).\(ext)"
            }
            let destinationURL = parentDir.appendingPathComponent(conflictFileName)

            do {
                try await fileCoordinator.coordinatedCopy(from: versionURL, to: destinationURL)
                logger.info(
                    "iCloudConflictResolver: keepBoth - 競合バージョン保存完了"
                    + " dst=\(conflictFileName, privacy: .public)"
                )
            } catch {
                logger.error(
                    "iCloudConflictResolver: keepBoth - コピー失敗 dst=\(conflictFileName, privacy: .public)"
                    + " error=\(error.localizedDescription, privacy: .public)"
                )
                throw ICloudConflictError.moveError(versionURL, destinationURL, error)
            }
        }

        // 全競合バージョンを解決済みとしてマーク
        markResolved(conflictVersions)

        // 不要バージョンを削除
        try removeOtherVersions(at: url)
    }

    // MARK: - Private: Helpers

    /// 競合バージョンの内容を現在のファイルに上書きコピーする。
    private func replaceCurrentFile(url: URL, with version: NSFileVersion) async throws {
        guard let versionURL = version.url else { return }
        try await fileCoordinator.coordinatedCopy(from: versionURL, to: url)
    }

    /// 競合バージョン配列をすべて解決済みにマークする。
    private func markResolved(_ versions: [NSFileVersion]) {
        for version in versions {
            version.isResolved = true
        }
    }

    /// `NSFileVersion.removeOtherVersionsOfItem(at:)` で不要バージョンを削除する。
    ///
    /// このメソッドは NSFileCoordinator のコンテキスト外から呼んではなりません。
    /// NSFileVersion のドキュメントでは「ファイル協調ブロック内で呼ぶこと」と
    /// 記されていますが、resolve 処理が完了してから削除するため、
    /// ここでは markResolved 後に呼び出します。
    private func removeOtherVersions(at url: URL) throws {
        do {
            try NSFileVersion.removeOtherVersionsOfItem(at: url)
        } catch {
            logger.error(
                "iCloudConflictResolver: 旧バージョン削除失敗"
                + " url=\(url.lastPathComponent, privacy: .public)"
                + " error=\(error.localizedDescription, privacy: .public)"
            )
            throw ICloudConflictError.removeVersionError(url, error)
        }
    }

    /// ファイルの変更日時を取得する（nil は distantPast と同義）。
    private func modificationDate(of url: URL) -> Date? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attrs?[.modificationDate] as? Date
    }
}
