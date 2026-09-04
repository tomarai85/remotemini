import XCTest
@testable import RemoteMini

/// 跳びが離脱窓へ入る所(対照表 #3 の後追い、2026-09-04)。
///
/// `SearchJumpTests` が測るのは「末尾の窓を伸ばして届く範囲」で、此処が測るのは
/// **其の範囲の外**。机の上限(500)より奥の当たりは、以前は `.tooFar` と断っていた。
@MainActor
final class JumpEntersDetachedModeTests: XCTestCase {

    /// 末尾の窓には 1 件しか返さず、`around` には錨の周りを返す机。
    /// 「末尾を伸ばしても届かない」を作る為に、`fetch` は常に同じ 1 件 + `truncated: true`。
    private final class DeepDesk: HistoryFetching, @unchecked Sendable {
        private(set) var aroundCalls: [String] = []
        private(set) var fetchCalls = 0
        let all: [HistoryEntry] = (0..<40).map {
            HistoryEntry(role: .user, text: "line \($0)", display: .init(who: "Tom"), anchor: "\($0 * 100):0")
        }
        func fetch(baseURL: URL, apiKey: String, sessionID: String, limit: Int) async -> Result<HistoryResponse, SessionsFetchError> {
            fetchCalls += 1
            return .success(HistoryResponse(history: [all[39]], truncated: true))
        }
        func search(baseURL: URL, apiKey: String, sessionID: String, limit: Int, query: String) async -> Result<TranscriptSearchResponse, SessionsFetchError> {
            .failure(.unreachable)
        }
        func around(baseURL: URL, apiKey: String, sessionID: String, anchor: String, limit: Int) async -> Result<HistoryAroundResponse, SessionsFetchError> {
            aroundCalls.append(anchor)
            guard let at = all.firstIndex(where: { $0.anchor == anchor }) else { return .failure(.anchorGone) }
            let lower = max(0, at - 3)
            let upper = min(all.count - 1, lower + 7)
            let start = max(0, min(lower, upper - 7))
            return .success(HistoryAroundResponse(history: Array(all[start...upper]), anchor: anchor,
                                                  olderAvailable: start > 0, newerAvailable: upper < all.count - 1))
        }
    }

    /// 錨が消えている机。窓は開けない。
    private struct GoneDesk: HistoryFetching {
        func fetch(baseURL: URL, apiKey: String, sessionID: String, limit: Int) async -> Result<HistoryResponse, SessionsFetchError> {
            .success(HistoryResponse(history: [], truncated: true))
        }
        func search(baseURL: URL, apiKey: String, sessionID: String, limit: Int, query: String) async -> Result<TranscriptSearchResponse, SessionsFetchError> {
            .failure(.unreachable)
        }
        func around(baseURL: URL, apiKey: String, sessionID: String, anchor: String, limit: Int) async -> Result<HistoryAroundResponse, SessionsFetchError> {
            .failure(.anchorGone)
        }
    }

    private func makeVM(_ desk: HistoryFetching) -> ConversationViewModel {
        let base = ConversationClients.fixture(state: .search)
        let clients = ConversationClients(
            history: desk, poll: base.poll, send: base.send, interrupt: base.interrupt,
            choice: base.choice, clearQueue: base.clearQueue
        )
        return ConversationViewModel(
            clients: clients, draftStore: InMemoryDraftStore(),
            baseURL: URL(string: "https://unit-test.invalid")!, apiKey: "k",
            sessionID: "s", title: "t", onUnauthorized: {}, initialLimit: 50
        )
    }

    /// 上限より奥の当たり = 以前は `.tooFar`。今は窓を開く。
    private func deepHit() -> HistoryEntry {
        HistoryEntry(role: .user, text: "line 20", display: .init(who: "Tom"),
                     anchor: "2000:0", fromEnd: 900)
    }

