import XCTest
@testable import RemoteMini

/// 探索の当たりへ跳ぶ判断(対照表 #3、2026-09-03)。作り物の机(`conversation-search`、240 行、錨 = 行番号 × 100)で、
/// 「手元に在る → 読み足さず印」「無い → fromEnd まで読み足して印」「錨無し → notFound」を測る。
/// ★2026-09-04 に契約が 1 つ変わった: **上限より奥は `tooFar` で断らず、離脱窓(`?around=`)へ回す**。
///   此の file の机(`DeskStub`)は `around` に答えないので、其の経路は「届かない」で終わる ——
///   窓が開く側の測定は `JumpEntersDetachedModeTests` が持つ。此処が測るのは「末尾の窓で届く範囲」だけ。
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

    /// ★2026-09-04 改訂。以前は「上限より奥 = `tooFar` と断る」を固定していたが、其の断りは
    ///   離脱窓が届ける様になった時点で誤りになった。**此処が今も守っているのは 2 つ**:
    ///   末尾の窓を上限より先へ伸ばさない事(電話が転写を丸ごと抱えない)と、黙って一番上を
    ///   見せない事。窓が開く側は `JumpEntersDetachedModeTests` が測る。
    func testAHitBeyondTheDeskCeilingOpensTheWindowWithoutGrowingTheTail() async {
        let vm = makeVM()
        await vm.load()
        // ★窓の大きさの私有な控えは検査から見えないので、**末尾の窓そのもの**(`history`)で測る。
        //   `entries` は離脱中に窓へ切り替わるので、伸びたかどうかの証拠にならない。
        let tailBefore = vm.history.count
        let far = HistoryEntry(role: .user, text: "line 001", display: .init(who: "Tom"), anchor: "100:0", fromEnd: 999)
        let outcome = await vm.jump(to: far)
        // 作り物の机は `around` に答えるので、此処は離脱窓が開く経路を通る。
        XCTAssertEqual(outcome, .detached, "上限より奥の当たりをまだ断っている")
        XCTAssertTrue(vm.isDetached)
        XCTAssertTrue(vm.entries.contains { $0.anchor == "100:0" }, "頼んだ行が窓に無い(黙って別の場所を見せている)")
        // ★守っている本体: **末尾の窓は伸びていない**。伸ばして届かせる道を採ると、
        //   深い当たり 1 件の為に電話が転写を丸ごと抱える。
        XCTAssertEqual(vm.history.count, tailBefore, "上限より奥の当たりで末尾の窓を伸ばした")
    }

    func testAHostileFromEndDoesNotTrap() async {
        let vm = makeVM()
        await vm.load()
        for bad in [Int.max, Int.min, -1, 500, 1_000_000] {
            let e = HistoryEntry(role: .user, text: "x", display: .init(who: "Tom"), anchor: "1:0", fromEnd: bad)
            let outcome = await vm.jump(to: e)
            // ★測っているのは **trap しない事**(`fromEnd + 1 + 余白` の加算が溢れない)。
            //   結果の値は 2026-09-04 に変わった —— 範囲外の `fromEnd` は断る理由ではなく
            //   「末尾の窓では判断できない」の印で、其の時に効くのは錨の方だから窓へ回す。
            //   此の机は `around` に答えないので `.failed` で終わる。`.revealed` になったら
            //   範囲外の値を信じて読み足した事になるので、其れだけは許さない。
            XCTAssertNotEqual(outcome, .revealed, "fromEnd=\(bad) を信じて読み足している")
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
