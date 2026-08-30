import XCTest
@testable import RemoteMini

/// 口座の**使用量**が、机の出す形のまま電話へ着き、画面に出る所まで測る(2026-08-30)。
///
/// ★本文(JSON)は**手で書いていない**。`AccountClientTests` と同じ流儀で、
/// `rc-backend` の `accountBody` を実際に走らせた出力を貼ってある:
///
///     node -e 'Promise.all([import("./src/wire.mjs"), import("./src/account.mjs")])
///       .then(([w,a]) => console.log(JSON.stringify(
///         w.accountBody(a.parseFleetAccount(raw),
///           { raw, usageByEmail: {...}, usageAgeSeconds: 45 }))))'
///
/// 手で組んだ本文は「電話が読める形」しか測らず、**机が本当に其の形を出すか**を一度も
/// 測らない —— 監査 S8-24 が数えた穴の正体。鍵名そのものの一致は
/// `rc-backend/test/wire-key-agreement.test.mjs` が両側を実行して測る。
///
/// ★此処が守る不変条件は3つ:
///   1. `null` の窓(測れていない)を 0 とも 100 とも読まない
///   2. 齢が閾値を超えたら**数字を出さない**(古い値が「今の値」として切替の判断に使われる)
///   3. 尽きた口座を色で名指しできる(`usageExhausted`)
final class AccountUsageTests: XCTestCase {

