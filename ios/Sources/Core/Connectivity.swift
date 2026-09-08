import Foundation

/// 机に届かない事の**唯一の語彙**(2026-09-08、案 D)。
///
/// 何が問題だったか(棚卸し `.harness/evidence-2026-09-07/ui-inventory.md` (a)): 同じ「机との間が怪しい」に 3 系統の
/// 別々の言い方と別々の見た目が在った —— 共有の赤い帯(`UnreachableBanner`)、会話だけの 3 段階の劣化の行、設定の口座行。
/// 段階の梯子(届かない > 遅れている > 応答が確認できない)なのに、見た目が段階でなく**実装された場所**で分かれていた。
///
/// 此処が決める物: 段ごとの **題・詳細・強さ**。描き方(色・位置)は `RCConnectivityBanner` が段の強さから決める。
/// ★純関数。検査は `ConnectivityTests` が値だけで撃つ。
enum Connectivity {
    /// 強さ。色や太さは画面がこの 3 値から決める(文言と強さを 2 箇所で決めない)。
    enum Severity: Equatable {
        /// 事実として伝える(押す物ではない)。
        case note
        /// 気に掛ける(遅れている)。
        case caution
        /// 届いていない / 確認できない。
        case alarm
    }

    /// 梯子の段。**下ほど重い**。
    enum Stage: Equatable {
        /// 通信そのものが通らない。`failures` = 連続で落ちた回数。
        case unreachable(failures: Int, onList: Bool)
        /// 通ってはいるが更新が遅れている。`lastConfirmed` = 最後に確認できた時刻の文字列。
        case lagging(lastConfirmed: String)
        /// 応答を確認できない(最後の確認から動いていない)。
        case noResponse(lastConfirmed: String)
    }

    struct Message: Equatable {
        let title: String
        let detail: String
        let severity: Severity
    }

    /// 段 → 画面に出す文。**題は何が起きているか、詳細は何をすればよいか**(順序を段で変えない)。
    static func message(for stage: Stage) -> Message {
        switch stage {
        case .unreachable(let failures, let onList):
            return Message(
                title: "Can't reach the desk",
                // ★文は書かず `UnreachableBanner.detailText` に委ねる(spec §5-4 の文と、其れを守る対照 ——
                //   原因を名指ししない / 件数が実測 —— を 2 箇所に分けない)。
                detail: UnreachableBanner.detailText(failures: failures, context: onList ? .list : .conversation),
                severity: .alarm)
        case .lagging(let lastConfirmed):
            return Message(
                title: "Updates are lagging",
                detail: "Last confirmed \(lastConfirmed)",
                severity: .caution)
        case .noResponse(let lastConfirmed):
            return Message(
                title: "No response confirmed",
                detail: "Last confirmed \(lastConfirmed)",
                severity: .alarm)
        }
    }

    /// 会話の 3 段階(`UnreadableMeter.Stage`)と通信断から段を組む。**届かないが最強**(通信が死んでいる時に
    /// 「遅れている」と言うと、直す先を間違える)。`nil` = 何も出さない。
    static func stage(unreachableFailures: Int?, lagging: Bool, noResponse: Bool, lastConfirmed: String) -> Stage? {
        if let f = unreachableFailures { return .unreachable(failures: f, onList: false) }
        if noResponse { return .noResponse(lastConfirmed: lastConfirmed) }
        if lagging { return .lagging(lastConfirmed: lastConfirmed) }
        return nil
    }
}
