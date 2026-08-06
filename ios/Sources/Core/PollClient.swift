import Foundation

protocol PollFetching {
    func poll(
        baseURL: URL,
        apiKey: String,
        sessionID: String,
        cursor: PollCursor,
        waitMs: Int
    ) async -> PollOutcome
}

/// What one `/poll` round trip produced. Deliberately NOT `Result<PollResponse,
/// SessionsFetchError>` -- reusing that 5-case enum would either grow a case that
/// means nothing to `HistoryClient`/`SessionsClient`, or force `.unreadable` to be
/// represented as the existing `.malformedBody`, which is exactly the "collapse two
/// failure modes into their nearest existing case" mistake brief §3-a forbids:
/// `.unreachable` still feeds `Backoff`, `.unreadable` must feed `UnreadableMeter`
/// instead, and a caller reading `Result<_, SessionsFetchError>` has no vocabulary to
/// keep those apart.
enum PollOutcome: Equatable {
    case success(PollResponse)
    /// §2-a steps 2-4: the response was HTTP 200, but either its body was not valid
    /// JSON, `ReadablePoll.check` rejected the loose tree, or a typed `JSONDecoder`
    /// pass over the SAME `Data` failed even though the loose check passed (a
    /// structurally-plausible-but-still-wrong-shaped 200). All three collapse to one
    /// case -- nothing downstream (`UnreadableMeter`) distinguishes among them, and
    /// the brief does not ask it to (§0-b⑦: `ReadablePoll` itself makes no such
    /// distinction, it only answers yes/no).
    case unreadable
    case unauthorized
    /// 404 carrying `SESSION_NOT_FOUND`: the conversation this loop is attached to is
    /// gone. Kept distinct from `.unreachable` for the same reason `HistoryClient`,
    /// `SendClient` and `InterruptClient` already keep it distinct -- collapsing them
    /// makes a deleted session look like a network problem, sending the user to check
    /// their signal while the real cause sits on the desk. This client was the last
    /// one still collapsing it.
    case sessionNotFound
    case unreachable
    case cancelled
}

/// `GET /api/sessions/<id>/poll?cursor=&wait=` -- same structural shape as
/// `HistoryClient`/`SessionsClient` (protocol + struct, injected `BackendSession`,
/// status-code-first branching, N6), extended by brief §2-a's two-pass read: a typed
/// decode is only ever attempted AFTER `ReadablePoll.check` has passed on the SAME
/// bytes. `ReadablePoll` (Sprint 1; brief: must not be rewritten) already encodes
/// what "trustworthy enough to show" means for this endpoint, and a typed decode
/// alone cannot ask that question on its own -- `JSONDecoder` would happily produce a
/// `PollResponse` from a body `ReadablePoll.check` would reject (e.g. a `kind:
/// "message"` item with neither `entries` nor `event`, which decodes fine as
/// `MessageItem(entries: nil, seq:)` but is exactly the shape `ReadablePoll.swift`'s
/// own doc comment calls out as unreadable).
struct PollClient: PollFetching {
    private let session: BackendSession

    init(session: BackendSession = .shared) {
        self.session = session
    }

    func poll(
        baseURL: URL,
        apiKey: String,
        sessionID: String,
        cursor: PollCursor,
        waitMs: Int
    ) async -> PollOutcome {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("api/sessions/\(sessionID)/poll"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "cursor", value: cursor.wireValue),
            URLQueryItem(name: "wait", value: String(waitMs)),
        ]
        guard let url = components?.url else {
            // Same judgment as `HistoryClient`: not observed in practice (session ids
            // are opaque server-issued strings, and the cursor is server-issued too),
            // but `URLComponents` construction is technically failable -- fail closed.
            return .unreachable
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = BackendSession.pollTimeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            return .cancelled
        } catch let urlError as URLError where urlError.code == .cancelled {
            return .cancelled
        } catch {
            return .unreachable
        }

        // N6: status is checked before the body is trusted.
        guard let http = response as? HTTPURLResponse else { return .unreachable }
        switch http.statusCode {
        case 200:
            break
        case 401:
            return .unauthorized
        case 404:
            // The two 404s this endpoint can produce are NOT the same event, and the
            // difference is exactly "can retrying ever succeed?":
            //
            //   `SESSION_NOT_FOUND` -- the session is gone. A deleted session does not
            //   come back under the same id, so the loop must stop. Reported as
            //   `.unreachable` (what this client did until now) it instead drove
            //   `reachability.recordFailure()` forever, showing a connectivity banner
            //   over a screen whose real problem was that the conversation had ended.
            //
            //   Any other 404 (no code, or `NO_SUCH_ROUTE`) -- the phone asked for a
            //   path this server does not serve, i.e. a version skew across a deploy.
            //   That CAN heal: the next deploy restores the route and the very next
            //   poll succeeds. So it stays `.unreachable` and keeps retrying.
            //
            // ★This is a deliberate divergence from `SendClient`, which turns the same
            // second case into a contract violation. Send is one-shot: it has no retry
            // loop to heal into, so its only options are "act on it" or "lie". A poll
            // loop has the third option, and taking it is strictly better than telling
            // the user 「送れたかどうかは確認できていません」 -- prose that belongs to a
            // send and would be simply false printed under a poll.
            guard (try? JSONDecoder().decode(RecoveryCode.self, from: data))?.code
                == RecoveryCode.sessionNotFound
            else {
                return .unreachable
            }
            return .sessionNotFound
        default:
            return .unreachable
        }

        // §2-a steps 2-3: parse the loose tree first, then run the existing
        // structural check on it -- `ReadablePoll.check` (Sprint 1, not rewritten
        // this sprint) operates on `Any`, never on a typed model.
        guard
            let tree = try? JSONSerialization.jsonObject(with: data),
            ReadablePoll.check(tree)
        else {
            return .unreadable
        }

        // §2-a step 4: only now attempt the typed decode, on the SAME `data` the
        // loose check just approved. A typed-decode failure here counts identically
        // to a structural-check failure (brief §0-b⑦): both mean "a 200 arrived that
        // this phone should not trust," and `UnreadableMeter` does not care which of
        // the two pre-conditions actually failed.
        guard let decoded = try? JSONDecoder().decode(PollResponse.self, from: data) else {
            return .unreadable
        }
        return .success(decoded)
    }
}
