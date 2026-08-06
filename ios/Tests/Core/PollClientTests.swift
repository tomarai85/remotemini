import XCTest
@testable import RemoteMini

/// `PollClient.poll` tests -- same `MockURLProtocol` harness/style as
/// `HistoryClientTests`/`SessionsClientTests`, extended for brief §2-a's two-pass
/// read: `ReadablePoll.check` on the loose tree, THEN a typed decode on the same
/// bytes, either gate failing landing on `.unreadable` (not on `.unreachable`,
/// which stays reserved for transport failures -- N1's subject, covered in
/// `PollLoopTests` where `UnreadableMeter`/`Backoff` both actually exist to check
/// against).
final class PollClientTests: XCTestCase {
    private let baseURL = URL(string: "https://unit-test.invalid")!

    override func setUp() { MockURLProtocol.reset() }
    override func tearDown() { MockURLProtocol.reset() }

    private func makeClient() -> PollClient { PollClient(session: MockURLProtocol.makeSession()) }

    // MARK: - Status-code branching

    func testStatus200WithAReadableTrustedBodyDecodesToSuccess() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(Self.validBody.utf8))]

        let outcome = await makeClient().poll(baseURL: baseURL, apiKey: "k", sessionID: "s", cursor: .empty, waitMs: 20_000)

        guard case .success(let response) = outcome else { return XCTFail("expected .success, got \(outcome)") }
        XCTAssertEqual(response.cursor, PollCursor(raw: "t.abc.1.0"))
        XCTAssertFalse(response.more)
    }

    func testStatus401IsUnauthorized() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 401)]

        let outcome = await makeClient().poll(baseURL: baseURL, apiKey: "k", sessionID: "s", cursor: .empty, waitMs: 0)

        XCTAssertEqual(outcome, .unauthorized)
    }

    func testOtherStatusIsUnreachable() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 500)]

        let outcome = await makeClient().poll(baseURL: baseURL, apiKey: "k", sessionID: "s", cursor: .empty, waitMs: 0)

        XCTAssertEqual(outcome, .unreachable)
    }

    func testConnectionFailureIsUnreachable() async {
        MockURLProtocol.stubQueue = []

        let outcome = await makeClient().poll(baseURL: baseURL, apiKey: "k", sessionID: "s", cursor: .empty, waitMs: 0)

        XCTAssertEqual(outcome, .unreachable)
    }

    // MARK: - 404: the two 404s this endpoint produces are not the same event

    func testStatus404WithSessionNotFoundIsItsOwnOutcome() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 404, body: Data(Self.sessionNotFoundBody.utf8))]

        let outcome = await makeClient().poll(baseURL: baseURL, apiKey: "k", sessionID: "s", cursor: .empty, waitMs: 0)

        XCTAssertEqual(outcome, .sessionNotFound)
    }

    /// The property, not the mapping: `PollClient` was the last client in this app
    /// still answering "the conversation is gone" and "the backend is unreachable"
    /// with the same value. Equal values cannot drive different behaviour no matter
    /// what the loop above them does, so the loop's fix rests on this inequality.
    /// Same assertion `HistoryClientTests` already makes for its own error type.
    func testSessionNotFoundIsNotEqualToUnreachable() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 404, body: Data(Self.sessionNotFoundBody.utf8))]
        let gone = await makeClient().poll(baseURL: baseURL, apiKey: "k", sessionID: "s", cursor: .empty, waitMs: 0)

        MockURLProtocol.stubQueue = []
        let offline = await makeClient().poll(baseURL: baseURL, apiKey: "k", sessionID: "s", cursor: .empty, waitMs: 0)

        XCTAssertNotEqual(gone, offline)
    }

    /// A 404 the server did NOT label `SESSION_NOT_FOUND` means the phone asked for a
    /// path this server does not serve -- a version skew across a deploy, which the
    /// next deploy fixes. Deliberately still `.unreachable` so the loop keeps retrying
    /// into that recovery, unlike `SendClient` (one-shot, no loop to heal into, so it
    /// reports a contract violation instead). Getting this backwards would turn every
    /// mid-deploy poll into a dead screen requiring a manual reopen.
    func testStatus404WithoutTheCodeStaysUnreachableSoADeployCanHealIt() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 404, body: Data(#"{"error":"no such route","code":"NO_SUCH_ROUTE"}"#.utf8))]

        let outcome = await makeClient().poll(baseURL: baseURL, apiKey: "k", sessionID: "s", cursor: .empty, waitMs: 0)

        XCTAssertEqual(outcome, .unreachable)
    }

    func testStatus404WithAnUndecodableBodyStaysUnreachable() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 404, body: Data("<html>404</html>".utf8))]

        let outcome = await makeClient().poll(baseURL: baseURL, apiKey: "k", sessionID: "s", cursor: .empty, waitMs: 0)

        XCTAssertEqual(outcome, .unreachable)
    }

    // MARK: - The two-pass read (§2-a steps 2-4)

    func testStatus200WithInvalidJSONIsUnreadable() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data("not even json {".utf8))]

        let outcome = await makeClient().poll(baseURL: baseURL, apiKey: "k", sessionID: "s", cursor: .empty, waitMs: 0)

        XCTAssertEqual(outcome, .unreadable)
    }

    func testStatus200RejectedByReadablePollCheckIsUnreadable() async {
        // Valid JSON, but no `items` key at all -- `ReadablePoll.check`'s first
        // guard. Never reaches the typed decoder.
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(#"{ "cursor": "t.a.1.0", "more": false }"#.utf8))]

        let outcome = await makeClient().poll(baseURL: baseURL, apiKey: "k", sessionID: "s", cursor: .empty, waitMs: 0)

        XCTAssertEqual(outcome, .unreadable)
    }

    func testStatus200PassingReadablePollButFailingTypedDecodeIsAlsoUnreadable() async {
        // Passes `ReadablePoll.check` (its `items` array is empty -- vacuously ok),
        // but is missing the required top-level `cursor` key, which the loose
        // structural check never looks at. This is the exact "structurally
        // plausible but still wrong-shaped" case `PollClient.swift`'s own doc
        // comment names: the two gates are independent, and either one failing
        // alone must still land on `.unreadable`, not crash past into `.success`
        // with some placeholder cursor.
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(#"{ "items": [], "more": false }"#.utf8))]

        let outcome = await makeClient().poll(baseURL: baseURL, apiKey: "k", sessionID: "s", cursor: .empty, waitMs: 0)

        XCTAssertEqual(outcome, .unreadable, "ReadablePoll.check passes an empty items array, but the missing `cursor` key must still fail the typed decode")
    }

    func testMessageItemWithNeitherEntriesNorEventFailsReadablePollCheckIsUnreadable() async {
        // `ReadablePoll.swift`'s own doc comment calls this out explicitly: a
        // `kind: "message"` item with neither shape decodes fine as a typed
        // `MessageItem(entries: nil, seq:)`, but `ReadablePoll.check` rejects it
        // first -- this is why the loose check must run BEFORE the typed decode is
        // even attempted, not merely in addition to it.
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data("""
        { "items": [ { "kind": "message", "seq": 1 } ], "cursor": "t.a.1.0", "more": false }
        """.utf8))]

        let outcome = await makeClient().poll(baseURL: baseURL, apiKey: "k", sessionID: "s", cursor: .empty, waitMs: 0)

        XCTAssertEqual(outcome, .unreadable)
    }

    // MARK: - §5-b branch 8: worker-route body, full round trip through the real client

    func testWorkerRouteShapedBodyDecodesCleanlyThroughTheFullClient() async {
        // Distinct from `PollModelsTests`'s pure-decode coverage of the same shape:
        // this layer ALSO exercises `ReadablePoll.check` against the identical
        // bytes -- no `display` key, `queued` as a number, an item carrying `event`
        // (a plain object) instead of `entries`, which `ReadablePoll.check` accepts
        // (`isPlainEvent`) exactly because it's a dict, not an array or null.
        let workerBody = """
        { "items": [ { "kind": "message", "seq": 4, "event": { "type": "assistant_text", "text": "hi" } } ], "screen": null, "queued": 3, "cursor": "w.7.2.0", "more": false }
        """
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(workerBody.utf8))]

        let outcome = await makeClient().poll(baseURL: baseURL, apiKey: "k", sessionID: "s", cursor: .empty, waitMs: 0)

        guard case .success(let response) = outcome else { return XCTFail("expected .success, got \(outcome)") }
        XCTAssertNil(response.display, "worker route has no display key at all")
        XCTAssertEqual(response.queued, 3)
        XCTAssertEqual(response.cursor, PollCursor(raw: "w.7.2.0"))
    }

    // MARK: - §5-b branch 10: a 302 is not auto-followed

    func testPollRequestDoesNotFollowA302RedirectAndReturnsUnreachable() async {
        // `RedirectRefusalTests.swift`'s own doc comment: whether a custom
        // `URLProtocol` subclass actually triggers `URLSession`'s redirect
        // machinery is undocumented/version-specific Foundation behavior, so that
        // file tests `RedirectRefusingDelegate` directly. Reusing that technique
        // here would test the same delegate twice; what this layer specifically
        // needs is the OUTCOME on the poll path -- `.unreachable`, and no second
        // request -- which only holds if `BackendSession` really is wired with
        // that delegate for poll requests too, not just history/sessions ones.
        MockURLProtocol.stubQueue = [.init(statusCode: 302, headers: ["Location": "https://attacker.invalid/steal"])]

        let outcome = await makeClient().poll(baseURL: baseURL, apiKey: "k", sessionID: "s", cursor: .empty, waitMs: 0)

        XCTAssertEqual(outcome, .unreachable)
        XCTAssertEqual(MockURLProtocol.requestedURLs.count, 1, "no auto-follow occurred -- only the original request was made")
    }

    // MARK: - Cancellation

    func testInjectedURLErrorCancelledMapsToCancelledOutcome() async {
        MockURLProtocol.injectedError = URLError(.cancelled)

        let outcome = await makeClient().poll(baseURL: baseURL, apiKey: "k", sessionID: "s", cursor: .empty, waitMs: 0)

        XCTAssertEqual(outcome, .cancelled)
    }

    func testRealTaskCancellationMapsToCancelledOutcome() async {
        MockURLProtocol.deliveryDelay = 0.3
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(Self.validBody.utf8))]
        let client = makeClient()

        let task = Task { await client.poll(baseURL: baseURL, apiKey: "k", sessionID: "s", cursor: .empty, waitMs: 0) }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let outcome = await task.value

        XCTAssertEqual(outcome, .cancelled)
    }

    // MARK: - Request shape: header, cursor/wait query params

    func testRequestCarriesTheKeyAsABearerAuthorizationHeader() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(Self.validBody.utf8))]

        _ = await makeClient().poll(baseURL: baseURL, apiKey: "correct-fixture-key", sessionID: "s", cursor: .empty, waitMs: 0)

        XCTAssertEqual(MockURLProtocol.lastRequestHeaders?["Authorization"], "Bearer correct-fixture-key")
    }

    func testRequestURLCarriesSessionIDCursorAndWait() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(Self.validBody.utf8))]

        _ = await makeClient().poll(
            baseURL: baseURL, apiKey: "k", sessionID: "sess-abc-123",
            cursor: PollCursor(raw: "t.xyz.9.1"), waitMs: 20_000
        )

        let requested = MockURLProtocol.requestedURLs.last
        XCTAssertEqual(requested?.path, "/api/sessions/sess-abc-123/poll")
        let query = Set((requested?.query ?? "").split(separator: "&"))
        XCTAssertTrue(query.contains("cursor=t.xyz.9.1"))
        XCTAssertTrue(query.contains("wait=20000"))
    }

    // 2026-08-05: `SessionsClient`/`SessionsModels`'s mutation-audit gap (no method
    // check anywhere in the tree) applies to this client too -- added alongside it.
    func testRequestMethodIsGET() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(Self.validBody.utf8))]

        _ = await makeClient().poll(baseURL: baseURL, apiKey: "k", sessionID: "s", cursor: .empty, waitMs: 0)

        XCTAssertEqual(MockURLProtocol.requestedMethods.last, "GET")
    }

    /// A GET carries no body. See `HistoryClientTests`' copy for why this dimension is
    /// asserted rather than assumed.
    func testGETCarriesNoRequestBody() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(Self.validBody.utf8))]

        _ = await makeClient().poll(baseURL: baseURL, apiKey: "k", sessionID: "s", cursor: .empty, waitMs: 0)

        XCTAssertEqual((MockURLProtocol.requestedBodies.last ?? nil)?.count ?? 0, 0)
    }

    /// The fourth recorded dimension (2026-08-06). ★This is the one client that must
    /// NOT take the shortened read timeout. The server deliberately holds this request
    /// up to `POLL_MAX_WAIT_MS` (20s) and answers 200-with-nothing-new; a client that
    /// gave up at `interactiveTimeout` (8s) would read that designed silence as a
    /// network failure and show the offline banner on a perfectly healthy link.
    /// What `requestedTimeouts` does and does not prove: see `RequestTimeoutTests`.
    func testPollKeepsTheLongTimeoutRatherThanTheShortenedReadTimeout() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(Self.validBody.utf8))]

        _ = await makeClient().poll(baseURL: baseURL, apiKey: "k", sessionID: "s", cursor: .empty, waitMs: 20_000)

        XCTAssertEqual(MockURLProtocol.requestedTimeouts, [BackendSession.pollTimeout])
        XCTAssertGreaterThan(BackendSession.pollTimeout, BackendSession.interactiveTimeout)
    }

    func testEmptyCursorIsSentAsAnEmptyQueryValueNotOmitted() async {
        // The fresh sentinel (`PollCursor.empty`) must still appear on the wire as
        // `cursor=` -- an omitted `cursor` param entirely would be a different
        // request shape than the one `tail.mjs`'s `pollDecision` documents.
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(Self.validBody.utf8))]

        _ = await makeClient().poll(baseURL: baseURL, apiKey: "k", sessionID: "s", cursor: .empty, waitMs: 0)

        let query = MockURLProtocol.requestedURLs.last?.query ?? ""
        XCTAssertTrue(query.contains("cursor="), "query was: \(query)")
    }

    // MARK: - Negative controls: the 5 outcomes are not collapsed pairwise

    func testUnauthorizedAndUnreachableAreNotCollapsedNegativeControl() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 401)]
        let unauthorized = await makeClient().poll(baseURL: baseURL, apiKey: "k", sessionID: "s", cursor: .empty, waitMs: 0)
        MockURLProtocol.stubQueue = [.init(statusCode: 500)]
        let unreachable = await makeClient().poll(baseURL: baseURL, apiKey: "k", sessionID: "s", cursor: .empty, waitMs: 0)

        XCTAssertNotEqual(unauthorized, unreachable)
    }

    func testUnreadableAndUnreachableAreNotCollapsedNegativeControl() async {
        // The pairing N1 exists to catch one level up (`PollLoop`, where `Backoff`
        // and `UnreadableMeter` both actually exist) -- this is the prerequisite
        // fact at the `PollClient` layer: the two outcomes themselves must already
        // be distinguishable before anything upstream can route them differently.
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data("not json".utf8))]
        let unreadable = await makeClient().poll(baseURL: baseURL, apiKey: "k", sessionID: "s", cursor: .empty, waitMs: 0)
        MockURLProtocol.stubQueue = [.init(statusCode: 500)]
        let unreachable = await makeClient().poll(baseURL: baseURL, apiKey: "k", sessionID: "s", cursor: .empty, waitMs: 0)

        XCTAssertNotEqual(unreadable, unreachable)
    }

    func testCancelledIsNotCollapsedIntoUnreachableNegativeControl() async {
        MockURLProtocol.injectedError = URLError(.cancelled)
        let cancelled = await makeClient().poll(baseURL: baseURL, apiKey: "k", sessionID: "s", cursor: .empty, waitMs: 0)
        MockURLProtocol.stubQueue = [.init(statusCode: 500)]
        let unreachable = await makeClient().poll(baseURL: baseURL, apiKey: "k", sessionID: "s", cursor: .empty, waitMs: 0)

        XCTAssertNotEqual(cancelled, unreachable)
    }

    // MARK: - Fixture

    private static let validBody = """
    { "items": [], "screen": null, "queued": null, "cursor": "t.abc.1.0", "more": false }
    """

    /// Byte-for-byte the object `server.mjs` freezes as `SESSION_NOT_FOUND` and
    /// returns from the shared session-route guard, which sits BEFORE the action
    /// dispatch -- so `poll` gets it on exactly the same terms `history` does.
    private static let sessionNotFoundBody = #"{"error":"unknown session","code":"SESSION_NOT_FOUND"}"#
}
