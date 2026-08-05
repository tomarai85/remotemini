import Foundation

protocol HistoryFetching {
    func fetch(baseURL: URL, apiKey: String, sessionID: String, limit: Int) async -> Result<HistoryResponse, SessionsFetchError>
}

/// `GET /api/sessions/<id>/history?limit=N` -- same shape as `SessionsClient`
/// (Sprint 3 brief §1-a): protocol + struct, `BackendSession` (never a bare
/// `URLSession` -- `rc-backend/test/session-guard.test.mjs` scans `ios/Sources/` and
/// fails the commit gate on any other file that spells `URLSession`), N6 (status code
/// checked before the body is trusted), and the exact same `SessionsFetchError`
/// 4-case taxonomy reused rather than inventing a Conversation-specific one (brief
/// §3-c: two error vocabularies would mean picking one every sprint from here on).
struct HistoryClient: HistoryFetching {
    private let session: BackendSession

    init(session: BackendSession = .shared) {
        self.session = session
    }

    func fetch(baseURL: URL, apiKey: String, sessionID: String, limit: Int) async -> Result<HistoryResponse, SessionsFetchError> {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("api/sessions/\(sessionID)/history"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        guard let url = components?.url else {
            // Not observed in practice (session ids are opaque server-issued
            // strings), but `URLComponents` construction is technically failable --
            // fail closed rather than force-unwrap.
            return .failure(.unreachable)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch let urlError as URLError where urlError.code == .cancelled {
            return .failure(.cancelled)
        } catch {
            return .failure(.unreachable)
        }

        // N6: status is checked before the body is trusted.
        guard let http = response as? HTTPURLResponse else { return .failure(.unreachable) }
        switch http.statusCode {
        case 200:
            break
        case 401:
            return .failure(.unauthorized)
        case 404:
            // Brief §3-c (same-day correction): distinct from the `default` bucket
            // below -- Conversation renders this as "this conversation is gone,"
            // never as "network trouble, try again" (`server.mjs`'s `/history`
            // handler, `json(res, 404, { error: "unknown session" })`).
            return .failure(.notFound)
        default:
            // Covers the brief §0-a-5 500 (`TRANSCRIPT_UNREADABLE`) case too: the
            // brief does not ask for a distinct display for that status, and folding
            // it into `.unreachable` matches `SessionsClient`'s existing judgment
            // that any non-200/401/404 status is "nothing usable to show."
            return .failure(.unreachable)
        }

        guard let decoded = try? JSONDecoder().decode(HistoryResponse.self, from: data) else {
            return .failure(.malformedBody)
        }
        return .success(decoded)
    }
}
