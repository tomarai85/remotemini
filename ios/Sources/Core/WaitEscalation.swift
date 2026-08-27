import Foundation

/// 「待たされている」が**普通から異常へ変わる点**を1箇所で決める。
///
/// ★なぜ純関数として切り出すか(`AppState.disconnectedReason` と同じ理由):
///   ここは判定の規則であって描画ではない。View の中に書くと、規則なのに検査から触れず
///   「画面に出た文」からしか確かめられなくなる。
///
/// ★閾値の根拠(2026-08-27 に一次資料で確認。全文 =
///   `.harness/evidence-2026-08-27/research-loading-narration.md`):
///   - Jakob Nielsen, *Usability Engineering* (1993) / NN-g "Response Times: The 3 Important Limits":
///     **10 秒 = 「利用者の注意がこの対話に留まる限界」**。これを超える待ちには
///     「いつ終わるのか」を示す手掛かりを出すべき、とされる。
///   - 1 秒未満は "no special feedback is necessary"。NN/g (Sherwin 2014) は更に
///     **「1秒未満のループアニメーションはむしろ邪魔」**と言う。
///   - Nah (2004) *A study on tolerable waiting time* は許容待ち時間を約2秒、
///     15 秒超を非許容と報告(Nielsen の 10 秒枠より一段厳しい実験値)。
///
/// ★Apple HIG との緊張関係を、無視せずここに書き残す(これが設計の要):
///   HIG は **"Avoid labeling a spinning progress indicator."** と明示し、
///   **"Avoid vague terms like loading or authenticating because they seldom add value."**
///   とも言う。つまり「今の無言スピナーに『読み込み中…』を足す」は HIG に**正面から反する**。
///   だからこの型は**ラベルを足さない**。10 秒を超えた時に起きるのは表現の切替 ——
///   「普通の操作に伴うスピナー」から「異常が起きているかもしれない状態」への遷移で、
///   HIG が「determinate になったら表現を変えよ」と言うのと同じ形にしてある。
///
/// ★確認できなかった事も書く: 「N 秒後にスピナーを文言付きへ切り替えよ」を名指しで
///   推奨する一次資料(Apple / Google / NN-g)は**見つからなかった**。10 秒という数字は
///   Nielsen の注意限界から取った物で、切替の設計そのものは此方の判断。
enum WaitEscalation {
    /// Nielsen の「注意が持続する限界」。既定 10 秒。
    /// ★検査から縮められる口を持つ: UI 検査で本当に 10 秒待つと、その1本だけで
    ///   検査全体の実行時間が跳ね上がり、やがて誰も回さなくなる。
    static var attentionLimitSeconds: TimeInterval {
        if let raw = ProcessInfo.processInfo.environment["RC_WAIT_ESCALATE_S"],
           let v = Double(raw), v > 0 {
            return v
        }
        return 10
    }

    /// 初回の待ちが今どの段に居るか。**段は2つだけ**で、途中の中間文言を作らない ——
    /// 実測のサーバ応答は 0.1-0.3 秒で、殆どの起動は `.normal` のまま終わる。
    /// 見えない段を増やしても、増えるのは検査の面積だけ。
    enum Stage: Equatable {
        /// 何も足さない。無言のスピナーのまま(1 秒未満はそもそも出さない方が良いが、
        /// それは表示側の判断で、ここは「文言を足さない」だけを言う)。
        case normal
        /// 注意の限界を超えた。表現を切り替え、**何を待っていて次に何ができるか**を出す。
        case abnormal
    }

    /// 経過秒から段を決める。**時計を持たない** = 検査が時間を進めずに全段を作れる。
    static func stage(elapsedSeconds: TimeInterval) -> Stage {
        elapsedSeconds >= attentionLimitSeconds ? .abnormal : .normal
    }

    /// 異常段で出す文。★曖昧語(loading / authenticating)を使わない —— HIG が
    /// 「価値を足さない」と名指しで避けている語。代わりに**何を待っているか**を言う。
    /// 文は1つだけ: 段が2つしか無いので、選び分ける物が無い。
    static let abnormalHeadline = "The MacBook mini hasn't answered yet"

    /// 次に何ができるか。★ここで「電波を確認してください」と言わない —— この電話が
    /// tailnet に居るかどうかを、この画面は観測していない。観測していない事を
    /// 助言の形で言うのは、当たれば正しく見え外れれば人を誤った所へ走らせる。
    static let abnormalBody = "It may be unreachable from here. You can keep waiting, or retry."
}
