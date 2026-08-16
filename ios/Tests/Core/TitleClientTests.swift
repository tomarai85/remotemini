import XCTest
@testable import RemoteMini

/// `TitleClient` — request の**全次元**(path / method / auth / body / timeout)と、
/// 応答の status → 意味の写像(spec-audit A1)。`ClearQueueClientTests` と同じ層の切り方。
final class TitleClientTests: XCTestCase {
    private let baseURL = URL(string: "https://unit-test.invalid")!

    override func setUp() { MockURLProtocol.reset() }
    override func tearDown() { MockURLProtocol.reset() }

    func testTheRequestHitsTheTitleRouteAsAPost() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(#"{"title":"名"}"#.utf8))]
        let client = TitleClient(session: MockURLProtocol.makeSession())

        _ = await client.rename(baseURL: baseURL, apiKey: "secret-key", sessionID: "sess-1", title: "名")

        XCTAssertEqual(MockURLProtocol.requestedURLs.last?.path, "/api/sessions/sess-1/title")
        XCTAssertEqual(MockURLProtocol.requestedMethods.last, "POST")
        XCTAssertEqual(MockURLProtocol.lastRequestHeaders?["Authorization"], "Bearer secret-key")
    }

    /// 付ける時の本文は `{"title": "<名>"}`。
    func testTheBodyCarriesTheTitle() async throws {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(#"{"title":"新しい名"}"#.utf8))]
        let client = TitleClient(session: MockURLProtocol.makeSession())

        _ = await client.rename(baseURL: baseURL, apiKey: "k", sessionID: "s", title: "新しい名")

        let body = try XCTUnwrap(MockURLProtocol.requestedBodies.last ?? nil)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(obj["title"] as? String, "新しい名")
    }

    /// ★外す時の本文は `{"title": null}` — **鍵の省略ではない**。synthesized Codable の
    /// Optional は encodeIfPresent(省略)に落ちるので、この検査が実装の辞書形を守る。
    /// 省略に退化するとサーバは「形が悪い」と読み、名前が二度と外せなくなる。
    func testClearingSendsAnExplicitNullNotAMissingKey() async throws {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(#"{"title":null}"#.utf8))]
        let client = TitleClient(session: MockURLProtocol.makeSession())

        _ = await client.rename(baseURL: baseURL, apiKey: "k", sessionID: "s", title: nil)

        let body = try XCTUnwrap(MockURLProtocol.requestedBodies.last ?? nil)
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("\"title\":null"), "null が線に載っていない: \(text)")
    }

    /// 書く側の期限(名前の付け外しは状態を変える操作)。
    func testTheWriteDeadlineIsUsed() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(#"{"title":"x"}"#.utf8))]
        let client = TitleClient(session: MockURLProtocol.makeSession())

        _ = await client.rename(baseURL: baseURL, apiKey: "k", sessionID: "s", title: "x")

        XCTAssertEqual(MockURLProtocol.requestedTimeouts.last, BackendSession.writeTimeout)
    }

    /// status → 意味の写像(純関数側)。
    func testStatusMapping() {
        XCTAssertEqual(RenameOutcome.from(status: 200, savedTitle: "名", serverError: nil), .renamed("名"))
        XCTAssertEqual(RenameOutcome.from(status: 200, savedTitle: nil, serverError: nil), .renamed(nil),
                       "外した時(title:null)の 200 は「無名に戻った」")
        XCTAssertEqual(RenameOutcome.from(status: 400, savedTitle: nil, serverError: "title required"), .rejected)
        XCTAssertEqual(RenameOutcome.from(status: 401, savedTitle: nil, serverError: nil), .unauthorized)
        XCTAssertEqual(RenameOutcome.from(status: 500, savedTitle: nil, serverError: nil), .unreachable)
        XCTAssertEqual(RenameOutcome.from(status: 404, savedTitle: nil, serverError: nil), .unreachable)
    }
}
