import XCTest
@testable import RemoteMini

/// `InterruptClient.interrupt` -- Sprint 6's only network client.
///
/// The question this suite is built around is narrower than `SendClientTests`'s. There
/// is no draft to protect and no `keepText` rule; what there IS, and what the send path
/// does not have, is a wire body full of tempting raw fields (`interrupted`, `stopped`,
/// `route`, `pane`) that the phone must not read. On 2026-08-03 the SERVER got exactly
/// that distinction wrong -- `interrupted: true` meant "Escape was pressed", and the
/// text printed for it was 「止めました(Escape)。」 while nothing had stopped. The
/// server now renders six separate sentences (`view.mjs`'s `interruptResult`, covered
/// branch by branch in `rc-backend/test/view.test.mjs`), so the phone's job is the
/// single property those tests cannot check from their side: **whatever the raw fields
/// say, the sentence shown is `display.text`.** The precedence and blindness controls
/// below are that property.
// not-a-port: JS の検査を名指ししているのは「あちらが見られない性質」を指す為で、移植ではない。
// 生の欄が何であれ表示は display.text である事だけを測るので、あちらに対応する行は無い。
final class InterruptClientTests: XCTestCase {
    private let baseURL = URL(string: "https://unit-test.invalid")!

    override func setUp() { MockURLProtocol.reset() }
    override func tearDown() { MockURLProtocol.reset() }

    // MARK: - Request shape

