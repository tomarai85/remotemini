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
            // Sprint 3 brief §3-c made 404 distinct from the `default` bucket below:
            // Conversation renders it as "this conversation is gone," never as
            // "network trouble, try again."
            //
            // Sprint 5 brief §0-c ② then NARROWED it, and that narrowing is the
            // point of DoD row 6. Counting `json(res, 404, …)` in `server.mjs` turned
            // up three sites carrying two meanings: the session really is unknown
            // (`SESSION_NOT_FOUND`), or the requested path does not exist at all
            // (`NO_SUCH_ROUTE`, twice). Branching on the status alone -- which is
            // what this line did until now -- rendered the second as "この会話はもう
            // 在りません," i.e. it told the user their conversation had been deleted
            // when the truth was that this app built a URL wrong.
            //
            // That combination is worse than a merely imprecise message. The same
            // day's mutation audit measured the request path as the least-guarded
            // thing in this tree (changing `api/sessions` to `api/session` left 214
            // tests green), so this branch was covering the most likely bug in the
            // app with the most convincing possible false explanation.
            let code = try? JSONDecoder().decode(RecoveryCode.self, from: data).code
            guard code == RecoveryCode.sessionNotFound else {
                return .failure(.contractViolation(ResponseContractViolation(status: 404, code: code)))
            }
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
