import XCTest
@testable import RemoteMini

/// 「机は新しい版を配っている」が、線から画面まで**落ちずに**着くか。
///
/// なぜ此の検査が要るか — 同じ形で2回落としているから:
///   CF-15: `ScreenBody` が `limited` を線から復号せず、返事が来ない事を会話画面が言えなかった。
///   CF-14: `AccountUsage` が `usageStatus` を復号したのに**写す所で落とし**、
///          壊れた口座が未測定の口座と同じ顔で並んだ。
/// どちらも「復号は通るので、画面が痩せるだけで気付けない」形。だから継ぎ目ごとに撃つ:
///
///     サーバ `updateNotice()`(文面を決める)
///       -> `SessionsResponse.OuterDisplay.update`(復号)
///         -> `ListViewModel.updateNotice`(運ぶ)
///           -> `ListView` の帯(描く)
///
/// 最後の1本(画素になるか)は単体では届かないので `ios/tools/update-notice-ui-control.sh` が撃つ。
@MainActor
final class ListUpdateNoticeTests: XCTestCase {

    /// `ListViewModelTests` と同じ形。`refresh()` を呼ばないので網には触れないが、
    /// 初期化子を満たす為に要る。
    private struct UnusedClient: SessionsListing {
        func fetch(baseURL: URL, apiKey: String) async -> Result<SessionsResponse, SessionsFetchError> {
            .failure(.unreachable)
        }
    }

    private func makeViewModel() -> ListViewModel {
        ListViewModel(
            client: UnusedClient(),
            baseURL: URL(string: "https://unit-test.invalid")!,
            apiKey: "unit-test-fixture-key-not-real",
            onUnauthorized: {},
            now: { 1_000_000 }
        )
    }

    private func decode(_ json: String) throws -> SessionsResponse {
        try JSONDecoder().decode(SessionsResponse.self, from: Data(json.utf8))
    }

    // MARK: 復号

    func testDecodesUpdateNoticeFromWire() throws {
        let res = try decode("""
        {"sessions":[],"display":{"scan":"s","update":"机は新しい版を配っています(手元 96 → 配布 105)。"},"paneFault":null}
        """)
        XCTAssertEqual(res.display.update, "机は新しい版を配っています(手元 96 → 配布 105)。")
    }

    /// ★鍵が無い応答で**復号が落ちない**事。落ちると、机が此の欄を出す前の版と
    ///   出した後の版で、一覧そのものが表示できなくなる。
    func testAbsentUpdateKeyDecodesAsNil() throws {
        let res = try decode("""
        {"sessions":[],"display":{"scan":"s"},"paneFault":null}
        """)
        XCTAssertNil(res.display.update)
    }

    func testExplicitNullUpdateDecodesAsNil() throws {
        let res = try decode("""
        {"sessions":[],"display":{"scan":"s","update":null},"paneFault":null}
        """)
        XCTAssertNil(res.display.update)
    }

    // MARK: 「後で」の規則(純関数)

    func testRuleShowsWhenNothingIsSnoozed() {
        XCTAssertEqual(UpdateNoticeRule.visibleNotice(notice: "n", build: "105", snoozed: nil), "n")
    }

    func testRuleHidesTheExactSnoozedBuild() {
        XCTAssertNil(UpdateNoticeRule.visibleNotice(notice: "n", build: "105", snoozed: "105"))
    }

    /// ★黙るのは**その版まで**。次の版が出たら再び出る —— 壁紙を消す仕掛けが
    ///   警報そのものを消してはいけない。
    func testRuleShowsAgainForANewerBuild() {
        XCTAssertEqual(UpdateNoticeRule.visibleNotice(notice: "n", build: "106", snoozed: "105"), "n")
    }

    /// ★**数として**比べる。文字列比較だと "99" > "105" になり、
    ///   105 を黙らせた後に 99 …ではなく、106 を黙らせた後に 99 が出る様な
    ///   逆転が起きる。此処は実際に踏みやすい。
    func testRuleComparesNumericallyNotLexically() {
        // 辞書順だと "99" > "105" なので、"99" を黙らせると "105" も黙る事になる。
        XCTAssertEqual(UpdateNoticeRule.visibleNotice(notice: "n", build: "105", snoozed: "99"), "n",
                       "辞書順で比べている(99 を黙らせたら 105 まで黙った)")
    }

