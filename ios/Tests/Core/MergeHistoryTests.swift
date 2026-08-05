import XCTest
@testable import RemoteMini

/// Port of every `mergeHistory` case in `rc-backend/test/view.test.mjs` (Sprint 3
/// brief §2-c) -- one Swift `func` per JS `test(...)`, English names (matching this
/// repo's existing Swift test-naming convention -- `SessionsClientTests`/
/// `SessionsModelsTests` name every case in English even where the source-of-truth
/// strings are Japanese), each citing the exact JS test name it ports so a
/// side-by-side diff against `view.test.mjs` is direct. This is the one function in
/// the app with two independent implementations (JS + Swift); porting the JS suite
/// verbatim, not "an equivalent Swift suite," is what keeps them from drifting apart.
final class MergeHistoryTests: XCTestCase {
    private func e(_ role: EntryRole, _ text: String) -> HistoryEntry {
        HistoryEntry(role: role, text: text, display: .init(who: "dummy"))
    }

    /// JS: "重なりが無ければそのまま繋がる"
    func testNoOverlapJustConcatenates() {
        let h = [e(.user, "a"), e(.assistant, "b")]
        let l = [e(.user, "c")]

        XCTAssertEqual(MergeHistory.merge(h, l), h + l)
    }

    /// JS: "★履歴の末尾とライブの先頭が重なったら剥がす(先に購読するので重複が出る)"
    func testOverlapBetweenHistoryTailAndLiveHeadIsStripped() {
        let h = [e(.user, "a"), e(.assistant, "b"), e(.user, "c")]
        let l = [e(.assistant, "b"), e(.user, "c"), e(.assistant, "d")]

        XCTAssertEqual(
            MergeHistory.merge(h, l),
            [e(.user, "a"), e(.assistant, "b"), e(.user, "c"), e(.assistant, "d")]
        )
    }

    /// JS: "ライブが丸ごと履歴に含まれていたら何も足さない"
    func testLiveEntirelyContainedInHistoryAddsNothing() {
        let h = [e(.user, "a"), e(.assistant, "b")]

        XCTAssertEqual(MergeHistory.merge(h, [e(.user, "a"), e(.assistant, "b")]), h)
    }

    /// JS: "片方が空でも壊れない"
    func testEitherSideEmptyDoesNotCrash() {
        XCTAssertEqual(MergeHistory.merge([], [e(.user, "a")]), [e(.user, "a")])
        XCTAssertEqual(MergeHistory.merge([e(.user, "a")], []), [e(.user, "a")])
        // JS's `mergeHistory(null, null)` -- Swift has no nil array to pass, both
        // sides already empty is the same input this app can ever actually produce.
        XCTAssertEqual(MergeHistory.merge([], []), [])
    }

    /// JS: "役割が違えば重なりと見なさない(本文だけの一致で剥がさない)"
    func testDifferentRoleIsNotTreatedAsOverlapEvenWithMatchingText() {
        let h = [e(.user, "同じ文")]
        let l = [e(.assistant, "同じ文"), e(.user, "次")]

        XCTAssertEqual(MergeHistory.merge(h, l), h + l)
    }

    /// JS: "★同じ発言を2回した時は剥がしすぎる(承知の上の代償)"
    ///
    /// Known limitation, not a bug (brief §2-c): saying the exact same thing 3 times
    /// in a row over-strips to 2. Green here means "acknowledged," not "correct" --
    /// see `MergeHistory.merge`'s doc comment on why descending-`k` cannot avoid this
    /// without breaking `testOverlapBetweenHistoryTailAndLiveHeadIsStripped` above.
    func testKnownLimitationSameUtteranceTwiceOverStrips() {
        let h = [e(.user, "はい"), e(.user, "はい")]
        let l = [e(.user, "はい")]

        XCTAssertEqual(MergeHistory.merge(h, l), h, "3回目が畳まれる = 既知の代償")
    }

    /// Sprint 3 brief §6 DoD: `display` (specifically `display.who`) must never
    /// enter the overlap decision -- `view.mjs`'s `history`/`live` elements never
    /// carry `display` at all (`{role, text}` is the whole comparison shape JS
    /// ports from), so a Swift `Equatable` synthesized straight off `HistoryEntry`
    /// (which DOES carry `display`) would silently diverge if `sameRoleAndText`
    /// leaked into using it. Two entries whose ONLY difference is `display.who`
    /// still strip as the same overlap, and the surviving copy is `history`'s own
    /// (never replaced by `live`'s, matching `merge`'s `history + live.suffix(from:
    /// k)` -- the stripped prefix of `live` is dropped, not swapped in).
    func testOverlapStillStripsWhenDisplayWhoDiffersButRoleAndTextMatch() {
        let hOverlap = HistoryEntry(role: .assistant, text: "b", display: .init(who: "History Name"))
        let lOverlap = HistoryEntry(role: .assistant, text: "b", display: .init(who: "Live Name"))
        let h = [e(.user, "a"), hOverlap]
        let l = [lOverlap, e(.user, "c")]

        XCTAssertEqual(MergeHistory.merge(h, l), [e(.user, "a"), hOverlap, e(.user, "c")])
    }
}
