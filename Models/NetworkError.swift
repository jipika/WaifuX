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
