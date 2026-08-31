import XCTest
@testable import RemoteMini

/// 電話が **どの版から来た要求か** を机へ名乗る経路。
///
/// ## なぜ此処(`BackendSession`)で測るのか
///
/// 2026-08-31 まで、名乗りは `SessionsClient` の一覧取得**1箇所だけ**が打っていた。
/// 他の口(`/api/account` / `/api/sessions/:id/poll` …)は全部 `build=-` として
/// 記録され、机側で実害になった: 同じミリ秒に `/api/sessions`(build=115)と
/// `/api/account`(build=-)が並び、「最後の app 行」を読む道具が後者を掴んで
/// **「電話は版を名乗っていない」と報告した** —— 電話は 115 だったのに。
///
/// 16 箇所の `Authorization` は全部 `BackendSession.data(for:)` を通る。**通り道で押す**
/// 方が、「client を1つ足した日に版が消える」形を構造的に潰せる。だから検査も
/// 通り道に置く —— client ごとに1本ずつ書くと、新しい client を足した日に書き忘れる。
///
/// ★測る中心は「header が出るか」ではない。**押していない実装と区別が付くか**
/// (`nil` を差した時に出ない事)と、**出鱈目な値を名乗らない事**の2つ。
///
/// 同じ header の**受ける側**は `rc-backend/test/reqlog.test.mjs` が測っている
/// (机が `X-App-Build` だけを版として読み、UA からは読まない事)。両端から挟む形。
final class AppBuildHeaderTests: XCTestCase {
    private let baseURL = URL(string: "https://unit-test.invalid")!

    override func setUp() { MockURLProtocol.reset() }
    override func tearDown() { MockURLProtocol.reset() }

    /// 通り道が押す。**client の種類に依らない**事が要点なので、
    /// 一覧ではない口(口座)で測る —— 旧実装は此処を押していなかった。
    func testEveryRequestThroughTheSessionCarriesTheBuild() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(#"{"account":{}}"#.utf8))]

        var request = URLRequest(url: baseURL.appendingPathComponent("api/account"))
        request.setValue("Bearer k", forHTTPHeaderField: "Authorization")
        _ = try? await MockURLProtocol.makeSession(appBuild: "115").data(for: request)

        XCTAssertEqual(
            MockURLProtocol.lastRequestHeaders?["X-App-Build"], "115",
            "一覧以外の口が版を名乗っていない = 机は其の行を『版が判らない』として記録する"
        )
    }

    /// ★陰性対照。之が無いと、`makeSession` が常に何かを押す実装でも上が緑になる。
    func testNoBuildMeansNoHeaderRatherThanAnEmptyOne() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data("{}".utf8))]

        var request = URLRequest(url: baseURL.appendingPathComponent("api/account"))
        request.setValue("Bearer k", forHTTPHeaderField: "Authorization")
        _ = try? await MockURLProtocol.makeSession(appBuild: nil).data(for: request)

        XCTAssertNil(
            MockURLProtocol.lastRequestHeaders?["X-App-Build"],
            "名乗れない時は**送らない**。空文字を送ると机は『版 = 空』を読む事になる"
        )
    }

    /// 既に入っている値は上書きしない。検査が意図して差した値を通り道が消すと、
    /// 「其の値で来た要求」を作れなくなる。
    func testAnExplicitHeaderSurvives() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data("{}".utf8))]

        var request = URLRequest(url: baseURL.appendingPathComponent("api/account"))
        request.setValue("96", forHTTPHeaderField: "X-App-Build")
        _ = try? await MockURLProtocol.makeSession(appBuild: "115").data(for: request)

        XCTAssertEqual(MockURLProtocol.lastRequestHeaders?["X-App-Build"], "96")
    }

    // MARK: - 役も同じ通り道で押す(2026-08-31)

    /// ★版と**同じ疎らさ**を役も持っていた: 元は一覧取得だけが `X-RC-Role` を押し、
    /// `/api/account` 等は役を名乗らないので机は `client=app` と記録した。
    /// 電話の版を見る枝は `client=app` の行を数えるので、**押していない口が1つ在れば
    /// 誤報が再発する**(実測: 誤報 2 通の行は両方の口に出ていた)。
    func testEveryRequestThroughTheSessionCarriesTheRole() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data("{}".utf8))]

        var request = URLRequest(url: baseURL.appendingPathComponent("api/account"))
        request.setValue("Bearer k", forHTTPHeaderField: "Authorization")
        _ = try? await MockURLProtocol.makeSession(appRole: "control").data(for: request)

        XCTAssertEqual(
            MockURLProtocol.lastRequestHeaders?["X-RC-Role"], "control",
            "一覧以外の口が役を名乗っていない = 机は其の行を Tom として数える"
        )
    }

    /// ★陰性対照。配る束は役を持たないので、**押さない**事が一線。
    func testNoRoleMeansNoHeader() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data("{}".utf8))]

        var request = URLRequest(url: baseURL.appendingPathComponent("api/account"))
        request.setValue("Bearer k", forHTTPHeaderField: "Authorization")
        _ = try? await MockURLProtocol.makeSession(appRole: nil).data(for: request)

        XCTAssertNil(
            MockURLProtocol.lastRequestHeaders?["X-RC-Role"],
            "配る束が役を名乗ると、Tom の要求が control として記録される = 今 直そうとしている嘘の悪い版"
        )
    }

    /// `xcodegen` が未定義の変数を書いた形(`${RC_ROLE}`)は名乗らない。
    func testOnlyRealRolesAreAnnounced() {
        XCTAssertEqual(BackendSession.normalizedRole("control"), "control")
        XCTAssertEqual(BackendSession.normalizedRole("  control "), "control")
        for bad in ["${RC_ROLE}", "", "   ", "a${b}c"] {
            XCTAssertNil(BackendSession.normalizedRole(bad), "名乗ってはいけない役が通った: [\(bad)]")
        }
        XCTAssertNil(BackendSession.normalizedRole(nil))
    }

    // MARK: - 名乗ってよい値の規則(束を立てずに測る)

    /// ★`xcodegen` は変数が未定義でも落ちず、`${...}` という**もっともらしい文字列**を
    /// Info.plist に書く(`BuildInfo.displayRev` が同じ罠を扱っている)。素通しにすると
    /// 其れが机の log に載り、後から「其の要求はどの版か」を誰も答えられなくなる。
    func testOnlyAllDigitValuesAreAnnounced() {
        XCTAssertEqual(BackendSession.normalizedBuild("115"), "115")
        XCTAssertEqual(BackendSession.normalizedBuild("  115 "), "115", "前後の空白は落とす")
        for bad in ["${MARKETING_VERSION}", "0.1", "115abc", "", "   ", "-1", "1e3", String(repeating: "9", count: 10)] {
            XCTAssertNil(BackendSession.normalizedBuild(bad), "名乗ってはいけない値が通った: [\(bad)]")
        }
        XCTAssertNil(BackendSession.normalizedBuild(nil))
        XCTAssertEqual(BackendSession.normalizedBuild("999999999"), "999999999", "9 桁までは通る")
    }
}
