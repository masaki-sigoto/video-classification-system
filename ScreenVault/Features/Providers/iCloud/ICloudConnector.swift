import Foundation
import OSLog

// MARK: - iCloud 定数

private enum ICloudConstants {
    /// iCloud コンテナ識別子（nil で デフォルトコンテナを使用）
    /// Info.plist の `NSUbiquitousContainerIsDocumentScopePublic` が `YES` であること。
    static let containerIdentifier: String? = nil

    /// アップロード先のベースサブディレクトリ（iCloud Documents フォルダ配下）
    static let baseSubDirectory = "ScreenVault"
}

// MARK: - ICloudConnectorError

/// ICloudConnector 固有のエラー型。
enum ICloudConnectorError: LocalizedError {
    /// iCloud が利用できない（Apple ID 未ログイン / iCloud Drive 無効）
    case iCloudUnavailable
    /// iCloud コンテナ URL を取得できない
    case containerURLNotFound
    /// Documents フォルダが見つからない
    case documentsDirectoryNotFound
    /// フォルダの作成に失敗した
    case folderCreationFailed(path: String, underlying: Error)
    /// ファイルのコピーに失敗した
    case fileCopyFailed(fileName: String, underlying: Error)
    /// ハッシュ計算に失敗した
    case hashComputationFailed(fileName: String, underlying: Error)
    /// 指定したパスにファイルが存在しない
    case remoteFileNotFound(path: String)

    var errorDescription: String? {
        switch self {
        case .iCloudUnavailable:
            return "iCloud が利用できません。設定 > Apple ID > iCloud > iCloud Drive が有効になっているか確認してください。"
        case .containerURLNotFound:
            return "iCloud コンテナ URL を取得できませんでした。"
        case .documentsDirectoryNotFound:
            return "iCloud の Documents フォルダが見つかりません。"
        case .folderCreationFailed(let path, let error):
            return "フォルダの作成に失敗しました: \(path) — \(error.localizedDescription)"
        case .fileCopyFailed(let fileName, let error):
            return "ファイルのアップロードに失敗しました: \(fileName) — \(error.localizedDescription)"
        case .hashComputationFailed(let fileName, let error):
            return "ハッシュ計算に失敗しました: \(fileName) — \(error.localizedDescription)"
        case .remoteFileNotFound(let path):
            return "iCloud ファイルが見つかりません: \(path)"
        }
    }
}

// MARK: - ICloudConnector

/// iCloud Drive 向けの ProviderConnector 実装。
///
/// iCloud Drive には REST API がないため、以下の戦略を採用します:
/// - **認証**: OS レベルの Apple ID (`FileManager.ubiquityIdentityToken`) で確認
/// - **フォルダ作成**: `FileManager.createDirectory` でローカル iCloud フォルダを作成（自動同期）
/// - **アップロード**: NSFileCoordinator でローカル iCloud フォルダへコピー（iCloud デーモンが自動同期）
/// - **ハッシュ**: REST API がないため、ローカルファイルの SHA-256 で代替
/// - **共有**: iCloud Drive の共有は限定的なため、スタブ実装
///
/// すべてのファイル操作は `ICloudFileCoordinator` を介して協調します。
final class ICloudConnector: ProviderConnector {

    // MARK: - ProviderConnector

    var providerType: ProviderType { .iCloud }

    // MARK: - Properties

    /// 紐付くアカウント ID
    let accountID: String

    private let fileCoordinator: ICloudFileCoordinator
    private let conflictResolver: ICloudConflictResolver
    private let logger = SVLogger.provider

    // MARK: - Init

    init(
        accountID: String,
        fileCoordinator: ICloudFileCoordinator = ICloudFileCoordinator(),
        conflictResolver: ICloudConflictResolver? = nil
    ) {
        self.accountID = accountID
        self.fileCoordinator = fileCoordinator
        self.conflictResolver = conflictResolver ?? ICloudConflictResolver(fileCoordinator: fileCoordinator)
    }

    // MARK: - authenticate

    /// iCloud の利用可否を `FileManager.ubiquityIdentityToken` で確認する。
    ///
    /// iCloud はOS レベルの Apple ID に依存するため、OAuth フローは不要です。
    /// `ubiquityIdentityToken` が nil の場合は iCloud が無効または未ログインです。
    func authenticate() async throws {
        logger.info("iCloud: 認証確認開始 accountID=\(self.accountID, privacy: .public)")

        guard FileManager.default.ubiquityIdentityToken != nil else {
            logger.error("iCloud: ubiquityIdentityToken が nil。iCloud Drive が無効または Apple ID 未ログイン")
            throw ICloudConnectorError.iCloudUnavailable
        }

        // iCloud コンテナ URL が取得できることを確認
        _ = try await iCloudDocumentsURL()

        logger.info("iCloud: 認証確認完了 accountID=\(self.accountID, privacy: .public)")
    }

