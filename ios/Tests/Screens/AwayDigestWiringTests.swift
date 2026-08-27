import XCTest
@testable import RemoteMini

/// 留守中の要約が **画面まで届く配線** を測る。2026-08-26 新設。
///
/// ★型と口が在っても、画面が読まなければ Tom には何も見えない —— 2026-08-26 に
///   `DigestClient`(型)と `DigestFetcher`(口)を作った時点では、`Sources/Screens/` の
///   どの file もそれを使っていなかった。**「作った」と「届いた」は別**。
///
/// ★此処が守る一線は 3 つ:
///   1. 開いたら取りに行く(取りに行かなければ帯は永久に出ない)
///   2. **取れなくても会話を壊さない**(要約の失敗は会話の失敗ではない)
///   3. **急かすのは急かすべき時だけ**(`unknown` で急かすと信号ごと無視される)
@MainActor
final class AwayDigestWiringTests: XCTestCase {

    private func makeViewModel(digest: DigestFetching) -> ConversationViewModel {
        var clients = ConversationClients.fixture(state: .threeRoles)
        clients = ConversationClients(
            history: clients.history, poll: clients.poll, send: clients.send,
            interrupt: clients.interrupt, choice: clients.choice,
            clearQueue: clients.clearQueue, attach: clients.attach, digest: digest)
        return ConversationViewModel(
            clients: clients,
            draftStore: InMemoryDraftStore(),
            baseURL: URL(string: "https://desk.example")!,
            apiKey: "k",
            sessionID: "abc-123",
            title: "t",
            onUnauthorized: {})
    }

    func test_開いたら要約を取りに行く() async {
        let vm = makeViewModel(digest: DigestFetchingFixture(state: .complete))
        XCTAssertNil(vm.awayDigest, "取りに行く前から値が在る")
        await vm.load()
        XCTAssertNotNil(vm.awayDigest, "開いても取りに行っていない = 帯は永久に出ない")
        XCTAssertEqual(vm.awayDigest?.counts, .init(user: 1, assistant: 1, tool: 1))
    }

    /// ★★要約が取れなくても**会話は使える**。ここで phase を触ると
    /// 「要約の失敗」が「会話の失敗」に化ける。
    func test_要約が取れなくても会話を壊さない() async {
        let vm = makeViewModel(digest: DigestFetchingFailing(error: .unreachable))
        await vm.load()
        XCTAssertNil(vm.awayDigest, "取れていないのに値が在る")
        XCTAssertEqual(vm.phase, .loaded, "要約の失敗で会話まで壊した")
        XCTAssertFalse(vm.history.isEmpty, "履歴まで捨てた")
    }

    /// 鍵の失効だけは別 —— 会話も含めて全部が使えない状態なので合流させる。
    func test_鍵の失効は履歴側と同じ扱いへ合流する() async {
        var called = false
        var clients = ConversationClients.fixture(state: .threeRoles)
        clients = ConversationClients(
            history: clients.history, poll: clients.poll, send: clients.send,
            interrupt: clients.interrupt, choice: clients.choice,
            clearQueue: clients.clearQueue, attach: clients.attach,
            digest: DigestFetchingFailing(error: .unauthorized))
        let vm = ConversationViewModel(
            clients: clients, draftStore: InMemoryDraftStore(),
            baseURL: URL(string: "https://desk.example")!, apiKey: "k",
            sessionID: "abc-123", title: "t", onUnauthorized: { called = true })
        await vm.load()
        XCTAssertTrue(called, "401 を握り潰した")
    }

    /// ★急かすのは急かすべき時だけ。`unknown` で急かすと、信号ごと無視される様になる。
    func test_待っている時だけ急かす() async {
        let waiting = makeViewModel(digest: DigestFetchingFixture(state: .waiting))
        await waiting.load()
        XCTAssertEqual(waiting.awayDigest?.shouldUrge, true, "待っているのに急かさない")

        let unreadable = makeViewModel(digest: DigestFetchingFixture(state: .incomplete))
        await unreadable.load()
        XCTAssertEqual(unreadable.awayDigest?.shouldUrge, false, "unknown で急かしている")
    }

    /// 読めなかった窓は **`counts` が nil のまま**画面へ届く(0 に潰さない)。
    func test_読めなかった窓は0件に見せない() async {
        let vm = makeViewModel(digest: DigestFetchingFixture(state: .incomplete))
        await vm.load()
        XCTAssertNil(vm.awayDigest?.counts, "0 件に潰すと『静かだった』に見える")
        XCTAssertEqual(vm.awayDigest?.complete, false)
    }
}

/// 失敗だけを返す作り物。`DigestFetchingFixture` は成功しか返さないので分けた ——
/// 1 つの作り物に成功と失敗を両方持たせると、呼ぶ側が状態を書き換える手間が増えて
/// 「どちらを測っている検査か」が読みにくくなる。
private struct DigestFetchingFailing: DigestFetching {
    let error: SessionsFetchError
    func fetch(baseURL: URL, apiKey: String, sessionID: String) async
        -> Result<SessionDigest, SessionsFetchError> { .failure(error) }
}
