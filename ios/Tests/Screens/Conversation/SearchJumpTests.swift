import XCTest
@testable import RemoteMini

/// 探索の当たりへ跳ぶ判断(対照表 #3、2026-09-03)。作り物の机(`conversation-search`、240 行、錨 = 行番号 × 100)で、
/// 「手元に在る → 読み足さず印」「無い → fromEnd まで読み足して印」「上限より奥 → tooFar」「錨無し → notFound」を測る。
/// Codex 2026-09-03 の所見の対照: 探索後の追記(#1)/ 錨で跳ぶ(#2)/ 跳びの最中の再タップ(#3)/ 異常な fromEnd(#4)。
@MainActor
final class SearchJumpTests: XCTestCase {

    private func makeVM(initialLimit: Int = 50, history: HistoryFetching? = nil) -> ConversationViewModel {
        var clients = ConversationClients.fixture(state: .search)
        if let history {
            clients = ConversationClients(
                history: history, poll: clients.poll, send: clients.send, interrupt: clients.interrupt,
                choice: clients.choice, clearQueue: clients.clearQueue
            )
        }
        return ConversationViewModel(
            clients: clients,
            draftStore: InMemoryDraftStore(),
            baseURL: URL(string: "https://unit-test.invalid")!,
            apiKey: "k",
            sessionID: "s",
            title: "t",
            onUnauthorized: {},
            initialLimit: initialLimit
        )
    }

    private func line(_ n: Int) -> HistoryEntry {
        HistoryEntry(role: n.isMultiple(of: 2) ? .assistant : .user, text: String(format: "line %03d", n),
                     display: .init(who: "Tom"), anchor: "\(n * 100):0")
    }

    private func hit(line n: Int, total: Int = 240) -> HistoryEntry {
        HistoryEntry(role: .user, text: String(format: "line %03d", n), display: .init(who: "Tom"),
                     anchor: "\(n * 100):0", fromEnd: total - n)
    }

    /// 作り物の机: `total` 行を持ち、`fetch` は末尾 `limit` 行を返す。`delay` で遅い机を作れる。
    private struct DeskStub: HistoryFetching {
        let total: Int
        var delayNanos: UInt64 = 0
        var lineAt: (Int) -> HistoryEntry
        func fetch(baseURL: URL, apiKey: String, sessionID: String, limit: Int) async -> Result<HistoryResponse, SessionsFetchError> {
            if delayNanos > 0 { try? await Task.sleep(nanoseconds: delayNanos) }
            let all = (1...total).map(lineAt)
            let shown = Array(all.suffix(limit))
            return .success(HistoryResponse(history: shown, truncated: shown.count < all.count))
        }
        func search(baseURL: URL, apiKey: String, sessionID: String, limit: Int, query: String) async -> Result<TranscriptSearchResponse, SessionsFetchError> {
            .failure(.unreachable)
        }
        func around(baseURL: URL, apiKey: String, sessionID: String, anchor: String, limit: Int) async -> Result<HistoryAroundResponse, SessionsFetchError> {
            .failure(.unreachable)
        }
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
        XCTAssertEqual(vm.jumpRevealAnchor, "23000:0", "跳ぶ先は錨で持つ(index ではない)")
    }

