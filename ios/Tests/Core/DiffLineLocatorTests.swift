import XCTest
@testable import RemoteMini

/// `DiffLineLocator` -- computes line numbers #6's comments key on, from a hunk's
/// raw `@@ -a,b +c,d @@` header. 机は行番号を送らないので、此処が唯一の出所。
final class DiffLineLocatorTests: XCTestCase {
    // MARK: - startLines

    func testStartLinesReadsBothCounters() {
        XCTAssertEqual(DiffLineLocator.startLines(header: "@@ -12,3 +12,4 @@")?.old, 12)
        XCTAssertEqual(DiffLineLocator.startLines(header: "@@ -12,3 +12,4 @@")?.new, 12)
    }

    /// git omits the `,count` suffix when a hunk is exactly one line.
    func testStartLinesHandlesTheSingleLineFormWithNoComma() {
        let start = DiffLineLocator.startLines(header: "@@ -1 +1 @@")
        XCTAssertEqual(start?.old, 1)
        XCTAssertEqual(start?.new, 1)
    }

    /// git appends the enclosing function's name after the second `@@` on some
    /// languages. The trailing text must not break the leading counters.
    func testStartLinesIgnoresATrailingFunctionContextSuffix() {
        let start = DiffLineLocator.startLines(header: "@@ -40,2 +40,3 @@ func readWorkingDiff() {")
        XCTAssertEqual(start?.old, 40)
        XCTAssertEqual(start?.new, 40)
    }

    func testStartLinesReturnsNilForAnUnrecognizedHeaderNegativeControl() {
        XCTAssertNil(DiffLineLocator.startLines(header: "not a hunk header"))
        XCTAssertNil(DiffLineLocator.startLines(header: ""))
    }

    // MARK: - lineNumbers

    private func line(_ kind: DiffLineKind, _ text: String = "x") -> DiffLine {
        DiffLine(kind: kind, text: text)
    }

    /// `ctx` からは両側が動くが、報告するのは新側 -- `del` が旧側だけ動かして
    /// 報告する事と対になる。
    func testCtxLinesAdvanceBothSidesButReportTheNewSide() {
        let lines = [line(.ctx), line(.add), line(.ctx)]
        let numbers = DiffLineLocator.lineNumbers(header: "@@ -10,2 +10,3 @@", lines: lines)

        XCTAssertEqual(numbers, [10, 11, 12])
    }

    /// `del` は旧側だけ増える -- 新側に居場所が無い行なので、新側の数字を割り当てると
    /// 存在しないコードの行を指す事になる。
    func testDelLinesAdvanceOnlyTheOldSide() {
        let lines = [line(.ctx), line(.del), line(.del), line(.add)]
        let numbers = DiffLineLocator.lineNumbers(header: "@@ -10,3 +10,2 @@", lines: lines)

        // ctx(10,10) -> del(旧11) -> del(旧12) -> add(新11)
        XCTAssertEqual(numbers, [10, 11, 12, 11])
    }

    /// ★同じ数字が旧側・新側の両方に出る実例 -- `DiffComment` が `kind` まで持たないと
    ///   此の2行が同じ宛先に見えてしまう、という前提を裏付ける。
    func testDelAndAddCanShareTheSameNumericLineOnDifferentSides() {
        let lines = [line(.ctx), line(.del), line(.add)]
        let numbers = DiffLineLocator.lineNumbers(header: "@@ -10,2 +10,2 @@", lines: lines)

        // ctx(10,10) -> del(旧11) -> add(新11): 2番目と3番目が両方 "11"。
        XCTAssertEqual(numbers, [10, 11, 11])
        XCTAssertEqual(lines[1].kind, .del)
        XCTAssertEqual(lines[2].kind, .add)
    }

    func testUnrecognizedHeaderProducesAllNilNumbersNotACrashNegativeControl() {
        let lines = [line(.ctx), line(.add), line(.del)]
        let numbers = DiffLineLocator.lineNumbers(header: "garbage", lines: lines)

        XCTAssertEqual(numbers, [nil, nil, nil])
    }

    func testNumbersArrayIsAlwaysTheSameLengthAsLinesNegativeControl() {
        let lines = [line(.ctx), line(.add), line(.del), line(.ctx)]
        let numbers = DiffLineLocator.lineNumbers(header: "@@ -1,2 +1,3 @@", lines: lines)

        XCTAssertEqual(numbers.count, lines.count)
    }
}
