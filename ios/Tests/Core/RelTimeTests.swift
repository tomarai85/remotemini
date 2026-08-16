import XCTest
@testable import RemoteMini

/// Mirrors `rc-backend/test/view.test.mjs`'s `relTime` block input-for-input (Sprint
/// 2 brief §2-a): the JS fixtures are the source of truth for what `relTime` must
/// return, so this is tested against the identical inputs rather than re-derived
/// expected values.
final class RelTimeTests: XCTestCase {
    // MARK: - view.test.mjs: "relTime は時計に依存せず、粒度ごとに変わる"

    func testRelTimeVariesByGranularityIndependentOfWallClock() {
        let now = ISO8601DateFormatter().date(from: "2026-08-02T12:00:00Z")!.timeIntervalSince1970 * 1000
        func at(_ seconds: Double) -> String {
            let iso = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: (now - seconds * 1000) / 1000))
            return RelTime.relTime(iso, nowMs: now)
        }
        XCTAssertEqual(at(5), "now")
        XCTAssertEqual(at(90), "1m ago")
        XCTAssertEqual(at(3 * 3600), "3h ago")
        XCTAssertEqual(at(2 * 86400), "2d ago")

        let monthDay = at(30 * 86400)
        XCTAssertTrue(monthDay.range(of: #"^\d+/\d+$"#, options: .regularExpression) != nil, "1週間より前は日付: got \(monthDay)")

        XCTAssertEqual(RelTime.relTime("こわれた", nowMs: now), "")
        XCTAssertEqual(at(-30), "now", "時計のずれで未来になっても壊さない")
    }

    // MARK: - Negative control (repo convention: a green suite alone proves no regression, not no defect)

    func testFoldingUnparseableInputToEmptyStringIsWhatActuallyHappens() {
        // Negative control: a plausible "safer-looking" wrong implementation throws
        // or returns a placeholder like "?" for unparseable input instead of "".
        // Confirm the real function actually returns the empty string (not merely
        // "something falsy") -- if a stub always threw instead, this diverges.
        func placeholderOnFailure(_ iso: String, nowMs: Double) -> String {
            if ISO8601DateFormatter().date(from: iso) == nil { return "?" }
            return RelTime.relTime(iso, nowMs: nowMs)
        }
        let now = 1_000_000.0
        XCTAssertNotEqual(RelTime.relTime("こわれた", nowMs: now), placeholderOnFailure("こわれた", nowMs: now))
        XCTAssertEqual(RelTime.relTime("こわれた", nowMs: now), "")
    }
}
