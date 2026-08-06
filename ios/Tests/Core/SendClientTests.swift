import XCTest
@testable import RemoteMini

/// `SendClient.send` -- Sprint 5's only network client.
///
/// Structured around one question the other client suites do not have to ask: **who
/// wrote the sentence the user reads?** Every table row below feeds a body copied from
/// `rc-backend/src/view.mjs`'s `sendResult` and asserts the outcome carries THAT text,
/// not a phone-composed equivalent. A suite that only checked "some banner appeared"
/// would pass on an implementation that quietly localized 400s or appended its own
/// note to a 202 -- the two things brief §1-b forbids by name.
final class SendClientTests: XCTestCase {
    private let baseURL = URL(string: "https://unit-test.invalid")!

    override func setUp() { MockURLProtocol.reset() }
    override func tearDown() { MockURLProtocol.reset() }

    // MARK: - Request shape (all four `MockURLProtocol` recorders)

    func testRequestIsAPOSTToTheMessagesPathWithTheBearerKeyAndTheTextAsJSON() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 202, body: Data(Self.okBody.utf8))]
        let client = SendClient(session: MockURLProtocol.makeSession())

        _ = await client.send(
            baseURL: baseURL,
            apiKey: "correct-fixture-key",
            sessionID: "sess-abc-123",
            text: "こんにちは"
        )

        XCTAssertEqual(MockURLProtocol.requestedURLs.last?.path, "/api/sessions/sess-abc-123/messages")
        XCTAssertEqual(MockURLProtocol.requestedMethods.last, "POST")
        XCTAssertEqual(MockURLProtocol.lastRequestHeaders?["Authorization"], "Bearer correct-fixture-key")
        XCTAssertEqual(MockURLProtocol.lastRequestHeaders?["Content-Type"], "application/json")

        // The one recorder that only this client can meaningfully exercise. Decoded
        // rather than string-compared: JSON key order and escaping are not part of the
        // contract, the resulting `text` value is.
        let body = MockURLProtocol.requestedBodies.last ?? nil
        let decoded = try? JSONDecoder().decode([String: String].self, from: body ?? Data())
        XCTAssertEqual(decoded?["text"], "こんにちは")
    }

    /// Negative control for the body assertion above. `requestedBodies` is read from
    /// `httpBodyStream`, and the failure mode it exists to prevent is silent: a version
    /// that read `httpBody` instead would record `nil` for every request, and the test
    /// above would still "pass" its own decode only by accident. Two different texts
    /// must produce two different recordings -- if they do not, the recorder is not
    /// recording.
    func testTwoDifferentTextsProduceTwoDifferentRecordedBodiesNegativeControl() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 202, body: Data(Self.okBody.utf8))]
        _ = await SendClient(session: MockURLProtocol.makeSession())
            .send(baseURL: baseURL, apiKey: "k", sessionID: "s", text: "first")
        MockURLProtocol.stubQueue = [.init(statusCode: 202, body: Data(Self.okBody.utf8))]
        _ = await SendClient(session: MockURLProtocol.makeSession())
            .send(baseURL: baseURL, apiKey: "k", sessionID: "s", text: "second")

        XCTAssertEqual(MockURLProtocol.requestedBodies.count, 2)
        XCTAssertNotNil(MockURLProtocol.requestedBodies.first ?? nil)
        XCTAssertNotEqual(MockURLProtocol.requestedBodies.first ?? nil, MockURLProtocol.requestedBodies.last ?? nil)
    }

    /// The fourth recorded dimension (2026-08-06). ★A send keeps the LONG timeout on
    /// purpose. The reads were shortened to 8s because re-issuing a read is free; a
    /// send is not free to re-issue. `POST /api/sessions/<id>/messages` carries no
    /// idempotency key (checked against `server.mjs` the same day -- it resolves a
    /// pane and calls the injector), so a client that gives up early cannot tell
    /// "never arrived" from "arrived and the reply is slow", and the retry types the
    /// user's message into Claude's composer a second time.
    /// What `requestedTimeouts` does and does not prove: see `RequestTimeoutTests`.
    func testSendKeepsTheWriteTimeoutRatherThanTheShortenedReadTimeout() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 202, body: Data(Self.okBody.utf8))]
        let client = SendClient(session: MockURLProtocol.makeSession())

        _ = await client.send(baseURL: baseURL, apiKey: "k", sessionID: "s", text: "こんにちは")

        XCTAssertEqual(MockURLProtocol.requestedTimeouts, [BackendSession.writeTimeout])
        XCTAssertGreaterThan(BackendSession.writeTimeout, BackendSession.interactiveTimeout)
    }

    /// The text goes on the wire exactly as typed. The phone does NOT trim: `server.mjs`
    /// trims, and a phone that also trimmed would be a second place deciding what the
    /// user's message is -- the difference becomes visible the day the two disagree
    /// about, say, a trailing newline that the user put there on purpose.
    func testTextIsSentUntrimmed() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 202, body: Data(Self.okBody.utf8))]
        let client = SendClient(session: MockURLProtocol.makeSession())

        _ = await client.send(baseURL: baseURL, apiKey: "k", sessionID: "s", text: "  padded  ")

        let body = MockURLProtocol.requestedBodies.last ?? nil
        let decoded = try? JSONDecoder().decode([String: String].self, from: body ?? Data())
        XCTAssertEqual(decoded?["text"], "  padded  ")
    }

    // MARK: - The display table (brief §3-b), bodies copied from `view.mjs`

    func testEveryDisplayBranchIsCarriedThroughVerbatim() async {
        // 401 is deliberately absent: it is a ROUTE decision taken from the status
        // before any `display` is looked for (brief §0-c ①), so it has no row in a
        // display table. Its own test is below.
        let cases: [(name: String, status: Int, body: String, kind: String, text: String, keepText: Bool?)] = [
            (
                name: "202 + delivered:verified",
                status: 202,
                body: #"{"accepted":true,"delivered":"verified","display":{"kind":"ok","text":"送った","keepText":false}}"#,
                kind: "ok", text: "送った", keepText: false
            ),
            (
                name: "202 + worker route",
                status: 202,
                body: #"{"accepted":true,"route":"worker","display":{"kind":"ok","text":"送った(ワーカー)","keepText":false}}"#,
                kind: "ok", text: "送った(ワーカー)", keepText: false
            ),
            (
                name: "202 + delivered:unverified",
                status: 202,
                body: #"{"accepted":true,"delivered":"unverified","display":{"kind":"warn","text":"入れた形跡が確認できません。本文は残してあります。送り直すと二重に入ることがあります。","keepText":true}}"#,
                kind: "warn",
                text: "入れた形跡が確認できません。本文は残してあります。送り直すと二重に入ることがあります。",
                keepText: true
            ),
            (
                name: "409 refused",
                status: 409,
                body: #"{"error":"busy","display":{"kind":"refused","text":"今は入れられません","keepText":true}}"#,
                kind: "refused", text: "今は入れられません", keepText: true
            ),
            (
                name: "400 with internal English",
                status: 400,
                body: #"{"error":"text required","display":{"kind":"error","text":"text required","keepText":true}}"#,
                kind: "error", text: "text required", keepText: true
            ),
            (
                name: "500",
                status: 500,
                body: #"{"error":"internal","display":{"kind":"error","text":"机の側で失敗しました","keepText":true}}"#,
                kind: "error", text: "机の側で失敗しました", keepText: true
            ),
        ]

        for c in cases {
            MockURLProtocol.reset()
            MockURLProtocol.stubQueue = [.init(statusCode: c.status, body: Data(c.body.utf8))]
            let outcome = await SendClient(session: MockURLProtocol.makeSession())
                .send(baseURL: baseURL, apiKey: "k", sessionID: "s", text: "t")

            guard case .display(let display) = outcome else {
                XCTFail("\(c.name): expected .display, got \(outcome)")
                continue
            }
            XCTAssertEqual(display.kind, c.kind, c.name)
            XCTAssertEqual(display.text, c.text, c.name)
            XCTAssertEqual(display.keepText, c.keepText, c.name)
        }
    }

    /// The 400 row above, stated as its own claim so it cannot be lost in a table edit:
    /// the server's internal English reaches the phone untranslated. Brief §0-c ④ --
    /// translating it here would put the wording of an error in two files.
    func testInternalEnglishFrom400IsNotLocalizedByThePhone() async {
        MockURLProtocol.stubQueue = [
            .init(statusCode: 400, body: Data(#"{"error":"text required","display":{"kind":"error","text":"text required","keepText":true}}"#.utf8))
        ]

        let outcome = await SendClient(session: MockURLProtocol.makeSession())
            .send(baseURL: baseURL, apiKey: "k", sessionID: "s", text: "")

        XCTAssertEqual(outcome, .display(ResultDisplay(kind: "error", text: "text required", keepText: true)))
    }

    /// An unknown `kind` must still deliver its text (brief §0-c ⑥). If `kind` were a
    /// strict `Decodable` enum this would throw, the whole `display` would be lost, and
    /// a perfectly readable server message would be replaced by "could not read the
    /// response."
    func testUnknownKindStillCarriesItsTextAndFallsBackToWarnTone() async {
        MockURLProtocol.stubQueue = [
            .init(statusCode: 202, body: Data(#"{"display":{"kind":"quarantined","text":"新しい状態です","keepText":true}}"#.utf8))
        ]

        let outcome = await SendClient(session: MockURLProtocol.makeSession())
            .send(baseURL: baseURL, apiKey: "k", sessionID: "s", text: "t")

        guard case .display(let display) = outcome else {
            return XCTFail("expected .display, got \(outcome)")
        }
        XCTAssertEqual(display.text, "新しい状態です")
        XCTAssertEqual(display.tone, .warn)
    }

    /// Negative control for the tone fallback: `.warn` must be a real decision, not the
    /// value every unknown-shaped input happens to produce. A known `kind` must map to
    /// something else.
    func testToneIsNotAlwaysWarnNegativeControl() {
        XCTAssertEqual(ResultDisplay(kind: "ok", text: "x", keepText: nil).tone, .ok)
        XCTAssertEqual(ResultDisplay(kind: "refused", text: "x", keepText: nil).tone, .refused)
        XCTAssertEqual(ResultDisplay(kind: "error", text: "x", keepText: nil).tone, .error)
        XCTAssertEqual(ResultDisplay(kind: "unheard-of", text: "x", keepText: nil).tone, .warn)
    }

    // MARK: - The two recovery decisions

    func testStatus401IsUnauthorizedWithoutConsultingTheBody() async {
        // Body deliberately carries a `display` the phone must NOT act on: 401 is
        // settled before display is looked for. If the implementation ever reordered
        // those two, this returns `.display` instead and the route to Key-entry is gone.
        MockURLProtocol.stubQueue = [
            .init(statusCode: 401, body: Data(#"{"error":"unauthorized","code":"AUTH_REQUIRED","display":{"kind":"error","text":"鍵が違います","keepText":true}}"#.utf8))
        ]

        let outcome = await SendClient(session: MockURLProtocol.makeSession())
            .send(baseURL: baseURL, apiKey: "wrong", sessionID: "s", text: "t")

        XCTAssertEqual(outcome, .unauthorized)
    }

    func testStatus404WithSessionNotFoundCodeIsSessionNotFound() async {
        MockURLProtocol.stubQueue = [
            .init(statusCode: 404, body: Data(#"{"error":"unknown session","code":"SESSION_NOT_FOUND"}"#.utf8))
        ]

        let outcome = await SendClient(session: MockURLProtocol.makeSession())
            .send(baseURL: baseURL, apiKey: "k", sessionID: "gone", text: "t")

        XCTAssertEqual(outcome, .sessionNotFound)
    }

    func testStatus404WithNoSuchRouteCodeIsContractViolation() async {
        MockURLProtocol.stubQueue = [
            .init(statusCode: 404, body: Data(#"{"error":"not found","code":"NO_SUCH_ROUTE"}"#.utf8))
        ]

        let outcome = await SendClient(session: MockURLProtocol.makeSession())
            .send(baseURL: baseURL, apiKey: "k", sessionID: "s", text: "t")

        XCTAssertEqual(
            outcome,
            .contractViolation(ResponseContractViolation(status: 404, code: "NO_SUCH_ROUTE"))
        )
    }

    /// ★The negative control the whole 404 narrowing exists for. Both bodies are 404s;
    /// only the code differs; the outcomes must differ. A `case 404: return
    /// .sessionNotFound` -- the shape this app shipped until today -- makes these equal,
    /// and every other test in this file still passes.
    func testTheTwo404MeaningsAreNotCollapsedNegativeControl() async {
        MockURLProtocol.stubQueue = [
            .init(statusCode: 404, body: Data(#"{"error":"unknown session","code":"SESSION_NOT_FOUND"}"#.utf8))
        ]
        let gone = await SendClient(session: MockURLProtocol.makeSession())
            .send(baseURL: baseURL, apiKey: "k", sessionID: "s", text: "t")
        MockURLProtocol.stubQueue = [
            .init(statusCode: 404, body: Data(#"{"error":"not found","code":"NO_SUCH_ROUTE"}"#.utf8))
        ]
        let badPath = await SendClient(session: MockURLProtocol.makeSession())
            .send(baseURL: baseURL, apiKey: "k", sessionID: "s", text: "t")

        XCTAssertNotEqual(gone, badPath)
    }

    // MARK: - Contract violations

    /// ★§3-a control 1: a 200 that carries no `display` must not leave the screen
    /// silent. The failure this prevents is the quiet one -- a send that produces no
    /// banner at all reads to the user as "nothing happened", which is the single thing
    /// this app must never say about a message that may well have been delivered.
    func testResponseWithNoDisplayIsAContractViolation() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(#"{"accepted":true}"#.utf8))]

        let outcome = await SendClient(session: MockURLProtocol.makeSession())
            .send(baseURL: baseURL, apiKey: "k", sessionID: "s", text: "t")

        XCTAssertEqual(outcome, .contractViolation(ResponseContractViolation(status: 200, code: nil)))
    }

    /// The §3-b table's 「本文なし」 row: not merely a missing `display` key but a
    /// zero-byte body. Separated because the two reach the same guard by different
    /// routes (decode-returns-nil vs decode-throws), and only one of them exercises
    /// `try?`'s error path.
    func testCompletelyEmptyBodyIsAContractViolation() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 202, body: Data())]

        let outcome = await SendClient(session: MockURLProtocol.makeSession())
            .send(baseURL: baseURL, apiKey: "k", sessionID: "s", text: "t")

        XCTAssertEqual(outcome, .contractViolation(ResponseContractViolation(status: 202, code: nil)))
    }

    /// A `display` object missing its `text` is not a display. Decoding must fail, and
    /// failing must land here rather than producing an empty banner -- a banner with no
    /// words is indistinguishable from a successful send that said nothing.
    func testDisplayWithoutTextIsAContractViolation() async {
        MockURLProtocol.stubQueue = [
            .init(statusCode: 202, body: Data(#"{"display":{"kind":"ok","keepText":false}}"#.utf8))
        ]

        let outcome = await SendClient(session: MockURLProtocol.makeSession())
            .send(baseURL: baseURL, apiKey: "k", sessionID: "s", text: "t")

        XCTAssertEqual(outcome, .contractViolation(ResponseContractViolation(status: 202, code: nil)))
    }

    func testCompletelyUnparseableBodyIsAContractViolation() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 502, body: Data("<html>bad gateway</html>".utf8))]

        let outcome = await SendClient(session: MockURLProtocol.makeSession())
            .send(baseURL: baseURL, apiKey: "k", sessionID: "s", text: "t")

        XCTAssertEqual(outcome, .contractViolation(ResponseContractViolation(status: 502, code: nil)))
    }

    /// The violation must carry the status it actually saw. Without this, a single
    /// hardcoded status would satisfy every test above and the log line -- the only
    /// countable half of brief §0-c ③ -- would report the same number forever.
    func testContractViolationCarriesTheObservedStatusNegativeControl() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 502, body: Data("x".utf8))]
        let a = await SendClient(session: MockURLProtocol.makeSession())
            .send(baseURL: baseURL, apiKey: "k", sessionID: "s", text: "t")
        MockURLProtocol.stubQueue = [.init(statusCode: 418, body: Data("x".utf8))]
        let b = await SendClient(session: MockURLProtocol.makeSession())
            .send(baseURL: baseURL, apiKey: "k", sessionID: "s", text: "t")

        XCTAssertNotEqual(a, b)
    }

    /// A contract violation and a real display must not collapse into one another --
    /// the two lead to opposite user actions (check the desk vs. read what happened).
    func testContractViolationIsNotCollapsedIntoDisplayNegativeControl() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 202, body: Data(#"{"accepted":true}"#.utf8))]
        let violation = await SendClient(session: MockURLProtocol.makeSession())
            .send(baseURL: baseURL, apiKey: "k", sessionID: "s", text: "t")
        MockURLProtocol.stubQueue = [.init(statusCode: 202, body: Data(Self.okBody.utf8))]
        let display = await SendClient(session: MockURLProtocol.makeSession())
            .send(baseURL: baseURL, apiKey: "k", sessionID: "s", text: "t")

        XCTAssertNotEqual(violation, display)
    }

    // MARK: - Transport

    func testConnectionFailureIsUnreachable() async {
        MockURLProtocol.stubQueue = []

        let outcome = await SendClient(session: MockURLProtocol.makeSession())
            .send(baseURL: baseURL, apiKey: "k", sessionID: "s", text: "t")

        XCTAssertEqual(outcome, .unreachable)
    }

    func testInjectedURLErrorCancelledMapsToCancelled() async {
        MockURLProtocol.injectedError = URLError(.cancelled)

        let outcome = await SendClient(session: MockURLProtocol.makeSession())
            .send(baseURL: baseURL, apiKey: "k", sessionID: "s", text: "t")

        XCTAssertEqual(outcome, .cancelled)
    }

    func testRealTaskCancellationMapsToCancelled() async {
        MockURLProtocol.deliveryDelay = 0.3
        MockURLProtocol.stubQueue = [.init(statusCode: 202, body: Data(Self.okBody.utf8))]
        let client = SendClient(session: MockURLProtocol.makeSession())

        let task = Task { await client.send(baseURL: baseURL, apiKey: "k", sessionID: "s", text: "t") }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let outcome = await task.value

        XCTAssertEqual(outcome, .cancelled)
    }

    /// Cancelled must not read as unreachable. They lead to different composer
    /// behaviour -- one shows a "could not confirm" banner, the other shows nothing at
    /// all -- and folding them would put a scary warning on every screen dismissal.
    func testCancelledIsNotCollapsedIntoUnreachableNegativeControl() async {
        MockURLProtocol.injectedError = URLError(.cancelled)
        let cancelled = await SendClient(session: MockURLProtocol.makeSession())
            .send(baseURL: baseURL, apiKey: "k", sessionID: "s", text: "t")
        MockURLProtocol.stubQueue = []
        let unreachable = await SendClient(session: MockURLProtocol.makeSession())
            .send(baseURL: baseURL, apiKey: "k", sessionID: "s", text: "t")

        XCTAssertNotEqual(cancelled, unreachable)
    }

    // MARK: - Fixture

    private static let okBody = #"{"accepted":true,"delivered":"verified","display":{"kind":"ok","text":"送った","keepText":false}}"#
}
