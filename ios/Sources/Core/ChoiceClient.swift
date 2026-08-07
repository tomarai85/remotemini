import Foundation

/// The result of one `POST …/choice`, as the phone needs it.
///
/// `outcome` is `SendOutcome` unchanged, not a parallel enum. The reuse test
/// `SendClient` sets ("do the two really have the same failure modes?") passes case for
/// case: this route runs `speaks(res, choiceResult)`, so every response carries
/// `display`; 401 is decided before the keystroke is attempted; both 404 shapes exist
/// here; transport failure and cancellation are transport-wide. Declaring a third enum
/// with the same six cases would be a copy that can drift, and `ResultDisplay.keepText`
/// -- the one member that does not apply -- is a field on the payload, not a case.
///
/// `serverDigest` is the one fact this route reports that the others do not, so it
/// rides alongside rather than inside. On a 409 the server deliberately attaches the
/// fingerprint the screen has **right now**, and the phone's whole staleness decision
/// is `serverDigest != theDigestWeSent`.
///
/// ★Why compare fingerprints instead of reading `reason`: the refusal vocabulary
/// (`digest-mismatch`, `choice-key-not-allowed`, `choice-already-sent`, …) is the
/// server's WORDING vocabulary, and `InterruptClient`'s doc records what happens when
/// the phone starts branching on the server's words -- the 2026-08-03 bug where the
/// phone re-derived "it stopped" from a field that did not mean that. The fingerprint
/// is not a word, it is the mechanism: two different fingerprints mean the screen moved
/// under us, whatever the server chose to call it. Binding to the mechanism cannot
/// drift when the vocabulary is reworded.
struct ChoiceAttempt: Equatable {
    let outcome: SendOutcome
    /// `nil` = the server said nothing about the current fingerprint (every 200, and
    /// any refusal raised before a screen was captured). Absence is not "unchanged" --
    /// the caller must treat it as "no new information", never as confirmation.
    let serverDigest: String?
}

protocol ChoiceSending {
    func choose(
        baseURL: URL, apiKey: String, sessionID: String, key: String, digest: String
    ) async -> ChoiceAttempt
}

/// `POST /api/sessions/<id>/choice`, body `{"key": …, "digest": …}`.
///
/// Both fields are echoed from what the server itself handed the phone: `key` comes
/// from a `ChoiceButton` the server put in `buttons`, `digest` from the same
/// `ChoiceView` that carried that button. Nothing in this file composes either value.
/// That is what makes the server's guarantee -- 見た物と押す物が同じ -- hold across the
/// wire rather than only inside the backend.
struct ChoiceClient: ChoiceSending {
    private let session: BackendSession

    init(session: BackendSession = .shared) {
        self.session = session
    }

    func choose(
        baseURL: URL, apiKey: String, sessionID: String, key: String, digest: String
    ) async -> ChoiceAttempt {
        let url = baseURL.appendingPathComponent("api/sessions/\(sessionID)/choice")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = BackendSession.writeTimeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let encoded: Data
        do {
            encoded = try JSONEncoder().encode(RequestBody(key: key, digest: digest))
        } catch {
            // Same branch, same reasoning as `SendClient`: unreachable for two
            // `String`s, written out so that adding a field later cannot turn a
            // keystroke into a crash. `.unreachable` is the honest bucket -- its
            // banner claims only that delivery could not be confirmed.
            return ChoiceAttempt(outcome: .unreachable, serverDigest: nil)
        }
        request.httpBody = encoded

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            return ChoiceAttempt(outcome: .cancelled, serverDigest: nil)
        } catch let urlError as URLError where urlError.code == .cancelled {
            return ChoiceAttempt(outcome: .cancelled, serverDigest: nil)
        } catch {
            // ★A timed-out keystroke may well have landed. Nothing here may claim
            // otherwise, and the caller must not auto-retry -- see
            // `ConversationViewModel.applyChoiceAttempt(_:sentDigest:)`.
            return ChoiceAttempt(outcome: .unreachable, serverDigest: nil)
        }

        guard let http = response as? HTTPURLResponse else {
            return ChoiceAttempt(outcome: .unreachable, serverDigest: nil)
        }

        // Recovery before display, in the same order as the other two write clients:
        // 401 and the SESSION_NOT_FOUND 404 decide WHICH SCREEN the phone is on, and
        // that is settled from status + `code` before `display` is consulted at all.
        if http.statusCode == 401 {
            return ChoiceAttempt(outcome: .unauthorized, serverDigest: nil)
        }

        let envelope = try? JSONDecoder().decode(Envelope.self, from: data)

        if http.statusCode == 404 {
            guard envelope?.code == RecoveryCode.sessionNotFound else {
                return ChoiceAttempt(
                    outcome: .contractViolation(
                        ResponseContractViolation(status: 404, code: envelope?.code)),
                    serverDigest: nil)
            }
            return ChoiceAttempt(outcome: .sessionNotFound, serverDigest: nil)
        }

        // The fingerprint is carried out of every remaining response, including the
        // ones that turn into a contract violation: a 409 whose `display` the phone
        // could not read still tells the truth about which screen is live, and
        // discarding that would strand the card in its stale state until the next poll.
        let served = envelope?.digest.flatMap { $0.isEmpty ? nil : $0 }

        guard let display = envelope?.display else {
            return ChoiceAttempt(
                outcome: .contractViolation(
                    ResponseContractViolation(status: http.statusCode, code: envelope?.code)),
                serverDigest: served)
        }
        return ChoiceAttempt(outcome: .display(display), serverDigest: served)
    }

    private struct RequestBody: Encodable {
        let key: String
        let digest: String
    }

    /// `digest` joins `display`/`code` here and nothing else does. The refusal body
    /// also carries `error`, `route`, `pane`, `screen` and `reason`; none is decoded,
    /// for the reason spelled out on `ChoiceAttempt` -- the wording is `display.text`'s
    /// job and the behaviour is the fingerprint's.
    private struct Envelope: Decodable {
        let display: ResultDisplay?
        let code: String?
        let digest: String?
    }
}
