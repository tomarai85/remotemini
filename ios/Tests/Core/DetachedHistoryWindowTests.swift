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
        XCTAssertEqual(desk.calls, callsAfterOpen + 1, "端と判定した後も叩き続けている")
        XCTAssertTrue(w.olderAvailable, "机の旗はそのまま(嘘を電話側で書き換えない)")
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
        XCTAssertEqual(w.entries, snapshot, "ライブの項目が窓に混ざった")
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
