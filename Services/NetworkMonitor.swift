import Foundation
import Network
import Combine

/// 网络状态监测服务
@MainActor
final class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()
    
    // MARK: - Published Properties
    
    /// 当前网络状态
    @Published private(set) var status: NetworkStatus = .unknown
    
    /// 网络连接状态
    var connectionState: NetworkConnectionState { status.connectionState }
    
    /// 网络质量
    var quality: NetworkQuality { status.quality }
    
    /// 是否在线
    var isConnected: Bool { status.connectionState.isConnected }
    
    /// 是否离线
    var isOffline: Bool { !status.connectionState.isConnected }
    
    /// 是否使用 WiFi
    var isWiFi: Bool { status.connectionState.isWiFi }
    
    /// 是否使用蜂窝网络
    var isCellular: Bool {
        if case .cellular = status.connectionState { return true }
        return false
    }
    
    /// 是否按流量计费
    var isExpensive: Bool { status.isExpensive }
    
    // MARK: - Private Properties
    
    private let monitor: NWPathMonitor
    private let queue = DispatchQueue(label: "com.wallhaven.networkmonitor", qos: .utility)
    private var isMonitoring = false
    
    /// 网络恢复时的回调
    var onNetworkRestored: (() -> Void)?
    
    // MARK: - Initialization
    
    private init() {
        monitor = NWPathMonitor()
        setupMonitor()
    }
    
    // MARK: - Public Methods
    
    /// 开始监测网络状态
    func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true
        monitor.start(queue: queue)
        print("[NetworkMonitor] Started monitoring")
    }
    
    /// 停止监测网络状态
    func stopMonitoring() {
        guard isMonitoring else { return }
        monitor.cancel()
        isMonitoring = false
        print("[NetworkMonitor] Stopped monitoring")
    }
    
    /// 获取当前网络质量对应的推荐重试配置
    func recommendedRetryConfiguration() -> RetryConfiguration {
        switch quality {
        case .excellent:
            return .default
        case .good:
            return .default
        case .fair:
            return RetryConfiguration(
                maxRetries: 4,
                initialDelay: 1.5,
                maxDelay: 12.0,
                delayMultiplier: 2.0,
                allowRetryOnCellular: true
            )
        case .poor:
            return RetryConfiguration(
                maxRetries: 5,
                initialDelay: 2.0,
                maxDelay: 16.0,
                delayMultiplier: 2.0,
                allowRetryOnCellular: true
            )
        case .offline:
            return RetryConfiguration(
                maxRetries: 0,
                initialDelay: 0,
                maxDelay: 0,
                delayMultiplier: 1.0,
                allowRetryOnCellular: false
            )
        }
    }
    
    /// 获取当前网络质量对应的推荐超时时间
    func recommendedTimeout() -> TimeInterval {
        status.quality.recommendedTimeout
    }
    
    /// 等待网络恢复
    func waitForConnection(timeout: TimeInterval = 30) async -> Bool {
        guard isOffline else { return true }
        
        return await withTimeout(timeout: timeout) { @MainActor in
            await withCheckedContinuation { continuation in
                var cancellable: AnyCancellable?
                cancellable = self.$status
                    .filter { $0.connectionState.isConnected }
                    .first()
                    .sink { _ in
                        cancellable?.cancel()
                        continuation.resume(returning: true)
                    }
            }
        } ?? false
    }
    
    // MARK: - Private Methods
    
    private func setupMonitor() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.handlePathUpdate(path)
            }
        }
    }
    
    private func handlePathUpdate(_ path: NWPath) {
        let previousStatus = status
        let newStatus = createStatus(from: path)
        
        status = newStatus
        
        // 检测网络恢复
        if !previousStatus.connectionState.isConnected && newStatus.connectionState.isConnected {
            print("[NetworkMonitor] Network restored: \(newStatus.connectionState.description)")
            onNetworkRestored?()
        }
        
        // 检测网络断开
        if previousStatus.connectionState.isConnected && !newStatus.connectionState.isConnected {
            print("[NetworkMonitor] Network disconnected")
        }
        
        // 打印状态变化
        if previousStatus != newStatus {
            print("[NetworkMonitor] Status changed: \(previousStatus.connectionState.description) -> \(newStatus.connectionState.description), Quality: \(newStatus.quality)")
        }
    }
    
    private func createStatus(from path: NWPath) -> NetworkStatus {
        let connectionState: NetworkConnectionState
        let quality: NetworkQuality
        
        switch path.status {
        case .satisfied:
            // 确定连接类型
            if path.usesInterfaceType(.wifi) {
                connectionState = .wifi
                quality = .excellent
            } else if path.usesInterfaceType(.cellular) {
                connectionState = .cellular
                // 根据约束判断质量
                if path.isConstrained {
                    quality = .fair
                } else {
                    quality = .good
                }
            } else if path.usesInterfaceType(.wiredEthernet) {
                connectionState = .other
                quality = .excellent
            } else {
                connectionState = .other
                quality = .good
            }
            
        case .unsatisfied:
            connectionState = .offline
            quality = .offline
            
        case .requiresConnection:
            connectionState = .offline
            quality = .offline
            
        @unknown default:
            connectionState = .offline
            quality = .offline
        }
        
        return NetworkStatus(
            connectionState: connectionState,
            quality: quality,
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained
        )
    }
    
    /// 带超时的异步操作
    @MainActor
    private func withTimeout<T: Sendable>(timeout: TimeInterval, operation: @escaping @Sendable () async -> T) async -> T? {
        try? await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw CancellationError()
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}

// MARK: - Convenience Extensions

extension NetworkMonitor {
    /// 检查是否应该发起网络请求
    var shouldMakeRequests: Bool {
        isConnected
    }
    
    /// 检查是否应该下载大文件
    var shouldDownloadLargeFiles: Bool {
        guard isConnected else { return false }
        if isWiFi { return true }
        // 蜂窝网络下根据质量判断
        return quality >= .good && !isExpensive
    }
    
    /// 网络状态描述文本 (用于调试)
    var debugDescription: String {
        """
        Network Status:
        - Connection: \(status.connectionState.description)
        - Quality: \(status.quality)
        - Expensive: \(status.isExpensive)
        - Constrained: \(status.isConstrained)
        """
    }
}
