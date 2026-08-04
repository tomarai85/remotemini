import XCTest
@testable import RemoteMini

/// Mirrors the `readablePoll` block of `test/view.test.mjs` input-for-input, per
/// spec's "そのまま移植" instruction -- the JS fixtures are the source of truth for
/// what `readablePoll` must accept and reject, so the Swift port is tested against
/// the identical inputs rather than re-derived cases.
final class ReadablePollTests: XCTestCase {
    // MARK: - view.test.mjs: "★tmux 経路の形を読める(entries を持つ)"

    func testTmuxRouteShapeWithEntriesIsReadable() {
        let entryRow: [String: Any] = ["role": "user", "text": "a"] // `e("user","a")`; contents are irrelevant to readablePoll, only Array-ness of `entries` is checked
        XCTAssertTrue(ReadablePoll.check(["items": [["kind": "message", "entries": [entryRow]]]]))
    }

    func testEmptyItemsIsReadable() {
        XCTAssertTrue(ReadablePoll.check(["items": [] as [Any]]))
    }

    func testGapKindIsReadable() {
        XCTAssertTrue(ReadablePoll.check(["items": [["kind": "gap", "why": "ring-overflow"]]]))
    }

    // MARK: - view.test.mjs: "★★ワーカー経路の形も読める(entries でなく event を運ぶ)"

    func testWorkerRouteShapeWithEventIsReadable() {
        XCTAssertTrue(ReadablePoll.check([
            "items": [
                ["kind": "message", "event": ["type": "user_sent", "text": "x"], "seq": 3],
            ],
        ]))
    }

    // MARK: - view.test.mjs: "★読めない形は真にしない(空へ化かさない)"

    func testMessageWithNeitherFieldIsUnreadable() {
        XCTAssertFalse(ReadablePoll.check(["items": [["kind": "message"]]]))
    }

    func testEntriesNotAnArrayIsUnreadable() {
        XCTAssertFalse(ReadablePoll.check(["items": [["kind": "message", "entries": "abc"]]]))
    }

    func testEventThatIsAnArrayIsUnreadable() {
        // An array is not a "plain event" -- this is the exact worker/entries
        // mixup the spec calls out (§0-4): entries is array-shaped, event is
        // object-shaped, and a payload that blurs the two must not pass.
        XCTAssertFalse(ReadablePoll.check(["items": [["kind": "message", "event": [] as [Any]]]]))
    }

    func testNullItemIsUnreadable() {
        XCTAssertFalse(ReadablePoll.check(["items": [NSNull()]]))
    }

    func testItemsNotAnArrayIsUnreadable() {
        XCTAssertFalse(ReadablePoll.check(["items": "nope"]))
    }

    func testMissingItemsIsUnreadable() {
        XCTAssertFalse(ReadablePoll.check([String: Any]()))
    }

    func testNilPayloadIsUnreadable() {
        XCTAssertFalse(ReadablePoll.check(nil))
    }

    // MARK: - view.test.mjs: "知らない kind は拒まない(古い電話が新しいサーバで固まらない)"

    func testUnknownKindIsNotRejected() {
        XCTAssertTrue(ReadablePoll.check(["items": [["kind": "future-thing", "whatever": 1]]]))
    }

    // MARK: - JS `typeof` fidelity (not exercised by view.test.mjs; found while porting)

    func testBareArrayItemIsNotRejectedMatchingJSTypeofQuirk() {
        // JS `typeof it !== "object"` is true for both plain objects AND arrays
        // (only null/primitives fail it). A bare-array item therefore has no
        // `.kind`, so `it.kind === "message"` is false and the loop body no-ops --
        // the real function does not reject it. `view.test.mjs` never exercises
        // this input; ported here for fidelity per the spec's "そのまま移植"
        // instruction rather than silently "fixed" to reject it.
        XCTAssertTrue(ReadablePoll.check(["items": [["nested", "array", "item"] as [Any]]]))
    }

    // MARK: - Negative controls (repo convention: a green suite alone proves no regression, not no defect)

    func testLoosenedEventCheckNegativeControl() {
        // Negative control for testEventThatIsAnArrayIsUnreadable: the easy mistake
        // is checking only "is `event` present" instead of "is `event` a plain
        // object." Prove that a loosened check diverges on the exact case above --
        // if it didn't, the fixture would be proving nothing.
        func loosenedCheck(_ d: Any?) -> Bool {
            guard let dict = d as? [String: Any], let items = dict["items"] as? [Any] else { return false }
            for item in items {
                guard let itemDict = item as? [String: Any] else { continue }
                guard (itemDict["kind"] as? String) == "message" else { continue }
                let hasEntries = itemDict["entries"] is [Any]
                let hasEvent = itemDict["event"] != nil // loosened: presence, not shape
                if !hasEntries && !hasEvent { return false }
            }
            return true
        }
        let payload: [String: Any] = ["items": [["kind": "message", "event": [] as [Any]]]]
        XCTAssertTrue(loosenedCheck(payload), "control must actually accept the malformed payload")
        XCTAssertNotEqual(ReadablePoll.check(payload), loosenedCheck(payload))
    }

    func testAlwaysReadableNegativeControl() {
        // Negative control mirroring view.test.mjs's own "★陰性対照": a stub that
        // always returns true would let corrupted data overwrite screen state
        // silently. Confirm the real function actually diverges from that stub on
        // an unreadable input -- if it never diverged, the suite could pass with
        // `readablePoll` gutted to `{ true }`.
        func alwaysTrue(_ d: Any?) -> Bool { true }
        let unreadable: [String: Any] = ["items": [["kind": "message"]]]
        XCTAssertNotEqual(ReadablePoll.check(unreadable), alwaysTrue(unreadable))
    }
}
