import Foundation

protocol SessionsAuthChecking {
    func check(baseURL: URL, apiKey: String) async -> SessionsAuthProbe.Outcome
}

/// A single `GET /api/sessions` call used only by Key-entry to prove the API key is
/// correct (spec §2-1). This is not the List screen's data source -- Sprint 2 owns
/// that client, with the full response shape.
struct SessionsAuthProbe: SessionsAuthChecking {
    enum Outcome: Equatable {
        case authorized
        case unauthorized
        /// Judgment call: spec §5-1's table only names two Key-entry outcomes
        /// (healthz unreachable / healthz-ok-but-401). It does not say what to show
        /// for a non-200/401 response from `/api/sessions` (e.g. a 500). Grouped
        /// with "server unreachable" here because such a response is not evidence
        /// the *key* is wrong -- flagged in progress.md as a spec gap, not silently
        /// assumed.
        case unreachable
    }

    /// `BackendSession`, not `URLSession`: see that type for why N5 is a constraint
    /// here rather than a default argument. This probe carries the bearer key, so a
    /// followed redirect would be the exact leak N5 exists to prevent.
    private let session: BackendSession

    init(session: BackendSession = .shared) {
        self.session = session
    }

    func check(baseURL: URL, apiKey: String) async -> Outcome {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/sessions"))
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let response: URLResponse
        do {
            (_, response) = try await session.data(for: request)
        } catch {
            return .unreachable
        }

        guard let http = response as? HTTPURLResponse else { return .unreachable }
        switch http.statusCode {
        case 200: return .authorized
        case 401: return .unauthorized
        default: return .unreachable
        }
    }
}
