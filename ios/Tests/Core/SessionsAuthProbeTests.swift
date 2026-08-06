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

    // MARK: - Request shape: the other three recorded dimensions
    //
    // ★Added 2026-08-06, and the reason is the finding itself. `request-shape.test.mjs`
    // used to derive what it inspects from `ios/Sources/Core/*Client.swift`, and this
    // type is named `…Probe`. So it built a bearer-carrying request the request-shape
    // gate had never once looked at -- URL, method and body all unwatched here while
    // every neighbouring client was covered. The same shape as the finding that gate was
    // written from: not a missing check, a check that does not reach.
    // That scan now derives from "builds a `URLRequest`" instead of the filename, so a
    // future `…Probe`/`…Poller`/`…Uploader` cannot slip out the same way.

    func testRequestURLIsTheSessionsEndpoint() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200)]

        _ = await SessionsAuthProbe(session: MockURLProtocol.makeSession())
            .check(baseURL: baseURL, apiKey: "k")

        XCTAssertEqual(MockURLProtocol.requestedURLs.last?.path, "/api/sessions")
    }

    /// The probe only ever asks a question. A mutation to `"POST"` would make this
    /// key-entry check write to the server on every keystroke-triggered probe, and
    /// until this assertion existed nothing in the tree could see it.
    func testRequestMethodIsGET() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200)]

        _ = await SessionsAuthProbe(session: MockURLProtocol.makeSession())
            .check(baseURL: baseURL, apiKey: "k")

        XCTAssertEqual(MockURLProtocol.requestedMethods.last, "GET")
    }

    /// A GET carries no body. See `HistoryClientTests`' copy for why this dimension is
    /// asserted rather than assumed.
    func testGETCarriesNoRequestBody() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200)]

        _ = await SessionsAuthProbe(session: MockURLProtocol.makeSession())
            .check(baseURL: baseURL, apiKey: "k")

        XCTAssertEqual((MockURLProtocol.requestedBodies.last ?? nil)?.count ?? 0, 0)
    }

    /// Key entry runs this probe while the user waits on the setup screen, so it takes
    /// the shortened read timeout rather than the 30s poll length.
    /// What `requestedTimeouts` does and does not prove: see `RequestTimeoutTests`.
    func testRequestUsesTheInteractiveTimeout() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200)]

        _ = await SessionsAuthProbe(session: MockURLProtocol.makeSession())
            .check(baseURL: baseURL, apiKey: "k")

        XCTAssertEqual(MockURLProtocol.requestedTimeouts, [BackendSession.interactiveTimeout])
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
