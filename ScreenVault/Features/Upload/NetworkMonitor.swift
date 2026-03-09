import Foundation
import Network
import OSLog

// MARK: - NetworkMonitor

/// NWPathMonitor を使ってネットワーク状態を監視する ObservableObject。
///
/// 使用例:
/// ```swift
/// let monitor = NetworkMonitor()
/// monitor.$isConnected
///     .sink { connected in ... }
/// ```
@MainActor
final class NetworkMonitor: ObservableObject {

    // MARK: - Published

    /// ネットワークが利用可能かどうか
    @Published private(set) var isConnected: Bool = false

    /// セルラーなどコスト高の回線を使用しているかどうか
    @Published private(set) var isExpensive: Bool = false

    // MARK: - Private

    private let monitor: NWPathMonitor
    private let monitorQueue: DispatchQueue

    // MARK: - Init / Deinit

    init() {
        self.monitor = NWPathMonitor()
        self.monitorQueue = DispatchQueue(label: "com.screenvault.networkmonitor", qos: .utility)
        startMonitoring()
    }

    deinit {
        monitor.cancel()
    }

    // MARK: - Public API

    /// 監視を明示的に停止する（通常は deinit で自動停止）
    func stop() {
        monitor.cancel()
        SVLogger.upload.info("NetworkMonitor: stopped")
    }

    // MARK: - Private helpers

    private func startMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let connected = path.status == .satisfied
            let expensive = path.isExpensive

            Task { @MainActor in
                let wasConnected = self.isConnected
                self.isConnected = connected
                self.isExpensive = expensive

                if connected && !wasConnected {
                    SVLogger.upload.info("NetworkMonitor: network restored (expensive=\(expensive))")
                } else if !connected && wasConnected {
                    SVLogger.upload.info("NetworkMonitor: network lost")
                }
            }
        }

        monitor.start(queue: monitorQueue)
        SVLogger.upload.info("NetworkMonitor: started")
    }
}

