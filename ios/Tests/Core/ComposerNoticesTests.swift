import XCTest
@testable import RemoteMini

/// 入力欄の上の 3 層(2026-09-07、案 A)。棚卸しが数えた 15 本の独立した行を、急ぎ **1 本** と状態 **1 行** に畳む規則。
///
/// 此処が守る物は「どれを先に見せるか」の唯一の場所である事。画面の `if` の並び順が優先順位だった時代には、
/// 5 本以上が同時に積み、利用者はどれに反応すべきか決められなかった(「帯 3 段」の事故)。
final class ComposerNoticesTests: XCTestCase {
    private func plan(
        limited: String? = nil, composerDisabled: String? = nil, interruptDisabled: String? = nil,
        send: SendBanner? = nil, interrupt: SendBanner? = nil, choice: SendBanner? = nil,
        queue: String? = nil, attach: String? = nil,
        sendInFlight: String? = nil, interruptInFlight: String? = nil, choiceInFlight: String? = nil,
        deskWorking: Bool? = nil, currentTool: String? = nil, waitingOnYou: Bool = false,
        runtime: String? = nil, permissionMode: String? = nil, digest: String? = nil, digestUrges: Bool = false
    ) -> ComposerNotices.Plan {
        ComposerNotices.plan(limited: limited, composerDisabled: composerDisabled, interruptDisabled: interruptDisabled,
                             send: send, interrupt: interrupt, choice: choice, queue: queue, attach: attach,
                             sendInFlight: sendInFlight, interruptInFlight: interruptInFlight, choiceInFlight: choiceInFlight,
                             deskWorking: deskWorking, currentTool: currentTool, waitingOnYou: waitingOnYou,
                             runtime: runtime, permissionMode: permissionMode, digest: digest, digestUrges: digestUrges)
    }
    private func banner(_ text: String, _ tone: ResultDisplay.Tone) -> SendBanner {
        SendBanner(locallyWorded: text, tone: tone)
    }

    // MARK: - 急ぎは 1 本だけ

    func testNothingToSayShowsNothing() {
        let p = plan()
        XCTAssertNil(p.urgent)
        XCTAssertNil(p.state)
        XCTAssertTrue(p.isEmpty)
    }

    /// ★本題。棚卸しが挙げた最悪の形 —— 送信中・割り込み中・古い選択・添付の結果・上限が同時に真 —— でも 1 本。
    func testTheWorstCaseStackCollapsesToOne() {
        let p = plan(limited: "Usage limit reached on the desk.",
                     send: banner("Sent.", .ok), interrupt: banner("Stopped.", .ok), choice: banner("Picked 1.", .ok),
                     queue: "Queue cleared.", attach: "Could not read that file.",
                     sendInFlight: "Sending…", interruptInFlight: "Stopping…", choiceInFlight: "Answering…")
        XCTAssertEqual(p.urgent?.id, "conversation.limitedNotice", "上限は送れない事を意味するので最優先")
        XCTAssertEqual(p.urgent?.tone, .error)
    }

    func testBlockersBeatOutcomes() {
        let p = plan(composerDisabled: "Waiting on a choice. Text can't be sent",
                     send: banner("Could not send.", .error))
        XCTAssertEqual(p.urgent?.id, "conversation.composerDisabledReason")
    }

    func testComposerBlockerBeatsInterruptBlocker() {
        let p = plan(composerDisabled: "Text can't be sent", interruptDisabled: "v1 does not interrupt from the phone")
        XCTAssertEqual(p.urgent?.id, "conversation.composerDisabledReason")
    }

    /// 失敗は行動を要求し、成功は確認でしかない。同時なら失敗を見せる。
    func testFailureBeatsSuccessAcrossDifferentActions() {
        let p = plan(send: banner("Could not send.", .error), interrupt: banner("Stopped.", .ok))
        XCTAssertEqual(p.urgent?.id, "conversation.sendBanner")
        XCTAssertEqual(p.urgent?.tone, .error)
    }

    func testErrorBeatsWarnAcrossActions() {
        let p = plan(send: banner("Kept your text.", .warn), choice: banner("The desk refused.", .error))
        XCTAssertEqual(p.urgent?.id, "conversation.choiceBanner")
    }

