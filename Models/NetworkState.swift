import Foundation
import Network

/// 网络连接状态
enum NetworkConnectionState: Equatable {
    /// 在线 (WiFi)
    case wifi
    /// 在线 (蜂窝网络)
    case cellular
    /// 在线 (其他网络)
    case other
    /// 离线
    case offline
    
    var isConnected: Bool {
        switch self {
        case .wifi, .cellular, .other:
            return true
        case .offline:
            return false
        }
    }
    
    var isWiFi: Bool {
        if case .wifi = self { return true }
        return false
    }
    
    var description: String {
        switch self {
        case .wifi:
            return "WiFi"
        case .cellular:
            return "Cellular"
        case .other:
            return "Connected"
        case .offline:
            return "Offline"
        }
    }
}

/// 网络质量等级
enum NetworkQuality: Equatable, Comparable {
    /// 优秀 (WiFi/高速网络)
    case excellent
    /// 良好 (正常4G/5G)
    case good
    /// 一般 (慢速网络)
    case fair
    /// 差 (极慢/不稳定)
    case poor
    /// 离线
    case offline
    
    static func < (lhs: NetworkQuality, rhs: NetworkQuality) -> Bool {
        let order: [NetworkQuality] = [.offline, .poor, .fair, .good, .excellent]
        guard let lhsIndex = order.firstIndex(of: lhs),
              let rhsIndex = order.firstIndex(of: rhs) else {
            return false
        }
        return lhsIndex < rhsIndex
    }
    
    var isSuitableForLargeDownloads: Bool {
        self >= .good
    }
    
    var recommendedRetryCount: Int {
        switch self {
        case .excellent:
            return 2
        case .good:
            return 3
        case .fair:
            return 4
        case .poor:
            return 5
        case .offline:
            return 0
        }
    }
    
    var recommendedTimeout: TimeInterval {
        switch self {
        case .excellent:
            return 30
        case .good:
            return 45
        case .fair:
            return 60
        case .poor:
            return 90
        case .offline:
            return 0
        }
    }
}

/// 网络状态信息
struct NetworkStatus: Equatable {
    let connectionState: NetworkConnectionState
    let quality: NetworkQuality
    let isExpensive: Bool  // 是否按流量计费 (蜂窝网络)
    let isConstrained: Bool // 是否受限 (低数据模式)
    
    static let unknown = NetworkStatus(
        connectionState: .other,
        quality: .good,
        isExpensive: false,
        isConstrained: false
    )
    
    static let offline = NetworkStatus(
        connectionState: .offline,
        quality: .offline,
        isExpensive: false,
        isConstrained: false
    )
}

/// 重试配置
struct RetryConfiguration {
    /// 最大重试次数
    let maxRetries: Int
    /// 初始延迟 (秒)
    let initialDelay: TimeInterval
    /// 最大延迟 (秒)
    let maxDelay: TimeInterval
    /// 延迟乘数 (指数退避)
    let delayMultiplier: Double
    /// 是否允许在蜂窝网络上重试
    let allowRetryOnCellular: Bool
    
    static let `default` = RetryConfiguration(
        maxRetries: 3,
        initialDelay: 1.0,
        maxDelay: 8.0,
        delayMultiplier: 2.0,
        allowRetryOnCellular: true
    )
    
    static let aggressive = RetryConfiguration(
        maxRetries: 5,
        initialDelay: 0.5,
        maxDelay: 16.0,
        delayMultiplier: 2.0,
        allowRetryOnCellular: true
    )
    
    static let conservative = RetryConfiguration(
        maxRetries: 2,
        initialDelay: 2.0,
        maxDelay: 4.0,
        delayMultiplier: 2.0,
        allowRetryOnCellular: false
    )
    
    /// 计算第 n 次重试的延迟时间
    func delayForRetry(attempt: Int) -> TimeInterval {
        let delay = initialDelay * pow(delayMultiplier, Double(attempt - 1))
        return min(delay, maxDelay)
    }
}

/// 判断错误是否可重试
protocol RetryableError {
    var isRetryable: Bool { get }
}

extension NetworkError: RetryableError {
    var isRetryable: Bool {
        switch self {
        case .timeout:
            return true
        case .httpError(let code):
            // 5xx 服务器错误可重试，4xx 客户端错误不重试
            return code >= 500
        case .networkError:
            // 网络错误通常可重试，除了明确的离线情况
            return true
        case .invalidResponse, .decodingError, .serverError:
            return false
        }
    }
}

extension Error {
    var isRetryable: Bool {
        if let retryable = self as? RetryableError {
            return retryable.isRetryable
        }
        
        // 检查 URLError
        if let urlError = self as? URLError {
            switch urlError.code {
            case .timedOut,
                 .cannotFindHost,
                 .cannotConnectToHost,
                 .networkConnectionLost,
                 .dnsLookupFailed,
                 .httpTooManyRedirects,
                 .resourceUnavailable,
                 .notConnectedToInternet:
                return true
            default:
                return false
            }
        }
        
        return false
    }
}
