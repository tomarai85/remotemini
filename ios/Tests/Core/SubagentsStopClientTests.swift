import XCTest
@testable import RemoteMini

/// `SubagentsClient.stop` tests(対照表 #8「半分その二」、2026-09-06)。`SubagentsClientTests` と同じ砂場。
/// 要点: 409 は「断った」であって輸送の失敗ではない —— 本文の `reason`/`error` が届く事を測る。
final class SubagentsStopClientTests: XCTestCase {
    private let baseURL = URL(string: "https://unit-test.invalid")!
    override func setUp() { MockURLProtocol.reset() }
    override func tearDown() { MockURLProtocol.reset() }

    private static let observed = """
    { "stopped": "observed", "reason": null, "error": null, "sent": true,
      "keys": ["-l /tasks", "Enter", "Enter", "-l x", "Escape"], "escapes": 1,
      "target": { "agentId": "a6de70ba039382014", "description": "count slowly" },
      "after": { "screen": "SENDABLE", "overlayClosed": true, "stopObserved": "panel" } }
    """
    private static let refused = """
    { "stopped": false, "reason": "ambiguous",
      "error": "More than one running agent has this exact description and nothing on the desk tells them apart. Nothing was pressed.",
      "sent": false, "keys": ["-l /tasks", "Enter", "Escape"], "escapes": 1,
      "target": { "agentId": "a6de70ba039382014", "description": "count slowly" }, "after": null }
    """

    func testPostsToTheStopPathWithBearerAndEmptyJsonBody() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(Self.observed.utf8))]
        let client = SubagentsClient(session: MockURLProtocol.makeSession())
        let result = await client.stop(baseURL: baseURL, apiKey: "correct-fixture-key", sessionID: "sess-0001", agentID: "a6de70ba039382014")
        guard case .success(let body) = result else { return XCTFail("expected .success, got \(result)") }
        XCTAssertTrue(body.stopped)
        XCTAssertEqual(body.escapes, 1)
        XCTAssertEqual(body.target?.description, "count slowly")
        XCTAssertEqual(MockURLProtocol.requestedMethods.last, "POST")
        XCTAssertEqual(MockURLProtocol.requestedURLs.last?.path, "/api/sessions/sess-0001/subagents/a6de70ba039382014/stop")
        XCTAssertEqual(MockURLProtocol.lastRequestHeaders?["Authorization"], "Bearer correct-fixture-key")
        XCTAssertEqual(MockURLProtocol.requestedBodies.last.flatMap { $0 }.map { String(decoding: $0, as: UTF8.self) }, "{}")
    }

    func testStatus409IsARefusalCarriedInTheBodyNotATransportFailure() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 409, body: Data(Self.refused.utf8))]
        let client = SubagentsClient(session: MockURLProtocol.makeSession())
        let result = await client.stop(baseURL: baseURL, apiKey: "x", sessionID: "sess-0001", agentID: "a6de70ba039382014")
        guard case .success(let body) = result else { return XCTFail("expected .success(refusal), got \(result)") }
        XCTAssertFalse(body.stopped)
        XCTAssertEqual(body.reason, "ambiguous")
        XCTAssertEqual(body.sent, false)
        XCTAssertTrue((body.error ?? "").hasSuffix("Nothing was pressed."), "机の文がそのまま届く")
    }

    func testStoppedFalseAsBooleanAndMissingFieldsStillDecode() async {
        let body = #"{ "stopped": false, "reason": "unverified", "error": "x", "sent": true }"#
        MockURLProtocol.stubQueue = [.init(statusCode: 409, body: Data(body.utf8))]
        let client = SubagentsClient(session: MockURLProtocol.makeSession())
        let result = await client.stop(baseURL: baseURL, apiKey: "x", sessionID: "s", agentID: "a")
        guard case .success(let decoded) = result else { return XCTFail("expected .success, got \(result)") }
        XCTAssertFalse(decoded.stopped)
        XCTAssertTrue(decoded.sent)
        XCTAssertEqual(decoded.escapes, 0)
        XCTAssertNil(decoded.target)
    }

    func testStatus401IsUnauthorizedAndOthersAreUnreachable() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 401, body: Data()), .init(statusCode: 500, body: Data())]
        let client = SubagentsClient(session: MockURLProtocol.makeSession())
        let r1 = await client.stop(baseURL: baseURL, apiKey: "x", sessionID: "s", agentID: "a")
        guard case .failure(.unauthorized) = r1 else { return XCTFail("expected .unauthorized, got \(r1)") }
        let r2 = await client.stop(baseURL: baseURL, apiKey: "x", sessionID: "s", agentID: "a")
        guard case .failure(.unreachable) = r2 else { return XCTFail("expected .unreachable, got \(r2)") }
    }

    func testMalformedBodyOn200IsMalformedNotSuccess() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data("not json".utf8))]
        let client = SubagentsClient(session: MockURLProtocol.makeSession())
        let r = await client.stop(baseURL: baseURL, apiKey: "x", sessionID: "s", agentID: "a")
        guard case .failure(.malformedBody) = r else { return XCTFail("expected .malformedBody, got \(r)") }
    }
}
