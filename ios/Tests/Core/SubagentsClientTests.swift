import XCTest
@testable import RemoteMini

/// `SubagentsClient.fetch` tests(対照表 #8「半分その一」、2026-09-05)。
/// `DiffClientTests` から様式を写す: 同じ `MockURLProtocol` の砂場、status 分岐、
/// cancellation、Authorization header、`SessionsFetchError` が対で潰れていない事の陰性対照。
///
/// ★此の口の要点は「**空配列に意味が3つ在る**」事。`directory`/`parent` を落とすと、
///   電話は一番都合の良い読み方(= 何も走っていない)をする。だから欄が届く事を測る。
final class SubagentsClientTests: XCTestCase {
    private let baseURL = URL(string: "https://unit-test.invalid")!

    override func setUp() { MockURLProtocol.reset() }
    override func tearDown() { MockURLProtocol.reset() }

    private static let twoAgents = """
    { "subagents": [
        { "agentId": "aaaa1111", "agentType": "Explore", "description": "終わった子",
          "model": "claude-opus-5", "state": "finished", "reason": "parent-completed",
          "meta": "read", "lastActivityIso": "2026-09-05T10:00:00.000Z",
          "display": { "state": "Finished" } },
        { "agentId": "bbbb2222", "agentType": "general-purpose", "description": "走っている子",
          "model": null, "state": "running", "reason": "no-result-active",
          "meta": "read", "lastActivityIso": "2026-09-05T10:05:00.000Z",
          "display": { "state": "Working" } }
      ],
      "directory": "read", "parent": "read", "truncated": false,
      "counts": { "finished": 1, "running": 1, "stalled": 0, "unknown": 0 },
      "display": { "note": "2 subagents." } }
    """
    private static let sessionNotFoundBody = #"{"error":"unknown session","code":"SESSION_NOT_FOUND"}"#

    // MARK: - Status-code branching

    func testStatus200DecodesTheRealShapeToSuccess() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(Self.twoAgents.utf8))]
        let client = SubagentsClient(session: MockURLProtocol.makeSession())

        let result = await client.fetch(baseURL: baseURL, apiKey: "correct-fixture-key", sessionID: "sess-0001")

        guard case .success(let body) = result else {
            return XCTFail("expected .success, got \(result)")
        }
        XCTAssertEqual(body.subagents.count, 2)
        XCTAssertEqual(body.subagents[0].display.state, "Finished")
        XCTAssertEqual(body.subagents[1].display.state, "Working")
        XCTAssertEqual(body.counts?.running, 1)
        XCTAssertEqual(body.display.note, "2 subagents.")
    }

    func testEmptyListStillCarriesWhyItIsEmpty() async {
        // ★之が此の口の一番大事な検査。`subagents: []` の意味は 3 通り在り、
        //   `directory`/`parent`/`display.note` が落ちると全部「何も走っていない」に化ける。
        let body = """
        { "subagents": [], "directory": "unreadable", "parent": "unscanned", "truncated": false,
          "counts": null, "display": { "note": "Could not read the subagent directory." } }
        """
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(body.utf8))]
        let client = SubagentsClient(session: MockURLProtocol.makeSession())

        let result = await client.fetch(baseURL: baseURL, apiKey: "x", sessionID: "sess-0001")

        guard case .success(let decoded) = result else {
            return XCTFail("expected .success, got \(result)")
        }
        XCTAssertTrue(decoded.subagents.isEmpty)
        XCTAssertEqual(decoded.directory, "unreadable")
        XCTAssertNil(decoded.counts, "読めなかった回に件数を出すと、0 を観測値として信じられる")
        XCTAssertFalse(decoded.display.note.isEmpty)
    }

    func testMissingCountsIsNotAnError() async {
        // `counts` の欠落と `null` は同じ「書けなかった」。片方だけを失敗にしない。
        let body = """
        { "subagents": [], "directory": "absent", "parent": "unscanned", "truncated": false,
          "display": { "note": "This session has no subagents." } }
        """
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(body.utf8))]
        let client = SubagentsClient(session: MockURLProtocol.makeSession())

        guard case .success(let decoded) = await client.fetch(baseURL: baseURL, apiKey: "x", sessionID: "s") else {
            return XCTFail("expected .success")
        }
        XCTAssertNil(decoded.counts)
        XCTAssertEqual(decoded.directory, "absent")
    }

    func testStatus401IsUnauthorized() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 401, body: Data())]
        let client = SubagentsClient(session: MockURLProtocol.makeSession())
        guard case .failure(.unauthorized) = await client.fetch(baseURL: baseURL, apiKey: "x", sessionID: "s") else {
            return XCTFail("expected .unauthorized")
        }
    }

    func testStatus404WithSessionNotFoundCodeIsNotFound() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 404, body: Data(Self.sessionNotFoundBody.utf8))]
        let client = SubagentsClient(session: MockURLProtocol.makeSession())
        guard case .failure(.notFound) = await client.fetch(baseURL: baseURL, apiKey: "x", sessionID: "s") else {
            return XCTFail("expected .notFound")
        }
    }

    func testStatus404WithoutTheCodeIsAContractViolation() async {
        // ★status ではなく CODE が決める(`DiffClient` と同じ判断)。綴りの無い 404 を
        //   「会話が無い」と読むと、電話が誤った path を組んだ時に其れが会話の消失に化ける。
        MockURLProtocol.stubQueue = [.init(statusCode: 404, body: Data(#"{"error":"nope"}"#.utf8))]
        let client = SubagentsClient(session: MockURLProtocol.makeSession())
        guard case .failure(.contractViolation) = await client.fetch(baseURL: baseURL, apiKey: "x", sessionID: "s") else {
            return XCTFail("expected .contractViolation")
        }
    }

    func testMalformedBodyIsItsOwnError() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data("not json".utf8))]
        let client = SubagentsClient(session: MockURLProtocol.makeSession())
        guard case .failure(.malformedBody) = await client.fetch(baseURL: baseURL, apiKey: "x", sessionID: "s") else {
            return XCTFail("expected .malformedBody")
        }
    }

    func testTheRequestItselfIsWhatWasIntended() async {
        // ★観測は `MockURLProtocol` が実際に受けた要求から採る(この repo の様式)。
        //   URL と動詞と鍵を別々に確かめるのは、3 つのうち 1 つでも違うと
        //   「机は答えたが別の物を答えた」になるから。
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(Self.twoAgents.utf8))]
        let client = SubagentsClient(session: MockURLProtocol.makeSession())
        _ = await client.fetch(baseURL: baseURL, apiKey: "the-key", sessionID: "sess-0001")

        XCTAssertEqual(MockURLProtocol.requestedURLs.first?.path, "/api/sessions/sess-0001/subagents")
        XCTAssertEqual(MockURLProtocol.requestedMethods.first, "GET")
        XCTAssertEqual(MockURLProtocol.lastRequestHeaders?["Authorization"], "Bearer the-key")
        XCTAssertNil(MockURLProtocol.requestedBodies.first ?? nil, "読むだけの口に本文は付けない")
        // ★期限も request の次元の1つ。`request-shape.test.mjs` が「一度も見ていない次元」を
        //   数えて赤にする —— 見ていない次元には変異を植えても赤が出ないので、実質守られていない。
        //   値は `BackendSession.interactiveTimeout`(画面が人を待たせる口の共通の期限)。
        XCTAssertEqual(MockURLProtocol.requestedTimeouts.first, BackendSession.interactiveTimeout)
    }
}