    // MARK: - ensureFolder

    /// iCloud Documents フォルダ配下にフォルダ階層を作成し、末端フォルダの ID（絶対 path 文字列）を返す。
    ///
    /// iCloud Drive ではフォルダ ID という概念がなく、パスそのものが識別子になります。
    /// ここではローカル iCloud コンテナへの絶対パスを返します。
    ///
    /// - Parameter pathComponents: 作成するフォルダのパスコンポーネント
    /// - Returns: 作成した末端フォルダの絶対パス文字列（remoteFolderID として使用）
    func ensureFolder(pathComponents: [String]) async throws -> String {
        let documentsURL = try await iCloudDocumentsURL()

        // ScreenVault ベースディレクトリ + 追加コンポーネントを順に作成
        let allComponents = [ICloudConstants.baseSubDirectory] + pathComponents
        var currentURL = documentsURL

        for component in allComponents {
            currentURL = currentURL.appendingPathComponent(component)
            try await createDirectoryIfNeeded(at: currentURL, component: component)
        }

        let finalPath = currentURL.path
        logger.info("iCloud: フォルダ確保完了 path=\(finalPath, privacy: .public)")
        return finalPath
    }

    // MARK: - uploadResumable

    /// ローカル iCloud フォルダへファイルをコピーし、iCloud デーモンによる自動同期に委ねる。
    ///
    /// iCloud Drive に REST API はないため、ローカルの iCloud コンテナにファイルをコピーすることが
    /// 実質的な「アップロード」になります。NSFileCoordinator でファイル協調を遵守します。
    ///
    /// - Parameters:
    ///   - fileURL: アップロードするローカルファイルの URL
    ///   - remoteFolderID: `ensureFolder` が返した末端フォルダの絶対パス文字列
    ///   - fileName: iCloud 上のファイル名
    /// - Returns: iCloud 上のファイルパス文字列（remoteFileID として使用）
    func uploadResumable(
        fileURL: URL,
        remoteFolderID: String,
        fileName: String
    ) async throws -> String {
        logger.info(
            "iCloud: アップロード開始 file=\(fileName, privacy: .public)"
            + " folder=\(remoteFolderID, privacy: .public)"
        )

        let folderURL = URL(fileURLWithPath: remoteFolderID)
        let destinationURL = folderURL.appendingPathComponent(fileName)

        // ファイルデータを読み取り
        let fileData: Data
        do {
            fileData = try Data(contentsOf: fileURL)
        } catch {
            logger.error(
                "iCloud: ソースファイル読み取り失敗 file=\(fileName, privacy: .public)"
                + " error=\(error.localizedDescription, privacy: .public)"
            )
            throw ICloudConnectorError.fileCopyFailed(fileName: fileName, underlying: error)
        }

        // NSFileCoordinator で協調書き込み
        do {
            try await fileCoordinator.coordinatedWrite(to: destinationURL, data: fileData)
        } catch {
            logger.error(
                "iCloud: 協調書き込み失敗 file=\(fileName, privacy: .public)"
                + " error=\(error.localizedDescription, privacy: .public)"
            )
            throw ICloudConnectorError.fileCopyFailed(fileName: fileName, underlying: error)
        }

        // 競合チェック（アップロード直後）
        if conflictResolver.hasConflicts(at: destinationURL) {
            logger.warning("iCloud: アップロード直後に競合検出。keepNewest で解決します file=\(fileName, privacy: .public)")
            try await conflictResolver.resolveConflicts(at: destinationURL, policy: .keepNewest)
        }

        let remoteFileID = destinationURL.path
        logger.info(
            "iCloud: アップロード完了（iCloud デーモンが同期予定）"
            + " remoteFileID=\(remoteFileID, privacy: .public)"
        )
        return remoteFileID
    }

    // MARK: - setSharing

    /// iCloud Drive の共有は NSItemProvider / CloudKit 共有など複雑な仕組みが必要なため、スタブ実装。
    ///
    /// iCloud Drive ではフォルダ共有（iCloud 共有フォルダ）が macOS 13 以降でサポートされますが、
    /// ScreenVault v1 の対象外です。将来の対応のためスタブとして保持します。
    func setSharing(remoteFileID: String, policy: SharingPolicy) async throws {
        logger.info(
            "iCloud: setSharing はスタブ実装のため何もしません"
            + " remoteFileID=\(remoteFileID, privacy: .public)"
        )
        // iCloud Drive の共有は OS レベルの操作が必要なため、将来実装
    }

