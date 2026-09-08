import SwiftUI

/// Spec §5-4's banner, in one place. Both List and Conversation render THIS -- the
/// spec asks for it by name: 「List/Conversation 共通のコンポーネントとして文言・見た目を
/// 1箇所にまとめる」.
///
/// ★It states what was measured and never names a cause. §5-5's own table lists three
/// possible causes for this state (電波 / edith 停止 / tailnet 切断) and the phone can
/// distinguish none of them. The pre-Sprint-6 List wording led with
/// 「バックエンドに接続できません」, which asserts the third-to-first of those as fact --
/// and did so even when the streak was actually made of contract violations, because
/// `ListViewModel` counts those too (see `ReachabilityMeter`'s doc). Leading with the
/// observation instead makes the sentence true for every streak that can reach it, and
/// costs the reader nothing: the second line already told them what to do.
///
/// No dismiss affordance, by spec: 「手動で『消す』操作は用意しない」. It goes away when
/// a request succeeds, and only then.
/// ★2026-09-08(案 D): **view をやめ、文言の権威だけ残した**。机との間の異常を描く帯は `RCConnectivityBanner` の 1 つに
/// 統合したが、此処の文(spec §5-4、Tom が国外で読む文)と其れを守る検査 —— 原因を名指ししない対照、件数が実測である対照 ——
/// は其のまま生かす。`Connectivity.message` が此の関数を呼ぶ。
enum UnreachableBanner {
    enum Context {
        case list
        case conversation
    }

    static func detailText(failures: Int, context: Context) -> String {
        switch context {
        case .list:
            // ★末尾の動詞だけ 2026-09-08 に変えた(案 C): 直ぐ下のボタンが `Read the list again` なのに文が「retry」と言うと、
            //   同じ操作に 2 つの名前が付く。原因を名指ししない性質(下の対照)も件数の実測も、この編集では変わらない。
            return "\(failures) fetches in a row have failed. Make sure Tailscale is connected, then read the list again"
        case .conversation:
            return "\(failures) fetches in a row have failed. Showing the last data that could be read"
        }
    }
}
