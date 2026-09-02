import XCTest
@testable import RemoteMini

/// `PathCompletionClient.complete` —— `@` の補完(2026-09-02)。
///
/// 重心は 2 つ:
///   ① **要求の全次元**(URL / method / header / body / 待ち時間)を線の上で見る。
///      `rc-backend/test/request-shape.test.mjs` が此の file の存在と、其の 5 つを
///      全部読んでいる事を機械的に見張る —— 見ていない次元は「変異を植えても
///      赤くならない = 実質守られていない」と其の検査が言う通り。
///   ② **取り消しを「届かない」に丸めない**。此の口だけは打鍵ごとに前の要求を
///      捨てるので、取り消しは異常ではなく常態。丸めると、速く打っただけで
///      「机に繋がらない」と描く事になる。
final class PathCompletionClientTests: XCTestCase {
    private let baseURL = URL(string: "https://unit-test.invalid")!

    override func setUp() { MockURLProtocol.reset() }
    override func tearDown() { MockURLProtocol.reset() }

    private func client() -> PathCompletionClient {
        PathCompletionClient(session: MockURLProtocol.makeSession())
    }

    private func ok(_ json: String) -> MockURLProtocol.Stub {
        .init(statusCode: 200, body: Data(json.utf8))
    }

    private static let body = #"{"paths":[{"path":"src/wire.mjs","kind":"file"}],"truncated":false,"reason":null}"#

    // MARK: - 要求の形

