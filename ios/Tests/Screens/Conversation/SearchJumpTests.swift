import XCTest
@testable import RemoteMini

/// 探索の当たりへ跳ぶ判断(対照表 #3、2026-09-03)。作り物の机(`conversation-search`、240 行、錨 = 行番号 × 100)で、
/// 「手元に在る → 読み足さず印」「無い → fromEnd まで読み足して印」「上限より奥 → tooFar」「錨無し → notFound」を測る。
@MainActor
final class SearchJumpTests: XCTestCase {

    private func makeVM(initialLimit: Int = 50) -> ConversationViewModel {
        ConversationViewModel(
            clients: .fixture(state: .search),
            draftStore: InMemoryDraftStore(),
            baseURL: URL(string: "https://unit-test.invalid")!,
            apiKey: "k",
            sessionID: "s",
            title: "t",
            onUnauthorized: {},
            initialLimit: initialLimit
        )
    }

    private func hit(line n: Int, total: Int = 240) -> HistoryEntry {
        HistoryEntry(role: .user, text: String(format: "line %03d", n), display: .init(who: "Tom"),
                     anchor: "\(n * 100):0", fromEnd: total - n)
    }

    func testAHitAlreadyLoadedIsRevealedWithoutRefetching() async {
        let vm = makeVM()
        await vm.load()
        XCTAssertEqual(vm.entries.count, 50, "前提: 末尾 50 行が手元に在る")
        let before = vm.jumpRevealToken
        let outcome = await vm.jump(to: hit(line: 230))
        XCTAssertEqual(outcome, .revealed)
        XCTAssertEqual(vm.jumpRevealToken, before + 1)
        XCTAssertEqual(vm.entries.count, 50, "手元に在るのに読み足した")
        XCTAssertEqual(vm.jumpRevealIndex.flatMap { vm.entries[$0].anchor }, "23000:0")
    }

    func testAHitFurtherBackGrowsTheWindowJustEnoughAndReveals() async {
        let vm = makeVM()
        await vm.load()
        let outcome = await vm.jump(to: hit(line: 120))   // fromEnd = 120 → 121 + 20 = 141 件まで
        XCTAssertEqual(outcome, .revealed)
        XCTAssertEqual(vm.entries.count, 141, "fromEnd + 1 + 余白 まで読み足す(全部ではない)")
        let i = try? XCTUnwrap(vm.jumpRevealIndex)
        XCTAssertEqual(i.flatMap { vm.entries[$0].anchor }, "12000:0")
        XCTAssertEqual(vm.entries.last?.text, "line 240", "窓は末尾から N 件のまま(別の窓の型を作らない)")
    }

    func testAHitBeyondTheDeskCeilingIsTooFarNotSilentlyTop() async {
        let vm = makeVM()
        await vm.load()
        let far = HistoryEntry(role: .user, text: "line 001", display: .init(who: "Tom"), anchor: "100:0", fromEnd: 999)
        let outcome = await vm.jump(to: far)
        XCTAssertEqual(outcome, .tooFar)
        XCTAssertEqual(vm.entries.count, 50, "跳べないのに読み足した")
        XCTAssertFalse(outcome.text.isEmpty)
    }

    func testAHitWithoutAnAnchorIsNotFound() async {
        let vm = makeVM()
        await vm.load()
        let old = HistoryEntry(role: .user, text: "line 230", display: .init(who: "Tom"))
        let outcome = await vm.jump(to: old)
        XCTAssertEqual(outcome, .notFound, "錨の無い当たり(古い机)は本文の一致で跳ばない")
    }

    func testAHitDecodesAnchorAndFromEndFromTheWire() throws {
        let json = #"{"role":"user","text":"x","display":{"who":"Tom"},"anchor":"5137:0","fromEnd":12}"#
        let e = try JSONDecoder().decode(HistoryEntry.self, from: Data(json.utf8))
        XCTAssertEqual(e.anchor, "5137:0"); XCTAssertEqual(e.fromEnd, 12)
        let plain = try JSONDecoder().decode(HistoryEntry.self, from: Data(#"{"role":"user","text":"x","display":{"who":"Tom"}}"#.utf8))
        XCTAssertNil(plain.anchor); XCTAssertNil(plain.fromEnd)
    }
}