    func testAHitFurtherBackGrowsTheWindowJustEnoughAndReveals() async {
        let vm = makeVM()
        await vm.load()
        let outcome = await vm.jump(to: hit(line: 120))   // fromEnd = 120 → 121 + 20 = 141 件まで
        XCTAssertEqual(outcome, .revealed)
        XCTAssertEqual(vm.entries.count, 141, "fromEnd + 1 + 余白 まで読み足す(全部ではない)")
        XCTAssertEqual(vm.jumpRevealAnchor, "12000:0")
        XCTAssertTrue(vm.entries.contains { $0.anchor == "12000:0" })
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

    func testAHostileFromEndDoesNotTrap() async {
        let vm = makeVM()
        await vm.load()
        for bad in [Int.max, Int.min, -1, 500, 1_000_000] {
            let e = HistoryEntry(role: .user, text: "x", display: .init(who: "Tom"), anchor: "1:0", fromEnd: bad)
            let outcome = await vm.jump(to: e)
            XCTAssertEqual(outcome, .tooFar, "fromEnd=\(bad) は範囲外 = 奥すぎる(加算の前に弾く)")
        }
        XCTAssertEqual(vm.entries.count, 50)
    }

    func testAHitWithoutAnAnchorIsNotFound() async {
        let vm = makeVM()
        await vm.load()
        let old = HistoryEntry(role: .user, text: "line 230", display: .init(who: "Tom"))
        let outcome = await vm.jump(to: old)
        XCTAssertEqual(outcome, .notFound, "錨の無い当たり(古い机)は本文の一致で跳ばない")
    }

    /// Codex #1: 探索の後に会話が 30 行伸びた(fromEnd は探索時点の 240 行基準 = 古い)。余白 20 では足りない
    /// → 窓を倍にして追う → 見つかる。
    func testAppendsAfterTheSearchAreRecoveredByGrowingTheWindow() async {
        let desk = DeskStub(total: 270, lineAt: line)
        let vm = makeVM(history: desk)
        await vm.load()
        let stale = hit(line: 200, total: 240)          // fromEnd = 40 だが今は 70 行奥
        let outcome = await vm.jump(to: stale)
        XCTAssertEqual(outcome, .revealed, "追記で古くなった fromEnd を窓の拡大で吸収する")
        XCTAssertEqual(vm.jumpRevealAnchor, "20000:0")
        XCTAssertTrue(vm.entries.contains { $0.anchor == "20000:0" })
        XCTAssertEqual(vm.entries.count, 122, "61 → 122 と倍にした 2 回目で入る(全部は読まない)")
    }

    /// 転写を最後まで読んでも錨が無い = 本当に無い(消えた / 別の会話)。窓を増やし続けない。
    func testAMissingAnchorAfterTheWholeTranscriptIsNotFound() async {
        let desk = DeskStub(total: 60, lineAt: line)
        let vm = makeVM(history: desk)
        await vm.load()
        let ghost = HistoryEntry(role: .user, text: "ghost", display: .init(who: "Tom"), anchor: "999999:0", fromEnd: 30)
        let outcome = await vm.jump(to: ghost)
        XCTAssertEqual(outcome, .notFound)
        XCTAssertEqual(vm.entries.count, 60, "全部読んだ所で止まる")
    }

    /// Codex #3: 跳びの最中の再タップは busy。古い応答が新しい跳びを上書きしない。
    func testASecondTapDuringAJumpIsBusy() async {
        let desk = DeskStub(total: 240, delayNanos: 300_000_000, lineAt: line)
        let vm = makeVM(history: desk)
        await vm.load()
        async let first = vm.jump(to: hit(line: 120))
        try? await Task.sleep(nanoseconds: 50_000_000)
        let second = await vm.jump(to: hit(line: 100))
        XCTAssertEqual(second, .busy)
        let firstOutcome = await first
        XCTAssertEqual(firstOutcome, .revealed)
        XCTAssertEqual(vm.jumpRevealAnchor, "12000:0", "最初の跳びが勝つ")
    }

    func testAHitDecodesAnchorAndFromEndFromTheWire() throws {
        let json = #"{"role":"user","text":"x","display":{"who":"Tom"},"anchor":"5137:0","fromEnd":12}"#
        let e = try JSONDecoder().decode(HistoryEntry.self, from: Data(json.utf8))
        XCTAssertEqual(e.anchor, "5137:0"); XCTAssertEqual(e.fromEnd, 12)
        let plain = try JSONDecoder().decode(HistoryEntry.self, from: Data(#"{"role":"user","text":"x","display":{"who":"Tom"}}"#.utf8))
        XCTAssertNil(plain.anchor); XCTAssertNil(plain.fromEnd)
    }
}