    func testRequestIsAGETToThePathsRouteWithTheQueryAndTheBearerKey() async {
        MockURLProtocol.stubQueue = [ok(Self.body)]

        _ = await client().complete(
            baseURL: baseURL, apiKey: "correct-fixture-key",
            sessionID: "sess-abc-123", query: "src/wi", limit: 30)

        let url = MockURLProtocol.requestedURLs.last
        XCTAssertEqual(url?.path, "/api/sessions/sess-abc-123/paths")
        let items = URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first(where: { $0.name == "q" })?.value, "src/wi")
        XCTAssertEqual(items.first(where: { $0.name == "limit" })?.value, "30")
        XCTAssertEqual(MockURLProtocol.requestedMethods.last, "GET")
        XCTAssertEqual(MockURLProtocol.lastRequestHeaders?["Authorization"], "Bearer correct-fixture-key")
    }

    /// ★空の問いでも `q=` を**送る**。`HistoryClient.search` は空を送らないが、
    ///   あちらは `q` が落ちると机の別経路(素の履歴)へ行くから。此処は同じ経路で、
    ///   空 = 「cwd の直下」= `@` を打った直後の一段目そのもの。落とすと入口が消える。
    func testAnEmptyQueryIsStillSentBecauseItMeansTheTopLevel() async {
        MockURLProtocol.stubQueue = [ok(Self.body)]

        _ = await client().complete(
            baseURL: baseURL, apiKey: "k", sessionID: "s", query: "", limit: 30)

        let items = URLComponents(url: MockURLProtocol.requestedURLs.last!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertTrue(items.contains(where: { $0.name == "q" }), "空の問いで `q` を落としている")
        XCTAssertEqual(items.first(where: { $0.name == "q" })?.value, "")
    }

    /// ★読む口なので本文は送らない。
    func testSendsNoBodyBecauseItIsAReadOnlyRoute() async {
        MockURLProtocol.stubQueue = [ok(Self.body)]

        _ = await client().complete(
            baseURL: baseURL, apiKey: "k", sessionID: "s", query: "a", limit: 5)

        let body = MockURLProtocol.requestedBodies.last ?? nil
        XCTAssertTrue(body == nil || body?.isEmpty == true, "本文を送っている: \(String(describing: body))")
    }

    /// ★書き込み用の長い待ちを使わない。補完は打鍵に付いて来なければ意味が無く、
    ///   長く待つと「もう画面に無い問い」の答えが遅れて着く窓が広がるだけ。
    func testUsesTheInteractiveTimeoutNotTheWriteTimeout() async {
        MockURLProtocol.stubQueue = [ok(Self.body)]

        _ = await client().complete(
            baseURL: baseURL, apiKey: "k", sessionID: "s", query: "a", limit: 5)

        XCTAssertEqual(MockURLProtocol.requestedTimeouts.last, BackendSession.interactiveTimeout)
        XCTAssertNotEqual(MockURLProtocol.requestedTimeouts.last, BackendSession.writeTimeout,
                          "書き込み用の待ちを使っている")
    }

    /// 日本語の問いが percent-encode されて往復する。
    func testAJapaneseQuerySurvivesTheRoundTrip() async {
        MockURLProtocol.stubQueue = [ok(Self.body)]

        _ = await client().complete(
            baseURL: baseURL, apiKey: "k", sessionID: "s", query: "資料/メモ", limit: 5)

        let items = URLComponents(url: MockURLProtocol.requestedURLs.last!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first(where: { $0.name == "q" })?.value, "資料/メモ")
    }

    // MARK: - 答えの読み方

    func testASuccessfulBodyDecodesIntoSuggestions() async {
        MockURLProtocol.stubQueue = [ok(#"""
        {"paths":[{"path":"src","kind":"dir"},{"path":"src/wire.mjs","kind":"file"}],
         "truncated":true,"reason":null}
        """#)]

        let result = await client().complete(
            baseURL: baseURL, apiKey: "k", sessionID: "s", query: "src", limit: 30)

        guard case .success(let response) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(response.paths,
                       [PathSuggestion(path: "src", kind: .dir),
                        PathSuggestion(path: "src/wire.mjs", kind: .file)])
        XCTAssertTrue(response.truncated)
        XCTAssertNil(response.reason)
    }

    /// ★机の断りは**語のまま**残す。丸めると、呼ぶ側が「作業場所が無い」と
    ///   「今は読めない」を区別できなくなる(前者は訊き直す意味が無い)。
    func testTheDeskRefusalSurvivesAsAWord() async {
        MockURLProtocol.stubQueue = [ok(#"{"paths":[],"truncated":false,"reason":"no_cwd"}"#)]

        let result = await client().complete(
            baseURL: baseURL, apiKey: "k", sessionID: "s", query: "a", limit: 30)

        guard case .success(let response) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(response.reason, PathCompletionReason.noCwd)
        XCTAssertTrue(response.paths.isEmpty)
    }

    func testUnauthorizedIsItsOwnCase() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 401, body: Data())]

        let result = await client().complete(
            baseURL: baseURL, apiKey: "k", sessionID: "s", query: "a", limit: 30)

        XCTAssertEqual(result, .failure(.unauthorized))
    }

    /// ★404 の読み分け。`HistoryClient` と**同じ narrowing** —— 会話が消えたのか、
    ///   電話が URL を組み違えたのかを status だけで決めない。
    func testA404WithoutTheSessionCodeIsAContractViolationNotADeletedSession() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 404, body: Data(#"{"code":"NO_SUCH_ROUTE"}"#.utf8))]

        let result = await client().complete(
            baseURL: baseURL, apiKey: "k", sessionID: "s", query: "a", limit: 30)

        XCTAssertEqual(result, .failure(.contractViolation(
            ResponseContractViolation(status: 404, code: "NO_SUCH_ROUTE"))))
    }

    func testA404WithTheSessionCodeIsADeletedSession() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 404, body: Data(#"{"code":"SESSION_NOT_FOUND"}"#.utf8))]

        let result = await client().complete(
            baseURL: baseURL, apiKey: "k", sessionID: "s", query: "a", limit: 30)

        XCTAssertEqual(result, .failure(.notFound))
    }

    /// ★必須鍵が欠けた 200 は `.malformedBody`。**空の候補列に化かさない** ——
    ///   「探したが無い」と「机が答えていない」を同じ顔にしない。
    func testA200MissingARequiredKeyIsMalformedNotEmpty() async {
        MockURLProtocol.stubQueue = [ok(#"{"paths":[]}"#)] // `truncated` が無い

        let result = await client().complete(
            baseURL: baseURL, apiKey: "k", sessionID: "s", query: "a", limit: 30)

        XCTAssertEqual(result, .failure(.malformedBody))
    }

    /// ★★取り消しは `.cancelled`。**`.unreachable` に丸めない** ——
    ///   此の口では取り消しが常態(打鍵ごとに前の要求を捨てる)なので、
    ///   丸めると速く打っただけで「机に繋がらない」を名乗る事になる。
    func testCancellationIsNotReportedAsUnreachable() async {
        MockURLProtocol.deliveryDelay = 5
        MockURLProtocol.stubQueue = [ok(Self.body)]

        let task = Task { [baseURL] in
            await PathCompletionClient(session: MockURLProtocol.makeSession())
                .complete(baseURL: baseURL, apiKey: "k", sessionID: "s", query: "a", limit: 30)
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()

        let result = await task.value
        XCTAssertEqual(result, .failure(.cancelled))
    }
}
