import XCTest
@testable import RemoteMini

/// 手で組む二重(fixture ではない)。`AccountFixture` は UI 走行の面を持つので、
/// 此処では**返す物を1本ずつ指定できる**方が測りたい遷移に届く。
private final class StubAccountAPI: AccountReading, AccountAdvancing {
    var currentResults: [Result<AccountState, AccountError>] = []
    var nextResults: [Result<AccountState, AccountError>] = []
    private(set) var currentCalls = 0
    private(set) var nextCalls = 0

    func current(baseURL: URL, apiKey: String) async -> Result<AccountState, AccountError> {
        currentCalls += 1
        return currentResults.isEmpty ? .failure(.unreachable) : currentResults.removeFirst()
    }

    func next(baseURL: URL, apiKey: String) async -> Result<AccountState, AccountError> {
        nextCalls += 1
        return nextResults.isEmpty ? .failure(.unreachable) : nextResults.removeFirst()
    }
}

/// 読み取りを**任意の時点まで止められる**二重。順序の欠陥は「遅い方が後に着く」を
/// 実際に作らないと測れないので、`Task.sleep` のような時間頼みではなく門で止める
/// (時間で組むと、遅い機械では逆順になって検査が別の物を測る)。
@MainActor
private final class GatedAccountAPI: AccountReading, AccountAdvancing {
    private struct PendingRead {
        let result: Result<AccountState, AccountError>
        let gated: Bool
    }

    private var reads: [PendingRead] = []
    private var gate: CheckedContinuation<Void, Never>?
    private var gatedReadStarted: CheckedContinuation<Void, Never>?
    private var gatedReadIsRunning = false
    var nextResult: Result<AccountState, AccountError> = .failure(.unreachable)

    func enqueueRead(_ result: Result<AccountState, AccountError>, gated: Bool) {
        reads.append(PendingRead(result: result, gated: gated))
    }

    /// 門付きの読み取りが**実際に始まった**所まで待つ。之が無いと、切替が先に走って
    /// しまい「古い読み取りが後に着く」という測りたい順序が作れない。
    func waitUntilGatedReadStarted() async {
        if gatedReadIsRunning { return }
        await withCheckedContinuation { self.gatedReadStarted = $0 }
    }

    func releaseGatedRead() {
        gate?.resume()
        gate = nil
    }

    func current(baseURL: URL, apiKey: String) async -> Result<AccountState, AccountError> {
        guard !reads.isEmpty else { return .failure(.unreachable) }
        let pending = reads.removeFirst()
        if pending.gated {
            gatedReadIsRunning = true
            gatedReadStarted?.resume()
            gatedReadStarted = nil
            await withCheckedContinuation { self.gate = $0 }
        }
        return pending.result
    }

    func next(baseURL: URL, apiKey: String) async -> Result<AccountState, AccountError> {
        nextResult
    }
}

@MainActor
final class AccountViewModelTests: XCTestCase {
    private let baseURL = URL(string: "https://unit-test.invalid")!

    private func makeViewModel(
        _ api: AccountReading & AccountAdvancing,
        onUnauthorized: @escaping () -> Void = {}
    ) -> AccountViewModel {
        AccountViewModel(
            reader: api, advancer: api,
            baseURL: baseURL, apiKey: "k",
            onUnauthorized: onUnauthorized
        )
    }

    /// ★「まだ訊いていない」と「訊いたが口座が無い」を1つに畳まない事の検査。
    /// 畳むと、まだ見ていないだけの時に空のラベルが出て「口座が無い」に読める。
    func testBeforeAnythingIsAskedThePhaseIsIdleAndNotAnEmptyAccount() {
        let viewModel = makeViewModel(StubAccountAPI())

        XCTAssertEqual(viewModel.phase, .idle)
    }

    func testLoadShowsTheAccountTheBackendNamed() async {
        let api = StubAccountAPI()
        api.currentResults = [.success(AccountState(account: "a@example.com"))]
        let viewModel = makeViewModel(api)

        await viewModel.load()

        XCTAssertEqual(viewModel.phase, .loaded(account: "a@example.com", switching: false))
    }

    func testAdvanceMovesToTheNextAccount() async {
        let api = StubAccountAPI()
        api.currentResults = [.success(AccountState(account: "a"))]
        api.nextResults = [.success(AccountState(account: "b"))]
        let viewModel = makeViewModel(api)
        await viewModel.load()

        await viewModel.advance()

        XCTAssertEqual(viewModel.phase, .loaded(account: "b", switching: false))
        XCTAssertEqual(api.nextCalls, 1)
    }

