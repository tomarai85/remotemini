import XCTest
@testable import RemoteMini

/// `StatusClient.fetch` の検査。`DigestFetcherTests` と同じ `MockURLProtocol` の仕掛け、
/// 同じ書き方に揃える(error の語彙を2つ持たない、という §3-c の判断と同じ理由)。
///
/// ★本文は**手で組んでいない** —— `rc-backend/src/wire.mjs` の `statusBodyTmux` /
///   `statusBodyWorker`(対照表 #16)の実際の出力形を、`rc-backend/test/e2e-local.mjs`
///   の実測(tmux 経路: `route/pane/screen/activity/limited/source/permissionMode`、
///   worker 経路: `route/worker/state/queued/errored/limited/permissionMode`)から写した。
///
/// ★ここが守る一線は `DigestFetcherTests` と同じ2つ(N6 / 404の2意味)に加えて、
///   **`StatusEnvelope` が `permissionMode` 以外の鍵を無視して壊れない事** ——
///   `route`/`pane`/`screen`/`choice`/`worker`/`state` 等、電話が読まないと決めた鍵が
///   線に乗っていても、其れを理由に `malformedBody` へ落ちてはいけない
///   (`JSONDecoder` は既知の鍵だけ拾うのでこの心配は本来無いが、**測って確かめる**)。
final class StatusClientTests: XCTestCase {

    override func setUp() { MockURLProtocol.reset() }
    override func tearDown() { MockURLProtocol.reset() }

    // 実サーバ出力・tmux 経路(2026-09-02、rc-backend/test/e2e-local.mjs の実測形)。
    private static let tmuxBody = """
    {"route":"tmux","pane":"%10","screen":"SENDABLE","activity":"observed","limited":false,"source":"registry","permissionMode":"bypassPermissions"}
    """

    // 同・worker 経路。
    private static let workerBody = """
    {"route":"worker","worker":"running","state":"ready","queued":0,"errored":false,"limited":false,"permissionMode":"plan"}
    """

    private func fetch(_ sid: String = "abc-123", body: String = tmuxBody, status: Int = 200) async
        -> Result<String?, SessionsFetchError>
    {
        MockURLProtocol.stubQueue = [.init(statusCode: status, body: Data(body.utf8))]
        let client = StatusClient(session: MockURLProtocol.makeSession())
        return await client.fetch(baseURL: URL(string: "https://desk.example")!,
                                  apiKey: "k", sessionID: sid)
    }

    // MARK: - デコード(封筒の残りの鍵を無視して permissionMode だけ拾う)

    func test_tmux経路の200はpermissionModeを返す() async throws {
        let r = await fetch(body: Self.tmuxBody)
        guard case .success(let mode) = r else { return XCTFail("失敗した: \(r)") }
        XCTAssertEqual(mode, "bypassPermissions")
    }

    func test_worker経路の200も同じ鍵で返る() async throws {
        let r = await fetch(body: Self.workerBody)
        guard case .success(let mode) = r else { return XCTFail("失敗した: \(r)") }
        XCTAssertEqual(mode, "plan")
    }

    /// ★読めない事は「無い」と同じ扱い —— 発明しない。空のチップ(nil)は正しい答え。
    func test_permissionModeがnullなら成功のままnilを返す() async throws {
        let body = #"{"route":"worker","worker":"none","state":"idle","queued":0,"errored":false,"limited":false,"permissionMode":null}"#
        let r = await fetch(body: body)
        guard case .success(let mode) = r else { return XCTFail("失敗した: \(r)") }
        XCTAssertNil(mode)
    }

    /// ★古い机(此の鍵をまだ持たない `/status`)でも壊れない。欠けた鍵は nil に落ちる。
    func test_permissionMode欄が無い古い応答でもnilに落ちて壊れない() async throws {
        let body = #"{"route":"worker","worker":"none","state":"idle","queued":0,"errored":false,"limited":false}"#
        let r = await fetch(body: body)
        guard case .success(let mode) = r else { return XCTFail("失敗した: \(r)") }
        XCTAssertNil(mode)
    }

