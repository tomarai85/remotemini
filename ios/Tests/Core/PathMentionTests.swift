import XCTest
@testable import RemoteMini

/// `PathMention` —— 「候補を出してよい入力か」と「選んだ物をどう差すか」。
///
/// ★此処の誤りは**2方向**に出る。出るべき時に出ない(機能が無いのと同じ)と、
///   出てはいけない時に出る(`user@example.com` を打っている人の前に候補が湧く)。
///   片方だけ測ると、もう片方は永久に無監視になるので、両方を名指しで並べる。
final class PathMentionTests: XCTestCase {

    // MARK: - 出す / 出さない

    func testTrailingAtWithTextIsAQuery() {
        XCTAssertEqual(PathMention.trailingQuery(in: "見て @src/wi"), "src/wi")
        XCTAssertEqual(PathMention.trailingQuery(in: "@src"), "src")
    }

    /// ★`@` を打った直後は `""` であって `nil` ではない。机は空の問いに cwd の直下を
    ///   返すので、之が此の機能の入口そのもの —— `nil` に倒すと一段目が永久に出ない。
    func testBareAtIsAnEmptyQueryNotNil() {
        XCTAssertEqual(PathMention.trailingQuery(in: "@"), "")
        XCTAssertEqual(PathMention.trailingQuery(in: "これを見て @"), "")
    }

    func testNoAtMeansNoQuery() {
        XCTAssertNil(PathMention.trailingQuery(in: ""))
        XCTAssertNil(PathMention.trailingQuery(in: "ふつうの文"))
    }

    /// ★空白が来た = 書き終えた。之が無いと、`@src/wire.mjs を直して` と打ち切った後も
    ///   候補列が残り、押すと**打った文の後半が消える**。
    func testWhitespaceAfterTheAtEndsTheMention() {
        XCTAssertNil(PathMention.trailingQuery(in: "@src/wire.mjs を直して"))
        XCTAssertNil(PathMention.trailingQuery(in: "@src "))
        XCTAssertNil(PathMention.trailingQuery(in: "@src\nつぎ"))
    }

    /// ★メールアドレスや `a@b` を拾わない。`@` の直前が行頭か空白の時だけ。
    func testAnAtGluedToAWordIsNotAMention() {
        XCTAssertNil(PathMention.trailingQuery(in: "tom@example.com"))
        XCTAssertNil(PathMention.trailingQuery(in: "npm i left-pad@1.3.0"))
    }

    /// 最後の `@` を見る。前の方に在る `@` は既に書き終えた物。
    func testTheLastAtWins() {
        XCTAssertEqual(PathMention.trailingQuery(in: "@a/b.txt と @src/wi"), "src/wi")
    }

    /// ★長過ぎる問いは撃たない(机を舐めさせない)。机側にも同じ枠が在るが、
    ///   送る前に止める方が往復1回ぶん安い。
    func testAnAbsurdlyLongTailIsNotAQuery() {
        let long = "@" + String(repeating: "a", count: 201)
        XCTAssertNil(PathMention.trailingQuery(in: long))
        let atLimit = "@" + String(repeating: "a", count: 200)
        XCTAssertEqual(PathMention.trailingQuery(in: atLimit)?.count, 200)
    }

    // MARK: - 差し込み

    func testPickingAFileReplacesOnlyTheTailAndEndsTheMention() {
        let after = PathMention.replacingTrailingQuery(
            in: "これ見て @src/wi",
            with: PathSuggestion(path: "src/wire.mjs", kind: .file))
        XCTAssertEqual(after, "これ見て @src/wire.mjs ")
        // ★空白が付いた事で、候補列はその場で消える(= 選び終えた)。
        XCTAssertNil(PathMention.trailingQuery(in: after))
    }

    /// ★dir は `/` で終えて**空白を足さない**。足すと一段も降りられない ——
    ///   問いが `src` のままなら同じ候補列がもう一度出るだけ。
    func testPickingADirectoryKeepsTheMentionOpenSoTheNextLevelLoads() {
        let after = PathMention.replacingTrailingQuery(
            in: "@sr",
            with: PathSuggestion(path: "src", kind: .dir))
        XCTAssertEqual(after, "@src/")
        XCTAssertEqual(PathMention.trailingQuery(in: after), "src/")
    }

    /// 知らない種別は dir 扱いにしない(降りられない物を降りられる顔にしない)。
    func testAnUnrecognizedKindIsTreatedLikeAFile() {
        let after = PathMention.replacingTrailingQuery(
            in: "@x",
            with: PathSuggestion(path: "x.bin", kind: .unrecognized))
        XCTAssertEqual(after, "@x.bin ")
    }

    /// ★打った文の**前半**は1文字も動かさない。
    func testTheTextBeforeTheMentionIsUntouched() {
        let after = PathMention.replacingTrailingQuery(
            in: "長い前置き。改行も含む\nそして @sr",
            with: PathSuggestion(path: "src", kind: .dir))
        XCTAssertEqual(after, "長い前置き。改行も含む\nそして @src/")
    }

    /// 書きかけの `@` が無ければ**何もしない**(末尾へ勝手に足さない)。
    func testWithoutAMentionNothingIsInserted() {
        let text = "ふつうの文"
        XCTAssertEqual(
            PathMention.replacingTrailingQuery(in: text, with: PathSuggestion(path: "a", kind: .file)),
            text)
    }
}