    /// 机の実出力(3行 = 週を使い切った team / 余裕の biz / 測れない sdgs)。
    private static let body = Data(#"""
    {"account":"team","current":"team","accounts":[\#
    {"name":"team","hasToken":true,"active":true,"selectable":true,"display":{"blocked":null},\#
    "usage":{"usageStatus":"ok","sessionUsedPct":0,"weeklyUsedPct":100,\#
    "weeklyResetsIn":"20h 46m","willLastToReset":false}},\#
    {"name":"biz","hasToken":true,"active":false,"selectable":true,"display":{"blocked":null},\#
    "usage":{"usageStatus":"ok","sessionUsedPct":6,"weeklyUsedPct":13,\#
    "weeklyResetsIn":"5d 19h","willLastToReset":true}},\#
    {"name":"sdgs","hasToken":false,"active":false,"selectable":false,\#
    "display":{"blocked":"That account's token is missing on host-redacted."},\#
    "usage":{"usageStatus":"unavailable","sessionUsedPct":null,"weeklyUsedPct":null,\#
    "weeklyResetsIn":null,"willLastToReset":null}}],\#
    "ok":true,"parseStatus":"ok","anomalies":[],"usageAgeSeconds":45,\#
    "display":{"status":null,"anomalies":[]}}
    """#.utf8)

    /// `usage` の鍵が**丸ごと無い**机(この機能を配る前の版)。古い机に繋いでも落ちない事。
    private static let bodyWithoutUsage = Data(#"""
    {"account":"team","current":"team","accounts":[\#
    {"name":"team","hasToken":true,"active":true,"selectable":true,"display":{"blocked":null}}],\#
    "ok":true,"parseStatus":"ok","anomalies":[],"display":{"status":null,"anomalies":[]}}
    """#.utf8)

    private let baseURL = URL(string: "https://unit-test.invalid")!

    override func setUp() { MockURLProtocol.reset() }
    override func tearDown() { MockURLProtocol.reset() }

    /// 机の封筒を1回返して、電話が読んだ結果を取る(`AccountClientTests` と同じ足場)。
    private func read(_ data: Data) async -> AccountState? {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: data)]
        let client = AccountClient(session: MockURLProtocol.makeSession())
        guard case .success(let state) = await client.current(baseURL: baseURL, apiKey: "k") else {
            return nil
        }
        return state
    }

    // MARK: - ① 机の出力がそのまま model へ着く

    func testDeskUsageReachesTheModelUnchanged() async throws {
        let read = await read(Self.body)
        let state = try XCTUnwrap(read, "読めていない")
        XCTAssertEqual(state.usageAgeSeconds, 45, "観測の齢が落ちている")

        let team = try XCTUnwrap(state.accounts.first { $0.name == "team" })
        let usage = try XCTUnwrap(team.usage, "使用量が落ちている")
        XCTAssertEqual(usage.sessionUsedPct, 0)
        XCTAssertEqual(usage.weeklyUsedPct, 100)
        XCTAssertEqual(usage.weeklyResetsIn, "20h 46m")
        XCTAssertEqual(usage.willLastToReset, false)
    }

    /// ★測れていない窓は `nil` のまま。**0 でも 100 でもない** ——
    /// 0 に落とせば「使い切った」、100 に落とせば「空いている」と読まれ、
    /// どちらも口座の切替を誤らせる。
    func testUnmeasuredWindowsStayNilNotZero() async throws {
        let read = await read(Self.body)
        let state = try XCTUnwrap(read, "読めていない")
        let sdgs = try XCTUnwrap(state.accounts.first { $0.name == "sdgs" })
        let usage = try XCTUnwrap(sdgs.usage, "行ごと消えている(消してはいけない)")
        XCTAssertNil(usage.sessionUsedPct)
        XCTAssertNil(usage.weeklyUsedPct)
        XCTAssertNil(usage.weeklyResetsIn)
    }

    /// 使用量を知らない机(この機能の前の版)に繋いでも decode が落ちない。
    func testOlderDeskWithoutUsageStillDecodes() async throws {
        let read = await read(Self.bodyWithoutUsage)
        let state = try XCTUnwrap(read, "読めていない")
        XCTAssertNil(state.usageAgeSeconds)
        XCTAssertNil(state.accounts.first?.usage, "鍵が無い時は nil であって 0 ではない")
    }

    // MARK: - ② 画面に出る文字列

    func testUsageLineShowsRemainingNotUsed() {
        let u = AccountUsage(sessionUsedPct: 0, weeklyUsedPct: 100,
                             weeklyResetsIn: "20h 46m", willLastToReset: false)
        // 机は**使用率**を送り、画面は**残り**を描く(100 - pct)。
        XCTAssertEqual(SettingsView.usageLine(u),
                       "Session 100% left · Week 0% left · resets 20h 46m")
    }

    func testUsageLineDropsWindowsItCannotMeasure() {
        let onlyWeekly = AccountUsage(sessionUsedPct: nil, weeklyUsedPct: 13,
                                      weeklyResetsIn: "5d 19h", willLastToReset: true)
        XCTAssertEqual(SettingsView.usageLine(onlyWeekly), "Week 87% left · resets 5d 19h")

        let nothing = AccountUsage(sessionUsedPct: nil, weeklyUsedPct: nil,
                                   weeklyResetsIn: nil, willLastToReset: nil)
        XCTAssertEqual(SettingsView.usageLine(nothing), "",
                       "測れていない口座は**行ごと出さない**(空文字が其の合図)")
    }

    func testExhaustedAccountIsNamed() {
        let sessionGone = AccountUsage(sessionUsedPct: 100, weeklyUsedPct: 13,
                                       weeklyResetsIn: nil, willLastToReset: true)
        let weeklyGone = AccountUsage(sessionUsedPct: 3, weeklyUsedPct: 99,
                                      weeklyResetsIn: nil, willLastToReset: false)
        let fine = AccountUsage(sessionUsedPct: 20, weeklyUsedPct: 40,
                                weeklyResetsIn: nil, willLastToReset: true)
        XCTAssertTrue(SettingsView.usageExhausted(sessionGone))
        XCTAssertTrue(SettingsView.usageExhausted(weeklyGone), "99% 使用は実質尽きている")
        XCTAssertFalse(SettingsView.usageExhausted(fine))
        // 測れていない物を「尽きている」と言わない。
        XCTAssertFalse(SettingsView.usageExhausted(
            AccountUsage(sessionUsedPct: nil, weeklyUsedPct: nil,
                         weeklyResetsIn: nil, willLastToReset: nil)))
    }

    // MARK: - ③ 古い数字を消す(Codex 2026-08-30 の指摘2)

    func testStaleUsageHidesTheNumbers() {
        // 机の TTL は 300s。正常な齢はその前後。
        XCTAssertFalse(SettingsView.usageTooStale(45), "正常な齢で数字を隠してはいけない")
        XCTAssertFalse(SettingsView.usageTooStale(SettingsView.usageStaleAfterSeconds))
        XCTAssertTrue(SettingsView.usageTooStale(SettingsView.usageStaleAfterSeconds + 1),
                      "閾値を越えたら数字を出さない = 先週の値が「今の値」として読まれるのを防ぐ")
        // ★`nil` は「古い」ではない。一度も測れていない時は行そのものが出ないので、
        //   此処で true を返すと「更新不能」の帯が常時出る机が生まれる。
        XCTAssertFalse(SettingsView.usageTooStale(nil))
    }

    // ── 机が名乗る測定の状態(2026-08-30、CF-14)────────────────────────────
    // ★測る中心は「文が出るか」ではなく **壊れた口座と未測定の口座が別の文になるか**。
    //   前者だけなら、両方に同じ1文を返す実装でも通る —— そして其の実装が
    //   2026-08-30 に Tom を壊れた口座へ導いた当の状態(どちらも空文字)と等価。

    func test_健全と未指定は状態の行を出さない() {
        XCTAssertNil(SettingsView.statusLine(
            AccountUsage(usageStatus: "ok", sessionUsedPct: 20, weeklyUsedPct: 40,
                         weeklyResetsIn: "3d", willLastToReset: true)))
        XCTAssertNil(SettingsView.statusLine(
            AccountUsage(sessionUsedPct: 20, weeklyUsedPct: 40,
                         weeklyResetsIn: "3d", willLastToReset: true)),
            "usageStatus 未指定の既定は nil であるべき(既定 ok は健全を騙る)")
    }

    func test_再ログインが要る口座と測れていない口座が別の文になる() {
        let relogin = AccountUsage(usageStatus: "relogin_required", sessionUsedPct: nil,
                                   weeklyUsedPct: nil, weeklyResetsIn: nil, willLastToReset: nil)
        let unmeasured = AccountUsage(usageStatus: "unavailable", sessionUsedPct: nil,
                                      weeklyUsedPct: nil, weeklyResetsIn: nil, willLastToReset: nil)
        let a = SettingsView.statusLine(relogin)
        let b = SettingsView.statusLine(unmeasured)
        XCTAssertNotNil(a); XCTAssertNotNil(b)
        XCTAssertNotEqual(a, b, "壊れた口座と未測定の口座が同じ文 = 2026-08-30 の見分けの付かなさが残る")
        XCTAssertTrue(a?.contains("re-login") == true, "行動が要る事が文に出ていない: \(a ?? "nil")")
        // ★数字が1つも無い時こそ此の行が要る。usageLine は空文字になり、行ごと消えるから。
        XCTAssertTrue(SettingsView.usageLine(relogin).isEmpty,
                      "この検体は usageLine が空である事が前提(空でないなら検体を直す)")
    }

    func test_色で名指しするのは再ログインだけ() {
        XCTAssertTrue(SettingsView.statusIsActionable(
            AccountUsage(usageStatus: "relogin_required", sessionUsedPct: nil,
                         weeklyUsedPct: nil, weeklyResetsIn: nil, willLastToReset: nil)))
        for s in ["unavailable", "keychain_unavailable", "ok"] {
            XCTAssertFalse(SettingsView.statusIsActionable(
                AccountUsage(usageStatus: s, sessionUsedPct: nil, weeklyUsedPct: nil,
                             weeklyResetsIn: nil, willLastToReset: nil)),
                "\(s) を行動が要る側に寄せると、赤が意味を失う")
        }
    }

    func test_知らない語を捨てずに見せる() {
        // ★`usageStatus` は cswap の**開いた語彙**。閉じた集合で switch して default を nil に
        //   すると、語が1つ増えた日に其の口座だけ理由が画面から消える。
        let unknown = AccountUsage(usageStatus: "quota_frozen_by_org", sessionUsedPct: nil,
                                   weeklyUsedPct: nil, weeklyResetsIn: nil, willLastToReset: nil)
        let line = SettingsView.statusLine(unknown)
        XCTAssertNotNil(line, "知らない語を捨てている")
        XCTAssertTrue(line?.contains("quota_frozen_by_org") == true,
                      "生の語が文に出ていない = 訳せない事と何も無い事が同じになる: \(line ?? "nil")")
        XCTAssertFalse(SettingsView.statusIsActionable(unknown),
                       "知らない語を行動が要る側に寄せない(赤の意味が薄まる)")
    }

    func test_空白だけの状態は無いものとして扱う() {
        for s in ["", "   "] {
            XCTAssertNil(SettingsView.statusLine(
                AccountUsage(usageStatus: s, sessionUsedPct: 10, weeklyUsedPct: 10,
                             weeklyResetsIn: nil, willLastToReset: nil)),
                "空白を語として出すと、空の行が画面に増える")
        }
    }

}