    // MARK: - getRemoteHash

    /// ローカル iCloud ファイルの SHA-256 ハッシュを返す。
    ///
    /// iCloud Drive には REST API がなく、リモートのハッシュを直接取得できません。
    /// ローカルキャッシュ（iCloud コンテナ内のコピー）のハッシュで代替します。
    ///
    /// - Parameter remoteFileID: `uploadResumable` が返したファイルの絶対パス文字列
    /// - Returns: SHA-256 ハッシュの16進数文字列（ファイルが存在しない場合は nil）
    func getRemoteHash(remoteFileID: String) async throws -> String? {
        let fileURL = URL(fileURLWithPath: remoteFileID)

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            logger.debug(
                "iCloud: getRemoteHash - ファイルが存在しない path=\(remoteFileID, privacy: .public)"
            )
            return nil
        }

        // NSFileCoordinator で協調読み取り
        let data: Data
        do {
            data = try await fileCoordinator.coordinatedRead(from: fileURL)
        } catch {
            logger.error(
                "iCloud: getRemoteHash - 協調読み取り失敗"
                + " path=\(remoteFileID, privacy: .public)"
                + " error=\(error.localizedDescription, privacy: .public)"
            )
            throw ICloudConnectorError.hashComputationFailed(
                fileName: fileURL.lastPathComponent,
                underlying: error
            )
        }

        let hash = HashHelper.sha256(of: data)
        logger.debug(
            "iCloud: getRemoteHash 完了 file=\(fileURL.lastPathComponent, privacy: .public)"
            + " hash=\(hash, privacy: .private)"
        )
        return hash
    }
}

// MARK: - Private: iCloud コンテナ操作

private extension ICloudConnector {

    /// iCloud Documents フォルダの URL を返す。
    ///
    /// `FileManager.url(forUbiquityContainerIdentifier:)` はブロッキング API のため
    /// Task.detached で別スレッドに委譲します。
    ///
    /// - Returns: iCloud Documents フォルダ URL
    /// - Throws: コンテナが見つからない場合は `ICloudConnectorError.containerURLNotFound`
    func iCloudDocumentsURL() async throws -> URL {
        // url(forUbiquityContainerIdentifier:) はブロッキング API のため別スレッドへ
        let containerURL: URL? = await Task.detached(priority: .userInitiated) {
            FileManager.default.url(
                forUbiquityContainerIdentifier: ICloudConstants.containerIdentifier
            )
        }.value

        guard let containerURL else {
            logger.error("iCloud: コンテナ URL が nil。iCloud Drive が無効の可能性あり")
            throw ICloudConnectorError.containerURLNotFound
        }

        let documentsURL = containerURL.appendingPathComponent("Documents")

        // Documents フォルダが存在しない場合は作成
        if !FileManager.default.fileExists(atPath: documentsURL.path) {
            do {
                try FileManager.default.createDirectory(
                    at: documentsURL,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
            } catch {
                logger.error(
                    "iCloud: Documents フォルダ作成失敗 error=\(error.localizedDescription, privacy: .public)"
                )
                throw ICloudConnectorError.documentsDirectoryNotFound
            }
        }

        return documentsURL
    }

    /// ディレクトリが存在しない場合に NSFileCoordinator 経由で作成する。
    ///
    /// - Parameters:
    ///   - url: 作成するディレクトリの URL
    ///   - component: ログ出力用のコンポーネント名
    func createDirectoryIfNeeded(at url: URL, component: String) async throws {
        guard !FileManager.default.fileExists(atPath: url.path) else {
            logger.debug("iCloud: フォルダ既存 path=\(url.lastPathComponent, privacy: .public)")
            return
        }

        // 空ディレクトリを NSFileCoordinator で作成する
        // NSFileCoordinator.coordinate(writingItemAt:options:) でディレクトリを作成する際は
        // .forReplacing ではなく options: [] を使い、その後 FileManager で mkdir する
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let coordinator = NSFileCoordinator()
            var coordinatorError: NSError?

            coordinator.coordinate(
                writingItemAt: url,
                options: [],
                error: &coordinatorError
            ) { writingURL in
                do {
                    try FileManager.default.createDirectory(
                        at: writingURL,
                        withIntermediateDirectories: true,
                        attributes: nil
                    )
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }

            if let error = coordinatorError {
                continuation.resume(throwing: ICloudConnectorError.folderCreationFailed(
                    path: url.path,
                    underlying: error
                ))
            }
        }

        logger.info("iCloud: フォルダ作成完了 path=\(url.lastPathComponent, privacy: .public)")
    }
}
