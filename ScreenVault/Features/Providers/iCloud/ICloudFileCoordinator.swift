import Foundation
import OSLog

// MARK: - ICloudFileCoordinator

/// iCloud Drive のファイル操作を NSFileCoordinator でラップする非同期ヘルパー。
///
/// iCloud Drive へのファイル操作（読み取り・書き込み・移動）は
/// NSFileCoordinator を介して行うことが Apple の推奨事項です（TN2347 / File System Programming Guide）。
/// 本クラスはコールバックベースの NSFileCoordinator API を Swift async/await に橋渡しします。
final class ICloudFileCoordinator: NSObject {

    // MARK: - Properties

    private let logger = SVLogger.provider

    // MARK: - Write

    /// iCloud フォルダへデータを協調書き込みする。
    ///
    /// NSFileCoordinator のスレッドブロッキング API を Task.detached で別スレッドに委譲し、
    /// completion を Checked Continuation で async/await に変換します。
    ///
    /// - Parameters:
    ///   - url: 書き込み先の URL（iCloud コンテナ内）
    ///   - data: 書き込むデータ
    /// - Throws: 書き込み協調または I/O に失敗した場合
    func coordinatedWrite(to url: URL, data: Data) async throws {
        logger.debug("iCloudFileCoordinator: 協調書き込み開始 url=\(url.lastPathComponent, privacy: .public)")

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let coordinator = NSFileCoordinator()
            var coordinatorError: NSError?

            coordinator.coordinate(
                writingItemAt: url,
                options: .forReplacing,
                error: &coordinatorError
            ) { writingURL in
                do {
                    // 親ディレクトリが存在しない場合は作成
                    let parentDir = writingURL.deletingLastPathComponent()
                    try FileManager.default.createDirectory(
                        at: parentDir,
                        withIntermediateDirectories: true,
                        attributes: nil
                    )
                    try data.write(to: writingURL, options: .atomic)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }

            if let error = coordinatorError {
                continuation.resume(throwing: error)
            }
        }

        logger.info("iCloudFileCoordinator: 協調書き込み完了 url=\(url.lastPathComponent, privacy: .public)")
    }

    // MARK: - Read

    /// iCloud ファイルを協調読み取りする。
    ///
    /// - Parameter url: 読み取り元の URL（iCloud コンテナ内）
    /// - Returns: ファイルの内容
    /// - Throws: 読み取り協調または I/O に失敗した場合
    func coordinatedRead(from url: URL) async throws -> Data {
        logger.debug("iCloudFileCoordinator: 協調読み取り開始 url=\(url.lastPathComponent, privacy: .public)")

        let result: Data = try await withCheckedThrowingContinuation { continuation in
            let coordinator = NSFileCoordinator()
            var coordinatorError: NSError?

            coordinator.coordinate(
                readingItemAt: url,
                options: .withoutChanges,
                error: &coordinatorError
            ) { readingURL in
                do {
                    let data = try Data(contentsOf: readingURL)
                    continuation.resume(returning: data)
                } catch {
                    continuation.resume(throwing: error)
                }
            }

            if let error = coordinatorError {
                continuation.resume(throwing: error)
            }
        }

        logger.debug("iCloudFileCoordinator: 協調読み取り完了 url=\(url.lastPathComponent, privacy: .public)")
        return result
    }

    // MARK: - Move

    /// iCloud ファイルを協調移動する。
    ///
    /// 移動操作では書き込み先・読み取り元の両方を協調する必要があります。
    ///
    /// - Parameters:
    ///   - source: 移動元の URL
    ///   - destination: 移動先の URL
    /// - Throws: 協調取得または移動 I/O に失敗した場合
    func coordinatedMove(from source: URL, to destination: URL) async throws {
        logger.debug(
            "iCloudFileCoordinator: 協調移動開始 src=\(source.lastPathComponent, privacy: .public)"
            + " dst=\(destination.lastPathComponent, privacy: .public)"
        )

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let coordinator = NSFileCoordinator()
            var coordinatorError: NSError?

            // 読み取り元: .forMoving、書き込み先: .forMoving
            coordinator.coordinate(
                writingItemAt: source,
                options: .forMoving,
                writingItemAt: destination,
                options: .forReplacing,
                error: &coordinatorError
            ) { srcURL, dstURL in
                do {
                    let parentDir = dstURL.deletingLastPathComponent()
                    try FileManager.default.createDirectory(
                        at: parentDir,
                        withIntermediateDirectories: true,
                        attributes: nil
                    )
                    // 既存ファイルがある場合は上書き
                    if FileManager.default.fileExists(atPath: dstURL.path) {
                        try FileManager.default.removeItem(at: dstURL)
                    }
                    try FileManager.default.moveItem(at: srcURL, to: dstURL)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }

            if let error = coordinatorError {
                continuation.resume(throwing: error)
            }
        }

        logger.info(
            "iCloudFileCoordinator: 協調移動完了 src=\(source.lastPathComponent, privacy: .public)"
            + " dst=\(destination.lastPathComponent, privacy: .public)"
        )
    }

    // MARK: - Copy

    /// iCloud ファイルを協調コピーする（競合解決で "keepBoth" ポリシー使用時）。
    ///
    /// - Parameters:
    ///   - source: コピー元の URL
    ///   - destination: コピー先の URL
    /// - Throws: 協調取得またはコピー I/O に失敗した場合
    func coordinatedCopy(from source: URL, to destination: URL) async throws {
        logger.debug(
            "iCloudFileCoordinator: 協調コピー開始 src=\(source.lastPathComponent, privacy: .public)"
            + " dst=\(destination.lastPathComponent, privacy: .public)"
        )

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let coordinator = NSFileCoordinator()
            var coordinatorError: NSError?

            // コピーは読み取り元を読み取り協調、書き込み先を書き込み協調
            coordinator.coordinate(
                readingItemAt: source,
                options: .withoutChanges,
                writingItemAt: destination,
                options: .forReplacing,
                error: &coordinatorError
            ) { srcURL, dstURL in
                do {
                    let parentDir = dstURL.deletingLastPathComponent()
                    try FileManager.default.createDirectory(
                        at: parentDir,
                        withIntermediateDirectories: true,
                        attributes: nil
                    )
                    if FileManager.default.fileExists(atPath: dstURL.path) {
                        try FileManager.default.removeItem(at: dstURL)
                    }
                    try FileManager.default.copyItem(at: srcURL, to: dstURL)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }

            if let error = coordinatorError {
                continuation.resume(throwing: error)
            }
        }

        logger.info("iCloudFileCoordinator: 協調コピー完了 dst=\(destination.lastPathComponent, privacy: .public)")
    }
}
