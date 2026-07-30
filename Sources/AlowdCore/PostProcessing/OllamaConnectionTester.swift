import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum OllamaConnectionError: Error, LocalizedError, Equatable {
    case nonLocalHost
    case serverError

    public var errorDescription: String? {
        switch self {
        case .nonLocalHost:
            "Alowd only talks to a local Ollama (127.0.0.1 or localhost)."
        case .serverError:
            "Ollama did not answer at that address. Is `ollama serve` running?"
        }
    }
}

/// Settings-window "Test connection" helper: asks the local Ollama for its
/// model list. Same localhost-only guard as URLSessionOllamaHTTPClient.
public enum OllamaConnectionTester {
    /// Returns the model names Ollama reports (possibly empty).
    public static func listModels(baseURL: URL) async throws -> [String] {
        guard baseURL.host == "127.0.0.1" || baseURL.host == "localhost" else {
            throw OllamaConnectionError.nonLocalHost
        }

        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 5

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw OllamaConnectionError.serverError
        }
        return try JSONDecoder().decode(OllamaTagsResponse.self, from: data).models.map(\.name)
    }
}

private struct OllamaTagsResponse: Codable {
    struct Model: Codable {
        var name: String
    }

    var models: [Model]
}
