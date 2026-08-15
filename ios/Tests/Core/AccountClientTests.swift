import XCTest
@testable import RemoteMini

/// ★此のファイルの本文(JSON)は**手で書いていない**。`rc-backend` の `accountBody` を
/// 実際に走らせた出力を貼ってある(2026-08-14):
///
///     node -e 'Promise.all([import("./src/wire.mjs"), import("./src/account.mjs")])
///       .then(([w,a]) => console.log(JSON.stringify(w.accountBody(a.parseFleetAccount(raw), {raw}))))'
///
/// 手で組んだ本文は「電話が読める形」を検査するだけで、**机が本当に其の形を出すか**は
/// 一度も測らない —— 監査 S8-24 が数えた「電話の Decodable 28本のうち机と突き合わせ
/// られていたのは6本」の正体が之。鍵名の一致自体は
/// `rc-backend/test/wire-key-agreement.test.mjs` が両側を**実行して**測る。
final class AccountClientTests: XCTestCase {
    private let baseURL = URL(string: "https://unit-test.invalid")!

    /// `fleet-account` が読めた時の封筒。3行(team = 現用、biz = 選べる、sdgs = トークン欠)。
    private static let readable = Data(#"""
    {"account":"team","current":"team","accounts":[\#
    {"name":"team","hasToken":true,"active":true,"selectable":true,"display":{"blocked":null}},\#
    {"name":"biz","hasToken":true,"active":false,"selectable":true,"display":{"blocked":null}},\#
    {"name":"sdgs","hasToken":false,"active":false,"selectable":false,\#
    "display":{"blocked":"そのアカウントのトークンが edith にありません。"}}],\#
    "ok":true,"parseStatus":"ok","anomalies":[],"display":{"status":null,"anomalies":[]}}
    """#.utf8)

    /// 台本の出力が読めなかった時の封筒。`ok:false` + 日本語の理由 + 生出力。
    private static let unreadable = Data(#"""
    {"account":"（未設定）","current":null,"accounts":[],"ok":false,\#
    "parseStatus":"no-current-line","anomalies":[],\#
    "display":{"status":"edith の fleet-account が想定と違う形を返しました(1行目が「現用:」ではありません)。切替は出来ません。","anomalies":[]},\#
    "raw":"garbage line\nmore","rawTruncated":false}
    """#.utf8)

    /// `rawTruncated` を**載せない**机の封筒 = #56 で出荷した版。上の `unreadable` から
    /// 其の1鍵だけを抜いた物で、電話が古い机に当たった日の形をそのまま置いてある。
    private static let unreadableWithoutFlag = Data(#"""
    {"account":"（未設定）","current":null,"accounts":[],"ok":false,\#
    "parseStatus":"no-current-line","anomalies":[],\#
    "display":{"status":"edith の fleet-account が想定と違う形を返しました(1行目が「現用:」ではありません)。切替は出来ません。","anomalies":[]},\#
    "raw":"garbage line\nmore"}
    """#.utf8)

    /// 生出力が上限(2000字)で**切られた**時の封筒。★上の2本と違い、本文を丸ごと
    /// 貼るのを止めて `raw` の中身だけ Swift で組んである —— 2000 字の `x` を此処へ
    /// 貼っても読めなくなるだけで、測る物は1つも増えない。鍵名と `rawTruncated` の
    /// 値は同じ走行(`accountBody(parseFleetAccount(raw), {raw})`、raw = 2100字)から取った。
    /// 「上限を超えたら真になる」関係そのものは机の側で測っている
    /// (`rc-backend/test/account.test.mjs` の「★上限を超えた生出力は切って…」)。
    private static var truncated: Data {
        let raw = "garbage line\\n" + String(repeating: "x", count: 1987)
        return Data(#"""
        {"account":"（未設定）","current":null,"accounts":[],"ok":false,\#
        "parseStatus":"no-current-line","anomalies":[],\#
        "display":{"status":"edith の fleet-account が想定と違う形を返しました(1行目が「現用:」ではありません)。切替は出来ません。","anomalies":[]},\#
        "raw":"\#(raw)","rawTruncated":true}
        """#.utf8)
    }

    override func setUp() { MockURLProtocol.reset() }
    override func tearDown() { MockURLProtocol.reset() }

    // MARK: - 読む側

    func testCurrentDecodesTheListingTheServerNamed() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Self.readable)]
        let client = AccountClient(session: MockURLProtocol.makeSession())

        let result = await client.current(baseURL: baseURL, apiKey: "k")

        guard case .success(let state) = result else { return XCTFail("読めていない: \(result)") }
        XCTAssertEqual(state.current, "team")
        XCTAssertTrue(state.ok)
        XCTAssertEqual(state.accounts.map(\.name), ["team", "biz", "sdgs"])
        XCTAssertNil(state.statusMessage)
        XCTAssertEqual(state.anomalyMessages, [])
        XCTAssertNil(state.raw)
    }

    /// ★選べない行が**一覧に残る**事の観測。机は消して来ないので、電話が消したら
    /// 「そんな口座は無い」という嘘になる。理由は机が書いた日本語がそのまま届く。
    func testARowThatCannotBeSelectedArrivesWithItsReasonInsteadOfBeingDropped() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Self.readable)]
        let client = AccountClient(session: MockURLProtocol.makeSession())

        let result = await client.current(baseURL: baseURL, apiKey: "k")

        guard case .success(let state) = result else { return XCTFail("読めていない: \(result)") }
        let sdgs = state.accounts.first { $0.name == "sdgs" }
        XCTAssertNotNil(sdgs, "選べない行が落ちている")
        XCTAssertEqual(sdgs?.selectable, false)
        XCTAssertEqual(sdgs?.hasToken, false)
        XCTAssertEqual(sdgs?.blocked, "そのアカウントのトークンが edith にありません。")
        XCTAssertEqual(state.accounts.first { $0.name == "biz" }?.blocked, nil)
    }

    /// `active` は**現用の印**であって `current` の写しではない。両方が線に載っている
    /// 事を測る —— 片方だけだと、印が2行に付いた壊れた出力を電話が正常として描く。
    func testTheActiveMarkArrivesPerRow() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Self.readable)]
        let client = AccountClient(session: MockURLProtocol.makeSession())

        let result = await client.current(baseURL: baseURL, apiKey: "k")

        guard case .success(let state) = result else { return XCTFail("読めていない: \(result)") }
        XCTAssertEqual(state.accounts.filter(\.active).map(\.name), ["team"])
    }

    /// ★一覧が読めない事は**答えの一種**であって通信の失敗ではない。`.failure` に
    /// 畳むと、画面は「机に届かない」と言う事になる —— 届いてはいるのに。
    func testAnUnreadableListingIsAnAnswerNotAFailure() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Self.unreadable)]
        let client = AccountClient(session: MockURLProtocol.makeSession())

        let result = await client.current(baseURL: baseURL, apiKey: "k")

        guard case .success(let state) = result else { return XCTFail("失敗に畳んでいる: \(result)") }
        XCTAssertFalse(state.ok)
        XCTAssertEqual(state.accounts, [])
        XCTAssertNil(state.current)
        XCTAssertEqual(state.statusMessage?.contains("現用:"), true)
        XCTAssertEqual(state.raw, "garbage line\nmore")
        XCTAssertFalse(state.rawTruncated, "切れていないのに切れたと言っている")
    }

    /// ★生出力が切られている事は**画面まで持ち上げる**。生の出力は末尾に失敗行が
    /// 来るので、黙って先頭 2000 字だけ出すと「失敗行が無い = 台本は最後まで走った」
    /// と読める —— 診断の材料としては、其れが一番害の大きい嘘になる。
    func testATruncatedRawSaysSoInsteadOfLookingComplete() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Self.truncated)]
        let client = AccountClient(session: MockURLProtocol.makeSession())

        let result = await client.current(baseURL: baseURL, apiKey: "k")

        guard case .success(let state) = result else { return XCTFail("読めていない: \(result)") }
        XCTAssertTrue(state.rawTruncated)
        XCTAssertEqual(state.raw?.count, 2000)
    }

    /// 出荷済みの机(`rawTruncated` を載せない版)に当たった時。★鍵の欠けを
    /// `true` 側へ倒すと、切れていない出力にまで「続きがある」と書く事になる。
    /// 欠け = 「机が其の枝を持っていない」なので、偽側が正しい。
    func testAServerWithoutTheTruncationFlagIsReadAsNotTruncated() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Self.unreadableWithoutFlag)]
        let client = AccountClient(session: MockURLProtocol.makeSession())

        let result = await client.current(baseURL: baseURL, apiKey: "k")

        guard case .success(let state) = result else { return XCTFail("読めていない: \(result)") }
        XCTAssertEqual(state.raw, "garbage line\nmore")
        XCTAssertFalse(state.rawTruncated)
    }

    /// ★機械語(`parseStatus` / `anomalies`)は線に載っているが**型が受けない**。
    /// 受けてしまうと、いつか画面へ英語のまま出る道が生える(監査 S8-22 が実際に
    /// 踏んだ形)。此処は「読める事」ではなく「読まない事」を固定する検査。
    func testTheMachineReadableTokensAreNotDecodedAtAll() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Self.unreadable)]
        let client = AccountClient(session: MockURLProtocol.makeSession())

        let result = await client.current(baseURL: baseURL, apiKey: "k")

        guard case .success(let state) = result else { return XCTFail("読めていない: \(result)") }
        // `AccountState` に機械語の置き場が無い事を、値の側から確かめる。
        let rendered = [state.statusMessage ?? ""] + state.anomalyMessages
        for text in rendered {
            XCTAssertFalse(text.contains("no-current-line"), "機械語が人の読む文に混ざっている: \(text)")
            XCTAssertFalse(text.contains("parseStatus"), "機械語が人の読む文に混ざっている: \(text)")
        }
    }

    /// 引っ掛かり(`anomalies`)は日本語に畳まれて届く。`active-count-<n>` の族も含めて
    /// 机が文にするので、電話側に語彙を持たない。
    func testAnomaliesArriveAlreadyWordedForAPerson() async {
        let body = Data(#"""
        {"account":"team","current":"team","accounts":[],"ok":true,"parseStatus":"ok",\#
        "anomalies":["current-not-listed","active-count-0"],\#
        "display":{"status":null,"anomalies":["現用のアカウントが一覧に載っていません。","一覧のどの行にも現用の印(->)が付いていません。"]}}
        """#.utf8)
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: body)]
        let client = AccountClient(session: MockURLProtocol.makeSession())

        let result = await client.current(baseURL: baseURL, apiKey: "k")

        guard case .success(let state) = result else { return XCTFail("読めていない: \(result)") }
        XCTAssertEqual(state.anomalyMessages.count, 2)
        XCTAssertEqual(state.anomalyMessages.allSatisfy { !$0.contains("active-count") }, true)
    }

    /// `display` を欠いた本文は**読めない**とする。既定値で埋めると、机の古い版に
    /// 繋いだ時に「引っ掛かりは無い」という測っていない主張を電話が描く。
    func testABodyWithoutTheDisplayNamespaceIsMalformed() async {
        let body = Data(#"{"account":"team","current":"team","accounts":[],"ok":true}"#.utf8)
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: body)]
        let client = AccountClient(session: MockURLProtocol.makeSession())

        let result = await client.current(baseURL: baseURL, apiKey: "k")

        XCTAssertEqual(result, .failure(.malformedBody))
    }

    /// 空白だけの現用名は口座名ではない。`nil` に寄せる(空白のラベルを描くより
    /// 「現用は無い」の方が嘘が小さい)。**失敗にはしない** —— 一覧は生きている。
    func testAWhitespaceOnlyCurrentBecomesNoCurrentRatherThanABlankLabel() async {
        let body = Data(#"""
        {"account":"   ","current":"   ","accounts":[],"ok":true,"parseStatus":"ok",\#
        "anomalies":[],"display":{"status":null,"anomalies":[]}}
        """#.utf8)
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: body)]
        let client = AccountClient(session: MockURLProtocol.makeSession())

        let result = await client.current(baseURL: baseURL, apiKey: "k")

        guard case .success(let state) = result else { return XCTFail("失敗に畳んでいる: \(result)") }
        XCTAssertNil(state.current)
        XCTAssertTrue(state.ok)
    }

    func testCurrentAsksTheAccountRouteWithTheKeyAttached() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Self.readable)]
        let client = AccountClient(session: MockURLProtocol.makeSession())

        _ = await client.current(baseURL: baseURL, apiKey: "secret-key")

        XCTAssertEqual(MockURLProtocol.requestedURLs.last?.path, "/api/account")
        XCTAssertEqual(MockURLProtocol.requestedMethods.last, "GET")
        XCTAssertEqual(MockURLProtocol.lastRequestHeaders?["Authorization"], "Bearer secret-key")
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

    // MARK: - 名指しで選ぶ側(§9-3)

    func testSelectPostsTheNameInTheBodyNotThePath() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Self.readable)]
        let client = AccountClient(session: MockURLProtocol.makeSession())

        _ = await client.select(name: "biz", baseURL: baseURL, apiKey: "k")

        XCTAssertEqual(MockURLProtocol.requestedURLs.last?.path, "/api/account/select")
        XCTAssertEqual(MockURLProtocol.requestedMethods.last, "POST")
        // ★名前が**経路に載っていない**事の観測。載せると机の log の経路欄に残る。
        XCTAssertEqual(MockURLProtocol.requestedURLs.last?.absoluteString.contains("biz"), false)
        let body = MockURLProtocol.requestedBodies.last ?? nil
        XCTAssertNotNil(body)
        let decoded = try? JSONDecoder().decode([String: String].self, from: body ?? Data())
        XCTAssertEqual(decoded, ["name": "biz"])
    }

    /// ★400(断り)と 500(机が壊れた)を**別の case** にする事の観測。
    /// 断りは台本を叩く**前**に返るので口座は動いていない —— 呼び手が
    /// 「測り直すか / 理由を出すだけか」を分けられるのは、此処で分けてあるから。
    func testARefusalIsItsOwnCaseCarryingTheServersWording() async {
        let body = Data(#"{"error":"そのアカウントのトークンが edith にありません。"}"#.utf8)
        MockURLProtocol.stubQueue = [.init(statusCode: 400, body: body)]
        let client = AccountClient(session: MockURLProtocol.makeSession())

        let result = await client.select(name: "sdgs", baseURL: baseURL, apiKey: "k")

        XCTAssertEqual(result, .failure(.refused("そのアカウントのトークンが edith にありません。")))
    }

    func testARefusalWithoutAReasonStillSaysItWasRefused() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 400, body: Data("not json".utf8))]
        let client = AccountClient(session: MockURLProtocol.makeSession())

        let result = await client.select(name: "sdgs", baseURL: baseURL, apiKey: "k")

        XCTAssertEqual(result, .failure(.refused("その口座は選べません")))
    }

    /// 名指しの切替も撃ち直さない。断られた1本で終わる。
    func testAFailedSelectIsNotRetried() async {
        MockURLProtocol.stubQueue = [
            .init(statusCode: 500, body: Data(#"{"error":"timed out"}"#.utf8)),
            .init(statusCode: 200, body: Self.readable),
        ]
        let client = AccountClient(session: MockURLProtocol.makeSession())

        let result = await client.select(name: "biz", baseURL: baseURL, apiKey: "k")

        XCTAssertEqual(result, .failure(.backend("timed out")))
        XCTAssertEqual(MockURLProtocol.requestedURLs.count, 1)
    }

    func testSelectUsesTheWriteDeadline() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Self.readable)]
        let client = AccountClient(session: MockURLProtocol.makeSession())

        _ = await client.select(name: "biz", baseURL: baseURL, apiKey: "k")

        XCTAssertEqual(MockURLProtocol.requestedTimeouts.last, BackendSession.writeTimeout)
    }

    // MARK: - 進める側(退避路)

    func testNextPostsToTheNextRoute() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Self.readable)]
        let client = AccountClient(session: MockURLProtocol.makeSession())

        let result = await client.next(baseURL: baseURL, apiKey: "k")

        guard case .success(let state) = result else { return XCTFail("読めていない: \(result)") }
        XCTAssertEqual(state.current, "team")
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
            .init(statusCode: 200, body: Self.readable),
        ]
        let client = AccountClient(session: MockURLProtocol.makeSession())

        let result = await client.next(baseURL: baseURL, apiKey: "k")

        XCTAssertEqual(result, .failure(.backend("timed out")))
        // 撃ち直していれば2本になる。1本である事が「撃ち直さない」の観測。
        XCTAssertEqual(MockURLProtocol.requestedURLs.count, 1)
    }

    /// ★読む道と進める道は**本文を1バイトも送らない**(名指しの道だけが送る)。
    ///
    /// 机の側は `/api/account` も `/api/account/next` も path 以外を読んでいない。
    /// 此処で `{}` を送ると、後で誰かが「この形に鍵を足す」= 机が読まない物を電話が
    /// 送る形になる。`InterruptClient` が同じ理由で本文を持たない。
    func testTheReadAndAdvanceRoutesSendNoRequestBody() async {
        MockURLProtocol.stubQueue = [
            .init(statusCode: 200, body: Self.readable),
            .init(statusCode: 200, body: Self.readable),
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
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Self.readable)]
        let client = AccountClient(session: MockURLProtocol.makeSession())

        _ = await client.next(baseURL: baseURL, apiKey: "k")

        XCTAssertEqual(MockURLProtocol.requestedTimeouts.last, BackendSession.writeTimeout)
        XCTAssertGreaterThan(BackendSession.writeTimeout, BackendSession.interactiveTimeout)
    }
}
