import Foundation
import OSLog

// MARK: - ICloudFilePresenterDelegate

/// iCloud ファイルの変更通知を受け取るデリゲート。
protocol ICloudFilePresenterDelegate: AnyObject {
    /// 監視対象ファイル/フォルダの内容が変化した。
    func presenterDidDetectChange(at url: URL)
    /// 監視対象ファイル/フォルダが新しい URL に移動した。
    func presenterDidDetectMove(to newURL: URL)
}

// MARK: - ICloudFilePresenter

/// NSFilePresenter プロトコルに準拠した iCloud フォルダ変更監視クラス。
///
/// NSFileCoordinator ベースのファイル協調では、同じファイルを扱う全プロセスが
/// NSFilePresenter を登録することで変更通知を受け取れます。
/// 本クラスは iCloud コンテナ内の特定フォルダを監視し、
/// 変更・移動を ICloudFilePresenterDelegate に通知します。
///
/// 使い方:
/// ```swift
/// let presenter = ICloudFilePresenter(url: iCloudFolderURL)
/// presenter.delegate = self
/// presenter.startPresenting()
/// // ... 使い終わったら
/// presenter.stopPresenting()
/// ```
final class ICloudFilePresenter: NSObject, NSFilePresenter {

    // MARK: - NSFilePresenter

    /// 監視対象の iCloud フォルダ URL。
    /// `presentedItemURL` の変更は NSFileCoordinator 経由で行う必要があります。
    private(set) var presentedItemURL: URL?

    /// NSFilePresenter のコールバックを受け取る専用キュー。
    /// Apple のドキュメントでは専用シリアルキューを使うことが推奨されています。
    let presentedItemOperationQueue: OperationQueue

    // MARK: - Properties

    weak var delegate: ICloudFilePresenterDelegate?
    private let logger = SVLogger.provider

    /// 現在 NSFileCoordinator に登録中かどうか。
    private var isPresenting: Bool = false

    // MARK: - Init

    /// - Parameters:
    ///   - url: 監視対象の iCloud フォルダ URL
    init(url: URL) {
        self.presentedItemURL = url

        let queue = OperationQueue()
        queue.name = "com.screenvault.icloud.presenter"
        queue.maxConcurrentOperationCount = 1  // シリアルキュー
        queue.qualityOfService = .utility
        self.presentedItemOperationQueue = queue

        super.init()
    }

    // MARK: - Lifecycle

    /// NSFileCoordinator への自身の登録を開始する。
    func startPresenting() {
        guard !isPresenting else { return }
        NSFileCoordinator.addFilePresenter(self)
        isPresenting = true
        logger.info(
            "iCloudFilePresenter: 監視開始 url=\(self.presentedItemURL?.lastPathComponent ?? "nil", privacy: .public)"
        )
    }

    /// NSFileCoordinator から自身の登録を解除する。
    func stopPresenting() {
        guard isPresenting else { return }
        NSFileCoordinator.removeFilePresenter(self)
        isPresenting = false
        logger.info(
            "iCloudFilePresenter: 監視停止 url=\(self.presentedItemURL?.lastPathComponent ?? "nil", privacy: .public)"
        )
    }

    // MARK: - NSFilePresenter: 変更通知

    /// 監視対象のファイル/フォルダが変更されたときに iCloud デーモンから呼ばれる。
    func presentedItemDidChange() {
        guard let url = presentedItemURL else { return }
        logger.debug(
            "iCloudFilePresenter: 変更検出 url=\(url.lastPathComponent, privacy: .public)"
        )
        delegate?.presenterDidDetectChange(at: url)
    }

    // MARK: - NSFilePresenter: 移動通知

    /// 監視対象のファイル/フォルダが別の URL に移動したときに呼ばれる。
    ///
    /// - Parameter newURL: 移動後の新しい URL
    func presentedItemDidMove(to newURL: URL) {
        logger.info(
            "iCloudFilePresenter: 移動検出"
            + " old=\(self.presentedItemURL?.lastPathComponent ?? "nil", privacy: .public)"
            + " new=\(newURL.lastPathComponent, privacy: .public)"
        )
        presentedItemURL = newURL
        delegate?.presenterDidDetectMove(to: newURL)
    }

    // MARK: - NSFilePresenter: 保存要求

    /// システムが変更内容の保存を要求したときに呼ばれる。
    ///
    /// iCloud は揮発性バッファを持つアプリ（ドキュメントエディタ等）向けに
    /// このメソッドを使って保存を促します。
    /// ScreenVault は読み取り専用モニタのため何もする必要がありませんが、
    /// completionHandler は必ず呼ぶ必要があります。
    ///
    /// - Parameter completionHandler: 保存完了後に呼ぶクロージャ
    func savePresentedItemChanges(completionHandler: @escaping (Error?) -> Void) {
        // 本アプリは監視用途のため、保存処理は不要
        logger.debug("iCloudFilePresenter: savePresentedItemChanges 呼び出し（保存不要、完了通知）")
        completionHandler(nil)
    }

    // MARK: - NSFilePresenter: サブアイテム変更通知

    /// フォルダ内のサブアイテムが変更されたときに呼ばれる。
    ///
    /// `presentedItemURL` がフォルダを指している場合、
    /// フォルダ内のファイル変更はこのメソッドで通知されます。
    ///
    /// - Parameter url: 変更されたサブアイテムの URL
    func presentedSubitemDidChange(at url: URL) {
        logger.debug(
            "iCloudFilePresenter: サブアイテム変更 url=\(url.lastPathComponent, privacy: .public)"
        )
        // フォルダ監視の場合、フォルダ自体の変更として上位に通知する
        if let folderURL = presentedItemURL {
            delegate?.presenterDidDetectChange(at: folderURL)
        }
    }

    /// フォルダ内のサブアイテムが追加されたときに呼ばれる。
    ///
    /// - Parameter url: 追加されたサブアイテムの URL
    func presentedSubitemDidAppear(at url: URL) {
        logger.debug(
            "iCloudFilePresenter: サブアイテム追加 url=\(url.lastPathComponent, privacy: .public)"
        )
        if let folderURL = presentedItemURL {
            delegate?.presenterDidDetectChange(at: folderURL)
        }
    }

    // MARK: - Deinit

    deinit {
        stopPresenting()
    }
}
