import XCTest
@testable import RemoteMini

/// `SessionsClient.fetch` tests -- the List screen's actual data source (brief §0),
/// distinct from `SessionsAuthProbeTests` (Key-entry's probe, which discards the
/// body and has a 3-case `Outcome`, not this type's 4-case `SessionsFetchError`).
/// Same `MockURLProtocol` harness, same style, per `SessionsAuthProbeTests`.
final class SessionsClientTests: XCTestCase {
    private let baseURL = URL(string: "https://unit-test.invalid")!

    override func setUp() { MockURLProtocol.reset() }
    override func tearDown() { MockURLProtocol.reset() }

    // MARK: - Status-code branching

    func testStatus200DecodesTheRealShapeToSuccess() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(Self.validBody.utf8))]
        let client = SessionsClient(session: MockURLProtocol.makeSession())

        let result = await client.fetch(baseURL: baseURL, apiKey: "correct-fixture-key")

        guard case .success(let response) = result else {
            return XCTFail("expected .success, got \(result)")
        }
        XCTAssertEqual(response.sessions.count, 1)
        XCTAssertEqual(response.sessions[0].id, "sess-0001")
        XCTAssertEqual(response.display.scan, "")
    }

    func testStatus401IsUnauthorized() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 401)]
        let client = SessionsClient(session: MockURLProtocol.makeSession())

        let result = await client.fetch(baseURL: baseURL, apiKey: "wrong-fixture-key")

        XCTAssertEqual(result, .failure(.unauthorized))
    }

    func testOtherStatusIsUnreachable() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 500)]
        let client = SessionsClient(session: MockURLProtocol.makeSession())

        let result = await client.fetch(baseURL: baseURL, apiKey: "fixture-key")

        XCTAssertEqual(result, .failure(.unreachable))
    }

    // Sprint 3 asserted that a stray 404 here fell through `default:` to
    // `.unreachable`; Sprint 5 brief §0-c ② changes what it must be, and the reason is
    // the whole point of the change: `/api/sessions` has no session id to 404 against,
    // so a 404 on THIS route can only mean the phone asked for a path the server does
    // not serve. `.unreachable` renders that as "the backend is unreachable" -- a
    // client bug wearing the appearance of an infrastructure problem, which is
    // precisely the disguise the mutation audit measured (`api/sessions` ->
    // `api/session` left 214 tests green).
    func testStatus404IsContractViolationForListNotUnreachable() async {
        MockURLProtocol.stubQueue = [
            .init(statusCode: 404, body: Data(#"{"error":"not found","code":"NO_SUCH_ROUTE"}"#.utf8))
        ]
        let client = SessionsClient(session: MockURLProtocol.makeSession())

        let result = await client.fetch(baseURL: baseURL, apiKey: "fixture-key")

        XCTAssertEqual(
            result,
            .failure(.contractViolation(ResponseContractViolation(status: 404, code: "NO_SUCH_ROUTE")))
        )
    }

    /// Even a 404 that claims `SESSION_NOT_FOUND` stays a contract violation on this
    /// route. There is no session in the request for the server to have failed to find,
    /// so that body would itself be the contract breaking -- and routing it to the
    /// "conversation is gone" recovery would be acting on a claim the request cannot
    /// support. The branch must not depend on the code's value; this test is what makes
    /// that non-dependence visible.
    func testStatus404WithSessionNotFoundCodeIsStillAContractViolationHere() async {
        MockURLProtocol.stubQueue = [
            .init(statusCode: 404, body: Data(#"{"error":"unknown session","code":"SESSION_NOT_FOUND"}"#.utf8))
        ]
        let client = SessionsClient(session: MockURLProtocol.makeSession())

        let result = await client.fetch(baseURL: baseURL, apiKey: "fixture-key")

        XCTAssertEqual(
            result,
            .failure(.contractViolation(ResponseContractViolation(status: 404, code: "SESSION_NOT_FOUND")))
        )
    }

    /// Negative control: 404 and 500 must not land in the same bucket. Without this,
    /// deleting the `case 404:` arm entirely would restore the old `.unreachable`
    /// behaviour and the two tests above would be the only thing objecting -- both of
    /// which a careless "fix the failing test" edit would simply rewrite.
    func testContractViolationIsNotCollapsedIntoUnreachableNegativeControl() async {
        MockURLProtocol.stubQueue = [
            .init(statusCode: 404, body: Data(#"{"error":"not found","code":"NO_SUCH_ROUTE"}"#.utf8))
        ]
        let violation = await SessionsClient(session: MockURLProtocol.makeSession())
            .fetch(baseURL: baseURL, apiKey: "x")
        MockURLProtocol.stubQueue = [.init(statusCode: 500)]
        let unreachable = await SessionsClient(session: MockURLProtocol.makeSession())
            .fetch(baseURL: baseURL, apiKey: "x")

        XCTAssertNotEqual(violation, unreachable)
    }

    /// A GET carries no body. See `HistoryClientTests`' copy for why this dimension is
    /// asserted rather than assumed.
    func testGETCarriesNoRequestBody() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(Self.validBody.utf8))]
        let client = SessionsClient(session: MockURLProtocol.makeSession())

        _ = await client.fetch(baseURL: baseURL, apiKey: "x")

        XCTAssertEqual((MockURLProtocol.requestedBodies.last ?? nil)?.count ?? 0, 0)
    }

    /// The fourth recorded dimension (2026-08-06). This is the request behind the
    /// first screen of the app, so it is the one whose give-up window the user feels
    /// most directly: `interactiveTimeout`, not the 30s poll length. Sized off the
    /// measured payload -- 41 conversations came to ~30 KB in 38-65 ms server-side.
    /// What `requestedTimeouts` does and does not prove: see `RequestTimeoutTests`.
    func testRequestUsesTheInteractiveTimeout() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(Self.validBody.utf8))]
        let client = SessionsClient(session: MockURLProtocol.makeSession())

        _ = await client.fetch(baseURL: baseURL, apiKey: "x")

        XCTAssertEqual(MockURLProtocol.requestedTimeouts, [BackendSession.interactiveTimeout])
    }

    func testConnectionFailureIsUnreachable() async {
        MockURLProtocol.stubQueue = []
        let client = SessionsClient(session: MockURLProtocol.makeSession())

        let result = await client.fetch(baseURL: baseURL, apiKey: "fixture-key")

        XCTAssertEqual(result, .failure(.unreachable))
    }

    // MARK: - Brief §4-a's own judgment call: 200 with an undecodable body

    func testStatus200WithUndecodableBodyIsMalformedBodyNotSuccess() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(#"{ "not": "the right shape" }"#.utf8))]
        let client = SessionsClient(session: MockURLProtocol.makeSession())

        let result = await client.fetch(baseURL: baseURL, apiKey: "fixture-key")

        XCTAssertEqual(result, .failure(.malformedBody))
    }

    // MARK: - Cancellation (brief §4-a/§8: `CancellationError` and `URLError.cancelled`
    // must both map here, and neither may be counted as `.unreachable`)

    func testInjectedURLErrorCancelledMapsToCancelledOutcome() async {
        // Deterministic, no Task-cancellation timing involved: this isolates the
        // `catch let urlError as URLError where .cancelled` arm on its own.
        MockURLProtocol.injectedError = URLError(.cancelled)
        let client = SessionsClient(session: MockURLProtocol.makeSession())

        let result = await client.fetch(baseURL: baseURL, apiKey: "fixture-key")

        XCTAssertEqual(result, .failure(.cancelled))
    }

    func testRealTaskCancellationMapsToCancelledOutcome() async {
        // A genuine `Task.cancel()`, not an injected error. `deliveryDelay` holds
        // the mock's response 300ms out -- long enough that the 50ms sleep below
        // reliably lands the cancel while the fetch is still in flight, without
        // ever blocking the thread `startLoading()` runs on (see that property's
        // doc comment in MockURLProtocol for why a blocking version of this test
        // corrupted every later test in the process instead).
        //
        // This does not pin down *which* of `SessionsClient`'s two catch arms fires
        // (Foundation's async bridging may surface `URLError(.cancelled)` or a bare
        // `CancellationError` depending on exactly when cancellation lands, and this
        // harness cannot force that choice deterministically). What it proves is the
        // observable contract the brief actually cares about: a fetch whose Task was
        // really cancelled ends up `.failure(.cancelled)`, not `.unreachable` and not
        // a spuriously decoded `.success`.
        MockURLProtocol.deliveryDelay = 0.3
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(Self.validBody.utf8))]
        let client = SessionsClient(session: MockURLProtocol.makeSession())

        let task = Task { await client.fetch(baseURL: baseURL, apiKey: "fixture-key") }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let result = await task.value

        XCTAssertEqual(result, .failure(.cancelled))
    }

    // MARK: - The header every request must carry

    func testRequestCarriesTheKeyAsABearerAuthorizationHeader() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(Self.validBody.utf8))]
        let client = SessionsClient(session: MockURLProtocol.makeSession())

        _ = await client.fetch(baseURL: baseURL, apiKey: "correct-fixture-key")

        XCTAssertEqual(MockURLProtocol.lastRequestHeaders?["Authorization"], "Bearer correct-fixture-key")
    }

    // MARK: - Request shape: URL and method (2026-08-05 mutation-audit finding --
    // this client was the only one of the three with zero checks on either)

    func testRequestURLIsApiSessions() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(Self.validBody.utf8))]
        let client = SessionsClient(session: MockURLProtocol.makeSession())

        _ = await client.fetch(baseURL: baseURL, apiKey: "x")

        XCTAssertEqual(MockURLProtocol.requestedURLs.last?.path, "/api/sessions")
    }

    func testRequestMethodIsGET() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(Self.validBody.utf8))]
        let client = SessionsClient(session: MockURLProtocol.makeSession())

        _ = await client.fetch(baseURL: baseURL, apiKey: "x")

        XCTAssertEqual(MockURLProtocol.requestedMethods.last, "GET")
    }

    // MARK: - Negative controls: the four cases are not collapsed pairwise

    func test401And5xxAreNotCollapsedIntoOneOutcomeNegativeControl() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 401)]
        let unauthorized = await SessionsClient(session: MockURLProtocol.makeSession())
            .fetch(baseURL: baseURL, apiKey: "x")
        MockURLProtocol.stubQueue = [.init(statusCode: 500)]
        let unreachable = await SessionsClient(session: MockURLProtocol.makeSession())
            .fetch(baseURL: baseURL, apiKey: "x")

        XCTAssertNotEqual(unauthorized, unreachable)
    }

    func testCancelledIsNotCollapsedIntoUnreachableNegativeControl() async {
        // The failure this guards against is exactly what the brief flags as a
        // Codex-found defect: a naive `catch { return .failure(.unreachable) }`
        // would make a cancelled pull-to-refresh look identical to a dead backend,
        // incrementing `ListViewModel`'s counter toward a red "unreachable" banner
        // on a perfectly healthy server.
        MockURLProtocol.injectedError = URLError(.cancelled)
        let cancelled = await SessionsClient(session: MockURLProtocol.makeSession())
            .fetch(baseURL: baseURL, apiKey: "x")
        MockURLProtocol.stubQueue = [.init(statusCode: 500)]
        let unreachable = await SessionsClient(session: MockURLProtocol.makeSession())
            .fetch(baseURL: baseURL, apiKey: "x")

        XCTAssertNotEqual(cancelled, unreachable)
    }

    func testMalformedBodyIsNotCollapsedIntoUnreachableNegativeControl() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(#"{ "not": "the right shape" }"#.utf8))]
        let malformed = await SessionsClient(session: MockURLProtocol.makeSession())
            .fetch(baseURL: baseURL, apiKey: "x")
        MockURLProtocol.stubQueue = [.init(statusCode: 500)]
        let unreachable = await SessionsClient(session: MockURLProtocol.makeSession())
            .fetch(baseURL: baseURL, apiKey: "x")

        XCTAssertNotEqual(malformed, unreachable)
    }

    // MARK: - Fixture

    private static let validBody = """
    {
      "sessions": [
        {
          "id": "sess-0001", "project": "p", "cwd": "/x", "title": "t", "lastPrompt": null, "turns": null,
          "metadataIncomplete": false, "updatedAt": "2026-08-05T09:00:00.000Z",
          "display": { "route": { "kind": "tmux", "short": "s", "text": "t", "screen": "" }, "subtitle": "s" }
        }
      ],
      "display": { "scan": "" },
      "paneFault": null
    }
    """
}
