import XCTest
@testable import RemoteMini

final class SessionsAuthProbeTests: XCTestCase {
    private let baseURL = URL(string: "https://unit-test.invalid")!

    override func setUp() { MockURLProtocol.reset() }
    override func tearDown() { MockURLProtocol.reset() }

    func testStatus200IsAuthorized() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200)]
        let probe = SessionsAuthProbe(session: MockURLProtocol.makeSession())

        let outcome = await probe.check(baseURL: baseURL, apiKey: "correct-fixture-key")

        XCTAssertEqual(outcome, .authorized)
    }

    func testStatus401IsUnauthorized() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 401)]
        let probe = SessionsAuthProbe(session: MockURLProtocol.makeSession())

        let outcome = await probe.check(baseURL: baseURL, apiKey: "wrong-fixture-key")

        XCTAssertEqual(outcome, .unauthorized)
    }

    func testOtherStatusIsUnreachable() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 500)]
        let probe = SessionsAuthProbe(session: MockURLProtocol.makeSession())

        let outcome = await probe.check(baseURL: baseURL, apiKey: "fixture-key")

        XCTAssertEqual(outcome, .unreachable)
    }

    func testConnectionFailureIsUnreachable() async {
        MockURLProtocol.stubQueue = []
        let probe = SessionsAuthProbe(session: MockURLProtocol.makeSession())

        let outcome = await probe.check(baseURL: baseURL, apiKey: "fixture-key")

        XCTAssertEqual(outcome, .unreachable)
    }

    func testRequestCarriesTheKeyAsABearerAuthorizationHeader() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200)]
        let probe = SessionsAuthProbe(session: MockURLProtocol.makeSession())

        _ = await probe.check(baseURL: baseURL, apiKey: "correct-fixture-key")

        XCTAssertEqual(MockURLProtocol.lastRequestHeaders?["Authorization"], "Bearer correct-fixture-key")
    }

    func test401And5xxAreNotCollapsedIntoOneOutcomeNegativeControl() async {
        // Negative control: the easy mistake is treating "not 200" as one bucket,
        // which would show the same message for "wrong key" and "server broken".
        // Prove the two stubbed responses actually produce different `Outcome`
        // cases.
        MockURLProtocol.stubQueue = [.init(statusCode: 401)]
        let unauthorized = await SessionsAuthProbe(session: MockURLProtocol.makeSession())
            .check(baseURL: baseURL, apiKey: "x")
        MockURLProtocol.stubQueue = [.init(statusCode: 500)]
        let serverError = await SessionsAuthProbe(session: MockURLProtocol.makeSession())
            .check(baseURL: baseURL, apiKey: "x")

        XCTAssertNotEqual(unauthorized, serverError)
    }
}
