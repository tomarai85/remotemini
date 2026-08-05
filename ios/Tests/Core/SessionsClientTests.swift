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

    // Negative control, added alongside Sprint 3's `.notFound` case (brief §3-c):
    // `/api/sessions` has no session id to 404 against, so `SessionsClient`'s switch
    // deliberately has no `case 404` of its own -- a stray 404 here still falls
    // through the existing `default:` to `.unreachable`, same as any other
    // unexpected status. This guards against `.notFound` handling creeping into
    // this client just because the enum it returns now has the case available.
    func testStatus404StillFallsThroughToUnreachableForListNegativeControl() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 404)]
        let client = SessionsClient(session: MockURLProtocol.makeSession())

        let result = await client.fetch(baseURL: baseURL, apiKey: "fixture-key")

        XCTAssertEqual(result, .failure(.unreachable))
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
