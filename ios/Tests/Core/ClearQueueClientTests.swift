import XCTest
@testable import RemoteMini

/// `ClearQueueClient` — request の**全次元**(path / method / auth / body / timeout)と、
/// 応答の status ごとの写り先。outcome の**文言の判断**は `QueueViewStateTests` の持ち分
/// (`ClearQueueOutcome.from` は純関数)で、此処は「線に何を出すか」だけを測る。
final class ClearQueueClientTests: XCTestCase {
    private let baseURL = URL(string: "https://unit-test.invalid")!

    override func setUp() { MockURLProtocol.reset() }
    override func tearDown() { MockURLProtocol.reset() }

    func testTheRequestHitsTheQueueRouteAsADelete() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(#"{"dropped":1}"#.utf8))]
        let client = ClearQueueClient(session: MockURLProtocol.makeSession())

        _ = await client.clearQueue(baseURL: baseURL, apiKey: "secret-key", sessionID: "sess-1")

        XCTAssertEqual(MockURLProtocol.requestedURLs.last?.path, "/api/sessions/sess-1/queue")
        XCTAssertEqual(MockURLProtocol.requestedMethods.last, "DELETE")
        XCTAssertEqual(MockURLProtocol.lastRequestHeaders?["Authorization"], "Bearer secret-key")
    }

    /// 本文は1バイトも送らない。サーバは path 以外を読まない(`InterruptClient` と同じ契約)
    /// —— `{}` を送ると、後で誰かが「この形に鍵を足す」= 机が読まない物を電話が送る形になる。
    func testNoRequestBodyIsSent() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(#"{"dropped":0}"#.utf8))]
        let client = ClearQueueClient(session: MockURLProtocol.makeSession())

        _ = await client.clearQueue(baseURL: baseURL, apiKey: "k", sessionID: "s")

        let body = MockURLProtocol.requestedBodies.last ?? nil
        XCTAssertTrue(body == nil || body?.isEmpty == true, "本文を送っている: \(String(describing: body))")
    }

    /// 書く側の期限(取り消しは状態を変える操作)。
    func testTheWriteDeadlineIsUsed() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(#"{"dropped":0}"#.utf8))]
        let client = ClearQueueClient(session: MockURLProtocol.makeSession())

        _ = await client.clearQueue(baseURL: baseURL, apiKey: "k", sessionID: "s")

        XCTAssertEqual(MockURLProtocol.requestedTimeouts.last, BackendSession.writeTimeout)
    }

    func testADroppedCountRidesThroughFromTheWire() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(#"{"dropped":2}"#.utf8))]
        let client = ClearQueueClient(session: MockURLProtocol.makeSession())

        let outcome = await client.clearQueue(baseURL: baseURL, apiKey: "k", sessionID: "s")

        XCTAssertEqual(outcome, .ok("Cancelled 2 queued sends (the one already running is not stopped)."))
    }

    /// 409 = 設計された断り。サーバの人向けの文がそのまま渡る(丸めない)。
    func testARefusalCarriesTheServersSentence() async {
        let body = Data(#"{"error":"この会話は机で開かれています。"}"#.utf8)
        MockURLProtocol.stubQueue = [.init(statusCode: 409, body: body)]
        let client = ClearQueueClient(session: MockURLProtocol.makeSession())

        let outcome = await client.clearQueue(baseURL: baseURL, apiKey: "k", sessionID: "s")

        XCTAssertEqual(outcome, .refused("この会話は机で開かれています。"))
    }

    func testTransportFailureIsItsOwnSentenceNotACrash() async {
        MockURLProtocol.injectedError = URLError(.notConnectedToInternet)
        let client = ClearQueueClient(session: MockURLProtocol.makeSession())

        let outcome = await client.clearQueue(baseURL: baseURL, apiKey: "k", sessionID: "s")

        XCTAssertEqual(outcome, .error("Can't reach the desk"))
    }
}
