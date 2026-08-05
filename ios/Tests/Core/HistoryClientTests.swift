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
    func testStatus404IsNotFound() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 404)]
        let client = HistoryClient(session: MockURLProtocol.makeSession())

        let result = await client.fetch(baseURL: baseURL, apiKey: "fixture-key", sessionID: "sess-0001", limit: 50)

        XCTAssertEqual(result, .failure(.notFound))
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
        MockURLProtocol.stubQueue = [.init(statusCode: 404)]
        let notFound = await HistoryClient(session: MockURLProtocol.makeSession())
            .fetch(baseURL: baseURL, apiKey: "x", sessionID: "s", limit: 50)
        MockURLProtocol.stubQueue = [.init(statusCode: 500)]
        let unreachable = await HistoryClient(session: MockURLProtocol.makeSession())
            .fetch(baseURL: baseURL, apiKey: "x", sessionID: "s", limit: 50)

        XCTAssertNotEqual(notFound, unreachable)
    }

    // MARK: - Fixture

    private static let validBody = """
    {
      "history": [
        { "role": "user", "text": "a", "display": { "who": "Tom" } }
      ],
      "truncated": false
    }
    """
}
