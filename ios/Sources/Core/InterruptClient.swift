import Foundation

protocol Interrupting {
    func interrupt(baseURL: URL, apiKey: String, sessionID: String) async -> SendOutcome
}

/// `POST /api/sessions/<id>/interrupt`, **no request body at all**.
///
/// The server's handler reads nothing from the request beyond the path -- it calls
/// `resolvePane()` and goes. Sending `{}` anyway would create a shape somebody later
/// "fixes" by adding a field to, so nothing is sent and no `Content-Type` is set.
///
/// Returns `SendOutcome`, reused rather than re-declared. `SendClient`'s own doc sets
/// the bar for when reuse is right ("do the two really have the same failure modes?"),
/// and here they do, case for case:
///
/// - `.display` -- the interrupt route runs `speaks(res, interruptResult)`, so every
///   response on it carries `display` (系統B), exactly like a send.
/// - `.unauthorized` / `.sessionNotFound` / `.contractViolation` -- identical: 401 is
///   decided before the operation, and both 404 shapes (`SESSION_NOT_FOUND` from the
///   session lookup, `NO_SUCH_ROUTE` from a path the phone built wrong) exist on this
///   route too.
/// - `.unreachable` / `.cancelled` -- transport, same everywhere.
///
/// The one member that does not apply is `ResultDisplay.keepText`: there is no
/// composer text at stake in an interrupt. That is a field on the payload, not a case
/// in the enum, and `ConversationViewModel.applyInterruptOutcome(_:)` simply never
/// reads it -- which is why it does not justify a second enum.
///
/// ★What this type must NOT do: look at `interrupted`, `stopped`, `reason`, `route`
/// or `pane`. Whether the generation actually stopped is a four-way distinction the
/// server already makes (`view.mjs`'s `interruptResult`, covered branch-by-branch in
/// `test/view.test.mjs`), and it was got *wrong* once already -- until 2026-08-03 the
/// server returned `interrupted: true` for "Escape was pressed" and the phone read
/// that as "it stopped". Re-deriving the wording here would rebuild that same bug on
/// the other side of the wire. Hence `Envelope` declares two fields and no more.
struct InterruptClient: Interrupting {
    private let session: BackendSession

    init(session: BackendSession = .shared) {
        self.session = session
    }

    func interrupt(baseURL: URL, apiKey: String, sessionID: String) async -> SendOutcome {
        let url = baseURL.appendingPathComponent("api/sessions/\(sessionID)/interrupt")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = BackendSession.writeTimeout
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

        guard let http = response as? HTTPURLResponse else { return .unreachable }

        // N6 and the same recovery-before-display order as `SendClient`: the two
        // decisions about *which screen to be on* are settled from status + `code`
        // before `display` is consulted at all.
        if http.statusCode == 401 { return .unauthorized }

        let envelope = try? JSONDecoder().decode(Envelope.self, from: data)

        if http.statusCode == 404 {
            guard envelope?.code == RecoveryCode.sessionNotFound else {
                return .contractViolation(ResponseContractViolation(status: 404, code: envelope?.code))
            }
            return .sessionNotFound
        }

        guard let display = envelope?.display else {
            return .contractViolation(
                ResponseContractViolation(status: http.statusCode, code: envelope?.code)
            )
        }
        return .display(display)
    }

    /// Two fields, and the omissions are the point -- see the ★ in this type's doc.
    private struct Envelope: Decodable {
        let display: ResultDisplay?
        let code: String?
    }
}
