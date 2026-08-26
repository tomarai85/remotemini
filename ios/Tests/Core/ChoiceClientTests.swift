import XCTest
@testable import RemoteMini

/// `ChoiceClient.choose` -- Sprint 7's only network client, and the one write whose
/// response carries a fact the other two do not: the fingerprint the screen has **right
/// now**.
///
/// The outcome half (`SendOutcome`'s six cases) is reused unchanged from the send path,
/// so re-asserting every branch here would be a copy of `SendClientTests` that drifts.
/// What this suite is built around instead is the pair of properties that exist only on
/// this route:
///
/// 1. **Nothing in the request is composed by the phone.** `key` and `digest` are echoed
///    from what the server itself handed over. That is what makes 見た物と押す物が同じ
///    hold across the wire rather than only inside the backend.
/// 2. **The staleness decision rides on the fingerprint, never on the wording.** The
///    refusal vocabulary (`digest-mismatch`, `choice-key-not-allowed`,
///    `choice-already-sent`) is the server's choice of words; the fingerprint is the
///    mechanism. `InterruptClient` has the scar that made this a rule -- 2026-08-03, the
///    phone re-deriving "it stopped" from a field that did not mean that.
final class ChoiceClientTests: XCTestCase {
    private let baseURL = URL(string: "https://unit-test.invalid")!

    override func setUp() { MockURLProtocol.reset() }
    override func tearDown() { MockURLProtocol.reset() }

    // MARK: - Request shape

