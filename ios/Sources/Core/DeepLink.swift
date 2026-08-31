import Foundation
import Combine

/// 外(通知・URL)から「この会話を開け」を運ぶ一本道。
///
/// ── 何故 之が要るか(2026-08-31、実測)────────────────────────────────────────
/// `remotemini` の URL scheme は **既に Info.plist に登録済み**(`ios/project.yml` の
/// `CFBundleURLSchemes`)。しかし `onOpenURL` を受ける側が **iOS のソースに 1 行も無かった**
/// (grep 0 件)。つまり通知にリンクを載せても、アプリが前面に出るだけで**会話には着地しない**。
///
/// 机の側は既に配線が在る —— `~/.claude/settings.json` の `Stop` / `Notification` hook が
/// 発火している。ただし行き先が `afplay` = **机のスピーカーが鳴るだけ**で、
/// Tom が机に居ない時は何の役にも立っていない。
///
/// 「気付く → 着地する → 答える」の鎖のうち、**着地が此処で切れていた**。
///
/// ── 何故 環境オブジェクトなのか ───────────────────────────────────────────────
/// `ListView.init` は引数が多く、呼び出し側が 2 箇所(実物 / fixture)在る。
/// 引数を 1 本増やすと両方を触る事になり、壊す面が広がる。
/// 之は**画面の状態ではなく、アプリ全体に 1 つだけ在る「外から来た指示」**なので、
/// 環境に置くのが構造として正しい。
///
/// ★受け取った id は**消費されたら消す**。残すと、次に一覧へ戻った時に
///   同じ会話へ勝手に飛び続ける(押していないのに画面が動く = 最も嫌われる形)。
@MainActor
final class DeepLink: ObservableObject {
    /// 開くべき会話の id。`nil` = 指示なし。
    @Published var pendingSessionID: String?

    init() {
        #if DEBUG
        // ★検査から着地だけを測る為の口。`simctl openurl` は iOS が必ず
        //   「Open in "Remote Mini"?」の確認を挟むので、外から URL を投げる形では
        //   **最後まで測れない**(2026-08-31 実測、確認ダイアログで止まった)。
        //   だから鎖を測れる継ぎ目で切る —— URL の**解釈**は単体検査、
        //   **着地**は此の口で id を差して画で見る。
        //   既定(環境変数なし)では何も起きない。
        if let seed = ProcessInfo.processInfo.environment["RC_UI_DEEPLINK"], !seed.isEmpty {
            pendingSessionID = seed
        }
        #endif
    }

    /// `remotemini://session/<id>` を受ける。
    ///
    /// ★**知らない形は黙って捨てる**。将来 別の口(`remotemini://settings` 等)が
    ///   増えた時、此処が「解釈できない = 何かする」に倒れていると、
    ///   外から来た文字列で画面が予期せず動く。解釈できない物は無視が正しい。
    func handle(_ url: URL) {
        guard url.scheme == "remotemini" else { return }
        guard url.host == "session" else { return }
        let id = url.pathComponents.first(where: { $0 != "/" && !$0.isEmpty })
        guard let id, !id.isEmpty else { return }
        pendingSessionID = id
    }

    /// 使い終わったら消す。
    func consume() { pendingSessionID = nil }
}