    func testRequestIsAPOSTToTheInterruptPathWithTheBearerKey() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(Self.verifiedBody.utf8))]

        _ = await InterruptClient(session: MockURLProtocol.makeSession())
            .interrupt(baseURL: baseURL, apiKey: "correct-fixture-key", sessionID: "sess-abc-123")

        XCTAssertEqual(MockURLProtocol.requestedURLs.last?.path, "/api/sessions/sess-abc-123/interrupt")
        XCTAssertEqual(MockURLProtocol.requestedMethods.last, "POST")
        XCTAssertEqual(MockURLProtocol.lastRequestHeaders?["Authorization"], "Bearer correct-fixture-key")
    }

    /// ★No body and no `Content-Type`. The server's handler reads nothing from the
    /// request past the path, so sending `{}` anyway would invent a shape someone later
    /// "fixes" by adding a field to.
    ///
    /// The absence is asserted against a control in the same test, because an empty
    /// recording is exactly what a BROKEN recorder produces: `requestedBodies` reads
    /// from `httpBodyStream` (see `MockURLProtocol.readBody`), and a version that read
    /// `httpBody` would record `nil` for every request in this tree -- making this
    /// assertion pass while measuring nothing. So a `SendClient` POST goes through the
    /// same fixture first and must record a non-nil body.
    func testRequestCarriesNoBodyAndNoContentTypeWithAWorkingRecorderAsControl() async {
        MockURLProtocol.stubQueue = [
            .init(statusCode: 202, body: Data(#"{"display":{"kind":"ok","text":"送った","keepText":false}}"#.utf8))
        ]
        _ = await SendClient(session: MockURLProtocol.makeSession())
            .send(baseURL: baseURL, apiKey: "k", sessionID: "s", text: "control")
        XCTAssertNotNil(
            MockURLProtocol.requestedBodies.last ?? nil,
            "control: the recorder can see a body when one is sent -- without this the assertion below is vacuous"
        )

        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(Self.verifiedBody.utf8))]
        _ = await InterruptClient(session: MockURLProtocol.makeSession())
            .interrupt(baseURL: baseURL, apiKey: "k", sessionID: "s")

        XCTAssertNil(MockURLProtocol.requestedBodies.last ?? nil, "no request body at all")
        XCTAssertNil(MockURLProtocol.lastRequestHeaders?["Content-Type"], "…and therefore no Content-Type")
    }

    /// The fourth recorded dimension (2026-08-06). ★An interrupt keeps the LONG
    /// timeout on purpose, even though the user is waiting on it. Shortening the
    /// give-up window on a write does not cancel the write -- it only removes the
    /// client's knowledge of whether it landed, and this endpoint carries no
    /// idempotency key, so a retry after a premature give-up is a second interrupt.
    /// What `requestedTimeouts` does and does not prove: see `RequestTimeoutTests`.
    func testInterruptKeepsTheWriteTimeoutRatherThanTheShortenedReadTimeout() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(Self.verifiedBody.utf8))]

        _ = await InterruptClient(session: MockURLProtocol.makeSession())
            .interrupt(baseURL: baseURL, apiKey: "k", sessionID: "s")

        XCTAssertEqual(MockURLProtocol.requestedTimeouts, [BackendSession.writeTimeout])
        XCTAssertGreaterThan(BackendSession.writeTimeout, BackendSession.interactiveTimeout)
    }

    /// N5 (spec §3-7). `InterruptClient` takes a `BackendSession`, never a bare
    /// `URLSession`, so possessing one IS the proof that redirects are refused --
    /// `BackendSession`'s initializer installs `RedirectRefusingDelegate` itself and
    /// accepts no foreign session. This asserts the fixture these tests run through is
    /// that same type with that same delegate, i.e. that this suite exercises a session
    /// shaped like production rather than a delegate-less one (the Sprint 1 evaluator's
    /// Finding 1, which is what put the constraint in the type system).
    func testTheSessionThisClientTakesIsTheRedirectRefusingOne() {
        XCTAssertTrue(MockURLProtocol.makeSession().session.delegate is RedirectRefusingDelegate)
        XCTAssertTrue(BackendSession.shared.session.delegate is RedirectRefusingDelegate, "…and so is the default")
    }

    // MARK: - ★The one property only the phone side can check

    /// The raw fields and `display.text` are made to CONTRADICT each other, with the
    /// raw fields carrying the reading that was wrong in the 2026-08-03 bug
    /// (`interrupted:true` + `stopped:"verified"` = "it stopped") and `display` carrying
    /// the opposite sentence. The phone must show the sentence.
    func testDisplayTextWinsOverTheRawFieldsThatContradictIt() async {
        MockURLProtocol.stubQueue = [
            .init(statusCode: 200, body: Data(#"""
            {"interrupted":true,"stopped":"verified","route":"tmux","pane":"p",
             "display":{"kind":"warn","text":"止める対象がありませんでした。"}}
            """#.utf8))
        ]

        let outcome = await InterruptClient(session: MockURLProtocol.makeSession())
            .interrupt(baseURL: baseURL, apiKey: "k", sessionID: "s")

        guard case .display(let display) = outcome else { return XCTFail("expected .display, got \(outcome)") }
        XCTAssertEqual(display.text, "止める対象がありませんでした。", "the server's sentence, not the phone's reading of `stopped`")
        XCTAssertEqual(display.tone, .warn)
    }

    /// ★The blindness control, and the stronger half of the pair. Two responses whose
    /// raw fields differ in every way that matters -- one is the worker route with no
    /// `stopped` key at all, the other is tmux with `stopped:null` -- but whose
    /// `display` is byte-identical. If the client consulted ANY raw field, these two
    /// would not come out equal.
    ///
    /// (That the two really do get different sentences from the server is already
    /// asserted on the server side, `rc-backend/test/view.test.mjs`. Re-asserting it
    /// here would be the phone re-deriving the thing this test exists to forbid.)
    func testTwoWildlyDifferentRawBodiesWithTheSameDisplayProduceTheSameOutcome() async {
        MockURLProtocol.stubQueue = [
            .init(statusCode: 200, body: Data(#"{"interrupted":true,"route":"worker","display":{"kind":"ok","text":"同じ文","keepText":false}}"#.utf8))
        ]
        let worker = await InterruptClient(session: MockURLProtocol.makeSession())
            .interrupt(baseURL: baseURL, apiKey: "k", sessionID: "s")

        MockURLProtocol.stubQueue = [
            .init(statusCode: 200, body: Data(#"{"interrupted":false,"stopped":null,"route":"tmux","pane":"%9","display":{"kind":"ok","text":"同じ文","keepText":false}}"#.utf8))
        ]
        let tmux = await InterruptClient(session: MockURLProtocol.makeSession())
            .interrupt(baseURL: baseURL, apiKey: "k", sessionID: "s")

        XCTAssertEqual(worker, tmux, "no raw field may reach the outcome")
        XCTAssertEqual(worker, .display(ResultDisplay(kind: "ok", text: "同じ文", keepText: false)))
    }

    /// The other direction: identical raw fields, different `display.text`, different
    /// outcomes. Together with the test above this pins the outcome to `display` and to
    /// nothing else -- one shows the raw fields cannot make two outcomes differ, this
    /// shows `display` alone can.
    func testTheSameRawFieldsWithDifferentDisplayTextProduceDifferentOutcomes() async {
        let raw = #"{"interrupted":true,"stopped":"verified","route":"tmux"#

        MockURLProtocol.stubQueue = [
            .init(statusCode: 200, body: Data((raw + #"","display":{"kind":"ok","text":"止めました(生成が止まったのを確認)。"}}"#).utf8))
        ]
        let a = await InterruptClient(session: MockURLProtocol.makeSession())
            .interrupt(baseURL: baseURL, apiKey: "k", sessionID: "s")

        MockURLProtocol.stubQueue = [
            .init(statusCode: 200, body: Data((raw + #"","display":{"kind":"ok","text":"押した時には終わっていました(止めるものは残っていません)。"}}"#).utf8))
        ]
        let b = await InterruptClient(session: MockURLProtocol.makeSession())
            .interrupt(baseURL: baseURL, apiKey: "k", sessionID: "s")

        XCTAssertNotEqual(a, b)
    }

    /// Non-200 statuses still carry a `display`: `server.mjs`'s `json()` injects one
    /// into any body that lacks it, so 409 (refused) and 5xx are display-bearing on this
    /// route, not error shapes to be worded locally. A client that treated "not 2xx" as
    /// a failure would replace the server's own refusal sentence with a phone-composed
    /// one -- and 409's text is `b.error`, i.e. the specific reason.
    func testNon2xxResponsesThatCarryADisplayAreStillDisplayOutcomes() async {
        let rows: [(status: Int, body: String, kind: String, text: String, tone: ResultDisplay.Tone)] = [
            (409, #"{"error":"別の操作が進行中です","display":{"kind":"refused","text":"別の操作が進行中です"}}"#,
             "refused", "別の操作が進行中です", .refused),
            (503, #"{"display":{"kind":"error","text":"サーバ側で失敗しました(HTTP 503)。"}}"#,
             "error", "サーバ側で失敗しました(HTTP 503)。", .error),
        ]

        for row in rows {
            MockURLProtocol.stubQueue = [.init(statusCode: row.status, body: Data(row.body.utf8))]
            let outcome = await InterruptClient(session: MockURLProtocol.makeSession())
                .interrupt(baseURL: baseURL, apiKey: "k", sessionID: "s")

            guard case .display(let display) = outcome else {
                return XCTFail("HTTP \(row.status): expected .display, got \(outcome)")
            }
            XCTAssertEqual(display.text, row.text, "HTTP \(row.status)")
            XCTAssertEqual(display.tone, row.tone, "HTTP \(row.status)")
        }
    }

    /// An unknown `kind` must still deliver its text, same rule as every other display
    /// path: a future server release adding a fifth tone must not cost the user the
    /// sentence.
    func testUnknownKindStillCarriesItsTextAndFallsBackToWarnTone() async {
        MockURLProtocol.stubQueue = [
            .init(statusCode: 200, body: Data(#"{"interrupted":true,"display":{"kind":"quarantined","text":"新しい状態です"}}"#.utf8))
        ]

        let outcome = await InterruptClient(session: MockURLProtocol.makeSession())
            .interrupt(baseURL: baseURL, apiKey: "k", sessionID: "s")

        guard case .display(let display) = outcome else { return XCTFail("expected .display, got \(outcome)") }
        XCTAssertEqual(display.text, "新しい状態です")
        XCTAssertEqual(display.tone, .warn)
    }

    // MARK: - The two recovery decisions

    func testStatus401IsUnauthorizedWithoutConsultingTheBody() async {
        // The body carries a perfectly good `display` (401 is a display-bearing status
        // on this route too, `interruptResult` renders 「鍵が通りませんでした。」). Acting
        // on it would show that sentence over an intact screen and never route to
        // Key-entry -- the credentials would stay wrong forever.
        MockURLProtocol.stubQueue = [
            .init(statusCode: 401, body: Data(#"{"error":"unauthorized","code":"AUTH_REQUIRED","display":{"kind":"error","text":"鍵が通りませんでした。"}}"#.utf8))
        ]

        let outcome = await InterruptClient(session: MockURLProtocol.makeSession())
            .interrupt(baseURL: baseURL, apiKey: "wrong", sessionID: "s")

        XCTAssertEqual(outcome, .unauthorized)
    }

    func testStatus404WithSessionNotFoundCodeIsSessionNotFound() async {
        MockURLProtocol.stubQueue = [
            .init(statusCode: 404, body: Data(#"{"error":"unknown session","code":"SESSION_NOT_FOUND"}"#.utf8))
        ]

        let outcome = await InterruptClient(session: MockURLProtocol.makeSession())
            .interrupt(baseURL: baseURL, apiKey: "k", sessionID: "gone")

        XCTAssertEqual(outcome, .sessionNotFound)
    }

    func testStatus404WithNoSuchRouteCodeIsContractViolation() async {
        MockURLProtocol.stubQueue = [
            .init(statusCode: 404, body: Data(#"{"error":"not found","code":"NO_SUCH_ROUTE"}"#.utf8))
        ]

        let outcome = await InterruptClient(session: MockURLProtocol.makeSession())
            .interrupt(baseURL: baseURL, apiKey: "k", sessionID: "s")

        XCTAssertEqual(outcome, .contractViolation(ResponseContractViolation(status: 404, code: "NO_SUCH_ROUTE")))
    }

    /// ★Both 404 shapes genuinely exist on this route -- `SESSION_NOT_FOUND` from the
    /// session lookup that runs before the action dispatch, `NO_SUCH_ROUTE` from a path
    /// the phone built wrong. Collapsing them (`case 404: return .sessionNotFound`)
    /// would tell the user their conversation was deleted whenever the phone mistyped
    /// its own URL: the most likely bug hidden behind the most plausible lie.
    func testTheTwo404MeaningsAreNotCollapsedNegativeControl() async {
        MockURLProtocol.stubQueue = [
            .init(statusCode: 404, body: Data(#"{"code":"SESSION_NOT_FOUND"}"#.utf8))
        ]
        let gone = await InterruptClient(session: MockURLProtocol.makeSession())
            .interrupt(baseURL: baseURL, apiKey: "k", sessionID: "s")

        MockURLProtocol.stubQueue = [
            .init(statusCode: 404, body: Data(#"{"code":"NO_SUCH_ROUTE"}"#.utf8))
        ]
        let badPath = await InterruptClient(session: MockURLProtocol.makeSession())
            .interrupt(baseURL: baseURL, apiKey: "k", sessionID: "s")

        XCTAssertNotEqual(gone, badPath)
    }

    // MARK: - Contract violations

    /// A 200 with no `display` must not leave the screen silent. This is the quiet
    /// failure the whole contract-violation branch exists for: an interrupt that
    /// produces no banner reads as "nothing happened", and Escape may well have landed.
    func testResponseWithNoDisplayIsAContractViolation() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(#"{"interrupted":true,"stopped":"verified"}"#.utf8))]

        let outcome = await InterruptClient(session: MockURLProtocol.makeSession())
            .interrupt(baseURL: baseURL, apiKey: "k", sessionID: "s")

        XCTAssertEqual(outcome, .contractViolation(ResponseContractViolation(status: 200, code: nil)))
    }

    /// ★And it must stay a violation even though the raw fields alone would be enough
    /// to compose a sentence from. This is the temptation this client is written to
    /// refuse: `interrupted:true, stopped:"verified"` above is exactly the shape a
    /// "helpful" fallback would render as 「止めました」 -- rebuilding the 2026-08-03 bug
    /// on the phone's side of the wire, and doing it precisely when the server had
    /// stopped speaking.
    func testAMissingDisplayIsNotBackfilledFromTheRawFieldsNegativeControl() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(#"{"interrupted":true,"stopped":"verified"}"#.utf8))]
        let noDisplay = await InterruptClient(session: MockURLProtocol.makeSession())
            .interrupt(baseURL: baseURL, apiKey: "k", sessionID: "s")

        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(Self.verifiedBody.utf8))]
        let withDisplay = await InterruptClient(session: MockURLProtocol.makeSession())
            .interrupt(baseURL: baseURL, apiKey: "k", sessionID: "s")

        XCTAssertNotEqual(noDisplay, withDisplay, "identical raw fields, and only the one carrying `display` may speak")
        if case .display = noDisplay { XCTFail("a display was manufactured from the raw fields") }
    }

    func testCompletelyEmptyBodyIsAContractViolation() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data())]

        let outcome = await InterruptClient(session: MockURLProtocol.makeSession())
            .interrupt(baseURL: baseURL, apiKey: "k", sessionID: "s")

        XCTAssertEqual(outcome, .contractViolation(ResponseContractViolation(status: 200, code: nil)))
    }

    func testDisplayWithoutTextIsAContractViolation() async {
        MockURLProtocol.stubQueue = [
            .init(statusCode: 200, body: Data(#"{"interrupted":true,"display":{"kind":"ok"}}"#.utf8))
        ]

        let outcome = await InterruptClient(session: MockURLProtocol.makeSession())
            .interrupt(baseURL: baseURL, apiKey: "k", sessionID: "s")

        XCTAssertEqual(outcome, .contractViolation(ResponseContractViolation(status: 200, code: nil)))
    }

    func testCompletelyUnparseableBodyIsAContractViolation() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 502, body: Data("<html>bad gateway</html>".utf8))]

        let outcome = await InterruptClient(session: MockURLProtocol.makeSession())
            .interrupt(baseURL: baseURL, apiKey: "k", sessionID: "s")

        XCTAssertEqual(outcome, .contractViolation(ResponseContractViolation(status: 502, code: nil)))
    }

    /// The violation must carry the status it actually saw -- that number is the whole
    /// of what the log line can count, so a hardcoded one would make every violation
    /// look like the same violation forever.
    func testContractViolationCarriesTheObservedStatusNegativeControl() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 502, body: Data("x".utf8))]
        let a = await InterruptClient(session: MockURLProtocol.makeSession())
            .interrupt(baseURL: baseURL, apiKey: "k", sessionID: "s")
        MockURLProtocol.stubQueue = [.init(statusCode: 418, body: Data("x".utf8))]
        let b = await InterruptClient(session: MockURLProtocol.makeSession())
            .interrupt(baseURL: baseURL, apiKey: "k", sessionID: "s")

        XCTAssertNotEqual(a, b)
    }

    // MARK: - Transport

    func testConnectionFailureIsUnreachable() async {
        MockURLProtocol.stubQueue = []

        let outcome = await InterruptClient(session: MockURLProtocol.makeSession())
            .interrupt(baseURL: baseURL, apiKey: "k", sessionID: "s")

        XCTAssertEqual(outcome, .unreachable)
    }

    func testInjectedURLErrorCancelledMapsToCancelled() async {
        MockURLProtocol.injectedError = URLError(.cancelled)

        let outcome = await InterruptClient(session: MockURLProtocol.makeSession())
            .interrupt(baseURL: baseURL, apiKey: "k", sessionID: "s")

        XCTAssertEqual(outcome, .cancelled)
    }

    func testRealTaskCancellationMapsToCancelled() async {
        MockURLProtocol.deliveryDelay = 0.3
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(Self.verifiedBody.utf8))]
        let client = InterruptClient(session: MockURLProtocol.makeSession())

        let task = Task { await client.interrupt(baseURL: baseURL, apiKey: "k", sessionID: "s") }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let outcome = await task.value

        XCTAssertEqual(outcome, .cancelled)
    }

    /// Cancelled must not read as unreachable: one shows a "止められたか確認できません"
    /// warning, the other shows nothing at all, so folding them would put a scary
    /// warning on every screen dismissal.
    func testCancelledIsNotCollapsedIntoUnreachableNegativeControl() async {
        MockURLProtocol.injectedError = URLError(.cancelled)
        let cancelled = await InterruptClient(session: MockURLProtocol.makeSession())
            .interrupt(baseURL: baseURL, apiKey: "k", sessionID: "s")
        MockURLProtocol.stubQueue = []
        let unreachable = await InterruptClient(session: MockURLProtocol.makeSession())
            .interrupt(baseURL: baseURL, apiKey: "k", sessionID: "s")

        XCTAssertNotEqual(cancelled, unreachable)
    }

    // MARK: - Fixture

    /// `view.mjs`'s `stopped:"verified"` branch, copied rather than paraphrased.
    private static let verifiedBody = #"""
    {"interrupted":true,"stopped":"verified","route":"tmux","pane":"%1",
     "display":{"kind":"ok","text":"止めました(生成が止まったのを確認)。"}}
    """#
}
