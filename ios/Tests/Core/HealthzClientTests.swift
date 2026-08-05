import XCTest
@testable import RemoteMini

final class HealthzClientTests: XCTestCase {
    private let baseURL = URL(string: "https://unit-test.invalid")!

    override func setUp() { MockURLProtocol.reset() }
    override func tearDown() { MockURLProtocol.reset() }

    func testSuccessDecodesTheBody() async {
        let body = Data(#"{"ok":true,"pid":4242,"uptime":10,"version":"1.2.3"}"#.utf8)
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: body)]
        let client = HealthzClient(session: MockURLProtocol.makeSession())

        let result = await client.check(baseURL: baseURL)

        switch result {
        case .success(let value):
            XCTAssertEqual(value, HealthzResult(ok: true, pid: 4242, uptimeSeconds: 10, version: "1.2.3"))
        case .failure(let error):
            XCTFail("expected success, got \(error)")
        }
    }

    func testNon200StatusIsRejectedWithoutAttemptingToDecodeTheBody() async {
        // N6 (spec §3-3 step 1): status is checked before the body is trusted. A 500
        // whose body would decode cleanly if trusted must still fail as
        // `.unexpectedStatus`, not `.malformedBody` and not a decoded (wrong) success.
        let body = Data(#"{"ok":true,"pid":1,"uptime":1,"version":"x"}"#.utf8)
        MockURLProtocol.stubQueue = [.init(statusCode: 500, body: body)]
        let client = HealthzClient(session: MockURLProtocol.makeSession())

        let result = await client.check(baseURL: baseURL)

        XCTAssertEqual(result, .failure(.unexpectedStatus(500)))
    }

    func testMalformed200BodyIsMalformedBody() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data("not json".utf8))]
        let client = HealthzClient(session: MockURLProtocol.makeSession())

        let result = await client.check(baseURL: baseURL)

        XCTAssertEqual(result, .failure(.malformedBody))
    }

    func testConnectionFailureIsUnreachable() async {
        MockURLProtocol.stubQueue = [] // empty queue -> MockURLProtocol fails the load
        let client = HealthzClient(session: MockURLProtocol.makeSession())

        let result = await client.check(baseURL: baseURL)

        XCTAssertEqual(result, .failure(.unreachable))
    }

    func testBadStatusAndMalformedBodyAreDistinctOutcomesNegativeControl() {
        // Negative control: an implementation that collapses "bad status" and "bad
        // body" into one generic failure would still satisfy a naive "is failure"
        // assertion. Prove the two `HealthzError` cases actually carry different
        // information, not the same case reached two ways.
        XCTAssertNotEqual(HealthzError.unexpectedStatus(500), HealthzError.malformedBody)
    }

    // MARK: - Request shape: URL, method, and the ABSENCE of an Authorization header
    // (2026-08-05: this file had zero checks on any of `MockURLProtocol`'s
    // `requested…`/`lastRequest…` dimensions -- see this type's own doc comment:
    // `/healthz` is the one endpoint that must NOT carry the API key, so the
    // correct assertion on `lastRequestHeaders` is that Authorization is absent,
    // not that it holds some value)

    func testRequestURLIsHealthz() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(#"{"ok":true,"pid":1,"uptime":1,"version":"x"}"#.utf8))]
        let client = HealthzClient(session: MockURLProtocol.makeSession())

        _ = await client.check(baseURL: baseURL)

        XCTAssertEqual(MockURLProtocol.requestedURLs.last?.path, "/healthz")
    }

    func testRequestMethodIsGET() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(#"{"ok":true,"pid":1,"uptime":1,"version":"x"}"#.utf8))]
        let client = HealthzClient(session: MockURLProtocol.makeSession())

        _ = await client.check(baseURL: baseURL)

        XCTAssertEqual(MockURLProtocol.requestedMethods.last, "GET")
    }

    func testRequestCarriesNoAuthorizationHeaderByDesign() async {
        // `HealthzClient.check` never calls `setValue(_:forHTTPHeaderField:)` at
        // all -- Key-entry uses this exact endpoint to tell "wrong URL" apart from
        // "wrong key" (this type's doc comment), which only works if a probe here
        // truly cannot fail for a key-related reason. A future change that started
        // attaching the bearer key here would be a silent authentication-scope
        // widening, not a refactor -- this must fail as loudly as a real behavior
        // change does.
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(#"{"ok":true,"pid":1,"uptime":1,"version":"x"}"#.utf8))]
        let client = HealthzClient(session: MockURLProtocol.makeSession())

        _ = await client.check(baseURL: baseURL)

        XCTAssertNil(MockURLProtocol.lastRequestHeaders?["Authorization"])
    }
}
