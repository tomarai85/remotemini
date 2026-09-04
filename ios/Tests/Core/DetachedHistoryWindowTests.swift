import XCTest
@testable import RemoteMini

/// 離脱窓の状態機械(対照表 #3 の後追い、2026-09-04)。
/// 測るのは 3 つの不変条件 —— ライブを混ぜない / 端の錨で必ず進む(進まなければ止まる) /
/// 要求した錨が窓に無ければ開いたと言わない —— と、其の周りの遷移。
@MainActor
final class DetachedHistoryWindowTests: XCTestCase {
    private let baseURL = URL(string: "https://unit-test.invalid")!

    /// 40 件の転写を持つ作り物の机。錨は `n*100:0`。**机の前進の約束を守る**ので、
    /// 「約束を破る机」は別の stub(`StuckDesk`)で撃つ。
    private final class FakeDesk: HistoryFetching, @unchecked Sendable {
        let all: [HistoryEntry]
        /// ★本番の `DetachedHistoryWindow.span`(40)より**小さく**する。40 件の転写に 40 件の窓を
        ///   当てると 1 枚で全部入り、両端の旗が最初から下りる = 歩きの検査が何も測らない。
        ///   窓が転写より小さい事が、此の型が在る理由そのもの。
        var span = 8
        private(set) var asked: [String] = []
        init(count: Int = 40) {
            all = (0..<count).map {
                HistoryEntry(role: .user, text: "line \($0)", display: .init(who: "Tom"), anchor: "\($0 * 100):0")
            }
        }
        func fetch(baseURL: URL, apiKey: String, sessionID: String, limit: Int) async -> Result<HistoryResponse, SessionsFetchError> {
            .success(HistoryResponse(history: Array(all.suffix(limit)), truncated: all.count > limit))
        }
        func search(baseURL: URL, apiKey: String, sessionID: String, limit: Int, query: String) async -> Result<TranscriptSearchResponse, SessionsFetchError> {
            .failure(.unreachable)
        }
        func around(baseURL: URL, apiKey: String, sessionID: String, anchor: String, limit: Int) async -> Result<HistoryAroundResponse, SessionsFetchError> {
            asked.append(anchor)
            guard let at = all.firstIndex(where: { $0.anchor == anchor }) else { return .failure(.notFound) }
            let want = min(limit, span)
            let before = (want - 1) / 2
            let lower = max(0, at - before)
            let upper = min(all.count - 1, lower + want - 1)
            let start = max(0, min(lower, upper - want + 1))
            let window = Array(all[start...upper])
            return .success(HistoryAroundResponse(history: window, anchor: anchor,
                                                  olderAvailable: start > 0,
                                                  newerAvailable: upper < all.count - 1))
        }
    }

    /// 前進の約束を**破る**机: 何を訊かれても同じ窓と `olderAvailable: true` を返す。
    private final class StuckDesk: HistoryFetching, @unchecked Sendable {
        private(set) var calls = 0
        private let window: [HistoryEntry]
        init() {
            window = (0..<3).map {
                HistoryEntry(role: .user, text: "x\($0)", display: .init(who: "Tom"), anchor: "\($0):0")
            }
        }
        func fetch(baseURL: URL, apiKey: String, sessionID: String, limit: Int) async -> Result<HistoryResponse, SessionsFetchError> { .failure(.unreachable) }
        func search(baseURL: URL, apiKey: String, sessionID: String, limit: Int, query: String) async -> Result<TranscriptSearchResponse, SessionsFetchError> { .failure(.unreachable) }
        func around(baseURL: URL, apiKey: String, sessionID: String, anchor: String, limit: Int) async -> Result<HistoryAroundResponse, SessionsFetchError> {
            calls += 1
            return .success(HistoryAroundResponse(history: window, anchor: window[0].anchor!,
                                                  olderAvailable: true, newerAvailable: true))
        }
    }

    /// 要求した錨を**返さない**机(契約違反)。
    private struct LyingDesk: HistoryFetching {
        func fetch(baseURL: URL, apiKey: String, sessionID: String, limit: Int) async -> Result<HistoryResponse, SessionsFetchError> { .failure(.unreachable) }
        func search(baseURL: URL, apiKey: String, sessionID: String, limit: Int, query: String) async -> Result<TranscriptSearchResponse, SessionsFetchError> { .failure(.unreachable) }
        func around(baseURL: URL, apiKey: String, sessionID: String, anchor: String, limit: Int) async -> Result<HistoryAroundResponse, SessionsFetchError> {
            .success(HistoryAroundResponse(
                history: [HistoryEntry(role: .user, text: "elsewhere", display: .init(who: "Tom"), anchor: "999999:0")],
                anchor: anchor, olderAvailable: false, newerAvailable: false))
        }
    }