    /// ★番号が判らない時は黙らせられない。鍵の無い記憶は、何を黙らせたのか
    ///   誰も判らないまま警報だけを消す。
    func testRuleShowsWhenTheBuildNumberIsUnknown() {
        XCTAssertEqual(UpdateNoticeRule.visibleNotice(notice: "n", build: nil, snoozed: "105"), "n")
    }

    func testRuleSaysNothingWhenTheDeskSaysNothing() {
        XCTAssertNil(UpdateNoticeRule.visibleNotice(notice: nil, build: "105", snoozed: nil))
        XCTAssertNil(UpdateNoticeRule.visibleNotice(notice: "", build: "105", snoozed: nil))
    }

    // MARK: 運ぶ

    func testViewModelCarriesTheNoticeAfterASuccessfulFetch() {
        let vm = makeViewModel()
        XCTAssertNil(vm.updateNotice, "一度も取れていない時に何か言うのは嘘")
        vm.apply(.success(SessionsResponse(
            sessions: [],
            display: .init(scan: "s", update: "机は新しい版を配っています(手元 96 → 配布 105)。"),
            paneFault: nil
        )))
        XCTAssertEqual(vm.updateNotice, "机は新しい版を配っています(手元 96 → 配布 105)。")
    }

    /// ★空文字を `nil` に落とす。落とさないと**空の帯**が出る ——
    ///   「出す物が無い」と「文面が空」は別で、後者は画面に無言の帯を残す。
    func testEmptyNoticeIsTreatedAsNothingToSay() {
        let vm = makeViewModel()
        vm.apply(.success(SessionsResponse(
            sessions: [], display: .init(scan: "s", update: ""), paneFault: nil
        )))
        XCTAssertNil(vm.updateNotice)
    }

    /// ★机が欄を出していない時も黙る。**推測しない**のが此の欄の全部で、
    ///   「判らない」を「新しいのが在る」に化かすと、栞を叩いても何も変わらず、
    ///   その1回で此の帯は二度と読まれなくなる。
    /// 「後で」を押すと、その版は黙る。押していない版は黙らない。
    func testSnoozingHidesOnlyThatBuild() {
        let store = InMemoryUpdateSnooze()
        let vm = ListViewModel(
            client: UnusedClient(),
            baseURL: URL(string: "https://unit-test.invalid")!,
            apiKey: "unit-test-fixture-key-not-real",
            onUnauthorized: {}, snoozeStore: store
        )
        vm.apply(.success(SessionsResponse(
            sessions: [], display: .init(scan: "s", update: "n", updateBuild: "105"), paneFault: nil)))
        XCTAssertEqual(vm.updateNotice, "n")
        vm.snoozeUpdateNotice()
        XCTAssertNil(vm.updateNotice, "押した版が黙っていない")
        vm.apply(.success(SessionsResponse(
            sessions: [], display: .init(scan: "s", update: "n2", updateBuild: "106"), paneFault: nil)))
        XCTAssertEqual(vm.updateNotice, "n2", "次の版まで黙らせてしまっている")
    }

    /// ★番号が無い時は**憶えない**。憶えると、何を黙らせたのか判らないまま
    ///   以後の警報まで消えうる。
    func testSnoozingWithoutABuildNumberRemembersNothing() {
        let store = InMemoryUpdateSnooze()
        let vm = ListViewModel(
            client: UnusedClient(),
            baseURL: URL(string: "https://unit-test.invalid")!,
            apiKey: "unit-test-fixture-key-not-real",
            onUnauthorized: {}, snoozeStore: store
        )
        vm.apply(.success(SessionsResponse(
            sessions: [], display: .init(scan: "s", update: "n", updateBuild: nil), paneFault: nil)))
        vm.snoozeUpdateNotice()
        XCTAssertNil(store.snoozedBuild())
        XCTAssertEqual(vm.updateNotice, "n", "番号が無いのに黙った")
    }

    func testNoNoticeWhenServerSaysNothing() {
        let vm = makeViewModel()
        vm.apply(.success(SessionsResponse(
            sessions: [], display: .init(scan: "s", update: nil), paneFault: nil
        )))
        XCTAssertNil(vm.updateNotice)
    }
}
