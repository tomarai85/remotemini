import XCTest
@testable import RemoteMini

/// 手で組む二重(fixture ではない)。`AccountFixture` は UI 走行の面を持つので、
/// 此処では**返す物を1本ずつ指定できる**方が測りたい遷移に届く。
private final class StubAccountAPI: AccountReading, AccountAdvancing, AccountSelecting {
    var currentResults: [Result<AccountState, AccountError>] = []
    var nextResults: [Result<AccountState, AccountError>] = []
    var selectResults: [Result<AccountState, AccountError>] = []
    private(set) var currentCalls = 0
    private(set) var nextCalls = 0
    private(set) var selectedNames: [String] = []

    func current(baseURL: URL, apiKey: String) async -> Result<AccountState, AccountError> {
        currentCalls += 1
        return currentResults.isEmpty ? .failure(.unreachable) : currentResults.removeFirst()
    }

    func next(baseURL: URL, apiKey: String) async -> Result<AccountState, AccountError> {
        nextCalls += 1
        return nextResults.isEmpty ? .failure(.unreachable) : nextResults.removeFirst()
    }

    func select(name: String, baseURL: URL, apiKey: String) async -> Result<AccountState, AccountError> {
        selectedNames.append(name)
        return selectResults.isEmpty ? .failure(.unreachable) : selectResults.removeFirst()
    }
}