    /// 片側だけ動く机(Codex 所見 F4)。古い端は常に `200:0` のまま、新しい端だけを交互に振る。
    private final class LopsidedDesk: HistoryFetching, @unchecked Sendable {
        private var flip = false
        func fetch(baseURL: URL, apiKey: String, sessionID: String, limit: Int) async -> Result<HistoryResponse, SessionsFetchError> { .failure(.unreachable) }
        func search(baseURL: URL, apiKey: String, sessionID: String, limit: Int, query: String) async -> Result<TranscriptSearchResponse, SessionsFetchError> { .failure(.unreachable) }
        func around(baseURL: URL, apiKey: String, sessionID: String, anchor: String, limit: Int) async -> Result<HistoryAroundResponse, SessionsFetchError> {
            flip.toggle()
            let tail = flip ? "300:0" : "400:0"
            let rows = ["200:0", tail].map {
                HistoryEntry(role: .user, text: $0, display: .init(who: "Tom"), anchor: $0)
            }
            return .success(HistoryAroundResponse(history: rows, anchor: anchor,
                                                  olderAvailable: true, newerAvailable: true))
        }
    }

    /// 頼んだ錨を含まない窓を返す机(Codex 所見 F3)。`anchor` は律儀に echo する。
    private struct DriftingDesk: HistoryFetching {
        func fetch(baseURL: URL, apiKey: String, sessionID: String, limit: Int) async -> Result<HistoryResponse, SessionsFetchError> { .failure(.unreachable) }
        func search(baseURL: URL, apiKey: String, sessionID: String, limit: Int, query: String) async -> Result<TranscriptSearchResponse, SessionsFetchError> { .failure(.unreachable) }
        func around(baseURL: URL, apiKey: String, sessionID: String, anchor: String, limit: Int) async -> Result<HistoryAroundResponse, SessionsFetchError> {
            if anchor == "200:0" {
                let rows = ["100:0", "200:0", "300:0"].map {
                    HistoryEntry(role: .user, text: $0, display: .init(who: "Tom"), anchor: $0)
                }
                return .success(HistoryAroundResponse(history: rows, anchor: anchor, olderAvailable: true, newerAvailable: false))
            }
            // 歩いた先: 頼んだ `100:0` がどこにも居ない窓
            let rows = ["0:0", "50:0"].map {
                HistoryEntry(role: .user, text: $0, display: .init(who: "Tom"), anchor: $0)
            }
            return .success(HistoryAroundResponse(history: rows, anchor: anchor, olderAvailable: false, newerAvailable: true))
        }
    }

    /// 合図があるまで返さない机(Codex 所見 F1)。走行中に `close()` を挟む為だけに在る。
    private final class SlowDesk: HistoryFetching, @unchecked Sendable {
        private let asked = AsyncGate()
        private let gate = AsyncGate()
        func waitUntilAsked() async { await asked.wait() }
        func release() { gate.open() }
        func fetch(baseURL: URL, apiKey: String, sessionID: String, limit: Int) async -> Result<HistoryResponse, SessionsFetchError> { .failure(.unreachable) }
        func search(baseURL: URL, apiKey: String, sessionID: String, limit: Int, query: String) async -> Result<TranscriptSearchResponse, SessionsFetchError> { .failure(.unreachable) }
        func around(baseURL: URL, apiKey: String, sessionID: String, anchor: String, limit: Int) async -> Result<HistoryAroundResponse, SessionsFetchError> {
            let rows = ["100:0", "200:0", "300:0"].map {
                HistoryEntry(role: .user, text: $0, display: .init(who: "Tom"), anchor: $0)
            }
            guard anchor == "200:0" else {
                // 歩きの往路だけ待たせる
                asked.open()
                await gate.wait()
                let older = ["0:0", "50:0", "100:0"].map {
                    HistoryEntry(role: .user, text: $0, display: .init(who: "Tom"), anchor: $0)
                }
                return .success(HistoryAroundResponse(history: older, anchor: anchor, olderAvailable: false, newerAvailable: true))
            }
            return .success(HistoryAroundResponse(history: rows, anchor: anchor, olderAvailable: true, newerAvailable: true))
        }
    }

