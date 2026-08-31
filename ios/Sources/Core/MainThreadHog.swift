#if DEBUG
import Foundation

/// 検査の為に **app 本体の main run loop を意図的に細切れにする**注入口。
///
/// ── 何故 之が要るか(2026-08-31)────────────────────────────────────────────
/// `ConversationUITests.testOpeningALongConversationLandsAtTheNewestLine` は
/// 全掃きの最中にだけ倒れ、単独では必ず通る。倒れた瞬間の記録は
/// 「下端まで 375.6pt(約 7 行)残ったまま止まった」を示す。
///
/// 之を意図的に再現しようとして、**機械を混ませる形で 2 回 外した**(実測):
///
/// | 撒いた物 | 直す前のコードで |
/// |---|---|
/// | `yes` を 15 本(論理コア 15 = 飽和) | 5/5 PASS |
/// | 加えて別 simulator で `ConversationUITests` を回し続ける | 5/5 PASS |
///
/// 理由は QoS とプロセス木にある。shell から起いた `yes` は default QoS で、
/// simulator の前面 app は user-interactive —— scheduler は app を優先するので、
/// 15 核を埋めても **app の主スレッドは飢えない**。別 simulator は `launchd_sim` ごと
/// プロセス木が別なので、競合は host の GPU と `CoreSimulator` daemon で止まり、
/// 対象 app の run loop 予算には届かない。
///
/// ★つまり計器は**原因(混んだ機械)**を真似ようとしていたが、再現すべきは
///   **機序(app 自身の main run loop が細切れになる事)**だった。
///   機械負荷は其の遠位の代理で、しかも効かない代理だと 2 回の実測で判った。
///
/// ── 之が何の役に立つか ───────────────────────────────────────────────────
/// ★**私の仮説を殺せる**事が此の注入口の値打ち。
///   `scrollTo` の反復(実体化 → layout → 測り直し)が run loop の予算で
///   打ち切られる、というのが今の本命の仮説。main run loop を 9 割 占有しても
///   倒れないなら、**其の仮説は反証される** —— 其の時は機序を別に探すべきで、
///   今の補正は「効くかもしれない手当て」以上の資格を失う。
///   負荷模型が当たらない事は仮説を検証しないが、之は検証する。
///
/// ── 安全 ─────────────────────────────────────────────────────────────────
/// `#if DEBUG` で囲い、更に環境変数が**明示的に**渡された時だけ起きる。
/// 既定(変数無し)では `Timer` を1つも作らない = 何も起きない。
/// `RC_UI_FIXTURE` と同じ門の形なので、新しい概念を持ち込まない。
enum MainThreadHog {
    private static var timer: Timer?

    /// 実際に占有が始まっているか。★app の `print` は xcodebuild の log に出ないので、
    /// 「掛かっていない」と「掛かったが見えない」を区別するには**画面から読める口**が要る。
    /// 着地の読み出しに相乗りさせ、検査が毎回 刷る。
    static var isArmed: Bool { timer != nil }

    /// `RC_UI_MAIN_HOG_MS` が渡されていれば、周期ごとに main thread を其の分 占有する。
    ///
    /// - `RC_UI_MAIN_HOG_MS`: 1 回に主スレッドを止める長さ(ミリ秒)。0 か未設定で無効。
    /// - `RC_UI_MAIN_HOG_PERIOD_MS`: 周期(既定 16 = 概ね 1 フレーム)。
    ///
    /// 占有は `Timer` の callback の中で行うので、**必ず main run loop の上**で起きる。
    /// 別スレッドで回すと(前の 2 回と同じで)対象に届かない。
    static func startIfRequested() {
        guard timer == nil else { return }
        guard let raw = ProcessInfo.processInfo.environment["RC_UI_MAIN_HOG_MS"],
              let hogMs = Double(raw), hogMs > 0 else { return }
        let periodMs = ProcessInfo.processInfo.environment["RC_UI_MAIN_HOG_PERIOD_MS"]
            .flatMap(Double.init) ?? 16
        // 周期より長く占有すると run loop が完全に埋まって検査自体が進まない。
        // 其れは「倒れた」ではなく「測れなかった」なので、上限を周期の 9 割に置く。
        let capped = min(hogMs, periodMs * 0.9)
        // ★★発火した事を**必ず刷る**。之が無いと「負荷を掛けたのに倒れなかった」と
        //   「負荷が届いていなかった」が区別できず、**反証を主張できない**。
        //   渡り方は `TEST_RUNNER_` 接頭辞 → 実行側の ProcessInfo → app の
        //   launchEnvironment → 此処 と 3 段 経由するので、どこか 1 段で落ちても
        //   静かに何も起きない。今日だけで同型(配線されて見えるのに走らない)を
        //   3 回 踏んでいる。
        print("MAIN-HOG-ARMED ms=\(capped) period=\(periodMs)")
        timer = Timer.scheduledTimer(withTimeInterval: periodMs / 1000.0, repeats: true) { _ in
            let end = DispatchTime.now().uptimeNanoseconds + UInt64(capped * 1_000_000)
            while DispatchTime.now().uptimeNanoseconds < end { /* 主スレッドを占有する */ }
        }
    }
}
#endif
