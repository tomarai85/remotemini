import XCTest
@testable import RemoteMini

/// `DiffClient.fetch` tests -- 同じ `MockURLProtocol` の砂場、同じ様式を
/// `HistoryClientTests` から写す: status 分岐 / cancellation(injected + 実 `Task.cancel()`)/
/// Authorization header / `SessionsFetchError` の 4 値が対で潰れていない事の陰性対照。
final class DiffClientTests: XCTestCase {
    private let baseURL = URL(string: "https://unit-test.invalid")!

    override func setUp() { MockURLProtocol.reset() }
    override func tearDown() { MockURLProtocol.reset() }

    private static let validBody = """
    { "files": [
        { "path": "a.txt", "staged": false, "binary": false, "added": 1, "removed": 0, "truncated": false,
          "hunks": [ { "header": "@@ -0,0 +1 @@", "lines": [ { "kind": "add", "text": "x" } ] } ] }
      ], "truncated": false, "totalBytes": 5, "reason": null }
    """
    private static let sessionNotFoundBody = #"{"error":"unknown session","code":"SESSION_NOT_FOUND"}"#

    // MARK: - Status-code branching

    func testStatus200DecodesTheRealShapeToSuccess() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(Self.validBody.utf8))]
        let client = DiffClient(session: MockURLProtocol.makeSession())

        let result = await client.fetch(baseURL: baseURL, apiKey: "correct-fixture-key", sessionID: "sess-0001")

        guard case .success(let response) = result else {
            return XCTFail("expected .success, got \(result)")
        }
        XCTAssertEqual(response.files.count, 1)
        XCTAssertEqual(response.truncated, false)
        XCTAssertNil(response.reason)
    }

    func testStatus200WithReasonSetStillDecodesToSuccess() async {
        // ★診断: 読めない事は 200 + `reason` で来る(HTTP status では表せない)。
        //   之を失敗と読み違えると、diff の空面が全部「エラー」帯で出る。
        let body = #"{ "files": [], "truncated": false, "totalBytes": 0, "reason": "not_a_repo" }"#
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(body.utf8))]
        let client = DiffClient(session: MockURLProtocol.makeSession())

        let result = await client.fetch(baseURL: baseURL, apiKey: "x", sessionID: "sess-0001")

        guard case .success(let response) = result else {
            return XCTFail("expected .success, got \(result)")
        }
        XCTAssertEqual(response.reason, "not_a_repo")
    }

    func testStatus401IsUnauthorized() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 401)]
        let client = DiffClient(session: MockURLProtocol.makeSession())

        let result = await client.fetch(baseURL: baseURL, apiKey: "wrong-fixture-key", sessionID: "sess-0001")

        XCTAssertEqual(result, .failure(.unauthorized))
    }

    func testOtherStatusIsUnreachable() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 500)]
        let client = DiffClient(session: MockURLProtocol.makeSession())

        let result = await client.fetch(baseURL: baseURL, apiKey: "fixture-key", sessionID: "sess-0001")

        XCTAssertEqual(result, .failure(.unreachable))
    }

    func testStatus404WithSessionNotFoundCodeIsNotFound() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 404, body: Data(Self.sessionNotFoundBody.utf8))]
        let client = DiffClient(session: MockURLProtocol.makeSession())

        let result = await client.fetch(baseURL: baseURL, apiKey: "fixture-key", sessionID: "sess-0001")

        XCTAssertEqual(result, .failure(.notFound))
    }

    func testStatus404WithNoSuchRouteCodeIsContractViolationNotNotFound() async {
        MockURLProtocol.stubQueue = [
            .init(statusCode: 404, body: Data(#"{"error":"not found","code":"NO_SUCH_ROUTE"}"#.utf8))
        ]
        let client = DiffClient(session: MockURLProtocol.makeSession())

        let result = await client.fetch(baseURL: baseURL, apiKey: "fixture-key", sessionID: "sess-0001")

        XCTAssertEqual(
            result,
            .failure(.contractViolation(ResponseContractViolation(status: 404, code: "NO_SUCH_ROUTE")))
        )
    }

    // MARK: - 200 with an undecodable body

    func testStatus200WithUndecodableBodyIsMalformedBodyNotSuccess() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(#"{ "not": "the right shape" }"#.utf8))]
        let client = DiffClient(session: MockURLProtocol.makeSession())

        let result = await client.fetch(baseURL: baseURL, apiKey: "fixture-key", sessionID: "sess-0001")

        XCTAssertEqual(result, .failure(.malformedBody))
    }

    // MARK: - Cancellation

    func testInjectedURLErrorCancelledMapsToCancelledOutcome() async {
        MockURLProtocol.injectedError = URLError(.cancelled)
        let client = DiffClient(session: MockURLProtocol.makeSession())

        let result = await client.fetch(baseURL: baseURL, apiKey: "fixture-key", sessionID: "sess-0001")

        XCTAssertEqual(result, .failure(.cancelled))
    }

    func testRealTaskCancellationMapsToCancelledOutcome() async {
        MockURLProtocol.deliveryDelay = 0.3
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(Self.validBody.utf8))]
        let client = DiffClient(session: MockURLProtocol.makeSession())

        let task = Task { await client.fetch(baseURL: baseURL, apiKey: "fixture-key", sessionID: "sess-0001") }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let result = await task.value

        XCTAssertEqual(result, .failure(.cancelled))
    }

    // MARK: - The header every request must carry, and the request shape

    func testRequestCarriesTheKeyAsABearerAuthorizationHeader() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(Self.validBody.utf8))]
        let client = DiffClient(session: MockURLProtocol.makeSession())

        _ = await client.fetch(baseURL: baseURL, apiKey: "correct-fixture-key", sessionID: "sess-0001")

        XCTAssertEqual(MockURLProtocol.lastRequestHeaders?["Authorization"], "Bearer correct-fixture-key")
    }

    func testRequestURLCarriesSessionIDOnTheDiffRoute() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(Self.validBody.utf8))]
        let client = DiffClient(session: MockURLProtocol.makeSession())

        _ = await client.fetch(baseURL: baseURL, apiKey: "x", sessionID: "sess-abc-123")

        let requested = MockURLProtocol.requestedURLs.last
        XCTAssertEqual(requested?.path, "/api/sessions/sess-abc-123/diff")
    }

    func testRequestMethodIsGET() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(Self.validBody.utf8))]
        let client = DiffClient(session: MockURLProtocol.makeSession())

        _ = await client.fetch(baseURL: baseURL, apiKey: "x", sessionID: "sess-0001")

        XCTAssertEqual(MockURLProtocol.requestedMethods.last, "GET")
    }

    func testGETCarriesNoRequestBody() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(Self.validBody.utf8))]
        let client = DiffClient(session: MockURLProtocol.makeSession())

        _ = await client.fetch(baseURL: baseURL, apiKey: "x", sessionID: "sess-0001")

        XCTAssertEqual((MockURLProtocol.requestedBodies.last ?? nil)?.count ?? 0, 0)
    }

    // MARK: - Wait budget (`HistoryClient` と同じ4本目の次元、`test/request-shape.test.mjs` が
    // client ごとに必須で見張る)

    /// 会話を開いた**後**に押す脇の画面の要求 -- 待つのは人。`writeTimeout` ではなく
    /// `interactiveTimeout`(`HistoryClient` の判断をそのまま踏襲)。
    func testRequestUsesTheInteractiveTimeout() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(Self.validBody.utf8))]
        let client = DiffClient(session: MockURLProtocol.makeSession())

        _ = await client.fetch(baseURL: baseURL, apiKey: "x", sessionID: "sess-0001")

        XCTAssertEqual(MockURLProtocol.requestedTimeouts, [BackendSession.interactiveTimeout])
    }

    // MARK: - Negative controls: the four cases are not collapsed pairwise

    func test401And5xxAreNotCollapsedIntoOneOutcomeNegativeControl() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 401)]
        let unauthorized = await DiffClient(session: MockURLProtocol.makeSession())
            .fetch(baseURL: baseURL, apiKey: "x", sessionID: "s")
        MockURLProtocol.stubQueue = [.init(statusCode: 500)]
        let unreachable = await DiffClient(session: MockURLProtocol.makeSession())
            .fetch(baseURL: baseURL, apiKey: "x", sessionID: "s")

        XCTAssertNotEqual(unauthorized, unreachable)
    }

    func testCancelledIsNotCollapsedIntoUnreachableNegativeControl() async {
        MockURLProtocol.injectedError = URLError(.cancelled)
        let cancelled = await DiffClient(session: MockURLProtocol.makeSession())
            .fetch(baseURL: baseURL, apiKey: "x", sessionID: "s")
        MockURLProtocol.stubQueue = [.init(statusCode: 500)]
        let unreachable = await DiffClient(session: MockURLProtocol.makeSession())
            .fetch(baseURL: baseURL, apiKey: "x", sessionID: "s")

        XCTAssertNotEqual(cancelled, unreachable)
    }

    func testNotFoundIsNotCollapsedIntoUnreachableNegativeControl() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 404, body: Data(Self.sessionNotFoundBody.utf8))]
        let notFound = await DiffClient(session: MockURLProtocol.makeSession())
            .fetch(baseURL: baseURL, apiKey: "x", sessionID: "s")
        MockURLProtocol.stubQueue = [.init(statusCode: 500)]
        let unreachable = await DiffClient(session: MockURLProtocol.makeSession())
            .fetch(baseURL: baseURL, apiKey: "x", sessionID: "s")

        XCTAssertNotEqual(notFound, unreachable)
    }
}
