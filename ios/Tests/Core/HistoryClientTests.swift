import XCTest
@testable import RemoteMini

/// `HistoryClient.fetch` tests -- same `MockURLProtocol` harness, same style, as
/// `SessionsClientTests`. Reuses that suite's structure deliberately: status-code
/// branching, cancellation (both injected and real `Task.cancel()`), the
/// Authorization header, and the same 3 negative controls proving `SessionsFetchError`'s
/// 4 cases are not collapsed pairwise for THIS client too (brief §3-c: it's the same
/// enum, but a fresh `switch` in a fresh file is a fresh place to get the mapping wrong).
final class HistoryClientTests: XCTestCase {
    private let baseURL = URL(string: "https://unit-test.invalid")!

    override func setUp() { MockURLProtocol.reset() }
    override func tearDown() { MockURLProtocol.reset() }

    // MARK: - Status-code branching

    func testStatus200DecodesTheRealShapeToSuccess() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(Self.validBody.utf8))]
        let client = HistoryClient(session: MockURLProtocol.makeSession())

        let result = await client.fetch(baseURL: baseURL, apiKey: "correct-fixture-key", sessionID: "sess-0001", limit: 50)

        guard case .success(let response) = result else {
            return XCTFail("expected .success, got \(result)")
        }
        XCTAssertEqual(response.history.count, 1)
        XCTAssertEqual(response.history[0].role, .user)
        XCTAssertEqual(response.truncated, false)
    }

    func testStatus401IsUnauthorized() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 401)]
        let client = HistoryClient(session: MockURLProtocol.makeSession())

        let result = await client.fetch(baseURL: baseURL, apiKey: "wrong-fixture-key", sessionID: "sess-0001", limit: 50)

        XCTAssertEqual(result, .failure(.unauthorized))
    }

    func testOtherStatusIsUnreachable() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 500)]
        let client = HistoryClient(session: MockURLProtocol.makeSession())

        let result = await client.fetch(baseURL: baseURL, apiKey: "fixture-key", sessionID: "sess-0001", limit: 50)

        XCTAssertEqual(result, .failure(.unreachable))
    }

    // Brief §3-c (same-day correction): 404 gets its own case, distinct from the
    // generic `.unreachable` bucket `testOtherStatusIsUnreachable` above covers --
    // `server.mjs`'s `/history` handler, `json(res, 404, { error: "unknown session" })`.
    //
    // Sprint 5 brief §0-c ② narrowed it: the CODE decides, not the status. This test
    // used to stub a bare `.init(statusCode: 404)` with no body at all and assert
    // `.notFound`, which is exactly the behaviour DoD row 6 removes -- so it now sends
    // the body `server.mjs` actually sends.
    func testStatus404WithSessionNotFoundCodeIsNotFound() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 404, body: Data(Self.sessionNotFoundBody.utf8))]
        let client = HistoryClient(session: MockURLProtocol.makeSession())

        let result = await client.fetch(baseURL: baseURL, apiKey: "fixture-key", sessionID: "sess-0001", limit: 50)

        XCTAssertEqual(result, .failure(.notFound))
    }

    /// DoD row 6. The other two `json(res, 404, …)` sites in `server.mjs` send
    /// `NO_SUCH_ROUTE`, which means the phone asked for a path that does not exist --
    /// a bug in this app, not a deleted conversation.
    func testStatus404WithNoSuchRouteCodeIsContractViolationNotNotFound() async {
        MockURLProtocol.stubQueue = [
            .init(statusCode: 404, body: Data(#"{"error":"not found","code":"NO_SUCH_ROUTE"}"#.utf8))
        ]
        let client = HistoryClient(session: MockURLProtocol.makeSession())

        let result = await client.fetch(baseURL: baseURL, apiKey: "fixture-key", sessionID: "sess-0001", limit: 50)

        XCTAssertEqual(
            result,
            .failure(.contractViolation(ResponseContractViolation(status: 404, code: "NO_SUCH_ROUTE")))
        )
    }

    /// A 404 whose body does not parse at all cannot be shown to say
    /// `SESSION_NOT_FOUND`, so it must not be believed to. Fail toward "we could not
    /// read this," never toward the recovery action.
    func testStatus404WithUnreadableBodyIsContractViolation() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 404, body: Data("<html>404</html>".utf8))]
        let client = HistoryClient(session: MockURLProtocol.makeSession())

        let result = await client.fetch(baseURL: baseURL, apiKey: "fixture-key", sessionID: "sess-0001", limit: 50)

        XCTAssertEqual(
            result,
            .failure(.contractViolation(ResponseContractViolation(status: 404, code: nil)))
        )
    }

    /// Negative control for the pair above: the two 404 bodies must not produce the
    /// same outcome. Without this, both tests could be satisfied by a client that
    /// returned `.contractViolation` for every 404 -- which would break the real
    /// recovery path while looking green.
    func testTheTwo404sAreNotCollapsedNegativeControl() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 404, body: Data(Self.sessionNotFoundBody.utf8))]
        let gone = await HistoryClient(session: MockURLProtocol.makeSession())
            .fetch(baseURL: baseURL, apiKey: "x", sessionID: "s", limit: 50)
        MockURLProtocol.stubQueue = [
            .init(statusCode: 404, body: Data(#"{"error":"not found","code":"NO_SUCH_ROUTE"}"#.utf8))
        ]
        let badPath = await HistoryClient(session: MockURLProtocol.makeSession())
            .fetch(baseURL: baseURL, apiKey: "x", sessionID: "s", limit: 50)

        XCTAssertNotEqual(gone, badPath)
    }

    func testConnectionFailureIsUnreachable() async {
        MockURLProtocol.stubQueue = []
        let client = HistoryClient(session: MockURLProtocol.makeSession())

        let result = await client.fetch(baseURL: baseURL, apiKey: "fixture-key", sessionID: "sess-0001", limit: 50)

        XCTAssertEqual(result, .failure(.unreachable))
    }

    // MARK: - 200 with an undecodable body

    func testStatus200WithUndecodableBodyIsMalformedBodyNotSuccess() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(#"{ "not": "the right shape" }"#.utf8))]
        let client = HistoryClient(session: MockURLProtocol.makeSession())

        let result = await client.fetch(baseURL: baseURL, apiKey: "fixture-key", sessionID: "sess-0001", limit: 50)

        XCTAssertEqual(result, .failure(.malformedBody))
    }

    // MARK: - Cancellation

    func testInjectedURLErrorCancelledMapsToCancelledOutcome() async {
        MockURLProtocol.injectedError = URLError(.cancelled)
        let client = HistoryClient(session: MockURLProtocol.makeSession())

        let result = await client.fetch(baseURL: baseURL, apiKey: "fixture-key", sessionID: "sess-0001", limit: 50)

        XCTAssertEqual(result, .failure(.cancelled))
    }

    func testRealTaskCancellationMapsToCancelledOutcome() async {
        // Same deterministic-delay technique as `SessionsClientTests` -- see that
        // file's doc comment on this test for why a blocking wait was rejected.
        MockURLProtocol.deliveryDelay = 0.3
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(Self.validBody.utf8))]
        let client = HistoryClient(session: MockURLProtocol.makeSession())

        let task = Task { await client.fetch(baseURL: baseURL, apiKey: "fixture-key", sessionID: "sess-0001", limit: 50) }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let result = await task.value

        XCTAssertEqual(result, .failure(.cancelled))
    }

    // MARK: - The header every request must carry, and the limit query param

    func testRequestCarriesTheKeyAsABearerAuthorizationHeader() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(Self.validBody.utf8))]
        let client = HistoryClient(session: MockURLProtocol.makeSession())

        _ = await client.fetch(baseURL: baseURL, apiKey: "correct-fixture-key", sessionID: "sess-0001", limit: 50)

        XCTAssertEqual(MockURLProtocol.lastRequestHeaders?["Authorization"], "Bearer correct-fixture-key")
    }

    func testRequestURLCarriesSessionIDAndLimit() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(Self.validBody.utf8))]
        let client = HistoryClient(session: MockURLProtocol.makeSession())

        _ = await client.fetch(baseURL: baseURL, apiKey: "x", sessionID: "sess-abc-123", limit: 150)

        let requested = MockURLProtocol.requestedURLs.last
        XCTAssertEqual(requested?.path, "/api/sessions/sess-abc-123/history")
        XCTAssertEqual(requested?.query, "limit=150")
    }

    // 2026-08-05: `SessionsClient`/`SessionsModels`'s mutation-audit gap (no method
    // check anywhere in the tree) applies to this client too -- added alongside it.
    func testRequestMethodIsGET() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(Self.validBody.utf8))]
        let client = HistoryClient(session: MockURLProtocol.makeSession())

        _ = await client.fetch(baseURL: baseURL, apiKey: "x", sessionID: "sess-0001", limit: 50)

        XCTAssertEqual(MockURLProtocol.requestedMethods.last, "GET")
    }

    // MARK: - Negative controls: the four cases are not collapsed pairwise

    func test401And5xxAreNotCollapsedIntoOneOutcomeNegativeControl() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 401)]
        let unauthorized = await HistoryClient(session: MockURLProtocol.makeSession())
            .fetch(baseURL: baseURL, apiKey: "x", sessionID: "s", limit: 50)
        MockURLProtocol.stubQueue = [.init(statusCode: 500)]
        let unreachable = await HistoryClient(session: MockURLProtocol.makeSession())
            .fetch(baseURL: baseURL, apiKey: "x", sessionID: "s", limit: 50)

        XCTAssertNotEqual(unauthorized, unreachable)
    }

    func testCancelledIsNotCollapsedIntoUnreachableNegativeControl() async {
        MockURLProtocol.injectedError = URLError(.cancelled)
        let cancelled = await HistoryClient(session: MockURLProtocol.makeSession())
            .fetch(baseURL: baseURL, apiKey: "x", sessionID: "s", limit: 50)
        MockURLProtocol.stubQueue = [.init(statusCode: 500)]
        let unreachable = await HistoryClient(session: MockURLProtocol.makeSession())
            .fetch(baseURL: baseURL, apiKey: "x", sessionID: "s", limit: 50)

        XCTAssertNotEqual(cancelled, unreachable)
    }

    func testMalformedBodyIsNotCollapsedIntoUnreachableNegativeControl() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(#"{ "not": "the right shape" }"#.utf8))]
        let malformed = await HistoryClient(session: MockURLProtocol.makeSession())
            .fetch(baseURL: baseURL, apiKey: "x", sessionID: "s", limit: 50)
        MockURLProtocol.stubQueue = [.init(statusCode: 500)]
        let unreachable = await HistoryClient(session: MockURLProtocol.makeSession())
            .fetch(baseURL: baseURL, apiKey: "x", sessionID: "s", limit: 50)

        XCTAssertNotEqual(malformed, unreachable)
    }

    func testNotFoundIsNotCollapsedIntoUnreachableNegativeControl() async {
        // Guards against exactly the mistake the brief's own first draft made
        // (§3-c): a `default:` arm that swallows 404 alongside every other
        // non-200/401 status would make this equal `.unreachable`, and Conversation
        // would offer a useless "再試行" button on an already-permanent 404.
        MockURLProtocol.stubQueue = [.init(statusCode: 404, body: Data(Self.sessionNotFoundBody.utf8))]
        let notFound = await HistoryClient(session: MockURLProtocol.makeSession())
            .fetch(baseURL: baseURL, apiKey: "x", sessionID: "s", limit: 50)
        MockURLProtocol.stubQueue = [.init(statusCode: 500)]
        let unreachable = await HistoryClient(session: MockURLProtocol.makeSession())
            .fetch(baseURL: baseURL, apiKey: "x", sessionID: "s", limit: 50)

        XCTAssertNotEqual(notFound, unreachable)
    }

    // MARK: - Request body (Sprint 5's third recorded dimension)

    /// A GET must carry no body. Asserted rather than assumed: `requestedBodies` is a
    /// new recorder, and a dimension nobody reads is a dimension a mutation can move
    /// freely -- which is the entire finding `request-shape.test.mjs` was written from.
    ///
    /// `?? Data()` collapses "no body recorded" and "empty body" for the count only;
    /// both are correct here, and distinguishing them would assert a difference
    /// `URLSession` does not promise to preserve.
    func testGETCarriesNoRequestBody() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(Self.validBody.utf8))]
        let client = HistoryClient(session: MockURLProtocol.makeSession())

        _ = await client.fetch(baseURL: baseURL, apiKey: "x", sessionID: "sess-0001", limit: 50)

        XCTAssertEqual((MockURLProtocol.requestedBodies.last ?? nil)?.count ?? 0, 0)
    }

    // MARK: - Wait budget (the fourth recorded dimension, 2026-08-06)

    /// This is the request behind 会話を開く. Until the timeouts were split it waited
    /// the poll length (30s), so opening a conversation on a network that accepts the
    /// connection and then goes silent showed a bare `ProgressView` for half a minute
    /// before offering 再試行 -- RC 却下理由 1 reproduced inside this app.
    /// What `requestedTimeouts` does and does not prove: see `RequestTimeoutTests`.
    func testRequestUsesTheInteractiveTimeout() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(Self.validBody.utf8))]
        let client = HistoryClient(session: MockURLProtocol.makeSession())

        _ = await client.fetch(baseURL: baseURL, apiKey: "x", sessionID: "sess-0001", limit: 50)

        XCTAssertEqual(MockURLProtocol.requestedTimeouts, [BackendSession.interactiveTimeout])
    }

    // MARK: - Fixture

    /// What `server.mjs` actually sends from its `SESSION_NOT_FOUND` frozen constant.
    private static let sessionNotFoundBody = #"{"error":"unknown session","code":"SESSION_NOT_FOUND"}"#

    private static let validBody = """
    {
      "history": [
        { "role": "user", "text": "a", "display": { "who": "Tom" } }
      ],
      "truncated": false
    }
    """
}