    /// 同じ tone なら「直前に押した可能性の高い順」= 選択 → 割り込み → 送信。
    func testSameToneOrdersByLikelihoodOfTheLastTap() {
        let p = plan(send: banner("s", .warn), interrupt: banner("i", .warn), choice: banner("c", .warn))
        XCTAssertEqual(p.urgent?.text, "c")
        let q = plan(send: banner("s", .warn), interrupt: banner("i", .warn))
        XCTAssertEqual(q.urgent?.text, "i")
    }

    func testInFlightBeatsSuccessButLosesToFailure() {
        XCTAssertEqual(plan(send: banner("Sent.", .ok), sendInFlight: "Sending…").urgent?.id, "conversation.sendInFlightNotice")
        XCTAssertEqual(plan(send: banner("Could not send.", .error), sendInFlight: "Sending…").urgent?.id, "conversation.sendBanner")
    }

    func testSuccessIsShownWhenNothingElseIs() {
        let p = plan(send: banner("Sent.", .ok))
        XCTAssertEqual(p.urgent?.id, "conversation.sendBanner")
        XCTAssertEqual(p.urgent?.tone, .ok)
    }

    func testQueueAndAttachAreWarnLevelOutcomes() {
        XCTAssertEqual(plan(queue: "Queue cleared.").urgent?.id, "conversation.queueBanner")
        XCTAssertEqual(plan(attach: "Could not open that file.").urgent?.id, "conversation.attachNotice")
        XCTAssertEqual(plan(queue: "q", attach: "a").urgent?.id, "conversation.queueBanner", "queue が先")
    }

    // MARK: - 状態は 1 行

    func testStateCollapsesIntoOneLine() {
        let p = plan(deskWorking: true, currentTool: "Bash(npm test)", runtime: "opus-5 · main · 38.7k ctx", permissionMode: "auto")
        XCTAssertEqual(p.state, "Working · Bash(npm test) · opus-5 · main · 38.7k ctx · auto")
        XCTAssertEqual(p.stateDetail.count, 3)
        // 行に描くのは先頭だけ(幅で中略させない。全文は展開で読む)
        XCTAssertEqual(p.stateHeadline, "Working · Bash(npm test)")
    }

    func testStateSaysWaitingOnYouOnlyWhenTheDeskIsWaiting() {
        XCTAssertEqual(plan(deskWorking: false, waitingOnYou: true).state, "Waiting on you")
        XCTAssertEqual(plan(deskWorking: false, waitingOnYou: false).state, "Idle")
    }

    /// ★分からない物は行に出さない(空欄を「0」として読ませない)。
    func testUnknownDeskStateIsNotWritten() {
        XCTAssertNil(plan(deskWorking: nil).state)
        XCTAssertEqual(plan(deskWorking: nil, permissionMode: "auto").state, "auto")
    }

    /// 急ぎに上がった要約は状態に重ねない(同じ文が 2 箇所に出ない)。
    func testAnUrgentDigestIsNotAlsoInTheStateLine() {
        let p = plan(deskWorking: false, digest: "3 files changed while you were away", digestUrges: true)
        XCTAssertEqual(p.urgent?.id, "conversation.awayDigest")
        XCTAssertEqual(p.state, "Idle")
        let q = plan(deskWorking: false, digest: "3 files changed while you were away", digestUrges: false)
        XCTAssertNil(q.urgent)
        XCTAssertEqual(q.state, "Idle · 3 files changed while you were away")
    }

    /// ★否定対照: 規則を「最初に見つかった物」に潰すと、上の順位の検査が赤になる事を此処で言う。
    /// (順位が本当に働いている証拠 —— 同じ入力で id が変わる組を 2 つ並べる)
    func testTheOrderIsLoadBearingNegativeControl() {
        let both = plan(interruptDisabled: "can't interrupt", send: banner("Could not send.", .error))
        XCTAssertEqual(both.urgent?.id, "conversation.interruptDisabledReason")
        let onlyOutcome = plan(send: banner("Could not send.", .error))
        XCTAssertEqual(onlyOutcome.urgent?.id, "conversation.sendBanner")
        XCTAssertNotEqual(both.urgent?.id, onlyOutcome.urgent?.id)
    }
}
