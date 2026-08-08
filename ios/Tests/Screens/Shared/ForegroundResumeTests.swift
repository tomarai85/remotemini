import SwiftUI
import XCTest
@testable import RemoteMini

/// `ForegroundResume` -- 2画面が共有する「前面に戻った」の判定(会話画面の N4 /
/// 一覧画面の brief §3-d 引き金 #3)。
///
/// ★此処の検査が**対ではなく並び**を食わせるのには理由が在る。2026-08-08 まで、
///   この判定は `shouldResume(oldPhase:newPhase:)` という純関数で、検査は
///   `f(.background, .active) == true` の様に**1辺ずつ**当てていた。全部緑だった。
///   それでも会話画面の N4 は Sprint 4 から一度も発火していなかった ——
///   iOS が `.background -> .active` という辺を**一度も配らない**から。
///
///   規則は正しく、前提が偽だった。1辺ずつの検査は、原理的にその差を見られない:
///   「f はこの引数で正しく答えるか」しか訊いていないので、「iOS がその引数で f を
///   呼ぶか」は誰も訊いていなかった。だから此処は全部、**iOS が実際に配る並び**を
///   頭から流し込んで、復帰と数えた回数を数える形にしてある。
///
///   実測した並び(UI 試験の中で `.onChange` の `(old, new)` を全部書き出した。
///   fixture `list-normal`、`XCUIDevice.shared.press(.home)` -> `app.activate()`):
///
///     [inactive>active]      <- 起動
///     [active>inactive]      <- home 押下 1/2
///     [inactive>background]  <- home 押下 2/2
///     [background>inactive]  <- 復帰 1/2
///     [inactive>active]      <- 復帰 2/2
///
/// ★それでも此処は「規則」の側でしかない。**規則が画面に繋がっている**事は単体では
///   測れないので、本物の背面往復は `RemoteMiniUITests` の
///   `testReturningFromTheBackgroundRefreshesTheListExactlyOnce` と
///   `ios/tools/list-return-refresh-control.sh` の M4/M5 が測る。片方だけでは
///   足りない —— 単体だけなら誰も `.onChange` を繋がなくても緑、UI だけなら
///   規則のどの辺が効いているのか判らない。
final class ForegroundResumeTests: XCTestCase {
    /// 並びを頭から流して、`shouldResume` が真を返した回数を返す。
    ///
    /// 「返り値の列」ではなく**回数**を主張の単位にしているのは、この器の意味が
    /// 「何回取り直すか」だから: 実装が真を返す位置が1つずれても、回数が合っていれば
    /// 画面の振る舞いは正しい。位置まで固定すると、正しい実装を落とす検査になる。
    private func resumeCount(_ phases: [ScenePhase]) -> Int {
        var gate = ForegroundResume()
        return phases.reduce(into: 0) { count, phase in
            if gate.shouldResume(newPhase: phase) { count += 1 }
        }
    }

    /// 実測した「起動」。`.inactive -> .active` の1辺だけが来る。
    ///
    /// ★これが**0回**でなければならないのが一覧側の S8-5 の直しその物:
    ///   2026-08-08 まで `ListView` は到着側(`.active`)だけを見ていたので、
    ///   `.task` の初回取得と重なって**起動のたびに2回**机側へ走査を飛ばしていた。
    func testColdLaunchIsNotAResume() {
        XCTAssertEqual(
            resumeCount([.inactive, .active]),
            0,
            "起動そのものを復帰と読んではいけない(`.task` の初回取得と重なって二重に撃つ)"
        )
    }

    /// 実測した「本物の背面往復」。home を押して戻る。**ちょうど1回**。
    ///
    /// 並びの中に `.active` は**2回**現れる(起動の分と復帰の分)。1回だけ数える事が
    /// 主張の芯で、「`.active` に着いたら真」の実装は此処で 2 に落ちる。
    func testARealBackgroundRoundTripResumesExactlyOnce() {
        XCTAssertEqual(
            resumeCount([
                .inactive, .active,      // 起動
                .inactive, .background,  // home 押下
                .inactive, .active,      // 復帰
            ]),
            1,
            "背面往復の取り直しはちょうど1回"
        )
    }

    /// この番人が存在する理由の辺。Control Center を引いて戻す / 通知バナーが出て
    /// 消える / App Switcher を覗く —— どれも `.inactive` までしか下りない。
    ///
    /// 負の対照(片方だけの検査は逆向きに倒れる): 上の1本だけなら「`.active` に
    /// 着いたら真」で通ってしまい、電話では1日に何度も余分な走査が飛ぶ。
    func testAPeekThatNeverReachesTheBackgroundIsNotAResumeNegativeControl() {
        XCTAssertEqual(
            resumeCount([
                .inactive, .active,   // 起動
                .inactive, .active,   // Control Center / 通知バナーの出入り
            ]),
            0,
            "`.inactive` までしか下りない出入りは復帰ではない"
        )
    }

    /// 2往復すれば2回。
    ///
    /// 「一度でも背面に入ったら以後ずっと真」でも「最初の一度だけ真」でもない事を
    /// 同時に固定する —— 印を毎回立て直し、毎回倒している事の主張。
    func testTwoRoundTripsResumeTwice() {
        XCTAssertEqual(
            resumeCount([
                .inactive, .active,
                .inactive, .background,
                .inactive, .active,
                .inactive, .background,
                .inactive, .active,
            ]),
            2,
            "往復のたびに1回。回数は往復の数と一致する"
        )
    }

    /// 印が**倒れている**事の負の対照。背面から戻った後、背面へ入らずに前面へ
    /// 着き直した分は数えない。
    ///
    /// これが無いと、`wasBackgrounded` を立てるだけで倒さない実装 —— つまり
    /// 「一度背面に入ったら、以後は通知バナーが出るたびに取り直す」実装 —— が
    /// 上の全部を緑で通る(往復の検査は最後が `.active` で終わるので差が出ない)。
    func testTheFlagIsClearedSoALaterForegroundingIsNotASecondResumeNegativeControl() {
        XCTAssertEqual(
            resumeCount([
                .inactive, .active,
                .inactive, .background,
                .inactive, .active,   // 本物の復帰(1回目)
                .inactive, .active,   // その後の通知バナー = 数えない
            ]),
            1,
            "復帰を1回返したら印は倒れる。以後の `.active` は背面を通るまで復帰ではない"
        )
    }

    /// `.background` に着いた瞬間は復帰ではない。
    ///
    /// 「背面に関わる辺で真を返す」実装 —— 出入りを区別していない実装 —— を落とす。
    /// 到着側(`.active`)を見ている事の主張。
    func testArrivingAtTheBackgroundIsNotAResumeNegativeControl() {
        XCTAssertEqual(
            resumeCount([.inactive, .active, .inactive, .background]),
            0,
            "背面へ**入る**辺で取り直しても、その取得は誰も見ない"
        )
    }
}
