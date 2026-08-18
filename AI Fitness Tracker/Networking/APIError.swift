import Foundation

enum APIError: LocalizedError {
    case missingIngestKey
    case invalidResponse
    case httpError(statusCode: Int, body: String?)

    var errorDescription: String? {
        switch self {
        case .missingIngestKey:
            return "Add your Apple Health ingest API key in Settings before syncing."
        case .invalidResponse:
            return "The backend returned an invalid response."
        case let .httpError(statusCode, body):
            if let body, !body.isEmpty {
                return "Backend returned HTTP \(statusCode): \(body)"
            }
            return "Backend returned HTTP \(statusCode)."
        }
    }
}
