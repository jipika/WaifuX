import Foundation

enum NetworkError: Error, LocalizedError {
    case invalidResponse
    case httpError(Int)
    case decodingError
    case networkError(Error)
    case serverError(Int)
    case timeout

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
        }
    }
}
