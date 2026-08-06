import XCTest
@testable import RemoteMini

/// REQUIREMENTS §5-6「Loading で待たされない」の実装側の対照(2026-08-06)。
///
/// ## 何を直した結果の対照か
///
/// 分割前は `URLSessionConfiguration.timeoutIntervalForRequest = 30` の1本だけで、
/// **全ての要求**が 30 秒待った。接続は受け付けるが応答を返さない網 —— ホテルや空港の
/// captive portal、寝ている tailnet 相手、つまりこのアプリが存在する理由そのものの
/// 「移動中」——では、会話画面と一覧画面が 30 秒間ただの `ProgressView` を出し続けてから
/// やっと「再試行」を出した。RC を却下した理由1(「connecting」で作業が止まる)の再現。
///
/// ## 測っている物 / 測っていない物
///
/// 測る   = **各 client が要求に何秒を載せたか**(`MockURLProtocol` が `startLoading()` で
///          記録する `URLRequest.timeoutInterval`)。読む側が 8 秒、poll と書く側が 30 秒。
/// 測らない = その値で `URLSession` が実際に打ち切るか。これは Foundation の挙動なので
///          単体では測れない。**別に実測で確かめた**(2026-08-06、Jervis 上の素の Swift、
///          経路の無い 10.255.255.1 を相手に):
///
///          | 要求側 | session の config | 実際に終了した時刻 |
///          |---|---|---|
///          | 5s   | 30s | 5.03 秒 (`URLError` -1001) |
///          | 2s   | 30s | 2.01 秒 (同上) |
///          | 指定なし(既定 60.0 と読める) | 3s | 3.02 秒 (同上) |
///
///          = 要求が喋れば要求が勝ち、黙れば config が governs。分割が成立する土台。
///
/// ★従ってこの suite が記録する `requestedTimeouts` は **宣言した値**であって効いた値ではない
///   (指定なしの要求は 60 と記録される)。効く事の証明は上の実測の側に在る。
///   ここで「打ち切りまで測っている」と読ませないよう、両方を書いておく。
final class RequestTimeoutTests: XCTestCase {
    private let baseURL = URL(string: "https://unit-test.invalid")!

    override func setUp() { MockURLProtocol.reset() }
    override func tearDown() { MockURLProtocol.reset() }

    // MARK: - 定数そのもの

    func testPollTimeoutIsDerivedFromTheServerConstantNotHandWritten() {
        // server.mjs の `POLL_MAX_WAIT_MS = 20_000` を写した値 + 余裕。
        // 直接 30 と書いてしまうと、server 側が 25 秒に伸びた時に「正常な無変化 200」が
        // 網の障害として読まれる —— 分割前の1本だけの形が守っていた性質はこれ。
        XCTAssertEqual(BackendSession.serverPollMaxWait, 20)
        XCTAssertEqual(BackendSession.pollTimeout, BackendSession.serverPollMaxWait + 10)
        XCTAssertGreaterThan(BackendSession.pollTimeout, BackendSession.serverPollMaxWait)
    }

    func testInteractiveTimeoutIsShorterThanThePollTimeout() {
        // これが逆転したら分割の意味が消える(= 空白画面の待ちが縮まない)。
        XCTAssertLessThan(BackendSession.interactiveTimeout, BackendSession.pollTimeout)
        XCTAssertEqual(BackendSession.interactiveTimeout, 8)
    }

    func testWriteTimeoutStaysAtThePollLength() {
        // ★短くしない事が仕様。`POST /messages` に idempotency key が無いので
        //   (2026-08-06 に server.mjs を確認)、諦める窓を広げると
        //   「client は諦めた・server は注入済み」で再送 = 二重に打ち込む。
        XCTAssertEqual(BackendSession.writeTimeout, BackendSession.pollTimeout)
    }

    // MARK: - 各 client が実際に載せた値 —— は此処には無い
    //
    // 初版は7本を此処に並べた。`request-shape.test.mjs` が赤で教えた:
    //   「client `C` の request の次元 `D` は、`CTests.swift` が見ていなければ守られていない」
    // という規約が既に在り、topic で束ねたこの file はその規約の外に居た。
    // 各 client の値は**その client 自身の検査 file** に在る(`…Tests.swift` の
    // `testRequestUsesTheInteractiveTimeout` / `test…KeepsTheWriteTimeout…`)。
    //
    // ★規約側を緩めなかった理由: 「Tests/Core の何処かで綴りが出ていればよい」に広げると、
    //   全 client 名と全次元名を注釈で並べた file が1本在るだけで全部が緑になる。
    //   検査が**空振りしても緑**になる形は、この repo が何度も踏んでいる形そのもの。
    //
    // 此処に残すのは、**1本の client の file には書けない物だけ**:
    //   ① 定数どうしの関係(上)
    //   ② 計器そのものの陰性対照(下)

    // MARK: - 陰性対照

    /// 上の緑が「この計器はいつでも 8 と言う」以上の意味を持つか。
    /// 何も指定しない要求を同じ session で流すと、記録される値は 8 に**ならない**。
    /// これが 8 になるなら記録側が定数を焼き込んでいるだけで、全部の assertion が空振り。
    func testABareRequestDoesNotRecordTheInteractiveTimeout() async {
        let session = MockURLProtocol.makeSession()
        var bare = URLRequest(url: baseURL.appendingPathComponent("healthz"))
        bare.httpMethod = "GET"
        _ = try? await session.data(for: bare)

        XCTAssertEqual(MockURLProtocol.requestedTimeouts.count, 1)
        XCTAssertNotEqual(MockURLProtocol.requestedTimeouts.first, BackendSession.interactiveTimeout)
    }

    /// 読む側と待つ側が**同じ session** を通っても違う値で出る事。
    /// 片方だけを見ていると「session の既定が変わっただけ」を分割と読み違える。
    func testReadAndPollDifferOnTheSameSession() async {
        let session = MockURLProtocol.makeSession()
        _ = await HistoryClient(session: session)
            .fetch(baseURL: baseURL, apiKey: "k", sessionID: "s", limit: 50)
        _ = await PollClient(session: session)
            .poll(baseURL: baseURL, apiKey: "k", sessionID: "s", cursor: .empty, waitMs: 20_000)

        XCTAssertEqual(
            MockURLProtocol.requestedTimeouts,
            [BackendSession.interactiveTimeout, BackendSession.pollTimeout]
        )
    }
}
