import XCTest
@testable import RemoteMini

/// `DiffCommentFormatter` -- the pure function that turns pending diff comments
/// (#6) into the text `ConversationViewModel.send()` actually transmits. No desk
/// route change backs this: the format only has to be plain text a human/Claude can
/// read, so these tests pin the exact literal shape rather than a decoder contract
/// (there is no wire shape here to agree with the backend on).
final class DiffCommentFormatterTests: XCTestCase {
    private func comment(
        path: String = "src/app.js",
        staged: Bool = false,
        line: Int = 12,
        kind: DiffLineKind = .add,
        quotedText: String = "const y = 3;",
        text: String = "why 3 and not 2?"
    ) -> DiffComment {
        DiffComment(path: path, staged: staged, line: line, kind: kind, quotedText: quotedText, text: text)
    }

    // MARK: - block(for:) -- the exact literal format

    func testBlockFormatForAnAddedLine() {
        let c = comment(kind: .add, quotedText: "const y = 3;", text: "why 3?")
        XCTAssertEqual(
            DiffCommentFormatter.block(for: c),
            #"src/app.js:12 (+ "const y = 3;") — why 3?"#
        )
    }

    func testBlockFormatForADeletedLine() {
        let c = comment(line: 7, kind: .del, quotedText: "const y = 2;", text: "was this dead code?")
        XCTAssertEqual(
            DiffCommentFormatter.block(for: c),
            #"src/app.js:7 (- "const y = 2;") — was this dead code?"#
        )
    }

    func testBlockFormatForAContextLineUsesTheWordContext() {
        let c = comment(line: 1, kind: .ctx, quotedText: "const x = 1;", text: "is this still used?")
        XCTAssertEqual(
            DiffCommentFormatter.block(for: c),
            #"src/app.js:1 (context "const x = 1;") — is this still used?"#
        )
    }

    /// `unknown`(将来 机が増やすかもしれない種類)は `ctx` と同じ扱い -- 記号が
    /// 決まらないだけで、コメントの組み立て自体は諦めない。
    func testUnknownKindDegradesToTheContextWordNotACrash() {
        let c = comment(kind: .unknown, text: "?")
        XCTAssertTrue(DiffCommentFormatter.block(for: c).contains("(context "))
    }

    // MARK: - compose -- ordering, joining, the empty cases

    /// ★no comments = `userText` は**一切変えない**。`ConversationViewModelTests
    ///   .testTextIsTransmittedUnmodifiedIncludingSurroundingWhitespace` が緑のままな
    ///   のはこの条件のおかげ -- 空白を1文字でも足すとあの検査が落ちる。
    func testNoCommentsReturnsUserTextCompletelyUnchanged() {
        XCTAssertEqual(DiffCommentFormatter.compose(comments: [], userText: "  改行あり\n  "), "  改行あり\n  ")
        XCTAssertEqual(DiffCommentFormatter.compose(comments: [], userText: ""), "")
    }

    func testOneCommentPrecedesTheUserTextWithABlankLineBetween() {
        let c = comment(text: "why?")
        let composed = DiffCommentFormatter.compose(comments: [c], userText: "please check this")

        XCTAssertEqual(
            composed,
            "src/app.js:12 (+ \"const y = 3;\") — why?\n\nplease check this"
        )
    }

    /// コメントだけを送る事も有効 -- 「本文が無ければ送れない」という制約は
    /// `ConversationViewModel.canSend` の側(v1 のスコープ判断)が持ち、此処では持たない。
    func testEmptyUserTextWithCommentsReturnsCommentsOnlyNoTrailingBlankLine() {
        let c = comment(text: "why?")
        let composed = DiffCommentFormatter.compose(comments: [c], userText: "")

        XCTAssertEqual(composed, "src/app.js:12 (+ \"const y = 3;\") — why?")
    }

    func testMultipleCommentsAreOneBlockPerLineInGivenOrder() {
        let a = comment(path: "a.txt", line: 1, text: "first")
        let b = comment(path: "b.txt", line: 2, text: "second")
        let composed = DiffCommentFormatter.compose(comments: [a, b], userText: "go")

        let expected = """
        a.txt:1 (+ "const y = 3;") — first
        b.txt:2 (+ "const y = 3;") — second

        go
        """
        XCTAssertEqual(composed, expected)
    }
}
