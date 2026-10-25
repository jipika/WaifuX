import Foundation

enum NetworkError: Error, LocalizedError {
    case invalidResponse
    case httpError(Int)
    case decodingError
    case networkError(Error)
    case serverError(Int)
    case timeout
    /// Pixiv 等站点对需登录的接口（如 R18 排行榜）返回 403
    case loginRequired(message: String)

    /// Cloudflare 反爬拦截提示（NetworkService / 各 HTML 解析器共用同一文案）
    static let cloudflareBlockedMessage = "请求被 Cloudflare 反爬拦截。请在「设置 → 代理」启用 VPN/代理后重试。"

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return t("error.network.message")
        case .httpError(let code):
            return "\(t("error.server.title")): \(code)"
        case .decodingError:
            return t("error.parse.failed")
        case .networkError(let error):
            return error.localizedDescription
        case .serverError(let code):
            return "\(t("error.server.title")): \(code)"
        case .timeout:
            return t("error.network.message")
        case .loginRequired(let message):
            return message
        }
    }
}

// MARK: - 探索列表错误分类
///
/// 区分「真的网络问题」「搜索无结果」「源不支持中文搜索」「页面解析失败」，
/// 让列表空态面板按真实原因渲染，而不是一律套连接错误 + VPN 排查提示。
enum ExploreErrorKind: Equatable {
    /// 请求成功但 0 条结果（搜索没搜到）
    case noResults
    /// 当前源不支持中文搜索（纯 CJK 关键词注定为空）
    case chineseUnsupported
    /// 真网络问题：断网 / 超时 / 连接失败
    case network
    /// 服务器返回错误（4xx/5xx）
    case server
    /// 页面结构变化导致的解析失败（不是网络问题）
    case parse
    /// 被 Cloudflare 反爬拦截（需要代理，归入网络排查）
    case blocked
    /// 其他未知错误
    case unknown
}

enum ExploreErrorClassifier {
    /// 把任意错误映射为探索列表的错误分类
    static func kind(for error: Error) -> ExploreErrorKind {
        switch error {
        case let networkError as NetworkError:
            switch networkError {
            case .timeout, .networkError, .invalidResponse:
                return .network
            case .serverError, .httpError:
                return .server
            case .decodingError:
                return .parse
            case .loginRequired:
                return .blocked
            }
        case is URLError:
            // .cancelled 已被调用方提前拦截；其余 URLError 都按网络问题处理
            return .network
        case is FourKWallpapersParserError:
            return .parse
        case is WallsflowError:
            return .parse
        default:
            return .unknown
        }
    }
}

// MARK: - 搜索关键词 CJK 判定

extension String {
    /// 是否含有 CJK（中日韩表意文字/假名/谚文）字符
    var containsCJKCharacters: Bool {
        // Xcode 27 SDK：Unicode.Scalar 也是整数字面量类型，Range.contains 会被
        // 解析成 Collection 泛型重载而报错；改用 switch 区间匹配绕开。
        unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0x3040...0x30FF,
                 0xAC00...0xD7AF, 0xF900...0xFAFF:
                true
            default:
                false
            }
        }
    }

    /// 是否为「纯 CJK 查询」：含 CJK 字符且不含任何 ASCII 字母/数字。
    /// 用于判定「该源不支持中文搜索」——混有英文词的查询（如「银魂 goukan」）仍放行请求。
    var isCJKOnlyQuery: Bool {
        guard containsCJKCharacters else { return false }
        let hasASCIIWord = unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A:
                true
            default:
                false
            }
        }
        return !hasASCIIWord
    }
}
