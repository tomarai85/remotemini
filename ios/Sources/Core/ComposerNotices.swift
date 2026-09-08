import Foundation

/// 会話の入力欄の上に出す物を**3 層**に畳む(2026-09-07、案 A)。
///
/// 何が問題だったか(棚卸し `.harness/evidence-2026-09-07/ui-inventory.md`): 入力欄の上に、独立に条件づけられた行が 15 本
/// 並んでいた —— 机の状態・稼働時間・許可モード・留守の要約・queue / 送信 / 割り込み / 選択の帯・各 in-flight・入力不可の理由・
/// 添付の結果・上限の告知。最悪 5 行以上が積み、「帯 3 段」の事故が実際に起きている。**どれを先に見せるかの規則が
/// 1 箇所に無く、画面の `if` の並び順が事実上の優先順位だった**。
///
/// 3 層(此の型が決める):
///   急ぎ  = 最大 **1 本**。止まっている理由 > 直前の操作の答え(失敗が先)> 進行中 > 成功の確認。
///   状態  = **1 行に畳む**。机の今・稼働時間・許可モード。内訳は展開で読む。
///   診断  = 此処では出さない(上限の告知だけは急ぎ —— 送れないので)。
///
/// ★純関数。画面も view model も見ない —— 検査は `ComposerNoticesTests` が値だけで撃つ。
/// ★`id` は既存の accessibilityIdentifier を其のまま使う。検査と UI 自動化が指す字を変えない。
enum ComposerNotices {
    struct Urgent: Equatable {
        /// 既存の識別子(例 `conversation.sendBanner`)。画面は之を `accessibilityIdentifier` に使う。
        let id: String
        let text: String
        let tone: ResultDisplay.Tone
    }

    struct Plan: Equatable {
        /// 最大 1 本。無ければ nil。
        let urgent: Urgent?
        /// 畳んだ 1 行(例 `Working · Bash(npm test) · opus-5 · main · auto`)。材料が 1 つも無ければ nil。
        let state: String?
        /// 畳んだ時に**行に描く**先頭だけ(例 `Working · Bash(npm test)`)。
        /// ★`state` を其のまま描くと電話の幅で中略が起き、消える所が毎回変わる。行は短く、全文は展開で。
        let stateHeadline: String?
        /// 展開した時に出す内訳(state と同じ材料を行に分けた物)。
        let stateDetail: [String]
    }

    /// 画面が持っている値をそのまま渡す。**順番はこの関数が決める**。
    ///
    /// - Parameters:
    ///   - limited: 利用上限の告知(送れない = 最優先)
    ///   - composerDisabled: 入力できない理由
    ///   - interruptDisabled: 割り込めない理由
    ///   - send / interrupt / choice / queue: 各操作の答え(`SendBanner` の tone を持つ)
    ///   - attach: 添付の結果(文だけ。失敗しか出ないので warn として扱う)
    ///   - sendInFlight / interruptInFlight / choiceInFlight: 進行中の一文
    ///   - deskWorking: `true` 生成中 / `false` 待機 / `nil` 分からない
    ///   - currentTool: 今の道具名(`deskWorking == true` の時だけ意味がある)
    ///   - waitingOnYou: 机が選択待ち(`deskWorking == false` の時の言い分けに使う)
    ///   - runtime: 稼働の 1 行(model · branch · ctx)
    ///   - permissionMode: 許可モード
    ///   - digest / digestUrges: 留守中の要約と、其れが急ぎか
    static func plan(
        limited: String?,
        composerDisabled: String?,
        interruptDisabled: String?,
        send: SendBanner?,
        interrupt: SendBanner?,
        choice: SendBanner?,
        queue: String?,
        attach: String?,
        sendInFlight: String?,
        interruptInFlight: String?,
        choiceInFlight: String?,
        deskWorking: Bool?,
        currentTool: String?,
        waitingOnYou: Bool,
        runtime: String?,
        permissionMode: String?,
        digest: String?,
        digestUrges: Bool
    ) -> Plan {
        let detail = stateLine(deskWorking: deskWorking, currentTool: currentTool, waitingOnYou: waitingOnYou,
                               runtime: runtime, permissionMode: permissionMode, digest: digest, digestUrges: digestUrges)
        return Plan(
            urgent: urgent(limited: limited, composerDisabled: composerDisabled, interruptDisabled: interruptDisabled,
                           send: send, interrupt: interrupt, choice: choice, queue: queue, attach: attach,
                           sendInFlight: sendInFlight, interruptInFlight: interruptInFlight, choiceInFlight: choiceInFlight,
                           digest: digest, digestUrges: digestUrges),
            // ★材料が 1 つも無ければ nil。空文字を返すと画面が「空の 1 行」を描く。
            state: detail.isEmpty ? nil : detail.joined(separator: " · "),
            stateHeadline: detail.first,
            stateDetail: detail)
    }

