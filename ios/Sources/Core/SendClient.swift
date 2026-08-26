import Foundation

/// The result of one `POST …/messages`, in the vocabulary the Conversation screen
/// acts on.
///
/// Deliberately NOT `Result<ResultDisplay, SessionsFetchError>`: the send path's
/// failure vocabulary is genuinely different from the two GET clients'. A send has no
/// `.malformedBody` (an unreadable body is a contract violation, which is a louder
/// thing), and it has `.contractViolation`, which the GET clients only acquired
/// because of the 404 finding. Reusing one enum across both would have forced every
/// site to answer "can this case even happen here?" -- see `SessionsFetchError`'s own
/// doc for the counter-argument that kept THOSE two sharing a type (they really do
/// have the same failure modes; this one does not).
enum SendOutcome: Equatable {
    /// The server spoke (brief §0-c ③): render `display.text` verbatim.
    case display(ResultDisplay)
    /// HTTP 401. A ROUTE decision, not a display decision (brief §0-c ①): the phone
    /// never looks for a `display` here, because 401 is decided before the send is
    /// attempted at all -- it is the result of protocol/resource resolution, not of
    /// the operation. Handled by the existing credentials-cleared -> Key-entry path.
    case unauthorized
    /// HTTP 404 **with `code: "SESSION_NOT_FOUND"`** -- and only that. The other two
    /// 404 sites mean "the path this phone built does not exist," which is a client
    /// bug, and routing it here would tell the user their conversation was deleted
    /// (brief §0-c ②: "一番出やすいバグを、一番それらしい嘘で隠す").
    case sessionNotFound
    /// A response that should have carried a `display` and did not -- including any
    /// 404 whose `code` is not `SESSION_NOT_FOUND`.
    case contractViolation(ResponseContractViolation)
    /// No response reached the phone (connection failure, timeout, non-HTTP
    /// response). Note this does NOT mean "not sent": a request whose response was
    /// lost may well have been delivered, which is why the banner for this case says
    /// so and the composer keeps the text.
    case unreachable
    /// The in-flight request was cancelled (the screen went away, or a newer request
    /// superseded this one). No banner, no state change -- whoever cancelled owns the
    /// outcome. Same rule as `SessionsFetchError.cancelled`.
    case cancelled
}

protocol MessageSending {
    func send(baseURL: URL, apiKey: String, sessionID: String, text: String, sendId: String) async -> SendOutcome
}

/// `POST /api/sessions/<id>/messages`, body `{"text": …}`.
///
/// Same construction rules as the other clients: `BackendSession` rather than a bare
/// `URLSession` (N5 redirect refusal -- this request carries the bearer key AND the
/// user's typed text, so a followed redirect would leak both), and the status is
/// examined before the body is trusted (N6).
struct SendClient: MessageSending {
    private let session: BackendSession

    init(session: BackendSession = .shared) {
        self.session = session
    }

    func send(baseURL: URL, apiKey: String, sessionID: String, text: String, sendId: String) async -> SendOutcome {
        let url = baseURL.appendingPathComponent("api/sessions/\(sessionID)/messages")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = BackendSession.writeTimeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let encoded: Data
        do {
            encoded = try JSONEncoder().encode(RequestBody(text: text, sendId: sendId))
        } catch {
            // Unreachable for this shape (a Swift `String` is always encodable), but
            // written as a real branch rather than `try!` so that adding a field to
            // `RequestBody` later cannot turn a send into a crash. `.unreachable` is
            // the honest bucket: its banner claims only that delivery could not be
            // confirmed, which is true here too.
            return .unreachable
        }
        request.httpBody = encoded

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

        guard let http = response as? HTTPURLResponse else { return .unreachable }

        // Brief §2 step 4, in the brief's own order. The two RECOVERY decisions
        // (which screen to be on) are settled from status + `code` BEFORE `display`
        // is consulted at all -- not because `display` is absent on those paths as a
        // matter of implementation, but because those two responses report on
        // protocol/resource resolution rather than on the send (brief §0-c ①, the
        // Codex-corrected justification).
        if http.statusCode == 401 { return .unauthorized }

        let envelope = try? JSONDecoder().decode(Envelope.self, from: data)

        if http.statusCode == 404 {
            guard envelope?.code == RecoveryCode.sessionNotFound else {
                // Brief §0-c ②: every other 404 -- including one whose body did not
                // decode, so no `code` could be read -- is a contract violation, and
                // in particular is NOT routed back to the list. The user's session is
                // very probably still there; it is the phone's URL that is wrong.
                return .contractViolation(ResponseContractViolation(status: 404, code: envelope?.code))
            }
            return .sessionNotFound
        }

        guard let display = envelope?.display else {
            // Covers three real shapes at once: a body with no `display` key, a body
            // that did not decode at all, and a `display` object missing its `text`
            // (which fails `ResultDisplay`'s decode -- a display with nothing to say
            // is not a display).
            return .contractViolation(
                ResponseContractViolation(status: http.statusCode, code: envelope?.code)
            )
        }
        return .display(display)
    }

    private struct RequestBody: Encodable {
        let text: String
        /// 1つの論理送信に1つ。**再送では同じ値を使い回す** —— それが「同じ送信」だと
        /// 机に伝える唯一の手段で、無いと timeout 後の再送で同じ指示が2回実行される
        /// (2026-08-26 に本番で実測: 2回とも verified で通り、実画面に2回入った)。
        let sendId: String
    }

    /// Only the two fields the phone acts on. Every other key the server sends
    /// (`accepted`, `route`, `pane`, `delivered`, `note`, `reason`, `screen`, …) is
    /// intentionally undeclared: `JSONDecoder` ignores unknown keys, and declaring
    /// them would invite exactly the thing brief §1-b forbids -- the phone deciding
    /// what to show from the raw fields instead of from `display`.
    private struct Envelope: Decodable {
        let display: ResultDisplay?
        let code: String?
    }
}
