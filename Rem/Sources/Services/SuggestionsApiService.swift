import Foundation

// `TaskSuggestion` + `SuggestionAction` moved to `Shared/Models/TaskSuggestion.swift` so the
// shared `SuggestedTaskRow` view compiles on the Mac target too. This file keeps the iOS-only
// networking (the app performs task mutations locally; the backend only derives + records dismissals).

private struct SuggestionsResponse: Codable {
    let suggestions: [TaskSuggestion]
}

@MainActor
protocol SuggestionsApiServiceProtocol {
    func fetchSuggestions() async throws -> [TaskSuggestion]
    func dismiss(
        key: String,
        authority: AuthenticatedHttpClient.RequestAuthority
    ) async throws
}

/// HTTP client for the suggested-tasks endpoints (WS2, doc 38):
///   - GET  /api/v1/suggestions            — the current derived suggestions
///   - POST /api/v1/suggestions/:key/dismiss — durably hide one (also called on Accept)
@MainActor
final class SuggestionsApiService: SuggestionsApiServiceProtocol {
    private let decoder = JSONDecoder()

    func fetchSuggestions() async throws -> [TaskSuggestion] {
        let (data, http) = try await AuthenticatedHttpClient.request(
            path: "/api/v1/suggestions", method: "GET"
        )
        guard (200...299).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            throw RemApiError.requestFailed(statusCode: http.statusCode, message: message)
        }
        return try decoder.decode(SuggestionsResponse.self, from: data).suggestions
    }

    /// Suggestion actions retain the exact account/backend/token captured at tap time through the
    /// final durable dismissal. A 401 intentionally stays a failure instead of refreshing through
    /// whichever global credentials happen to be active after an account transition.
    func dismiss(
        key: String,
        authority: AuthenticatedHttpClient.RequestAuthority
    ) async throws {
        let encoded = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? key
        let (data, http) = try await AuthenticatedHttpClient.request(
            path: "/api/v1/suggestions/\(encoded)/dismiss",
            method: "POST",
            authority: authority
        )
        guard (200...299).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            throw RemApiError.requestFailed(statusCode: http.statusCode, message: message)
        }
    }
}