    /// 1 回だけ開く門。`DispatchSemaphore` を使うと `@MainActor` の検査を塞ぐので継続で書く。
    private final class AsyncGate: @unchecked Sendable {
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private let lock = NSLock()
        func open() {
            lock.lock()
            opened = true
            let w = waiters; waiters = []
            lock.unlock()
            for c in w { c.resume() }
        }
        func wait() async {
            lock.lock()
            if opened { lock.unlock(); return }
            lock.unlock()
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                lock.lock()
                if opened { lock.unlock(); c.resume(); return }
                waiters.append(c)
                lock.unlock()
            }
        }
    }

    private func make(_ desk: HistoryFetching) -> DetachedHistoryWindow {
        DetachedHistoryWindow(client: desk, baseURL: baseURL, apiKey: "k", sessionID: "s")
    }

    // MARK: - 開く

    func testOpenPutsTheRequestedAnchorInsideTheWindow() async {
        let w = make(FakeDesk())
        let outcome = await w.open(at: "2000:0")
        XCTAssertEqual(outcome, .moved)
        XCTAssertTrue(w.isOpen)
        XCTAssertEqual(w.openedAt, "2000:0")
        XCTAssertTrue(w.entries.contains { $0.anchor == "2000:0" }, "要求した錨が窓に無い")
        XCTAssertTrue(w.olderAvailable)
        XCTAssertTrue(w.newerAvailable)
    }

    func testOpenOnAWindowThatDoesNotContainTheAnchorIsAnchorGone() async {
        let w = make(LyingDesk())
        let outcome = await w.open(at: "1200:0")
        XCTAssertEqual(outcome, .anchorGone, "契約違反の窓を『開いた』と言っている")
        XCTAssertFalse(w.isOpen)
        XCTAssertTrue(w.entries.isEmpty)
    }

    func testOpenOnAnUnknownAnchorIsAnchorGoneAndLeavesNothingOpen() async {
        let w = make(FakeDesk())
        let outcome = await w.open(at: "999999:0")
        XCTAssertEqual(outcome, .anchorGone)
        XCTAssertFalse(w.isOpen)
    }

    // MARK: - 歩く(不変条件 2)

    func testWalkingOlderToTheStartTerminatesAndNeverRepeatsAWindow() async {
        let desk = FakeDesk()
        let w = make(desk)
        _ = await w.open(at: "2000:0")
        var seen = Set([w.entries.first!.anchor!])
        var steps = 0
        while w.olderAvailable {
            let outcome = await w.walkOlder()
            if outcome == .atEdge { break }
            XCTAssertEqual(outcome, .moved)
            let edge = w.entries.first!.anchor!
            XCTAssertFalse(seen.contains(edge), "同じ窓へ戻った: \(edge)")
            seen.insert(edge)
            steps += 1
            XCTAssertLessThan(steps, 50, "端へ着かない(歩きが止まらない)")
        }
        XCTAssertFalse(w.olderAvailable, "端まで来たのに旗が立っている")
        XCTAssertEqual(w.entries.first?.anchor, "0:0", "一番古い項目が窓に入っていない")
    }

    func testWalkingNewerToTheEndTerminates() async {
        let w = make(FakeDesk())
        _ = await w.open(at: "500:0")
        var steps = 0
        while w.newerAvailable {
            let outcome = await w.walkNewer()
            if outcome == .atEdge { break }
            XCTAssertEqual(outcome, .moved)
            steps += 1
            XCTAssertLessThan(steps, 50, "端へ着かない")
        }
        XCTAssertEqual(w.entries.last?.anchor, "3900:0", "一番新しい項目が窓に入っていない")
        // ★Codex 所見 F6: 之が無いと `newerAvailable = r.newerAvailable` を消しても検査は緑のまま。
        //   終端の証拠は「最後の項目が入っている」だけでなく「旗が下りている」の両方。
        XCTAssertFalse(w.newerAvailable, "端まで来たのに新しい側の旗が立っている")
    }

    /// ★机が前進の約束を破っても、電話は無限に往復しない。
    func testADeskThatNeverAdvancesIsTreatedAsAnEdgeInsteadOfLoopingForever() async {
        let desk = StuckDesk()
        let w = make(desk)
        // ★`XCTAssertEqual(await …)` は autoclosure なので通らない(此の repo で 3 度目)。先に束縛する。
        let opened = await w.open(at: "0:0")
        XCTAssertEqual(opened, .moved)
        let callsAfterOpen = desk.calls
        let walked = await w.walkOlder()
        XCTAssertEqual(walked, .atEdge, "進まない机を『動いた』と読んでいる")
        XCTAssertEqual(desk.calls, callsAfterOpen + 1)
        // ★Codex 所見 F5 + F7: 進まなかった向きは**其の場で端に確定**する。旗を立てたままだと
        //   押す度に机を叩き続けるボタンが残り、1 回しか呼ばない検査では其れが見えない。
        XCTAssertFalse(w.olderAvailable, "進まなかった向きの旗が下りていない")
        let again = await w.walkOlder()
        XCTAssertEqual(again, .atEdge)
        XCTAssertEqual(desk.calls, callsAfterOpen + 1, "端と確定した後も机を叩いている")
    }

    /// ★Codex 所見 F4: 歩いた向きと**反対側**の端だけが動いた応答を「進んだ」と読まない。
    func testOnlyTheWalkedEdgeCountsAsProgress() async {
        let desk = LopsidedDesk()
        let w = make(desk)
        let opened = await w.open(at: "200:0")
        XCTAssertEqual(opened, .moved)
        let walked = await w.walkOlder()
        XCTAssertEqual(walked, .atEdge, "古い端が動いていないのに『進んだ』と読んでいる")
        XCTAssertFalse(w.olderAvailable)
    }

    /// ★Codex 所見 F3: 頼んだ錨を含まない窓は、別の場所の窓。歩く時も開く時と同じ強さで断る。
    func testWalkingIntoAWindowWithoutTheRequestedAnchorIsAnchorGone() async {
        let w = make(DriftingDesk())
        let opened = await w.open(at: "200:0")
        XCTAssertEqual(opened, .moved)
        let walked = await w.walkOlder()
        XCTAssertEqual(walked, .anchorGone, "頼んだ錨の無い窓を受け入れている")
    }

    /// ★Codex 所見 F1: 走行中に閉じられたら、遅れて返った応答は**書き戻さない**。
    func testAResponseArrivingAfterCloseDoesNotResurrectTheWindow() async {
        let desk = SlowDesk()
        let w = make(desk)
        let opened = await w.open(at: "200:0")
        XCTAssertEqual(opened, .moved)
        async let walking = w.walkOlder()
        await desk.waitUntilAsked()
        w.close()
        desk.release()
        let outcome = await walking
        XCTAssertEqual(outcome, .busy, "閉じた後の応答を遷移として扱っている")
        XCTAssertFalse(w.isOpen, "閉じた窓が蘇っている")
        XCTAssertTrue(w.entries.isEmpty)
        XCTAssertNil(w.openedAt)
    }

    func testWalkingWithTheFlagDownDoesNotAskTheDesk() async {
        let desk = FakeDesk()
        let w = make(desk)
        _ = await w.open(at: "0:0")
        XCTAssertFalse(w.olderAvailable)
        let before = desk.asked.count
        let walked = await w.walkOlder()
        XCTAssertEqual(walked, .atEdge)
        XCTAssertEqual(desk.asked.count, before, "旗が下りているのに机を叩いた")
    }

    func testWalkingBeforeOpeningFails() async {
        let w = make(FakeDesk())
        let older = await w.walkOlder()
        let newer = await w.walkNewer()
        XCTAssertEqual(older, .failed)
        XCTAssertEqual(newer, .failed)
    }

    // MARK: - ライブを混ぜない(不変条件 1)

    func testLiveArrivalsAreCountedNotMerged() async {
        let w = make(FakeDesk())
        _ = await w.open(at: "2000:0")
        let snapshot = w.entries
        w.noteLiveArrival()
        w.noteLiveArrival(3)
        XCTAssertEqual(w.liveArrived, 4)
        // ★Codex 所見 F8: 旧版は `entries == snapshot` だけを見ていたが、`noteLiveArrival` は
        //   数しか受け取らないので**本文ごと消しても緑**だった(混ぜようがないので混ざらない)。
        //   此の型で測れるのは「数が窓と独立に動く」事なので、其方を測る。
        //   本当の非混合は SSE の合流点(`ConversationViewModel`)でしか測れない —— そちらの検査は
        //   繋ぎ込みの task が持つ。
        XCTAssertEqual(w.entries, snapshot)
        XCTAssertEqual(w.entries.count, snapshot.count, "窓の長さがライブで動いた")
    }

    func testLiveArrivalsAreIgnoredWhileClosed() {
        let w = make(FakeDesk())
        w.noteLiveArrival(5)
        XCTAssertEqual(w.liveArrived, 0, "閉じている間の数を溜めている(戻った直後に嘘の数が出る)")
    }

    func testLiveCountResetsWhenTheWindowMoves() async {
        let w = make(FakeDesk())
        _ = await w.open(at: "2000:0")
        w.noteLiveArrival(2)
        _ = await w.open(at: "1000:0")
        XCTAssertEqual(w.liveArrived, 0, "開き直しで数が残っている")
    }

    // MARK: - 閉じる

    func testCloseDropsEveryPieceOfTheDetachedState() async {
        let w = make(FakeDesk())
        _ = await w.open(at: "2000:0")
        w.noteLiveArrival(2)
        w.close()
        XCTAssertFalse(w.isOpen)
        XCTAssertTrue(w.entries.isEmpty)
        XCTAssertNil(w.openedAt)
        XCTAssertFalse(w.olderAvailable)
        XCTAssertFalse(w.newerAvailable)
        XCTAssertEqual(w.liveArrived, 0)
    }
}
