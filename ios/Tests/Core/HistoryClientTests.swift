import XCTest
@testable import RemoteMini

/// `HistoryClient.fetch` tests -- same `MockURLProtocol` harness, same style, as
/// `SessionsClientTests`. Reuses that suite's structure deliberately: status-code
/// branching, cancellation (both injected and real `Task.cancel()`), the
/// Authorization header, and the same 3 negative controls proving `SessionsFetchError`'s
/// 4 cases are not collapsed pairwise for THIS client too (brief §3-c: it's the same
/// enum, but a fresh `switch` in a fresh file is a fresh place to get the mapping wrong).
final class HistoryClientTests: XCTestCase {
    private let baseURL = URL(string: "https://unit-test.invalid")!

    override func setUp() { MockURLProtocol.reset() }
    override func tearDown() { MockURLProtocol.reset() }

    // MARK: - Status-code branching

    func testStatus200DecodesTheRealShapeToSuccess() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(Self.validBody.utf8))]
        let client = HistoryClient(session: MockURLProtocol.makeSession())

        let result = await client.fetch(baseURL: baseURL, apiKey: "correct-fixture-key", sessionID: "sess-0001", limit: 50)

        guard case .success(let response) = result else {
            return XCTFail("expected .success, got \(result)")
        }
        XCTAssertEqual(response.history.count, 1)
        XCTAssertEqual(response.history[0].role, .user)
        XCTAssertEqual(response.truncated, false)
    }

    func testStatus401IsUnauthorized() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 401)]
        let client = HistoryClient(session: MockURLProtocol.makeSession())

        let result = await client.fetch(baseURL: baseURL, apiKey: "wrong-fixture-key", sessionID: "sess-0001", limit: 50)

        XCTAssertEqual(result, .failure(.unauthorized))
    }

    func testOtherStatusIsUnreachable() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 500)]
        let client = HistoryClient(session: MockURLProtocol.makeSession())

        let result = await client.fetch(baseURL: baseURL, apiKey: "fixture-key", sessionID: "sess-0001", limit: 50)

        XCTAssertEqual(result, .failure(.unreachable))
    }

    // Brief §3-c (same-day correction): 404 gets its own case, distinct from the
    // generic `.unreachable` bucket `testOtherStatusIsUnreachable` above covers --
    // `server.mjs`'s `/history` handler, `json(res, 404, { error: "unknown session" })`.
    //
    // Sprint 5 brief §0-c ② narrowed it: the CODE decides, not the status. This test
    // used to stub a bare `.init(statusCode: 404)` with no body at all and assert
    // `.notFound`, which is exactly the behaviour DoD row 6 removes -- so it now sends
    // the body `server.mjs` actually sends.
    func testStatus404WithSessionNotFoundCodeIsNotFound() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 404, body: Data(Self.sessionNotFoundBody.utf8))]
        let client = HistoryClient(session: MockURLProtocol.makeSession())

        let result = await client.fetch(baseURL: baseURL, apiKey: "fixture-key", sessionID: "sess-0001", limit: 50)

        XCTAssertEqual(result, .failure(.notFound))
    }

    /// DoD row 6. The other two `json(res, 404, …)` sites in `server.mjs` send
    /// `NO_SUCH_ROUTE`, which means the phone asked for a path that does not exist --
    /// a bug in this app, not a deleted conversation.
    func testStatus404WithNoSuchRouteCodeIsContractViolationNotNotFound() async {
        MockURLProtocol.stubQueue = [
            .init(statusCode: 404, body: Data(#"{"error":"not found","code":"NO_SUCH_ROUTE"}"#.utf8))
        ]
        let client = HistoryClient(session: MockURLProtocol.makeSession())

        let result = await client.fetch(baseURL: baseURL, apiKey: "fixture-key", sessionID: "sess-0001", limit: 50)

        XCTAssertEqual(
            result,
            .failure(.contractViolation(ResponseContractViolation(status: 404, code: "NO_SUCH_ROUTE")))
        )
    }

    /// A 404 whose body does not parse at all cannot be shown to say
    /// `SESSION_NOT_FOUND`, so it must not be believed to. Fail toward "we could not
    /// read this," never toward the recovery action.
    func testStatus404WithUnreadableBodyIsContractViolation() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 404, body: Data("<html>404</html>".utf8))]
        let client = HistoryClient(session: MockURLProtocol.makeSession())

        let result = await client.fetch(baseURL: baseURL, apiKey: "fixture-key", sessionID: "sess-0001", limit: 50)

        XCTAssertEqual(
            result,
            .failure(.contractViolation(ResponseContractViolation(status: 404, code: nil)))
        )
    }

    /// Negative control for the pair above: the two 404 bodies must not produce the
    /// same outcome. Without this, both tests could be satisfied by a client that
    /// returned `.contractViolation` for every 404 -- which would break the real
    /// recovery path while looking green.
    func testTheTwo404sAreNotCollapsedNegativeControl() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 404, body: Data(Self.sessionNotFoundBody.utf8))]
        let gone = await HistoryClient(session: MockURLProtocol.makeSession())
            .fetch(baseURL: baseURL, apiKey: "x", sessionID: "s", limit: 50)
        MockURLProtocol.stubQueue = [
            .init(statusCode: 404, body: Data(#"{"error":"not found","code":"NO_SUCH_ROUTE"}"#.utf8))
        ]
        let badPath = await HistoryClient(session: MockURLProtocol.makeSession())
            .fetch(baseURL: baseURL, apiKey: "x", sessionID: "s", limit: 50)

        XCTAssertNotEqual(gone, badPath)
    }

    func testConnectionFailureIsUnreachable() async {
        MockURLProtocol.stubQueue = []
        let client = HistoryClient(session: MockURLProtocol.makeSession())

        let result = await client.fetch(baseURL: baseURL, apiKey: "fixture-key", sessionID: "sess-0001", limit: 50)

        XCTAssertEqual(result, .failure(.unreachable))
    }

    // MARK: - 200 with an undecodable body

    func testStatus200WithUndecodableBodyIsMalformedBodyNotSuccess() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(#"{ "not": "the right shape" }"#.utf8))]
        let client = HistoryClient(session: MockURLProtocol.makeSession())

        let result = await client.fetch(baseURL: baseURL, apiKey: "fixture-key", sessionID: "sess-0001", limit: 50)

        XCTAssertEqual(result, .failure(.malformedBody))
    }

    // MARK: - Cancellation

    func testInjectedURLErrorCancelledMapsToCancelledOutcome() async {
        MockURLProtocol.injectedError = URLError(.cancelled)
        let client = HistoryClient(session: MockURLProtocol.makeSession())

        let result = await client.fetch(baseURL: baseURL, apiKey: "fixture-key", sessionID: "sess-0001", limit: 50)

        XCTAssertEqual(result, .failure(.cancelled))
    }

    func testRealTaskCancellationMapsToCancelledOutcome() async {
        // Same deterministic-delay technique as `SessionsClientTests` -- see that
        // file's doc comment on this test for why a blocking wait was rejected.
        MockURLProtocol.deliveryDelay = 0.3
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(Self.validBody.utf8))]
        let client = HistoryClient(session: MockURLProtocol.makeSession())

        let task = Task { await client.fetch(baseURL: baseURL, apiKey: "fixture-key", sessionID: "sess-0001", limit: 50) }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let result = await task.value

        XCTAssertEqual(result, .failure(.cancelled))
    }

    // MARK: - The header every request must carry, and the limit query param

    func testRequestCarriesTheKeyAsABearerAuthorizationHeader() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(Self.validBody.utf8))]
        let client = HistoryClient(session: MockURLProtocol.makeSession())

        _ = await client.fetch(baseURL: baseURL, apiKey: "correct-fixture-key", sessionID: "sess-0001", limit: 50)

        XCTAssertEqual(MockURLProtocol.lastRequestHeaders?["Authorization"], "Bearer correct-fixture-key")
    }

    func testRequestURLCarriesSessionIDAndLimit() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(Self.validBody.utf8))]
        let client = HistoryClient(session: MockURLProtocol.makeSession())

        _ = await client.fetch(baseURL: baseURL, apiKey: "x", sessionID: "sess-abc-123", limit: 150)

        let requested = MockURLProtocol.requestedURLs.last
        XCTAssertEqual(requested?.path, "/api/sessions/sess-abc-123/history")
        XCTAssertEqual(requested?.query, "limit=150")
    }

    // 2026-08-05: `SessionsClient`/`SessionsModels`'s mutation-audit gap (no method
    // check anywhere in the tree) applies to this client too -- added alongside it.
    func testRequestMethodIsGET() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(Self.validBody.utf8))]
        let client = HistoryClient(session: MockURLProtocol.makeSession())

        _ = await client.fetch(baseURL: baseURL, apiKey: "x", sessionID: "sess-0001", limit: 50)

        XCTAssertEqual(MockURLProtocol.requestedMethods.last, "GET")
    }

    // MARK: - Negative controls: the four cases are not collapsed pairwise

    func test401And5xxAreNotCollapsedIntoOneOutcomeNegativeControl() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 401)]
        let unauthorized = await HistoryClient(session: MockURLProtocol.makeSession())
            .fetch(baseURL: baseURL, apiKey: "x", sessionID: "s", limit: 50)
        MockURLProtocol.stubQueue = [.init(statusCode: 500)]
        let unreachable = await HistoryClient(session: MockURLProtocol.makeSession())
            .fetch(baseURL: baseURL, apiKey: "x", sessionID: "s", limit: 50)

        XCTAssertNotEqual(unauthorized, unreachable)
    }

    func testCancelledIsNotCollapsedIntoUnreachableNegativeControl() async {
        MockURLProtocol.injectedError = URLError(.cancelled)
        let cancelled = await HistoryClient(session: MockURLProtocol.makeSession())
            .fetch(baseURL: baseURL, apiKey: "x", sessionID: "s", limit: 50)
        MockURLProtocol.stubQueue = [.init(statusCode: 500)]
        let unreachable = await HistoryClient(session: MockURLProtocol.makeSession())
            .fetch(baseURL: baseURL, apiKey: "x", sessionID: "s", limit: 50)

        XCTAssertNotEqual(cancelled, unreachable)
    }

    func testMalformedBodyIsNotCollapsedIntoUnreachableNegativeControl() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(#"{ "not": "the right shape" }"#.utf8))]
        let malformed = await HistoryClient(session: MockURLProtocol.makeSession())
            .fetch(baseURL: baseURL, apiKey: "x", sessionID: "s", limit: 50)
        MockURLProtocol.stubQueue = [.init(statusCode: 500)]
        let unreachable = await HistoryClient(session: MockURLProtocol.makeSession())
            .fetch(baseURL: baseURL, apiKey: "x", sessionID: "s", limit: 50)

        XCTAssertNotEqual(malformed, unreachable)
    }

    func testNotFoundIsNotCollapsedIntoUnreachableNegativeControl() async {
        // Guards against exactly the mistake the brief's own first draft made
        // (§3-c): a `default:` arm that swallows 404 alongside every other
        // non-200/401 status would make this equal `.unreachable`, and Conversation
        // would offer a useless "再試行" button on an already-permanent 404.
        MockURLProtocol.stubQueue = [.init(statusCode: 404, body: Data(Self.sessionNotFoundBody.utf8))]
        let notFound = await HistoryClient(session: MockURLProtocol.makeSession())
            .fetch(baseURL: baseURL, apiKey: "x", sessionID: "s", limit: 50)
        MockURLProtocol.stubQueue = [.init(statusCode: 500)]
        let unreachable = await HistoryClient(session: MockURLProtocol.makeSession())
            .fetch(baseURL: baseURL, apiKey: "x", sessionID: "s", limit: 50)

        XCTAssertNotEqual(notFound, unreachable)
    }

    // MARK: - Request body (Sprint 5's third recorded dimension)

    /// A GET must carry no body. Asserted rather than assumed: `requestedBodies` is a
    /// new recorder, and a dimension nobody reads is a dimension a mutation can move
    /// freely -- which is the entire finding `request-shape.test.mjs` was written from.
    ///
    /// `?? Data()` collapses "no body recorded" and "empty body" for the count only;
    /// both are correct here, and distinguishing them would assert a difference
    /// `URLSession` does not promise to preserve.
    func testGETCarriesNoRequestBody() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(Self.validBody.utf8))]
        let client = HistoryClient(session: MockURLProtocol.makeSession())

        _ = await client.fetch(baseURL: baseURL, apiKey: "x", sessionID: "sess-0001", limit: 50)

        XCTAssertEqual((MockURLProtocol.requestedBodies.last ?? nil)?.count ?? 0, 0)
    }

    // MARK: - Wait budget (the fourth recorded dimension, 2026-08-06)

    /// This is the request behind 会話を開く. Until the timeouts were split it waited
    /// the poll length (30s), so opening a conversation on a network that accepts the
    /// connection and then goes silent showed a bare `ProgressView` for half a minute
    /// before offering 再試行 -- RC 却下理由 1 reproduced inside this app.
    /// What `requestedTimeouts` does and does not prove: see `RequestTimeoutTests`.
    func testRequestUsesTheInteractiveTimeout() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(Self.validBody.utf8))]
        let client = HistoryClient(session: MockURLProtocol.makeSession())

        _ = await client.fetch(baseURL: baseURL, apiKey: "x", sessionID: "sess-0001", limit: 50)

        XCTAssertEqual(MockURLProtocol.requestedTimeouts, [BackendSession.interactiveTimeout])
    }

    // MARK: - 転写を探す(2026-09-01、spec §2-b。扉A)

    /// ★扉Aで守れる事と守れない事を先に書く。此処が見るのは
    ///   「`HistoryClient` が組み立てた `URLRequest`」まで —— **綴りが机の読む綴りと
    ///   一致するか**は見ない(`MockURLProtocol` は何を送っても 200 を返す)。
    ///   `q` という綴りが机に通じる事は `test/e2e-local.mjs` の往復(扉E)が持つ。
    ///   両方 要る: 此処だけなら机の綴りが変わっても緑、扉Eだけなら
    ///   電話が `q` を組み立てる行を消しても(要求が飛ばないだけで)気付きにくい。

    /// spec §9 の M1。`URLQueryItem(name: "q", …)` の行を消すと此処が赤くなる。
    func testSearchRequestCarriesTheQueryAsQParam() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(Self.validSearchBody.utf8))]
        let client = HistoryClient(session: MockURLProtocol.makeSession())

        _ = await client.search(baseURL: baseURL, apiKey: "x", sessionID: "sess-abc-123", limit: 100, query: "boot")

        let requested = MockURLProtocol.requestedURLs.last
        XCTAssertEqual(requested?.path, "/api/sessions/sess-abc-123/history")
        let items = URLComponents(url: requested!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first(where: { $0.name == "limit" })?.value, "100")
        XCTAssertEqual(items.first(where: { $0.name == "q" })?.value, "boot")
    }

    /// 日本語の問いが percent-encode されて往復する。**電話で打つ側は英語で打たない。**
    func testSearchCarriesAJapaneseQueryPercentEncoded() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(Self.validSearchBody.utf8))]
        let client = HistoryClient(session: MockURLProtocol.makeSession())

        let result = await client.search(baseURL: baseURL, apiKey: "x", sessionID: "s", limit: 100, query: "こんにちは")

        let raw = MockURLProtocol.requestedURLs.last?.absoluteString ?? ""
        XCTAssertTrue(raw.contains("q=%E3%81%93%E3%82%93%E3%81%AB%E3%81%A1%E3%81%AF"), raw)
        // 送れた事だけでなく、**返って来た物が探索の型として読める**所まで見る。
        guard case .success(let response) = result else { return XCTFail("expected .success, got \(result)") }
        XCTAssertEqual(response.matched, 7)
    }

    /// 空白だけの問いでは `q` を**付けない**(既存 `HistoryClient` の判断の継承)。
    /// ★付けてしまうと机は素の履歴経路へ落ち、`matched` の無い body が返る =
    ///   電話はそれを `.malformedBody` と読む。付けない方が往復 1 回ぶん安い。
    func testSearchOmitsQForABlankQuery() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(Self.validSearchBody.utf8))]
        let client = HistoryClient(session: MockURLProtocol.makeSession())

        _ = await client.search(baseURL: baseURL, apiKey: "x", sessionID: "s", limit: 100, query: "   \n ")

        let items = URLComponents(url: MockURLProtocol.requestedURLs.last!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertNil(items.first(where: { $0.name == "q" }))
        XCTAssertEqual(items.first(where: { $0.name == "limit" })?.value, "100")
    }

    func testSearchRequestMethodIsGETAndCarriesNoBody() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(Self.validSearchBody.utf8))]
        let client = HistoryClient(session: MockURLProtocol.makeSession())

        _ = await client.search(baseURL: baseURL, apiKey: "x", sessionID: "s", limit: 100, query: "boot")

        XCTAssertEqual(MockURLProtocol.requestedMethods.last, "GET")
        XCTAssertEqual((MockURLProtocol.requestedBodies.last ?? nil)?.count ?? 0, 0)
    }

    func testSearchRequestCarriesTheKeyAsABearerAuthorizationHeader() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(Self.validSearchBody.utf8))]
        let client = HistoryClient(session: MockURLProtocol.makeSession())

        _ = await client.search(baseURL: baseURL, apiKey: "correct-fixture-key", sessionID: "s", limit: 100, query: "boot")

        XCTAssertEqual(MockURLProtocol.lastRequestHeaders?["Authorization"], "Bearer correct-fixture-key")
    }

    /// spec §9 の M9。規約 2 は URL / method / header に加えて**待ち時間**も見る。
    /// 探索は人が待っている往復なので、`writeTimeout` ではなく `interactiveTimeout`。
    func testSearchUsesTheInteractiveTimeout() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(Self.validSearchBody.utf8))]
        let client = HistoryClient(session: MockURLProtocol.makeSession())

        _ = await client.search(baseURL: baseURL, apiKey: "x", sessionID: "s", limit: 100, query: "boot")

        XCTAssertEqual(MockURLProtocol.requestedTimeouts, [BackendSession.interactiveTimeout])
    }

    // MARK: - 探索の status 写像(7 分岐)

    private func search(status: Int, body: String? = nil) async -> Result<TranscriptSearchResponse, SessionsFetchError> {
        MockURLProtocol.stubQueue = [.init(statusCode: status, body: Data((body ?? "").utf8))]
        return await HistoryClient(session: MockURLProtocol.makeSession())
            .search(baseURL: baseURL, apiKey: "x", sessionID: "s", limit: 100, query: "boot")
    }

    func testSearchStatus200DecodesToSuccess() async {
        guard case .success(let r) = await search(status: 200, body: Self.validSearchBody) else {
            return XCTFail("expected .success")
        }
        XCTAssertEqual(r.matched, 7)
        XCTAssertEqual(r.coverage, .boundedScan)
    }

    func testSearchStatus401IsUnauthorized() async {
        let r = await search(status: 401)
        XCTAssertEqual(r, .failure(.unauthorized))
    }

    func testSearchStatus404WithSessionNotFoundIsNotFound() async {
        let r = await search(status: 404, body: Self.sessionNotFoundBody)
        XCTAssertEqual(r, .failure(.notFound))
    }

    func testSearchStatus404WithNoSuchRouteIsContractViolation() async {
        let r = await search(status: 404, body: #"{"error":"not found","code":"NO_SUCH_ROUTE"}"#)
        XCTAssertEqual(r, .failure(.contractViolation(ResponseContractViolation(status: 404, code: "NO_SUCH_ROUTE"))))
    }

    /// ★200 で `matched` の無い body(= 机が素の履歴経路へ落ちた)は
    ///   `.malformedBody`。**`.success` にしてはいけない** —— spec §2-a の芯。
    func testSearchStatus200WithoutMatchedIsMalformedBody() async {
        let r = await search(status: 200, body: #"{"history":[],"truncated":false}"#)
        XCTAssertEqual(r, .failure(.malformedBody))
    }

    func testSearchConnectionFailureIsUnreachable() async {
        MockURLProtocol.stubQueue = []
        let r = await HistoryClient(session: MockURLProtocol.makeSession())
            .search(baseURL: baseURL, apiKey: "x", sessionID: "s", limit: 100, query: "boot")
        XCTAssertEqual(r, .failure(.unreachable))
    }

    func testSearchCancellationMapsToCancelled() async {
        MockURLProtocol.injectedError = URLError(.cancelled)
        let r = await HistoryClient(session: MockURLProtocol.makeSession())
            .search(baseURL: baseURL, apiKey: "x", sessionID: "s", limit: 100, query: "boot")
        XCTAssertEqual(r, .failure(.cancelled))
    }

    // MARK: - 陰性対照: 探索でも 7 分岐が畳まれていない(spec §2-b)

    /// 既存の `fetch` 側と**同じ形**で 3 本。同じ enum でも `switch` が新しい口に
    /// 生えれば写像を間違える新しい場所になる、という此の file 冒頭の判断の継承。
    func testSearchUnauthorizedIsNotCollapsedIntoUnreachableNegativeControl() async {
        let unauthorized = await search(status: 401)
        let unreachable = await search(status: 500)
        XCTAssertNotEqual(unauthorized, unreachable)
    }

    func testSearchNotFoundIsNotCollapsedIntoContractViolationNegativeControl() async {
        let gone = await search(status: 404, body: Self.sessionNotFoundBody)
        let badPath = await search(status: 404, body: #"{"error":"not found","code":"NO_SUCH_ROUTE"}"#)
        XCTAssertNotEqual(gone, badPath)
    }

    func testSearchMalformedBodyIsNotCollapsedIntoUnreachableNegativeControl() async {
        let malformed = await search(status: 200, body: #"{"history":[],"truncated":false}"#)
        let unreachable = await search(status: 500)
        XCTAssertNotEqual(malformed, unreachable)
    }

    // MARK: - Fixture

    /// 机が探索の 200 で実際に吐く 4 鍵(`wire.mjs` の `historySearchBody`)。
    /// ★`truncated` を**入れてある**のが要点: 電話は読まないが線には出るので、
    ///   検体から抜くと「読まない事」を測っている顔で、実は来ない鍵を無視している
    ///   だけの検査になる。
    private static let validSearchBody = """
    {
      "history": [
        { "role": "user", "text": "a", "display": { "who": "Tom" } }
      ],
      "matched": 7,
      "truncated": true,
      "searchedToStart": false
    }
    """

    /// What `server.mjs` actually sends from its `SESSION_NOT_FOUND` frozen constant.
    private static let sessionNotFoundBody = #"{"error":"unknown session","code":"SESSION_NOT_FOUND"}"#

    private static let validBody = """
    {
      "history": [
        { "role": "user", "text": "a", "display": { "who": "Tom" } }
      ],
      "truncated": false
    }
    """

    // MARK: - 錨の窓(`?around=`、2026-09-04)

    func testAroundStatus200DecodesTheWindowShape() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(Self.validAroundBody.utf8))]
        let client = HistoryClient(session: MockURLProtocol.makeSession())

        let result = await client.around(baseURL: baseURL, apiKey: "k", sessionID: "s", anchor: "1200:0", limit: 40)

        guard case .success(let response) = result else { return XCTFail("expected .success, got \(result)") }
        XCTAssertEqual(response.history.count, 2)
        XCTAssertEqual(response.anchor, "1200:0")
        XCTAssertTrue(response.olderAvailable)
        XCTAssertFalse(response.newerAvailable)
    }

    /// ★旗の鍵が**丸ごと無い**体(転写がまだ無い会話へ机が返す空の窓)。`Bool?` にしていると
    ///   「解らない」が画面へ漏れ、非 optional の `Bool` にしていると復号ごと落ちる。
    func testAroundFlagsAbsentDecodeToFalse() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(#"{"history":[],"anchor":"0:0"}"#.utf8))]
        let client = HistoryClient(session: MockURLProtocol.makeSession())

        let result = await client.around(baseURL: baseURL, apiKey: "k", sessionID: "s", anchor: "0:0", limit: 40)

        guard case .success(let response) = result else { return XCTFail("expected .success, got \(result)") }
        XCTAssertTrue(response.history.isEmpty)
        XCTAssertFalse(response.olderAvailable)
        XCTAssertFalse(response.newerAvailable)
    }

    /// 机は `anchor` を必ず返す(要求した錨が窓の中に在る事の証)。無い体は契約違反なので
    /// `.success` にしない —— 空文字を捏造すると、電話は在りもしない錨で読み直しに行く。
    func testAroundWithoutTheAnchorKeyIsMalformed() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(#"{"history":[],"olderAvailable":false}"#.utf8))]
        let client = HistoryClient(session: MockURLProtocol.makeSession())

        let result = await client.around(baseURL: baseURL, apiKey: "k", sessionID: "s", anchor: "0:0", limit: 40)

        guard case .failure(.malformedBody) = result else { return XCTFail("expected .malformedBody, got \(result)") }
    }

    /// ★`around` と `q` を**同時に送らない**。机は両方在る要求を 400 で断る(Codex 所見 F6、
    ///   2026-09-03)ので、混ぜた要求は「探索でも窓でもない物」になる。URL を実測して固定する。
    func testAroundRequestSendsAnchorAndLimitAndNoQuery() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(Self.validAroundBody.utf8))]
        let client = HistoryClient(session: MockURLProtocol.makeSession())

        _ = await client.around(baseURL: baseURL, apiKey: "k", sessionID: "sess-0001", anchor: "1200:0", limit: 40)

        let url = try? XCTUnwrap(MockURLProtocol.requestedURLs.last)
        let items = URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(url?.path, "/api/sessions/sess-0001/history")
        XCTAssertEqual(items.first(where: { $0.name == "around" })?.value, "1200:0")
        XCTAssertEqual(items.first(where: { $0.name == "limit" })?.value, "40")
        XCTAssertNil(items.first(where: { $0.name == "q" }), "`q` と `around` は同時に送らない")
        XCTAssertEqual(MockURLProtocol.requestedMethods.last, "GET")
        XCTAssertEqual((MockURLProtocol.requestedBodies.last ?? nil)?.count ?? 0, 0)
        XCTAssertEqual(MockURLProtocol.lastRequestHeaders?["Authorization"], "Bearer k")
        XCTAssertEqual(MockURLProtocol.requestedTimeouts, [BackendSession.interactiveTimeout])
    }

    /// 錨は不透明な文字列(`<byte 位置>:<行内番号>`)。`:` が URL で壊れない事を実測する。
    func testAroundEscapesTheAnchorInTheQuery() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(Self.validAroundBody.utf8))]
        let client = HistoryClient(session: MockURLProtocol.makeSession())

        _ = await client.around(baseURL: baseURL, apiKey: "k", sessionID: "s", anchor: "9007199254740991:3", limit: 1)

        let items = URLComponents(url: MockURLProtocol.requestedURLs.last!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first(where: { $0.name == "around" })?.value, "9007199254740991:3")
    }

    /// 消えた錨(机が 409 `anchor_gone`)。**`.notFound` でも `.unreachable` でもない**。
    ///
    /// ★2026-09-04 に変えた(Codex 所見 F2)。旧版は 409 を `default` へ落として `.unreachable` にし、
    ///   此の検査は其の挙動を固定していた —— つまり「電波が切れた」と「錨が消えた」が同じ値だった。
    ///   2 つは読み手に逆の行動を求める(再試行 / 位置を諦めて live へ戻る)ので、値を分けた。
    func testAroundStatus409WithAnchorGoneIsItsOwnCase() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 409, body: Data(#"{"reason":"anchor_gone"}"#.utf8))]
        let client = HistoryClient(session: MockURLProtocol.makeSession())

        let result = await client.around(baseURL: baseURL, apiKey: "k", sessionID: "s", anchor: "1:0", limit: 40)

        guard case .failure(.anchorGone) = result else { return XCTFail("expected .anchorGone, got \(result)") }
    }

    /// ★陰性対照: status だけで決めない。理由が違う 409 を「錨が消えた」と読むと、将来 409 を
    ///   別の意味で使い始めた口の応答が、電話では位置の喪失として出る。
    func testAroundStatus409WithAnotherReasonIsAContractViolation() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 409, body: Data(#"{"reason":"something_else"}"#.utf8))]
        let client = HistoryClient(session: MockURLProtocol.makeSession())

        let result = await client.around(baseURL: baseURL, apiKey: "k", sessionID: "s", anchor: "1:0", limit: 40)

        guard case .failure(.contractViolation(let v)) = result else {
            return XCTFail("expected .contractViolation, got \(result)")
        }
        XCTAssertEqual(v.status, 409)
        XCTAssertEqual(v.code, "something_else")
    }

    private static let validAroundBody = """
    {
      "history": [
        { "role": "user", "text": "a", "display": { "who": "Tom" }, "anchor": "1200:0" },
        { "role": "assistant", "text": "b", "display": { "who": "Claude" }, "anchor": "1260:0" }
      ],
      "anchor": "1200:0",
      "olderAvailable": true,
      "newerAvailable": false
    }
    """
}
