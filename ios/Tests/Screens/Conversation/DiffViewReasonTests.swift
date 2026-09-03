import XCTest
@testable import RemoteMini

/// `DiffView` の `reason` の見出しと本文(2026-09-03、loop の discovery)。
///
/// 見つかった形: 本文(`reasonDetail`)は `git_failed` を知っていたが見出し(`reasonTitle`)が
/// 知らず、机の git の失敗が「Nothing to show」= 差分が無い顔で出ていた。守る線は 1 つ:
/// **見出しと本文は同じ reason を知っている**(片方だけが知る語を作らない)。
final class DiffViewReasonTests: XCTestCase {

    func test_git_failedは差分なしの顔をしない() {
        XCTAssertEqual(DiffView.reasonTitle("git_failed"), "Git couldn't be read")
        XCTAssertNotEqual(DiffView.reasonTitle("git_failed"), DiffView.reasonTitle("zzz-unknown"),
                          "git の失敗が「Nothing to show」(= 差分が無い)と同じ見出し")
    }

    func test_見出しと本文は同じreasonを知っている() {
        let genericTitle = DiffView.reasonTitle("zzz-unknown")
        let genericDetail = DiffView.reasonDetail("zzz-unknown")
        for r in DiffView.knownReasons {
            XCTAssertNotEqual(DiffView.reasonTitle(r), genericTitle, "見出しが \(r) を知らない")
            XCTAssertNotEqual(DiffView.reasonDetail(r), genericDetail, "本文が \(r) を知らない")
        }
    }

    func test_机が出すreasonは全部一覧に在る() {
        // 机(`sessiondiff.mjs` + `server.mjs`)が封筒に載せる reason。増えたら此処と一覧の両方を足す。
        for r in ["no_cwd", "cwd_missing", "not_a_repo", "git_failed", "unsafe_repo", "busy"] {
            XCTAssertTrue(DiffView.knownReasons.contains(r), "机の reason \(r) を電話が知らない")
        }
    }

    func test_未知のreasonは壊れた顔をしない() {
        XCTAssertEqual(DiffView.reasonTitle("something-new"), "Nothing to show")
        XCTAssertFalse(DiffView.reasonDetail("something-new").isEmpty)
    }
}
