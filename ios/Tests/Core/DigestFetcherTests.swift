import XCTest
@testable import RemoteMini

/// `DigestFetcher.fetch` の検査。`HistoryClientTests` と同じ `MockURLProtocol` の仕掛け、
/// 同じ書き方に揃える(error の語彙を 2 つ持たない、という §3-c の判断と同じ理由)。
///
/// ★ここが守る一線は「**本文を信じる前に status を見る**」(N6)と、
///   「**404 を 1 つの意味に丸めない**」の 2 つ。後者は `HistoryClient` が実測で
///   踏んだ罠で、丸めると **此方が URL を組み違えた事**を利用者に
///   「あなたの会話はもう在りません」と伝える事になる。
final class DigestFetcherTests: XCTestCase {

    override func setUp() { MockURLProtocol.reset() }
    override func tearDown() { MockURLProtocol.reset() }

    // 実サーバ出力(2026-08-26、Friday 上の src/digest.mjs)。手で組んでいない。
    private static let validBody = """
    {"digest":{"complete":true,"incompleteReason":null,"window":{"requestedFromIso":"2026-08-26T11:00:00.000Z","observedFromIso":"2026-08-26T11:01:00.000Z","toIso":"2026-08-26T12:00:00.000Z","minutes":60},"counts":{"user":1,"assistant":1,"tool":1},"tools":[{"name":"Read","n":1}],"fileTargets":["/a/b.txt"],"fileTargetsTotal":1,"lastAssistant":"done","lastAt":"2026-08-26T11:02:00.000Z"},"attention":"input","action":{"level":"soon","reason":"input"},"line":"60m · 1 replies · 1 tool calls · 1 file targets — stopped, needs a message."}
    """

    private func fetch(_ sid: String = "abc-123") async -> Result<SessionDigest, SessionsFetchError> {
        let client = DigestFetcher(session: MockURLProtocol.makeSession())
        return await client.fetch(baseURL: URL(string: "https://desk.example")!,
                                  apiKey: "k", sessionID: sid)
    }

    func test_200は要約を返す() async throws {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(Self.validBody.utf8))]
        let r = await fetch()
        guard case .success(let d) = r else { return XCTFail("失敗した: \(r)") }
        XCTAssertEqual(d.counts, .init(user: 1, assistant: 1, tool: 1))
        XCTAssertEqual(d.attention, .input)
        XCTAssertEqual(d.action, .soon)
        XCTAssertTrue(d.shouldUrge)
    }

    func test_401は鍵の失効として返す() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 401)]
        guard case .failure(.unauthorized) = await fetch() else {
            return XCTFail("401 を unauthorized にしていない")
        }
    }

    /// ★404 の片方: その会話が本当に無い。
    func test_404かつSESSION_NOT_FOUNDは会話が無いとして返す() async {
        let body = #"{"code":"SESSION_NOT_FOUND"}"#
        MockURLProtocol.stubQueue = [.init(statusCode: 404, body: Data(body.utf8))]
        guard case .failure(.notFound) = await fetch() else {
            return XCTFail("SESSION_NOT_FOUND を notFound にしていない")
        }
    }

    /// ★★404 のもう片方: **此方が URL を組み違えた**。
    /// これを `notFound` に丸めると「あなたの会話はもう在りません」と嘘を伝える。
    func test_404だが別の理由なら契約違反として返す_会話が消えたと言わない() async {
        let body = #"{"code":"NO_SUCH_ROUTE"}"#
        MockURLProtocol.stubQueue = [.init(statusCode: 404, body: Data(body.utf8))]
        let r = await fetch()
        if case .failure(.notFound) = r {
            return XCTFail("此方の URL 誤りを『会話が消えた』と伝えている")
        }
        guard case .failure(.contractViolation) = r else {
            return XCTFail("契約違反にしていない: \(r)")
        }
    }

    /// ★N6: **status が先**。200 でない応答の本文は、読める形でも読まない。
    func test_500は本文が正しくても信じない() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 500, body: Data(Self.validBody.utf8))]
        guard case .failure(.unreachable) = await fetch() else {
            return XCTFail("500 の本文を信じている")
        }
    }

    func test_200でも形が違えば壊れた本文として返す() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data("{}".utf8))]
        guard case .failure(.malformedBody) = await fetch() else {
            return XCTFail("壊れた本文を通した")
        }
    }

    // MARK: - request の全次元を見る
    //
    // ★門(`rc-backend/test/request-shape.test.mjs`)が要求している。理由は
    //   「一度も見ていない次元は、変異を植てても赤くならない = 実質守られていない」。
    //   実際 此の file の初版は 5 次元とも見ておらず、門が止めた。正しい指摘だった。

    func test_鍵をAuthorizationヘッダで運ぶ() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(Self.validBody.utf8))]
        let client = DigestFetcher(session: MockURLProtocol.makeSession())
        _ = await client.fetch(baseURL: URL(string: "https://desk.example")!,
                               apiKey: "correct-fixture-key", sessionID: "abc-123")
        XCTAssertEqual(MockURLProtocol.lastRequestHeaders?["Authorization"],
                       "Bearer correct-fixture-key")
    }

    func test_撃つURLが正しい() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(Self.validBody.utf8))]
        _ = await fetch("abc-123")
        XCTAssertEqual(MockURLProtocol.requestedURLs.last?.absoluteString,
                       "https://desk.example/api/sessions/abc-123/digest")
    }

    func test_GETで撃つ() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(Self.validBody.utf8))]
        _ = await fetch()
        XCTAssertEqual(MockURLProtocol.requestedMethods.last, "GET")
    }

    /// GET は本文を持たない。**想定ではなく測る**(`HistoryClientTests` と同じ判断)。
    func test_GETは本文を持たない() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(Self.validBody.utf8))]
        _ = await fetch()
        XCTAssertEqual((MockURLProtocol.requestedBodies.last ?? nil)?.count ?? 0, 0)
    }

    /// 待ち時間は `BackendSession.interactiveTimeout` に揃える。此処だけ別の値にすると、
    /// 冷えた起動(実測 TLS 6030ms)で此の口だけが先に諦める。
    func test_待ち時間が対話用に揃っている() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(Self.validBody.utf8))]
        _ = await fetch()
        XCTAssertEqual(MockURLProtocol.requestedTimeouts.last, BackendSession.interactiveTimeout)
    }

    /// ★id をそのまま path に混ぜない。`/` を含む id は**撃つ前に**断る。
    func test_危険なidは撃たずに断る() async {
        for bad in ["", "a/b", "a?b", "a#b", "../admin"] {
            let r = await fetch(bad)
            guard case .failure = r else {
                return XCTFail("危険な id を通した: \(bad)")
            }
        }
    }
}
