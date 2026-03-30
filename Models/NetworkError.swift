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
            return "Invalid response from server"
        case .httpError(let code):
            return "HTTP error: \(code)"
        case .decodingError:
            return "Failed to decode response"
        case .networkError(let error):
            return error.localizedDescription
        case .serverError(let code):
            return "Server error: \(code)"
        case .timeout:
            return "Request timed out"
        }
    }
}