/// 条件が真になるまで待つ。期限内に真にならなければ **false を返して諦める**。
///
/// ★期限を持たせる理由(2026-08-15、実測)。此処は元々 `withCheckedContinuation` を
/// 期限なしで待っていた。`account-ui-control.sh` の A3(= `select` の失敗後の
/// `await load()` を削る変異)を回すと、門付きの読み取りが**そもそも始まらない**ので
/// 誰も continuation を resume せず、`testTheOldNameStaysReadableWhileASwitchIsInFlight`
/// が **16分26秒 走り続けた**(観測: 単体走行1本が 10:58:17 開始で終わらず、
/// 兄弟の検査は全て 0.001 秒台)。
///
/// 質が違う: 期限の無い待ちは「振る舞いが消えた」を**赤ではなく走行の停止**に変える。
/// 赤は読めるが、停止は読めない —— 出荷の口(pre-commit)で此れが起きると commit が
/// 永久に返らず、しかも画面には「対照を回している」としか出ない。
/// 二重が待つ場所には全て期限を置く。5秒にしたのは、負荷の掛かった機械で
/// **偽の赤**を出さない幅を取りつつ、走行が停まったと判る所まで縮める為。
private func waitUntilTrue(
    _ condition: () -> Bool,
    within seconds: Double = 5
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
    while !condition() {
        if ContinuousClock.now >= deadline { return false }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return true
}

/// 読み取りを**任意の時点まで止められる**二重。順序の欠陥は「遅い方が後に着く」を
/// 実際に作らないと測れないので、`Task.sleep` のような時間頼みではなく門で止める
/// (時間で組むと、遅い機械では逆順になって検査が別の物を測る)。
///
/// ★門は旗で持つ(continuation ではない)。`waitUntilTrue` の doc に在る通り、
/// continuation は**誰も resume しない木**で走行ごと吊るからで、旗なら期限で降りられる。
@MainActor
private final class GatedAccountAPI: AccountReading, AccountAdvancing, AccountSelecting {
    private struct PendingRead {
        let result: Result<AccountState, AccountError>
        let gated: Bool
    }

    private var reads: [PendingRead] = []
    private var gateIsOpen = false
    private var gatedReadIsRunning = false
    var nextResult: Result<AccountState, AccountError> = .failure(.unreachable)
    var selectResult: Result<AccountState, AccountError> = .failure(.unreachable)

    func enqueueRead(_ result: Result<AccountState, AccountError>, gated: Bool) {
        reads.append(PendingRead(result: result, gated: gated))
    }

    /// 門付きの読み取りが**実際に始まった**所まで待つ。之が無いと、切替が先に走って
    /// しまい「古い読み取りが後に着く」という測りたい順序が作れない。
    ///
    /// 始まらないまま期限が来たら **XCTFail で赤にして先へ進む**。黙って進むと、
    /// 此の後の assertion が「順序が作れていない木」を測った結果として出る。
    func waitUntilGatedReadStarted(
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let started = await waitUntilTrue { self.gatedReadIsRunning }
        if !started {
            XCTFail(
                "門付きの読み取りが期限内に始まらなかった。"
                    + "読み直しを呼ぶ経路が消えている可能性がある(此の待ちは順序を作る為の物で、"
                    + "始まらない木では測りたい順序自体が存在しない)。",
                file: file,
                line: line
            )
        }
    }

    func releaseGatedRead() {
        gateIsOpen = true
    }

    func current(baseURL: URL, apiKey: String) async -> Result<AccountState, AccountError> {
        guard !reads.isEmpty else { return .failure(.unreachable) }
        let pending = reads.removeFirst()
        if pending.gated {
            gatedReadIsRunning = true
            // ★此処にも期限を置く。検査が `releaseGatedRead()` を呼び忘れた木では、
            //   呼び出し側の `await` が永久に返らない —— 上と同じ「赤ではなく停止」。
            let opened = await waitUntilTrue { self.gateIsOpen }
            if !opened {
                XCTFail("門付きの読み取りが期限内に解放されなかった(releaseGatedRead の呼び忘れ)。")
            }
        }
        return pending.result
    }

    func next(baseURL: URL, apiKey: String) async -> Result<AccountState, AccountError> {
        nextResult
    }

    func select(name: String, baseURL: URL, apiKey: String) async -> Result<AccountState, AccountError> {
        selectResult
    }
}

@MainActor
final class AccountViewModelTests: XCTestCase {
    private let baseURL = URL(string: "https://unit-test.invalid")!

    // MARK: - 検体の組み立て

    /// 読めた一覧。`current` が `names` の1本目、`tokenless` に挙げた名前だけが
    /// 選べない行になる —— 机が寄越す形(`rc-backend/src/wire.mjs` の `accountRow`)と同じ。
    private func listing(current: String?, names: [String], tokenless: Set<String> = []) -> AccountState {
        AccountState(
            current: current,
            accounts: names.map { name in
                AccountRow(
                    name: name,
                    hasToken: !tokenless.contains(name),
                    active: name == current,
                    selectable: !tokenless.contains(name),
                    blocked: tokenless.contains(name) ? "そのアカウントのトークンが edith にありません。" : nil
                )
            },
            ok: true,
            statusMessage: nil,
            anomalyMessages: [],
            raw: nil,
            rawTruncated: false
        )
    }

    /// 台本の出力が読めなかった時の答え。**失敗ではない**(机には届いている)。
    private func unreadable(current: String?) -> AccountState {
        AccountState(
            current: current,
            accounts: [],
            ok: false,
            statusMessage: "アカウント一覧の行が読めませんでした。",
            anomalyMessages: [],
            raw: "garbage",
            rawTruncated: false
        )
    }

    private func makeViewModel(
        _ api: AccountReading & AccountAdvancing & AccountSelecting,
        onUnauthorized: @escaping () -> Void = {}
    ) -> AccountViewModel {
        AccountViewModel(
            reader: api, advancer: api, selector: api,
            baseURL: baseURL, apiKey: "k",
            onUnauthorized: onUnauthorized
        )
    }

    // MARK: - 読む

    /// ★「まだ訊いていない」と「訊いたが口座が無い」を1つに畳まない事の検査。
    /// 畳むと、まだ見ていないだけの時に空のラベルが出て「口座が無い」に読める。
    func testBeforeAnythingIsAskedThePhaseIsIdleAndNotAnEmptyAccount() {
        let viewModel = makeViewModel(StubAccountAPI())

        XCTAssertEqual(viewModel.phase, .idle)
        XCTAssertNil(viewModel.currentName)
    }

    func testLoadShowsTheListingTheBackendNamed() async {
        let api = StubAccountAPI()
        api.currentResults = [.success(listing(current: "team", names: ["team", "biz"]))]
        let viewModel = makeViewModel(api)

        await viewModel.load()

        XCTAssertEqual(viewModel.currentName, "team")
        guard case .loaded(let state) = viewModel.phase else { return XCTFail("読めていない: \(viewModel.phase)") }
        XCTAssertEqual(state.accounts.map(\.name), ["team", "biz"])
    }

    /// ★一覧が読めない事は `.failed` ではない。`.failed` に落とすと画面は
    /// 「机に届かない」と言う事になる —— 届いてはいて、台本の出力が読めないだけ。
    /// 退避路(矢印)は其の場面でも押せなければならないので、相の区別が効く。
    func testAnUnreadableListingStaysLoadedRatherThanFalling() async {
        let api = StubAccountAPI()
        api.currentResults = [.success(unreadable(current: "team"))]
        let viewModel = makeViewModel(api)

        await viewModel.load()

        guard case .loaded(let state) = viewModel.phase else { return XCTFail("失敗に畳んでいる: \(viewModel.phase)") }
        XCTAssertFalse(state.ok)
        XCTAssertEqual(viewModel.currentName, "team")
    }

    // MARK: - 名指しで選ぶ(§9-3)

    func testSelectSwitchesToTheNamedAccount() async {
        let api = StubAccountAPI()
        api.currentResults = [.success(listing(current: "team", names: ["team", "biz"]))]
        api.selectResults = [.success(listing(current: "biz", names: ["team", "biz"]))]
        let viewModel = makeViewModel(api)
        await viewModel.load()

        await viewModel.select("biz")

        XCTAssertEqual(api.selectedNames, ["biz"])
        XCTAssertEqual(viewModel.currentName, "biz")
        XCTAssertNil(viewModel.lastFailure)
        XCTAssertFalse(viewModel.isBusy)
    }

    /// ★選べない行は机へ**投げない**。理由は机が書いた文をそのまま出す。
    /// 机側の門を消した訳ではない(此処は往復を1つ省くだけ)ので、
    /// 「電話が通しても机が断る」形は別の検体で押さえてある。
    func testSelectingABlockedRowShowsTheServersReasonWithoutARoundTrip() async {
        let api = StubAccountAPI()
        api.currentResults = [.success(listing(current: "team", names: ["team", "sdgs"], tokenless: ["sdgs"]))]
        let viewModel = makeViewModel(api)
        await viewModel.load()

        await viewModel.select("sdgs")

        XCTAssertEqual(api.selectedNames, [], "選べない行を机へ投げている")
        XCTAssertEqual(viewModel.lastFailure, "そのアカウントのトークンが edith にありません。")
        XCTAssertEqual(viewModel.currentName, "team", "断ったのに現用が動いた")
    }

    /// ★断り(400)の後は**読み直さない**。断りは台本を叩く前に返るので口座は動いて
    /// いない —— 読み直すと「何か起きたかもしれない」という誤った印象になる。
    func testARefusedSelectDoesNotRereadBecauseNothingMoved() async {
        let api = StubAccountAPI()
        api.currentResults = [.success(listing(current: "team", names: ["team", "biz"]))]
        api.selectResults = [.failure(.refused("そのアカウントは一覧にありません。"))]
        let viewModel = makeViewModel(api)
        await viewModel.load()

        await viewModel.select("biz")

        XCTAssertEqual(api.currentCalls, 1, "断りの後に測り直している")
        XCTAssertEqual(viewModel.lastFailure, "そのアカウントは一覧にありません。")
    }

    /// ★失敗しても**一覧が画面から消えない**事。失敗の直後こそ「今どこに居て、
    /// 他に何が選べるか」が要る場面なので、相を `.failed` へ落とすのは向きが逆。
    func testAFailedSelectKeepsTheListingOnScreen() async {
        let api = StubAccountAPI()
        api.currentResults = [
            .success(listing(current: "team", names: ["team", "biz"])),
            .success(listing(current: "biz", names: ["team", "biz"])), // 実は動いていた
        ]
        api.selectResults = [.failure(.backend("timed out"))]
        let viewModel = makeViewModel(api)
        await viewModel.load()

        await viewModel.select("biz")

        guard case .loaded(let state) = viewModel.phase else { return XCTFail("一覧が消えた: \(viewModel.phase)") }
        XCTAssertEqual(state.accounts.map(\.name), ["team", "biz"])
        XCTAssertEqual(api.currentCalls, 2, "500 の後に測り直していない")
        XCTAssertEqual(viewModel.currentName, "biz", "着地点が出ていない")
        XCTAssertEqual(viewModel.lastFailure?.contains("timed out"), true, "失敗の理由が消えた")
    }

    /// 何かが飛んでいる間は次を受け付けない。判定が2箇所に割れると
    /// 「矢印は押せないが名指しは押せる」形が生える。
    func testASecondSwitchIsRefusedWhileOneIsInFlight() async {
        let api = GatedAccountAPI()
        let viewModel = makeViewModel(api)
        api.enqueueRead(.success(listing(current: "team", names: ["team", "biz"])), gated: false)
        await viewModel.load()

        // 読み直しを門で止めて `advance()` を宙に浮かせる…のではなく、
        // `isBusy` の定義そのものを押さえる: 飛んでいない時だけ受け付ける。
        XCTAssertFalse(viewModel.isBusy)
        api.nextResult = .success(listing(current: "biz", names: ["team", "biz"]))
        await viewModel.advance()
        XCTAssertFalse(viewModel.isBusy, "終わったのに塞がったまま")
        XCTAssertEqual(viewModel.currentName, "biz")
    }

    /// 読み込む前(`.idle`)に押しても机へ飛ばない。一覧を持たないまま名前だけ投げる形は、
    /// 「画面に無い候補へ切り替わる」= 人が見ていない操作になる。
    func testSelectBeforeTheListingIsLoadedDoesNothing() async {
        let api = StubAccountAPI()
        let viewModel = makeViewModel(api)

        await viewModel.select("biz")

        XCTAssertEqual(api.selectedNames, [])
        XCTAssertEqual(viewModel.phase, .idle)
    }

    // MARK: - 矢印(退避路)

    func testAdvanceMovesToTheNextAccount() async {
        let api = StubAccountAPI()
        api.currentResults = [.success(listing(current: "team", names: ["team", "biz"]))]
        api.nextResults = [.success(listing(current: "biz", names: ["team", "biz"]))]
        let viewModel = makeViewModel(api)
        await viewModel.load()

        await viewModel.advance()

        XCTAssertEqual(viewModel.currentName, "biz")
        XCTAssertEqual(api.nextCalls, 1)
    }

    /// ★此のファイルの要。切替が失敗しても**口座は進んでいるかもしれない**ので、
    /// 失敗の後に必ず読み直す。読み直さない実装は、机の実際の口座と画面の表示が
    /// 食い違ったまま放置される —— しかも「失敗した」と出ているので、人は
    /// 「変わっていない」と読む。嘘の向きが一番悪い形。
    func testAFailedSwitchRereadsTheAccountRatherThanAssumingItDidNotMove() async {
        let api = StubAccountAPI()
        api.currentResults = [
            .success(listing(current: "team", names: ["team", "biz"])),   // 最初の load
            .success(listing(current: "biz", names: ["team", "biz"])),    // 読み直し = 実は進んでいた
        ]
        api.nextResults = [.failure(.backend("timed out"))]
        let viewModel = makeViewModel(api)
        await viewModel.load()

        await viewModel.advance()

        XCTAssertEqual(api.currentCalls, 2, "失敗の後に読み直していない")
        // 失敗した事と、実際に何処に着いたかの**両方**が出る。
        XCTAssertEqual(viewModel.lastFailure?.contains("timed out"), true, "失敗の理由が消えた")
        XCTAssertEqual(viewModel.currentName, "biz", "読み直した現在地が出ていない")
    }

    /// 撃ち直さない事の観測。`AccountClient` 側にも同じ的が在るが、此処が壊れると
    /// **view model の層で**二重に進む(client が1回しか撃たなくても意味が無い)。
    func testAdvanceIsNotFiredTwiceForOneTap() async {
        let api = StubAccountAPI()
        api.currentResults = [
            .success(listing(current: "team", names: ["team"])),
            .success(listing(current: "team", names: ["team"])),
        ]
        api.nextResults = [.failure(.backend("boom"))]
        let viewModel = makeViewModel(api)
        await viewModel.load()

        await viewModel.advance()

        XCTAssertEqual(api.nextCalls, 1)
    }

    /// 切替中も現用の名前は残る。消すと「切替がアカウントを消した」と見分けが付かない。
    func testTheOldNameStaysReadableWhileASwitchIsInFlight() async {
        let api = GatedAccountAPI()
        let viewModel = makeViewModel(api)
        api.enqueueRead(.success(listing(current: "team", names: ["team", "biz"])), gated: false)
        await viewModel.load()

        // 門付きの読み直しを積んでおくと、`select` の失敗経路が其処で止まる ——
        // 其の間の相を直に見る。
        api.selectResult = .failure(.backend("boom"))
        api.enqueueRead(.success(listing(current: "biz", names: ["team", "biz"])), gated: true)
        let switching = Task { await viewModel.select("biz") }
        await api.waitUntilGatedReadStarted()

        XCTAssertEqual(viewModel.currentName, "team", "切替の最中に名前が消えた")

        api.releaseGatedRead()
        await switching.value
    }

    // MARK: - 鍵

    /// 401 は口座の問題ではなく鍵の問題。上位へ抜けないと、電話は鍵入力へ戻れない。
    func testAnUnauthorizedReadTellsTheAppToDropTheCredentials() async {
        let api = StubAccountAPI()
        api.currentResults = [.failure(.unauthorized)]
        var dropped = false
        let viewModel = makeViewModel(api, onUnauthorized: { dropped = true })

        await viewModel.load()

        XCTAssertTrue(dropped)
        XCTAssertEqual(viewModel.phase, .failed(reason: "鍵が拒まれました"))
    }

    func testAnUnauthorizedSwitchAlsoDropsTheCredentials() async {
        let api = StubAccountAPI()
        api.currentResults = [.success(listing(current: "team", names: ["team"]))]
        api.nextResults = [.failure(.unauthorized)]
        var dropped = false
        let viewModel = makeViewModel(api, onUnauthorized: { dropped = true })
        await viewModel.load()

        await viewModel.advance()

        XCTAssertTrue(dropped)
    }

    func testAnUnauthorizedSelectAlsoDropsTheCredentials() async {
        let api = StubAccountAPI()
        api.currentResults = [.success(listing(current: "team", names: ["team", "biz"]))]
        api.selectResults = [.failure(.unauthorized)]
        var dropped = false
        let viewModel = makeViewModel(api, onUnauthorized: { dropped = true })
        await viewModel.load()

        await viewModel.select("biz")

        XCTAssertTrue(dropped)
        XCTAssertEqual(viewModel.phase, .failed(reason: "鍵が拒まれました"))
        // 鍵が拒まれた時に断りの1行を残すと、鍵入力画面へ戻った後も口座の断りが
        // 画面に居座る。相を落とす道では消す。
        XCTAssertNil(viewModel.lastFailure)
    }

    // MARK: - 順序

    /// ★**Codex 2026-08-12 が名指しした操作列**。会話画面から一覧へ戻ると `.task` が
    /// `load()` を撃つ。其の読み取りが飛んでいる最中に切替を押すと、`advance()` が
    /// B を書いた**後**に古い `load()` が A を返す —— 画面は A、机は B。
    /// しかも本人は切替が成功したのを見ているので、嘘だと気付く材料が無い。
    ///
    /// 遅延を掛けられる二重でしか測れない(実物の順序を作る必要が在る)。
    /// 使うのは実 API(`load` / `advance`)だけ —— 検査の為の口を製品に足すと、
    /// 「検査でしか通らない道」が出来て測っている物がずれる。
    func testASlowReadThatLandsAfterASwitchDoesNotOverwriteIt() async {
        let api = GatedAccountAPI()
        let viewModel = makeViewModel(api)

        // ① 普通に読めて A に着く(会話画面へ行く前の状態)。
        api.enqueueRead(.success(listing(current: "A", names: ["A", "B"])), gated: false)
        await viewModel.load()
        XCTAssertEqual(viewModel.currentName, "A")

        // ② 会話画面から戻る = `.task` が2本目の読み取りを撃つ。**止めておく**。
        api.enqueueRead(.success(listing(current: "A", names: ["A", "B"])), gated: true)
        let staleLoad = Task { await viewModel.load() }
        await api.waitUntilGatedReadStarted()

        // ③ 其の最中に切替が完走して B になる。
        api.nextResult = .success(listing(current: "B", names: ["A", "B"]))
        await viewModel.advance()
        XCTAssertEqual(viewModel.currentName, "B")

        // ④ 止めていた古い読み取りが、今頃 A を返す。
        api.releaseGatedRead()
        await staleLoad.value

        XCTAssertEqual(viewModel.currentName, "B",
                       "遅れて着いた古い読み取りが新しい結果を上書きした = 画面が机と食い違う")
    }

    /// 名指しの切替も同じ世代で守られている事。矢印だけ直して名指しを忘れる形を塞ぐ。
    func testASlowReadThatLandsAfterANamedSelectDoesNotOverwriteIt() async {
        let api = GatedAccountAPI()
        let viewModel = makeViewModel(api)

        api.enqueueRead(.success(listing(current: "A", names: ["A", "B"])), gated: false)
        await viewModel.load()

        api.enqueueRead(.success(listing(current: "A", names: ["A", "B"])), gated: true)
        let staleLoad = Task { await viewModel.load() }
        await api.waitUntilGatedReadStarted()

        api.selectResult = .success(listing(current: "B", names: ["A", "B"]))
        await viewModel.select("B")
        XCTAssertEqual(viewModel.currentName, "B")

        api.releaseGatedRead()
        await staleLoad.value

        XCTAssertEqual(viewModel.currentName, "B",
                       "名指しの切替が、遅れて着いた古い読み取りに上書きされた")
    }

    // MARK: - 文言

    /// 文言は view ではなく此処に在る(SwiftUI を立てずに測れる場所)。
    func testEveryFailureHasItsOwnSentence() {
        let sentences = [
            AccountViewModel.message(for: .unreachable),
            AccountViewModel.message(for: .cancelled),
            AccountViewModel.message(for: .unauthorized),
            AccountViewModel.message(for: .backend("x")),
            AccountViewModel.message(for: .refused("y")),
            AccountViewModel.message(for: .unexpectedStatus(418)),
            AccountViewModel.message(for: .malformedBody),
        ]
        XCTAssertEqual(Set(sentences).count, sentences.count, "別の失敗が同じ文になっている")
        XCTAssertTrue(sentences.allSatisfy { !$0.isEmpty })
        XCTAssertTrue(AccountViewModel.message(for: .backend("boom")).contains("boom"),
                      "机が返した理由が文から落ちている")
        // ★断りの文は**机の文そのまま**。言い換えを電話が持つと、机の門が増えた日に
        //   画面の断り方だけが古いまま残る。
        XCTAssertEqual(AccountViewModel.message(for: .refused("そのアカウントのトークンが edith にありません。")),
                       "そのアカウントのトークンが edith にありません。")
    }

    // MARK: - 検査の道具そのもの

    /// 二重の待ちに**期限が在る**事を固定する。
    ///
    /// 此処だけ他の検査と質が違う: 測っているのは製品ではなく、製品を測る道具の方。
    /// 期限を外すと `waitUntilTrue` は永久に返らないので、壊した人が受け取るのは
    /// **赤ではなく走行の停止**になる —— 停止は log に「失敗」として出ないから、
    /// 変異の対照でも pre-commit でも「回している最中」の顔をしたまま止まる
    /// (2026-08-15 に実測: A3 の変異で 16分26秒)。
    /// だから期限を外した時に最初に踏む所を、走行の口ではなく此処に置く。
    /// 此の検査自身は 0.05 秒で諦めるので、壊れていれば **此の1本が吊る** = 場所が判る。
    func testABoundedWaitGivesUpInsteadOfWaitingForever() async {
        let held = await waitUntilTrue({ false }, within: 0.05)
        XCTAssertFalse(held,
                       "期限が来ても諦めていない = 待ちに期限が効いていない。"
                           + "此の状態では『振る舞いが消えた』が赤ではなく走行の停止として出る。")
    }

    /// 期限が在る事と引き換えに**偽の赤**を出していないか。条件が既に真なら待たずに真を返す。
    func testABoundedWaitReturnsAtOnceWhenTheConditionAlreadyHolds() async {
        let held = await waitUntilTrue({ true }, within: 0.05)
        XCTAssertTrue(held, "既に真の条件で諦めている = 期限が短すぎるか判定の向きが逆")
    }

    /// 条件が**途中で**真になる木。上の2本は端(常に偽 / 常に真)しか押さえないので、
    /// 「一度も再評価していない」実装(初回だけ見て期限まで寝る)が通ってしまう。
    func testABoundedWaitSeesAConditionThatBecomesTrueLater() async {
        final class Flag: @unchecked Sendable { var value = false }
        let flag = Flag()
        Task {
            try? await Task.sleep(for: .milliseconds(20))
            flag.value = true
        }
        let held = await waitUntilTrue({ flag.value }, within: 5)
        XCTAssertTrue(held, "後から真になった条件を拾えていない = 条件を再評価していない")
    }
}
