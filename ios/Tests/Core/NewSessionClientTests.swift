import XCTest
@testable import RemoteMini

/// `NewSessionClient.startNear` — 2026-08-31。
///
/// 此の client が他と違う所は 1 つ:**答えに会話の id が無い**。
/// 机は `202` を返すだけで、会話は Claude Code が jsonl を書き登録簿が拾って
/// 初めて存在する。だから検査の重心は「id を作っていない事」と、
/// **机が断った理由を潰していない事**に置く(結果の読み分けは
/// `NewSessionOutcomeTests` が別に測る)。
final class NewSessionClientTests: XCTestCase {
    private let baseURL = URL(string: "https://unit-test.invalid")!

    override func setUp() { MockURLProtocol.reset() }
    override func tearDown() { MockURLProtocol.reset() }

    // MARK: - 要求の形

    func testRequestIsAPOSTToTheSessionsNewPathWithTheBearerKey() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 202, body: Data(#"{"started":true}"#.utf8))]

        _ = await NewSessionClient(session: MockURLProtocol.makeSession())
            .startNear(baseURL: baseURL, apiKey: "correct-fixture-key", sessionID: "sess-abc-123")

        XCTAssertEqual(MockURLProtocol.requestedURLs.last?.path, "/api/sessions/sess-abc-123/new")
        XCTAssertEqual(MockURLProtocol.requestedMethods.last, "POST")
        XCTAssertEqual(MockURLProtocol.lastRequestHeaders?["Authorization"], "Bearer correct-fixture-key")
    }

    /// ★本文を送らない。何処で始めるかは**机が会話から引く** —— 電話が cwd を
    ///   組み立てて送る形にすると、電話が知っている筈のない path を電話が名乗る事になり、
    ///   机の登録簿と食い違った時に**どちらが正しいか誰にも判らなくなる**。
    func testSendsNoBodyBecauseTheDeskDerivesTheWorkingDirectory() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 202, body: Data(#"{"started":true}"#.utf8))]

        _ = await NewSessionClient(session: MockURLProtocol.makeSession())
            .startNear(baseURL: baseURL, apiKey: "k", sessionID: "s")

        let body = MockURLProtocol.requestedBodies.last ?? nil
        XCTAssertTrue(body == nil || body?.isEmpty == true, "本文を送っている: \(String(describing: body))")
    }

    /// ★書き込みの待ち時間を明示する。既定の読み取り用より長い ——
    ///   机は tmux の window を作って Claude Code を起こすので、`GET` の感覚で
    ///   短く切ると「始まっているのに諦めた」が起きる。
    ///   其れは最悪の形で、**押した人には失敗に見えるが机では会話が増えている**。
    func testUsesTheWriteTimeoutNotTheDefaultReadTimeout() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 202, body: Data(#"{"started":true}"#.utf8))]

        _ = await NewSessionClient(session: MockURLProtocol.makeSession())
            .startNear(baseURL: baseURL, apiKey: "k", sessionID: "s")

        XCTAssertEqual(MockURLProtocol.requestedTimeouts.last, BackendSession.writeTimeout)
    }

    // MARK: - 答えの読み方

    func testAcceptedDoesNotInventASessionID() async {
        // ★`202` は「受け付けた」であって「会話が在る」ではない。
        //   此処で id を作ると、存在しない物を電話に持たせる事になる。
        MockURLProtocol.stubQueue = [.init(statusCode: 202, body: Data(#"{"started":true}"#.utf8))]

        let outcome = await NewSessionClient(session: MockURLProtocol.makeSession())
            .startNear(baseURL: baseURL, apiKey: "k", sessionID: "s")

        XCTAssertEqual(outcome, .started)
        // 型自体が id を持たない事を、此処で明示的に固定する。
        XCTAssertTrue(outcome.text.lowercased().contains("list"),
                      "一覧に出るまで間が在る事を言っていない")
    }

    func testTheDeskReasonSurvivesInsteadOfCollapsingToAGenericFailure() async {
        // 机が「作業場所が無い」と言っているのに「届かない」に丸めると、
        // 人は網を疑って空振りする。
        MockURLProtocol.stubQueue = [.init(statusCode: 409, body: Data(#"{"error":"cwd_unknown","reason":"no_cwd"}"#.utf8))]

        let outcome = await NewSessionClient(session: MockURLProtocol.makeSession())
            .startNear(baseURL: baseURL, apiKey: "k", sessionID: "s")

        XCTAssertEqual(outcome, .noWorkingDirectory)
    }

    func testTmuxFailureIsNamedAsTheDeskNotAsTheNetwork() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 502, body: Data(#"{"error":"new_window_failed","reason":"tmux_failed"}"#.utf8))]

        let outcome = await NewSessionClient(session: MockURLProtocol.makeSession())
            .startNear(baseURL: baseURL, apiKey: "k", sessionID: "s")

        XCTAssertEqual(outcome, .deskRefused)
    }

    func testAnUnnamedFailureIsNotBlamedOnTmux() async {
        // ★`reason` が無い 500 = 何が起きたか判らない。机の異常と言い切ると、
        //   人は tmux を見に行って空振りする。判らない物は「届かない」へ。
        MockURLProtocol.stubQueue = [.init(statusCode: 500, body: Data(#"{"error":"boom"}"#.utf8))]

        let outcome = await NewSessionClient(session: MockURLProtocol.makeSession())
            .startNear(baseURL: baseURL, apiKey: "k", sessionID: "s")

        XCTAssertEqual(outcome, .unreachable)
    }
}
