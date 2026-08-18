import Foundation

final class APIClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func importAppleHealth(
        payload: AppleHealthImportRequest,
        ingestKey: String
    ) async throws -> AppleHealthImportResponse {
        guard !ingestKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw APIError.missingIngestKey
        }

        let url = APIConfiguration.baseURL
            .appending(path: "api")
            .appending(path: "v1")
            .appending(path: "import")
            .appending(path: "apple-health")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(ingestKey, forHTTPHeaderField: APIConfiguration.ingestKeyHeader)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try encoder.encode(payload)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw APIError.httpError(
                statusCode: httpResponse.statusCode,
                body: String(data: data, encoding: .utf8)
            )
        }

        let decoder = JSONDecoder()
        return try decoder.decode(AppleHealthImportResponse.self, from: data)
    }
}