    func testAHitBeyondTheCeilingOpensTheDetachedWindowInsteadOfRefusing() async {
        let desk = DeepDesk()
        let vm = makeVM(desk)
        let outcome = await vm.jump(to: deepHit())
        XCTAssertEqual(outcome, .detached, "上限より奥の当たりをまだ断っている")
        XCTAssertNotEqual(outcome, .tooFar)
        XCTAssertTrue(vm.isDetached)
        XCTAssertEqual(desk.aroundCalls, ["2000:0"], "錨の窓を頼んでいない")
        XCTAssertTrue(vm.entries.contains { $0.anchor == "2000:0" }, "跳び先が転写に無い")
    }

    /// ★不変条件 1 が ViewModel の層でも守られている: 離脱中の `entries` は窓そのもので、
    ///   ライブの合流を通らない。`DetachedHistoryWindowTests` は型の中しか見られないので、
    ///   「`entries` の出所が切り替わる」事は此処でしか測れない。
    func testWhileDetachedTheTranscriptIsTheWindowNotTheLiveTail() async {
        let desk = DeepDesk()
        let vm = makeVM(desk)
        _ = await vm.jump(to: deepHit())
        let window = vm.entries
        vm.noteLiveWhileDetached(2)
        XCTAssertEqual(vm.entries, window, "ライブが窓に混ざった")
        XCTAssertTrue(vm.hasLiveWhileDetached)
        XCTAssertFalse(vm.entries.contains { $0.anchor == "3900:0" }, "末尾の行が窓に混ざっている")
    }

    func testWalkingOlderMovesTheWindowAndKeepsBothFlagsIndependent() async {
        let desk = DeepDesk()
        let vm = makeVM(desk)
        _ = await vm.jump(to: deepHit())
        let firstBefore = vm.entries.first?.anchor
        let outcome = await vm.walkDetachedOlder()
        XCTAssertEqual(outcome, .detached)
        XCTAssertNotEqual(vm.entries.first?.anchor, firstBefore, "窓が動いていない")
        // 片方だけ立つ状態が在り得る、が此の型の要点。両方が同じ値に畳まれていない事を見る。
        XCTAssertTrue(vm.canWalkNewer, "古い側へ歩いたのに新しい側の旗まで下りている")
    }

    func testBackToLiveClosesTheWindowRefetchesTheTailAndRecordsWhy() async {
        let desk = DeepDesk()
        let vm = makeVM(desk)
        _ = await vm.jump(to: deepHit())
        let fetchesBefore = desk.fetchCalls
        await vm.backToLive(reason: "tap")
        XCTAssertFalse(vm.isDetached)
        XCTAssertFalse(vm.hasLiveWhileDetached)
        XCTAssertGreaterThan(desk.fetchCalls, fetchesBefore, "末尾を読み直していない(離脱中に伸びた分が消える)")
        XCTAssertEqual(vm.detachedExits, ["tap"], "出口の理由を記録していない(唯一の測定)")
    }

    /// ★送信は必ず先に live へ戻る(設計レビュー 2026-09-04)。戻らずに送ると、文は末尾へ着くのに
    ///   画面は転写の途中を写したままで、「送ったのに出ない」に見える。
    func testSendingWhileDetachedReturnsToLiveFirst() async {
        let desk = DeepDesk()
        let vm = makeVM(desk)
        _ = await vm.jump(to: deepHit())
        XCTAssertTrue(vm.isDetached)
        vm.draft = "hello"
        await vm.send()
        XCTAssertFalse(vm.isDetached, "離脱したまま送っている")
        XCTAssertEqual(vm.detachedExits, ["send"], "送信での離脱解除が記録されていない")
    }

    /// 錨が消えている時は窓を開かず、**接続失敗とは違う文言**を出す。
    func testAVanishedAnchorSaysTheHistoryChangedNotThatTheDeskIsUnreachable() async {
        let vm = makeVM(GoneDesk())
        let outcome = await vm.jump(to: deepHit())
        XCTAssertEqual(outcome, .anchorGone)
        XCTAssertFalse(vm.isDetached)
        XCTAssertTrue(outcome.text.contains("history changed"), outcome.text)
        XCTAssertFalse(outcome.text.lowercased().contains("reach"), "接続失敗の文言になっている: \(outcome.text)")
    }
}