    /// ★此のファイルの要。切替が失敗しても**口座は進んでいるかもしれない**ので、
    /// 失敗の後に必ず読み直す。読み直さない実装は、机の実際の口座と画面の表示が
    /// 食い違ったまま放置される —— しかも「失敗した」と出ているので、人は
    /// 「変わっていない」と読む。嘘の向きが一番悪い形。
    func testAFailedSwitchRereadsTheAccountRatherThanAssumingItDidNotMove() async {
        let api = StubAccountAPI()
        api.currentResults = [
            .success(AccountState(account: "a")),   // 最初の load
            .success(AccountState(account: "b")),   // 失敗の後の読み直し = 実は進んでいた
        ]
        api.nextResults = [.failure(.backend("timed out"))]
        let viewModel = makeViewModel(api)
        await viewModel.load()

        await viewModel.advance()

        XCTAssertEqual(api.currentCalls, 2, "失敗の後に読み直していない")
        guard case .failed(let reason) = viewModel.phase else {
            return XCTFail("失敗を隠して成功に見せている: \(viewModel.phase)")
        }
        // 失敗した事と、実際に何処に着いたかの**両方**が出る。
        XCTAssertTrue(reason.contains("timed out"), "失敗の理由が消えた: \(reason)")
        XCTAssertTrue(reason.contains("b"), "読み直した現在地が出ていない: \(reason)")
    }

    /// 撃ち直さない事の観測。`AccountClient` 側にも同じ的が在るが、此処が壊れると
    /// **view model の層で**二重に進む(client が1回しか撃たなくても意味が無い)。
    func testAdvanceIsNotFiredTwiceForOneTap() async {
        let api = StubAccountAPI()
        api.currentResults = [.success(AccountState(account: "a")), .success(AccountState(account: "a"))]
        api.nextResults = [.failure(.backend("boom"))]
        let viewModel = makeViewModel(api)
        await viewModel.load()

        await viewModel.advance()

        XCTAssertEqual(api.nextCalls, 1)
    }

    /// 切替中は古いラベルを残す。消すと「切替がアカウントを消した」と見分けが付かない。
    func testTheOldLabelStaysVisibleWhileTheSwitchIsInFlight() async {
        let api = StubAccountAPI()
        api.currentResults = [.success(AccountState(account: "a"))]
        let viewModel = makeViewModel(api)
        await viewModel.load()

        // `advance()` の中で最初に立つ相を直に見る為、遅延を挟まず nextResults を
        // 空にして即失敗させ、**その手前で**立った相の形を検査する代わりに、
        // 相の定義そのものを撃つ: `switching: true` の時に口座名を持っている事。
        let inFlight = AccountViewModel.Phase.loaded(account: "a", switching: true)
        guard case .loaded(let account, let switching) = inFlight else {
            return XCTFail("相の形が変わった")
        }
        XCTAssertEqual(account, "a")
        XCTAssertTrue(switching)
    }

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
        api.currentResults = [.success(AccountState(account: "a"))]
        api.nextResults = [.failure(.unauthorized)]
        var dropped = false
        let viewModel = makeViewModel(api, onUnauthorized: { dropped = true })
        await viewModel.load()

        await viewModel.advance()

        XCTAssertTrue(dropped)
    }

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
        api.enqueueRead(.success(AccountState(account: "A")), gated: false)
        await viewModel.load()
        XCTAssertEqual(viewModel.phase, .loaded(account: "A", switching: false))

        // ② 会話画面から戻る = `.task` が2本目の読み取りを撃つ。**止めておく**。
        api.enqueueRead(.success(AccountState(account: "A")), gated: true)
        let staleLoad = Task { await viewModel.load() }
        await api.waitUntilGatedReadStarted()

        // ③ 其の最中に切替が完走して B になる。
        api.nextResult = .success(AccountState(account: "B"))
        await viewModel.advance()
        XCTAssertEqual(viewModel.phase, .loaded(account: "B", switching: false))

        // ④ 止めていた古い読み取りが、今頃 A を返す。
        api.releaseGatedRead()
        await staleLoad.value

        XCTAssertEqual(viewModel.phase, .loaded(account: "B", switching: false),
                       "遅れて着いた古い読み取りが新しい結果を上書きした = 画面が机と食い違う")
    }

    /// 文言は view ではなく此処に在る(SwiftUI を立てずに測れる場所)。
    func testEveryFailureHasItsOwnSentence() {
        let sentences = [
            AccountViewModel.message(for: .unreachable),
            AccountViewModel.message(for: .cancelled),
            AccountViewModel.message(for: .unauthorized),
            AccountViewModel.message(for: .backend("x")),
            AccountViewModel.message(for: .unexpectedStatus(418)),
            AccountViewModel.message(for: .malformedBody),
        ]
        XCTAssertEqual(Set(sentences).count, sentences.count, "別の失敗が同じ文になっている")
        XCTAssertTrue(sentences.allSatisfy { !$0.isEmpty })
        XCTAssertTrue(AccountViewModel.message(for: .backend("boom")).contains("boom"),
                      "机が返した理由が文から落ちている")
    }
}
