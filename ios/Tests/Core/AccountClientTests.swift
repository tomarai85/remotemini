import XCTest
@testable import RemoteMini

final class AccountClientTests: XCTestCase {
    private let baseURL = URL(string: "https://unit-test.invalid")!

    override func setUp() { MockURLProtocol.reset() }
    override func tearDown() { MockURLProtocol.reset() }

    // MARK: - 読む側

    func testCurrentDecodesTheAccountTheServerNamed() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(#"{"account":"a@example.com"}"#.utf8))]
        let client = AccountClient(session: MockURLProtocol.makeSession())

        let result = await client.current(baseURL: baseURL, apiKey: "k")

        XCTAssertEqual(result, .success(AccountState(account: "a@example.com")))
    }

    func testCurrentAsksTheAccountRouteWithTheKeyAttached() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(#"{"account":"a"}"#.utf8))]
        let client = AccountClient(session: MockURLProtocol.makeSession())

        _ = await client.current(baseURL: baseURL, apiKey: "secret-key")

        XCTAssertEqual(MockURLProtocol.requestedURLs.last?.path, "/api/account")
        XCTAssertEqual(MockURLProtocol.requestedMethods.last, "GET")
        XCTAssertEqual(MockURLProtocol.lastRequestHeaders?["Authorization"], "Bearer secret-key")
    }

    /// 空の口座名は口座ではない。`fleet-account` が何も印字しなかった時に空のラベルを
    /// 出すと「口座が設定されていない」と読めるが、それは此の層が持っていない主張。
    func testAnEmptyAccountNameIsNotTreatedAsAnAccount() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(#"{"account":"   "}"#.utf8))]
        let client = AccountClient(session: MockURLProtocol.makeSession())

        let result = await client.current(baseURL: baseURL, apiKey: "k")

        XCTAssertEqual(result, .failure(.malformedBody))
    }

    func testUnauthorizedIsItsOwnCaseRatherThanAGenericStatus() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 401, body: Data())]
        let client = AccountClient(session: MockURLProtocol.makeSession())

        let result = await client.current(baseURL: baseURL, apiKey: "k")

        XCTAssertEqual(result, .failure(.unauthorized))
    }

    /// サーバは此の道の失敗に必ず `error` を載せる。理由を捨てて「失敗しました」に
    /// 丸めると、電話を持っている人は**何が壊れたか**を知る手段を失う。
    func testTheBackendsOwnReasonIsCarriedOutOfAFiveHundred() async {
        let body = Data(#"{"error":"fleet-account failed: boom"}"#.utf8)
        MockURLProtocol.stubQueue = [.init(statusCode: 500, body: body)]
        let client = AccountClient(session: MockURLProtocol.makeSession())

        let result = await client.current(baseURL: baseURL, apiKey: "k")

        XCTAssertEqual(result, .failure(.backend("fleet-account failed: boom")))
    }

    func testAFiveHundredWithoutAReasonSaysSoInsteadOfInventingOne() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 500, body: Data("not json".utf8))]
        let client = AccountClient(session: MockURLProtocol.makeSession())

        let result = await client.current(baseURL: baseURL, apiKey: "k")

        XCTAssertEqual(result, .failure(.backend("サーバが理由を返しませんでした")))
    }

    // MARK: - 進める側

    func testNextPostsToTheNextRoute() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(#"{"account":"b@example.com"}"#.utf8))]
        let client = AccountClient(session: MockURLProtocol.makeSession())

        let result = await client.next(baseURL: baseURL, apiKey: "k")

        XCTAssertEqual(result, .success(AccountState(account: "b@example.com")))
        XCTAssertEqual(MockURLProtocol.requestedURLs.last?.path, "/api/account/next")
        XCTAssertEqual(MockURLProtocol.requestedMethods.last, "POST")
    }

    /// ★此の1本が此のファイルで一番大事。サーバ側の注釈が明記している通り、
    /// `fleet-account --next` は時間切れになる**前に**口座を進め終えている。
    /// つまり 500 は「口座が動かなかった」を意味しない —— 自動で撃ち直すと
    /// **二段進めて一段失敗したと報告する**。此の層は1回しか撃たない。
    func testAFailedSwitchIsNotRetried() async {
        MockURLProtocol.stubQueue = [
            .init(statusCode: 500, body: Data(#"{"error":"timed out"}"#.utf8)),
            .init(statusCode: 200, body: Data(#"{"account":"would-be-retry"}"#.utf8)),
        ]
        let client = AccountClient(session: MockURLProtocol.makeSession())

        let result = await client.next(baseURL: baseURL, apiKey: "k")

        XCTAssertEqual(result, .failure(.backend("timed out")))
        // 撃ち直していれば2本になる。1本である事が「撃ち直さない」の観測。
        XCTAssertEqual(MockURLProtocol.requestedURLs.count, 1)
    }

    /// ★どちらの道も**本文を1バイトも送らない**。
    ///
    /// 机の側は `/api/account` も `/api/account/next` も path 以外を読んでいない
    /// (`server.mjs` の2つのハンドラは `execFileSync` を撃つだけ)。此処で `{}` を
    /// 送ると、後で誰かが「この形に鍵を足す」= 机が読まない物を電話が送る形になる。
    /// `InterruptClient` が同じ理由で本文を持たず、其の判断を検査で固定してある。
    func testNeitherRouteSendsARequestBody() async {
        MockURLProtocol.stubQueue = [
            .init(statusCode: 200, body: Data(#"{"account":"a"}"#.utf8)),
            .init(statusCode: 200, body: Data(#"{"account":"b"}"#.utf8)),
        ]
        let client = AccountClient(session: MockURLProtocol.makeSession())

        _ = await client.current(baseURL: baseURL, apiKey: "k")
        _ = await client.next(baseURL: baseURL, apiKey: "k")

        XCTAssertEqual(MockURLProtocol.requestedBodies.count, 2)
        for body in MockURLProtocol.requestedBodies {
            XCTAssertTrue(body == nil || body?.isEmpty == true, "本文を送っている: \(String(describing: body))")
        }
    }

    /// 送る側の期限は `writeTimeout`。机が `fleet-account` に 10 秒を与えているので、
    /// 電話側の期限が其れより短いと**まだ口座を変えつつある呼び出しを見捨てる**。
    func testTheSwitchUsesTheWriteDeadlineNotTheInteractiveOne() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(#"{"account":"b"}"#.utf8))]
        let client = AccountClient(session: MockURLProtocol.makeSession())

        _ = await client.next(baseURL: baseURL, apiKey: "k")

        XCTAssertEqual(MockURLProtocol.requestedTimeouts.last, BackendSession.writeTimeout)
        XCTAssertGreaterThan(BackendSession.writeTimeout, BackendSession.interactiveTimeout)
    }
}