    func testRequestIsAPOSTToTheChoicePathWithTheBearerKeyAndJSONBody() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(Self.acceptedBody.utf8))]

        _ = await ChoiceClient(session: MockURLProtocol.makeSession())
            .choose(baseURL: baseURL, apiKey: "correct-fixture-key",
                    sessionID: "sess-abc-123", key: "2", digest: "d-aaa", confirm: nil)

        XCTAssertEqual(MockURLProtocol.requestedURLs.last?.path, "/api/sessions/sess-abc-123/choice")
        XCTAssertEqual(MockURLProtocol.requestedMethods.last, "POST")
        XCTAssertEqual(MockURLProtocol.lastRequestHeaders?["Authorization"], "Bearer correct-fixture-key")
        XCTAssertEqual(MockURLProtocol.lastRequestHeaders?["Content-Type"], "application/json")
    }

    /// ★The body carries the two values **verbatim**, and carries nothing else.
    ///
    /// Decoded rather than string-matched: asserting on the serialized text would pin
    /// key order, which `JSONEncoder` does not promise, and the property being measured
    /// is what the server reads, not how the bytes were arranged.
    func testBodyEchoesTheKeyAndFingerprintVerbatimAndAddsNothing() async throws {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(Self.acceptedBody.utf8))]

        _ = await ChoiceClient(session: MockURLProtocol.makeSession())
            .choose(baseURL: baseURL, apiKey: "k", sessionID: "s",
                    key: "escape", digest: "sha256:0f1e2d", confirm: nil)

        let raw = try XCTUnwrap(MockURLProtocol.requestedBodies.last ?? nil, "a body was sent")
        let sent = try XCTUnwrap(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
        XCTAssertEqual(sent["key"] as? String, "escape")
        XCTAssertEqual(sent["digest"] as? String, "sha256:0f1e2d")
        XCTAssertEqual(
            Set(sent.keys), ["key", "digest"],
            "a third field would be one the phone composed -- exactly what this route may not do"
        )
    }

    /// The fourth recorded dimension. A keystroke is a write, and the same reasoning as
    /// `InterruptClient`'s applies with more force here: this endpoint carries no
    /// idempotency key, and the server's own repeat guard (`inject.mjs`'s
    /// `choice-already-sent`) is what stops a second press -- shortening the give-up
    /// window would only remove the phone's knowledge of whether the first one landed.
    func testAKeystrokeKeepsTheWriteTimeoutRatherThanTheShortenedReadTimeout() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(Self.acceptedBody.utf8))]

        _ = await ChoiceClient(session: MockURLProtocol.makeSession())
            .choose(baseURL: baseURL, apiKey: "k", sessionID: "s", key: "1", digest: "d", confirm: nil)

        XCTAssertEqual(MockURLProtocol.requestedTimeouts, [BackendSession.writeTimeout])
        XCTAssertGreaterThan(BackendSession.writeTimeout, BackendSession.interactiveTimeout)
    }

    /// N5 (spec §3-7), same proof as the other clients: possessing a `BackendSession` IS
    /// the proof redirects are refused, because that type installs the delegate itself
    /// and accepts no foreign session.
    func testTheSessionThisClientTakesIsTheRedirectRefusingOne() {
        XCTAssertTrue(MockURLProtocol.makeSession().session.delegate is RedirectRefusingDelegate)
        XCTAssertTrue(BackendSession.shared.session.delegate is RedirectRefusingDelegate, "…and so is the default")
    }

    // MARK: - ★The fingerprint, which only this route reports

    /// A 409 attaches the fingerprint the screen has right now. The phone's entire
    /// staleness decision is `serverDigest != theDigestWeSent`, so losing this value
    /// would strand the card in whatever state it was in.
    func testARefusalCarriesTheFingerprintTheScreenHasNow() async {
        MockURLProtocol.stubQueue = [
            .init(statusCode: 409, body: Data(#"""
            {"error":"画面が変わりました","reason":"digest-mismatch","digest":"d-bbb",
             "display":{"kind":"refused","text":"画面が変わりました。何も送っていません。画面を取り直してください。"}}
            """#.utf8))
        ]

        let attempt = await ChoiceClient(session: MockURLProtocol.makeSession())
            .choose(baseURL: baseURL, apiKey: "k", sessionID: "s", key: "1", digest: "d-aaa", confirm: nil)

        XCTAssertEqual(attempt.serverDigest, "d-bbb")
        guard case .display(let display) = attempt.outcome else {
            return XCTFail("expected .display, got \(attempt.outcome)")
        }
        XCTAssertEqual(display.tone, .refused)
    }

    /// ★★The blindness control, and the reason this suite exists at all. Two 409s that
    /// differ **only** in `reason` -- the machine-readable name of the refusal, which the
    /// backend has already reworded once. Everything the user sees is held identical,
    /// because on this route `view.mjs` renders `display.text` from `b.error`; varying
    /// that too would be varying the sentence, which is a different property.
    ///
    /// If any branch ever keys on `reason`, this pair separates.
    func testTwoRefusalsDifferingOnlyInTheirReasonNameDecideTheSame() async {
        let body = { (reason: String) in
            #"{"error":"画面が変わりました","reason":"\#(reason)","digest":"d-same","display":{"kind":"refused","text":"画面が変わりました"}}"#
        }

        MockURLProtocol.stubQueue = [.init(statusCode: 409, body: Data(body("digest-mismatch").utf8))]
        let mismatch = await ChoiceClient(session: MockURLProtocol.makeSession())
            .choose(baseURL: baseURL, apiKey: "k", sessionID: "s", key: "1", digest: "d-old", confirm: nil)

        MockURLProtocol.stubQueue = [.init(statusCode: 409, body: Data(body("choice-already-sent").utf8))]
        let already = await ChoiceClient(session: MockURLProtocol.makeSession())
            .choose(baseURL: baseURL, apiKey: "k", sessionID: "s", key: "1", digest: "d-old", confirm: nil)

        XCTAssertEqual(mismatch, already, "the refusal vocabulary may not reach the outcome")
        XCTAssertEqual(mismatch.serverDigest, "d-same")
    }

    /// The other direction, so the test above cannot pass by the client ignoring the
    /// fingerprint too: identical wording, different fingerprints, different attempts.
    func testTheSameWordingWithDifferentFingerprintsProducesDifferentAttemptsNegativeControl() async {
        let body = { (digest: String) in
            #"{"error":"画面が変わりました","reason":"digest-mismatch","digest":"\#(digest)","display":{"kind":"refused","text":"同じ文"}}"#
        }

        MockURLProtocol.stubQueue = [.init(statusCode: 409, body: Data(body("d-bbb").utf8))]
        let b = await ChoiceClient(session: MockURLProtocol.makeSession())
            .choose(baseURL: baseURL, apiKey: "k", sessionID: "s", key: "1", digest: "d-aaa", confirm: nil)

        MockURLProtocol.stubQueue = [.init(statusCode: 409, body: Data(body("d-ccc").utf8))]
        let c = await ChoiceClient(session: MockURLProtocol.makeSession())
            .choose(baseURL: baseURL, apiKey: "k", sessionID: "s", key: "1", digest: "d-aaa", confirm: nil)

        XCTAssertNotEqual(b, c)
        XCTAssertEqual(b.outcome, c.outcome, "…and it is the fingerprint alone that separates them")
    }

    /// ★An absent fingerprint is "no new information", never "unchanged". A 200 does not
    /// report one, and treating `nil` as confirmation of the digest we sent would mark a
    /// card live off the back of the server saying nothing at all.
    func testAnAcceptedKeystrokeReportsNoFingerprint() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(Self.acceptedBody.utf8))]

        let attempt = await ChoiceClient(session: MockURLProtocol.makeSession())
            .choose(baseURL: baseURL, apiKey: "k", sessionID: "s", key: "1", digest: "d-aaa", confirm: nil)

        XCTAssertNil(attempt.serverDigest)
        guard case .display(let display) = attempt.outcome else {
            return XCTFail("expected .display, got \(attempt.outcome)")
        }
        XCTAssertEqual(display.text, "押しました(画面が変わったのを確認)。")
        XCTAssertEqual(display.tone, .ok)
    }

    /// An empty string is the shape a server bug produces, and `""` compares unequal to
    /// every real fingerprint -- so passing it through would mark the card stale forever
    /// while looking like a value. It is folded to `nil`, i.e. to "nothing was said".
    func testAnEmptyFingerprintIsTreatedAsNothingSaidRatherThanAsAValue() async {
        MockURLProtocol.stubQueue = [
            .init(statusCode: 409, body: Data(#"{"digest":"","display":{"kind":"refused","text":"だめ"}}"#.utf8))
        ]

        let attempt = await ChoiceClient(session: MockURLProtocol.makeSession())
            .choose(baseURL: baseURL, apiKey: "k", sessionID: "s", key: "1", digest: "d-aaa", confirm: nil)

        XCTAssertNil(attempt.serverDigest)
    }

    /// ★The fingerprint survives a body the phone could not otherwise read. A 409 whose
    /// `display` is missing still tells the truth about which screen is live, and
    /// dropping it would strand the card until the next poll -- which, before Sprint 7's
    /// fix, could be forever if the screen came back unchanged.
    func testTheFingerprintIsCarriedEvenOutOfAResponseThatViolatesTheContract() async {
        MockURLProtocol.stubQueue = [
            .init(statusCode: 409, body: Data(#"{"error":"画面が変わりました","digest":"d-bbb"}"#.utf8))
        ]

        let attempt = await ChoiceClient(session: MockURLProtocol.makeSession())
            .choose(baseURL: baseURL, apiKey: "k", sessionID: "s", key: "1", digest: "d-aaa", confirm: nil)

        XCTAssertEqual(attempt.outcome, .contractViolation(ResponseContractViolation(status: 409, code: nil)))
        XCTAssertEqual(attempt.serverDigest, "d-bbb", "the screen's identity is not collateral damage of an unreadable body")
    }

    // MARK: - The two recovery decisions (settled before `display` is consulted)

    /// 401 decides WHICH SCREEN the phone is on. The body carries a perfectly usable
    /// sentence; acting on it would show that sentence over an intact conversation and
    /// never route to Key-entry, leaving the credentials wrong forever.
    func testStatus401IsUnauthorizedWithoutConsultingTheBody() async {
        MockURLProtocol.stubQueue = [
            .init(statusCode: 401, body: Data(#"{"code":"AUTH_REQUIRED","digest":"d-bbb","display":{"kind":"error","text":"鍵が通りませんでした。"}}"#.utf8))
        ]

        let attempt = await ChoiceClient(session: MockURLProtocol.makeSession())
            .choose(baseURL: baseURL, apiKey: "wrong", sessionID: "s", key: "1", digest: "d-aaa", confirm: nil)

        XCTAssertEqual(attempt.outcome, .unauthorized)
        XCTAssertNil(attempt.serverDigest, "a rejected key observed nothing about the screen")
    }

    func testStatus404WithSessionNotFoundCodeIsSessionNotFound() async {
        MockURLProtocol.stubQueue = [
            .init(statusCode: 404, body: Data(#"{"error":"unknown session","code":"SESSION_NOT_FOUND"}"#.utf8))
        ]

        let attempt = await ChoiceClient(session: MockURLProtocol.makeSession())
            .choose(baseURL: baseURL, apiKey: "k", sessionID: "gone", key: "1", digest: "d-aaa", confirm: nil)

        XCTAssertEqual(attempt.outcome, .sessionNotFound)
    }

    /// Both 404 shapes exist on this route too, and collapsing them would tell the user
    /// their conversation was deleted whenever the phone mistyped its own URL.
    func testTheTwo404MeaningsAreNotCollapsedNegativeControl() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 404, body: Data(#"{"code":"SESSION_NOT_FOUND"}"#.utf8))]
        let gone = await ChoiceClient(session: MockURLProtocol.makeSession())
            .choose(baseURL: baseURL, apiKey: "k", sessionID: "s", key: "1", digest: "d", confirm: nil)

        MockURLProtocol.stubQueue = [.init(statusCode: 404, body: Data(#"{"code":"NO_SUCH_ROUTE"}"#.utf8))]
        let badPath = await ChoiceClient(session: MockURLProtocol.makeSession())
            .choose(baseURL: baseURL, apiKey: "k", sessionID: "s", key: "1", digest: "d", confirm: nil)

        XCTAssertNotEqual(gone, badPath)
        XCTAssertEqual(badPath.outcome, .contractViolation(ResponseContractViolation(status: 404, code: "NO_SUCH_ROUTE")))
    }

    // MARK: - Transport

    /// ★A timed-out keystroke may well have landed. `.unreachable` is the honest bucket:
    /// its banner claims only that delivery could not be confirmed, and the caller must
    /// not auto-retry -- the server's repeat guard is the thing that would have to catch
    /// a retry, and it can only do so while the screen has not moved.
    func testConnectionFailureIsUnreachableAndReportsNoFingerprint() async {
        MockURLProtocol.stubQueue = []

        let attempt = await ChoiceClient(session: MockURLProtocol.makeSession())
            .choose(baseURL: baseURL, apiKey: "k", sessionID: "s", key: "1", digest: "d-aaa", confirm: nil)

        XCTAssertEqual(attempt.outcome, .unreachable)
        XCTAssertNil(attempt.serverDigest)
    }

    func testRealTaskCancellationMapsToCancelled() async {
        MockURLProtocol.deliveryDelay = 0.3
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(Self.acceptedBody.utf8))]
        let client = ChoiceClient(session: MockURLProtocol.makeSession())

        let task = Task {
            await client.choose(baseURL: baseURL, apiKey: "k", sessionID: "s", key: "1", digest: "d", confirm: nil)
        }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let attempt = await task.value

        XCTAssertEqual(attempt.outcome, .cancelled)
    }

    /// Cancelled must not read as unreachable: one shows a "届いたか確認できません" warning,
    /// the other shows nothing, so folding them would put a scary banner on every screen
    /// dismissal.
    func testCancelledIsNotCollapsedIntoUnreachableNegativeControl() async {
        MockURLProtocol.injectedError = URLError(.cancelled)
        let cancelled = await ChoiceClient(session: MockURLProtocol.makeSession())
            .choose(baseURL: baseURL, apiKey: "k", sessionID: "s", key: "1", digest: "d", confirm: nil)

        MockURLProtocol.stubQueue = []
        let unreachable = await ChoiceClient(session: MockURLProtocol.makeSession())
            .choose(baseURL: baseURL, apiKey: "k", sessionID: "s", key: "1", digest: "d", confirm: nil)

        XCTAssertNotEqual(cancelled, unreachable)
    }

    // MARK: - Fixture

    /// `view.mjs`'s `applied === "verified"` branch, copied rather than paraphrased.
    /// ★`sent` and `applied` are separate fields on purpose -- 「送った」と「画面が動いた」
    /// を丸めると、押したのに何も起きていない画面を「決定しました」と言う事になる。
    private static let acceptedBody = #"""
    {"sent":true,"key":"1","applied":"verified",
     "display":{"kind":"ok","text":"押しました(画面が変わったのを確認)。"}}
    """#

    // MARK: - 危険な承認の第2手(2026-08-26)

    /// ★`confirm` が nil の時、**鍵ごと本文に出さない**。要らない画面に欄を作ると、
    /// 「いつも空で送っている物」になり、載っている事の意味が薄れる。
    func testConfirmIsAbsentFromTheBodyWhenNotArmed() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(Self.acceptedBody.utf8))]
        _ = await ChoiceClient(session: MockURLProtocol.makeSession())
            .choose(baseURL: baseURL, apiKey: "k", sessionID: "s", key: "1", digest: "d-aaa", confirm: nil)
        let body = String(data: MockURLProtocol.requestedBodies.last.flatMap { $0 } ?? Data(), encoding: .utf8) ?? ""
        XCTAssertFalse(body.contains("confirm"), "要らない画面にも欄が出た: \(body)")
    }

    /// ★構えた時は**指紋そのもの**を送る。別の値にすると「何に対する確認か」が
    /// 線の上で失われ、構えた画面と押した画面がずれても気付けない。
    func testConfirmCarriesTheDigestItself() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(Self.acceptedBody.utf8))]
        _ = await ChoiceClient(session: MockURLProtocol.makeSession())
            .choose(baseURL: baseURL, apiKey: "k", sessionID: "s", key: "1", digest: "d-aaa", confirm: "d-aaa")
        let body = String(data: MockURLProtocol.requestedBodies.last.flatMap { $0 } ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("\"confirm\":\"d-aaa\""), body)
    }
}