    /// D4/#17 が挙げる4値が全部そのまま通る事(サーバの語彙を電話で作り変えない)。
    func test_4つの実値がそのまま通る() async throws {
        for mode in ["bypassPermissions", "acceptEdits", "default", "plan"] {
            let body = #"{"route":"worker","worker":"none","state":"idle","queued":0,"errored":false,"limited":false,"permissionMode":"\#(mode)"}"#
            let r = await fetch(body: body)
            guard case .success(let got) = r else { return XCTFail("失敗した(\(mode)): \(r)") }
            XCTAssertEqual(got, mode)
        }
    }

    func test_401は鍵の失効として返す() async {
        let r = await fetch(body: "{}", status: 401)
        guard case .failure(.unauthorized) = r else {
            return XCTFail("401 を unauthorized にしていない")
        }
    }

    /// ★404 の片方: その会話が本当に無い。
    func test_404かつSESSION_NOT_FOUNDは会話が無いとして返す() async {
        let r = await fetch(body: #"{"code":"SESSION_NOT_FOUND"}"#, status: 404)
        guard case .failure(.notFound) = r else {
            return XCTFail("SESSION_NOT_FOUND を notFound にしていない")
        }
    }

    /// ★★404 のもう片方: **此方が URL を組み違えた**。`notFound` に丸めると
    /// 「あなたの会話はもう在りません」と嘘を伝える(`DigestFetcherTests` と同じ懸念)。
    func test_404だが別の理由なら契約違反として返す_会話が消えたと言わない() async {
        let r = await fetch(body: #"{"code":"NO_SUCH_ROUTE"}"#, status: 404)
        if case .failure(.notFound) = r {
            return XCTFail("此方の URL 誤りを『会話が消えた』と伝えている")
        }
        guard case .failure(.contractViolation) = r else {
            return XCTFail("契約違反にしていない: \(r)")
        }
    }

    /// ★N6: **status が先**。200 でない応答の本文は、読める形でも読まない。
    func test_500は本文が正しくても信じない() async {
        let r = await fetch(body: Self.tmuxBody, status: 500)
        guard case .failure(.unreachable) = r else {
            return XCTFail("500 の本文を信じている")
        }
    }

    func test_200でも形が違えば壊れた本文として返す() async {
        let r = await fetch(body: "not json")
        guard case .failure(.malformedBody) = r else {
            return XCTFail("壊れた本文を通した")
        }
    }

    // MARK: - request の全次元を見る
    //
    // ★門(`rc-backend/test/request-shape.test.mjs`)が要求している。理由は
    //   「一度も見ていない次元は、変異を植えても赤くならない = 実質守られていない」。

    func test_鍵をAuthorizationヘッダで運ぶ() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(Self.tmuxBody.utf8))]
        let client = StatusClient(session: MockURLProtocol.makeSession())
        _ = await client.fetch(baseURL: URL(string: "https://desk.example")!,
                               apiKey: "correct-fixture-key", sessionID: "abc-123")
        XCTAssertEqual(MockURLProtocol.lastRequestHeaders?["Authorization"],
                       "Bearer correct-fixture-key")
    }

    func test_撃つURLが正しい() async {
        _ = await fetch("abc-123")
        XCTAssertEqual(MockURLProtocol.requestedURLs.last?.absoluteString,
                       "https://desk.example/api/sessions/abc-123/status")
    }

    func test_GETで撃つ() async {
        _ = await fetch()
        XCTAssertEqual(MockURLProtocol.requestedMethods.last, "GET")
    }

    /// GET は本文を持たない。**想定ではなく測る**(`DigestFetcherTests` と同じ判断)。
    func test_GETは本文を持たない() async {
        _ = await fetch()
        XCTAssertEqual((MockURLProtocol.requestedBodies.last ?? nil)?.count ?? 0, 0)
    }

    /// 待ち時間は `BackendSession.interactiveTimeout` に揃える。此処だけ別の値にすると、
    /// 冷えた起動で此の口だけが先に諦める。
    func test_待ち時間が対話用に揃っている() async {
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
