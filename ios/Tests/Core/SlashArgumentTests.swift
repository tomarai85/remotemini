import XCTest
@testable import RemoteMini

/// `SlashArgument`(`/model` の引数の候補、対照表 #14)。
///
/// 守る線は `PathMention` と同じ 2 方向: 出るべき時に出る / 出てはいけない時に出ない。
/// そして規約: **押しても送らない**(此処は文字列を返すだけで、送信は別の道)。
final class SlashArgumentTests: XCTestCase {

    // MARK: - 出る

    func test_modelだけなら全候補() {
        XCTAssertEqual(SlashArgument.candidates(for: "/model"), SlashArgument.modelNames)
        XCTAssertEqual(SlashArgument.candidates(for: "/model "), SlashArgument.modelNames)
        XCTAssertEqual(SlashArgument.candidates(for: "  /model  "), SlashArgument.modelNames, "先頭の空白は無視")
    }

    func test_書きかけの語で前方一致() {
        XCTAssertEqual(SlashArgument.candidates(for: "/model so"), ["sonnet"])
        XCTAssertEqual(SlashArgument.candidates(for: "/model o"), ["opus"])
        XCTAssertEqual(SlashArgument.candidates(for: "/model opus"), ["opus"], "打ち終えた名前も、空白が無ければ 1 件出す(押せば帯が消える)")
    }

    // MARK: - 出ない

    func test_書き終えたら出ない() {
        XCTAssertEqual(SlashArgument.candidates(for: "/model opus "), [])
        XCTAssertEqual(SlashArgument.candidates(for: "/model opus 続きの文"), [])
    }

    func test_別の語や別のcommandでは出ない() {
        XCTAssertEqual(SlashArgument.candidates(for: "/models"), [], "`/models` を `/model` と読まない")
        XCTAssertEqual(SlashArgument.candidates(for: "/compact"), [])
        XCTAssertEqual(SlashArgument.candidates(for: "/context "), [])
        XCTAssertEqual(SlashArgument.candidates(for: "model"), [], "先頭の `/` が無い")
        XCTAssertEqual(SlashArgument.candidates(for: ""), [])
        XCTAssertEqual(SlashArgument.candidates(for: "文の途中で /model"), [], "文の途中の `/model` は拾わない(差し込み位置を推定しない)")
    }

    func test_一致しない書きかけは空() {
        XCTAssertEqual(SlashArgument.candidates(for: "/model zzz"), [])
    }

    // MARK: - 差し込み

    func test_選ぶと引数と末尾の空白が入り_帯が消える() {
        let after = SlashArgument.replacing("/model ", with: "sonnet")
        XCTAssertEqual(after, "/model sonnet ")
        XCTAssertEqual(SlashArgument.candidates(for: after), [], "選んだ後に候補が出続けると帯が消えない")
    }

    func test_書きかけの語は置き換える() {
        XCTAssertEqual(SlashArgument.replacing("/model so", with: "sonnet"), "/model sonnet ")
        XCTAssertEqual(SlashArgument.replacing("/model", with: "haiku"), "/model haiku ")
    }

    func test_modelで始まっていなければ何も変えない() {
        XCTAssertEqual(SlashArgument.replacing("/compact ", with: "opus"), "/compact ")
        XCTAssertEqual(SlashArgument.replacing("hello", with: "opus"), "hello")
    }

    /// ★規約の錨: 此の型は文字列しか返さない。送る道(`SendClient`)を知らない事を、
    ///   出力が改行を含まない(= Enter を含まない)形で固定する。
    func test_送らない_出力に改行が無い() {
        for name in SlashArgument.modelNames {
            XCTAssertFalse(SlashArgument.replacing("/model", with: name).contains("\n"))
        }
    }
}
