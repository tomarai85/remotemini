import SwiftUI

/// 「背面から前面へ戻って来た」の判定。2画面(会話 = N4 / 一覧 = brief §3-d 引き金 #3)が
/// 共有する。
///
/// ★2026-08-08 実測。これが**純関数ではなく状態を持つ器**である理由。
///
///   iOS が実際に配る `scenePhase` の並びを、UI 試験の中で `.onChange` の
///   `(old, new)` を全部書き出して観測した(fixture `list-normal`、
///   `XCUIDevice.shared.press(.home)` -> `app.activate()`):
///
///     [inactive>active]      <- 起動
///     [active>inactive]      <- home 押下 1/2
///     [inactive>background]  <- home 押下 2/2
///     [background>inactive]  <- 復帰 1/2
///     [inactive>active]      <- 復帰 2/2
///
///   **`background -> active` という辺は一度も現れない。** 背面への出入りは必ず
///   `.inactive` を経由して2段で配られる。
///
///   これが意味する事: Sprint 4 が置いた
///   `oldPhase == .background && newPhase == .active` は、単に厳しすぎたのではなく
///   **決して真にならない条件**だった。会話画面の N4「背面から戻ったら読み直す」は
///   Sprint 4 から 2026-08-08 まで、一度も発火していない。
///
///   なぜ検査4本(単体2 + Sprint 4 の変異 N8c/N8d)を通り抜けたか —— 全部が
///   `f(.background, .active) == true` という**規則**を測っていて、
///   「iOS がその引数で f を呼ぶか」を誰も測っていなかったから。規則は正しく、
///   前提が偽だった。だから今回の検査は対ではなく**並び**を食わせる形にしてある
///   (`ForegroundResumeTests` に上の実測列がそのまま入っている)し、
///   `ios/tools/list-return-refresh-control.sh` は本物の背面往復を通して測る。
///
/// なぜ `oldPhase` を引数から落としたか: 読まない引数は、この欠陥を5 sprint
/// 見えなくした形その物だから。判定に要るのは「途中で背面に居たか」という
/// **履歴**であって直前の1辺ではない。1辺では原理的に足りないので、器が状態を持つ。
///
/// ★`.harness/progress.md` の Sprint 4 の変異表(N8c / N8d)は
///   `ConversationView.shouldResumeOnForeground` という当時の名前で記録されている。
///   日付の付いた記録なので書き換えていない —— 追う人の為に、移動先と
///   「あの2本が測っていたのは満たされない前提だった」事を此処に書いておく。
struct ForegroundResume {
    /// 「`.background` を通った」を憶えておく。`.active` に着いた時にこれが立って
    /// いなければ、それは背面往復ではない —— 起動、通知バナーの出入り、Control Center を
    /// 引いて戻す、App Switcher の覗き見。どれも `.inactive` までしか下りない。
    private var wasBackgrounded = false

    /// `.onChange(of: scenePhase)` から**毎回**呼ぶ。真を返した回だけが本物の復帰。
    ///
    /// 印を返す時に倒すのが要点で、倒さないと以後の `.active` が全部復帰に見える
    /// (一度背面に入った後は、通知バナーを出すたびに取り直す)。
    mutating func shouldResume(newPhase: ScenePhase) -> Bool {
        if newPhase == .background {
            wasBackgrounded = true
            return false
        }
        guard newPhase == .active, wasBackgrounded else { return false }
        wasBackgrounded = false
        return true
    }
}
