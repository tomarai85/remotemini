import Foundation

enum SessionsFetchError: Error, Equatable {
    /// Connection failure/timeout, and any HTTP status other than 200/401 (5xx
    /// included). Judgment call, same shape as `SessionsAuthProbe.Outcome.unreachable`
    /// (spec gap, flagged in progress.md): the brief's §4-a counting table only names
    /// "接続不可 / タイムアウト / 5xx", it does not separately name e.g. a stray 403/404.
    /// Grouped here because none of those responses are evidence the List screen has
    /// anything usable to show, which is the property the failure counter actually
    /// tracks.
    case unreachable
    /// HTTP 401. Counted separately from `.unreachable` -- brief §4-a: a 401 does not
    /// advance the consecutive-failure counter at all, it exits straight to Key-entry.
    case unauthorized
    /// HTTP 200, but the body didn't decode as `SessionsResponse`. Treated as a
    /// failure (not a reset) by the ViewModel: brief §4-a's "200 resets the counter"
    /// rule is written with a well-formed body in mind (its own example is "200 that
    /// happens to carry a paneFault"), and reaching a 200 with an undecodable body is
    /// not the same evidence of a healthy round trip -- flagged in progress.md.
    case malformedBody
    /// The request was cancelled -- either `CancellationError` (structured-concurrency
    /// cancellation) or `URLError.cancelled` (`URLSession`'s own cancellation
    /// surfacing), which the brief explicitly says must both be treated as this same
    /// case, not folded into `.unreachable` (§4-a, §8: found via Codex, not
    /// self-discovered -- rapid pull-to-refresh cancels an in-flight fetch, and that
    /// must not look like the backend went unreachable).
    case cancelled
}

protocol SessionsListing {
    func fetch(baseURL: URL, apiKey: String) async -> Result<SessionsResponse, SessionsFetchError>
}

/// `GET /api/sessions`, decoded to the full response shape (unlike
/// `SessionsAuthProbe`, which only cares about the status code and discards the
/// body -- that type stays Key-entry's, this one is the List screen's data source).
struct SessionsClient: SessionsListing {
    /// `BackendSession`, not `URLSession`: see that type for why N5 is a constraint
    /// here rather than a default argument. This client carries the bearer key, so a
    /// followed redirect would be the exact leak N5 exists to prevent.
    private let session: BackendSession

    init(session: BackendSession = .shared) {
        self.session = session
    }

    func fetch(baseURL: URL, apiKey: String) async -> Result<SessionsResponse, SessionsFetchError> {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/sessions"))
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
        default:
            return .failure(.unreachable)
        }

        guard let decoded = try? JSONDecoder().decode(SessionsResponse.self, from: data) else {
            return .failure(.malformedBody)
        }
        return .success(decoded)
    }
}