    // MARK: - 急ぎ(最大 1 本)

    private static func urgent(
        limited: String?, composerDisabled: String?, interruptDisabled: String?,
        send: SendBanner?, interrupt: SendBanner?, choice: SendBanner?, queue: String?, attach: String?,
        sendInFlight: String?, interruptInFlight: String?, choiceInFlight: String?,
        digest: String?, digestUrges: Bool
    ) -> Urgent? {
        // 1. 上限 —— 送れないので他の何より先。
        if let limited { return Urgent(id: "conversation.limitedNotice", text: limited, tone: .error) }
        // 2. 出来ない理由。入力の方が割り込みより上(打てない方が困る)。
        if let composerDisabled { return Urgent(id: "conversation.composerDisabledReason", text: composerDisabled, tone: .warn) }
        if let interruptDisabled { return Urgent(id: "conversation.interruptDisabledReason", text: interruptDisabled, tone: .warn) }
        // 3. 操作の答え。**失敗が先**(失敗は行動を要求し、成功は確認でしかない)。
        //    同じ tone の中の順は「利用者が直前に押した可能性の高い順」= 選択 → 割り込み → 送信 → queue → 添付。
        let answers: [(String, SendBanner?)] = [
            ("conversation.choiceBanner", choice),
            ("conversation.interruptBanner", interrupt),
            ("conversation.sendBanner", send),
        ]
        for tone in [ResultDisplay.Tone.error, .warn] {
            for (id, banner) in answers where banner?.tone == tone {
                if let banner { return Urgent(id: id, text: banner.text, tone: tone) }
            }
            if tone == .warn {
                if let queue { return Urgent(id: "conversation.queueBanner", text: queue, tone: .warn) }
                if let attach { return Urgent(id: "conversation.attachNotice", text: attach, tone: .warn) }
            }
        }
        // 4. 留守中の要約が「見てくれ」と言っている時。
        if digestUrges, let digest, !digest.isEmpty { return Urgent(id: "conversation.awayDigest", text: digest, tone: .warn) }
        // 5. 進行中。
        if let choiceInFlight { return Urgent(id: "conversation.choiceInFlightNotice", text: choiceInFlight, tone: .warn) }
        if let interruptInFlight { return Urgent(id: "conversation.interruptInFlightNotice", text: interruptInFlight, tone: .warn) }
        if let sendInFlight { return Urgent(id: "conversation.sendInFlightNotice", text: sendInFlight, tone: .warn) }
        // 6. 成功の確認(最後)。
        for (id, banner) in answers where banner?.tone == .ok {
            if let banner { return Urgent(id: id, text: banner.text, tone: .ok) }
        }
        return nil
    }

    // MARK: - 状態(1 行)

    /// 机の今。材料の無い物は行に出さない(空の欄を「0」として読ませない)。
    private static func stateLine(
        deskWorking: Bool?, currentTool: String?, waitingOnYou: Bool,
        runtime: String?, permissionMode: String?, digest: String?, digestUrges: Bool
    ) -> [String] {
        var parts: [String] = []
        if let deskWorking {
            if deskWorking {
                parts.append(currentTool.map { "Working · \($0)" } ?? "Working")
            } else {
                parts.append(waitingOnYou ? "Waiting on you" : "Idle")
            }
        }
        if let runtime, !runtime.isEmpty { parts.append(runtime) }
        if let permissionMode, !permissionMode.isEmpty { parts.append(permissionMode) }
        // 急ぎに上がった要約は状態に重ねない(同じ文を 2 箇所に出さない)。
        if !digestUrges, let digest, !digest.isEmpty { parts.append(digest) }
        return parts
    }
}

extension ComposerNotices.Plan {
    /// 何も出さない(入力欄の上が空)か。
    var isEmpty: Bool { urgent == nil && (state == nil || state?.isEmpty == true) }
}
