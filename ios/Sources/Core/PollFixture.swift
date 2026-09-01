import Foundation

#if DEBUG

/// DEBUG-only fixture `PollFetching`, same convention as `HistoryFetchingFixture`
/// (Sprint 3) and `SessionsListingFixture` (Sprint 2): selected via `RC_UI_FIXTURE`,
/// holds no hostname/URL, never touches the network or the Keychain.
///
/// A `final class`, not a `struct`: it has to remember how many times it has been
/// called across one running `PollLoop`, and `PollLoop` holds its `client:
/// PollFetching` as a `let` -- an existential held in a `let` cannot dispatch to a
/// `mutating` struct method, so reference semantics is the only option that doesn't
/// also require changing `PollLoop`'s own storage.
///
/// Exists for two independent reasons, not one:
/// 1. Hygiene (unconditional): before this file, `RootView`'s DEBUG Conversation
///    branch never passed a `pollClient:` at all, so it defaulted to a real
///    `PollClient()` -- a background `Task` would have been making real (if
///    doomed-to-fail) HTTP requests against the inert `ui-fixture.invalid` host for
///    as long as any UI test or screenshot run kept that screen on-screen. Every
///    `RC_UI_FIXTURE` state, including the pre-existing `.threeRoles`, now gets an
///    explicit fixture instead.
/// 2. Sprint 4 brief §7 DoD item 6: 2 Simulator screenshots of the staged
///    degradation banner (`UnreadableMeter.Stage.degraded`/`.stalled`) -- `.degraded`
///    and `.stalled` drive `poll()` to return `.unreadable` just enough times to
///    reach and then FREEZE at the target stage, so a screenshot taken a couple of
///    seconds after launch reliably lands on the intended stage rather than racing
///    past it.
final class PollFetchingFixture: PollFetching {
    private let historyState: HistoryFetchingFixture.State
    private var callCount = 0

    init(historyState: HistoryFetchingFixture.State) {
        self.historyState = historyState
    }

    func poll(baseURL: URL, apiKey: String, sessionID: String, cursor: PollCursor, waitMs: Int) async -> PollOutcome {
        callCount += 1

        // 2026-08-06: the two states that are *readable*. Everything below this point
        // returns `.unreadable` forever, which is why `ConversationViewModel.screen`
        // stayed `nil` in every fixture and the composer/interrupt table -- the rule
        // the screen is shaped around -- had no UI-level coverage at all.
        //
        // One readable response, then hold: the classification must STICK for the
        // duration of a UI test's assertions. Returning it repeatedly would work too,
        // but a fixture that keeps resolving instantly spins the poll loop as fast as
        // the CPU allows; the same 60s hold the branch below uses is the honest shape
        // of a long-poll the server has not answered yet.
        if let classification = Self.readableClassification(for: historyState) {
            if callCount == 1 {
                return .success(Self.screenResponse(classification: classification, state: historyState))
            }
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            return .unreadable
        }

        let unreadableTarget: Int
        switch historyState {
        case .busy, .choice, .choiceKeys:
            // Unreachable: handled by the readable branch above. Kept explicit rather
            // than folded into a `default` so adding a 7th state is a compile error
            // here instead of a silent `unreadableTarget = 0`.
            unreadableTarget = 0
        case .threeRoles, .long, .search, .searchUnreachable:
            // No degradation intended for this state -- 0 means the very first call
            // already falls through to the "hold forever" branch below, so
            // `unreadableStage` never leaves `.normal`.
            //
            // `.long` は位置(開いた時どこに居るか / 「以前を読む」の後どこへ寄るか)
            // だけを測る為の状態なので、ライブ行もバナーも出さない -- 画面に他の
            // 動きが在ると、位置が動いた理由がどちらか言えなくなる。
            //
            // `.search` / `.searchUnreachable` も同じ理由で静かにする(2026-09-01)。
            // 加えて此処には固有の要求が在る: 探索の UI 検査は「検索の開閉を跨いで
            // `conversation.landingDistance` が **1 バイトも動かない**」を測る。
            // ライブ行が 1 本でも届けば `tailToken` が進み、読み出しの `corr=` /
            // `h=` が変わって、着地の輪が再起動したのか poll が伸ばしたのかを
            // 言えなくなる —— 対照が測る対象を失う。
            unreadableTarget = 0
        case .degraded:
            unreadableTarget = 1 // streak 1, below the stage-2 floor of 3.
        case .stalled:
            unreadableTarget = 3 // streak 3 crosses `UnreadableMeter`'s stalled floor.
        }

        if callCount <= unreadableTarget {
            return .unreadable
        }

        // Simulate a long-poll the server is holding open rather than one that keeps
        // resolving immediately -- without this, an unthrottled fixture would climb
        // straight past the intended stage within milliseconds of screen launch,
        // since nothing here is actually waiting on a real network round trip. A
        // 60s sleep comfortably outlasts `shots.sh`'s 2s capture delay and any UI
        // test's assertion timeout.
        try? await Task.sleep(nanoseconds: 60_000_000_000)
        return .unreadable
    }

    /// `nil` = this state is one of the unreadable ones (its whole point is the
    /// degradation banner), so it must not be handed a readable response.
    private static func readableClassification(for state: HistoryFetchingFixture.State) -> ScreenBody.Classification? {
        switch state {
        case .busy: return .busy
        case .choice, .choiceKeys: return .choice
        case .threeRoles, .degraded, .stalled, .long, .search, .searchUnreachable: return nil
        }
    }

    /// The readable poll response that carries a classification, plus **one live
    /// message** -- the anchor, and the reason this is not `items: []`.
    ///
    /// The first draft sent no items, reasoning that a transcript assertion would
    /// couple the composer test to rendering. Measuring it killed that reasoning:
    /// `BUSY` and "no screen observed yet" produce a **pixel-identical** screen
    /// (`composerEnabled`/`interruptEnabled` both return `true` from their `guard let
    /// screen else` path), so `testBusyLeavesBothTheComposerAndTheInterruptButtonUsable`
    /// passed whether or not the readable branch above ran at all. A test that cannot
    /// fail is not evidence -- it is a green light wired to nothing.
    ///
    /// `applyReadablePoll` assigns `screen` and appends `entries` in the same call with
    /// no branch between them, so the live line showing up on screen IS the proof that
    /// the classification landed. That is what makes the composer assertion, which has
    /// no observable of its own for `BUSY`, mean something.
    ///
    /// `display.choice` is attached only for the choice states, because that is the
    /// shape the real server sends -- `view.mjs` fills `choiceView(state)` exactly when
    /// the desk is sitting on a menu. Omitting it would make the fixture's CHOICE
    /// screen a state the backend never actually produces.
    ///
    /// ★It is keyed off `state`, **not** `classification`: the two choice fixtures share
    /// the `CHOICE` classification and differ only in whether the server handed over
    /// keys, which is precisely the distinction the allowlist makes. Keying on
    /// classification here would collapse them into one screen and quietly delete the
    /// thing the pair exists to measure.
    private static func screenResponse(
        classification: ScreenBody.Classification,
        state: HistoryFetchingFixture.State
    ) -> PollResponse {
        PollResponse(
            items: [
                .message(MessageItem(
                    entries: [HistoryEntry(
                        role: .assistant,
                        text: liveAnchorText(for: classification),
                        display: .init(who: "Claude")
                    )],
                    seq: 1
                ))
            ],
            // ★`limited` は検体では **false 固定**(2026-08-30)。此処を可変にするには
            //   `SENDABLE + limited` の状態を `HistoryFetchingFixture.State` に足す事になり、
            //   readable な状態は今 `busy` / `choice` 系しか無い。
            //   帯を出すか否かの**判断は純関数**(`ConversationView.limitedNotice`)に置き、
            //   単体で変異まで押さえた —— 面を1枚増やすより、判断を1つ露出させる方が
            //   証拠が強く、壊れた時に何が壊れたかが名指しできる。
            screen: ScreenBody(classification: classification, limited: false),
            display: choiceDisplay(for: state),
            // Queue(v2、2026-08-14): `.busy` だけ送信待ち2件を持つ。作業中の会話に
            // 送信を積む、が此の面の実在する使い方そのもの。他の状態は nil のまま
            // (= 観測していない側の枝も fixture に残る —— 帯が**出ない**事も面)。
            queued: classification == .busy ? 2 : nil,
            cursor: PollCursor.empty,
            more: false
        )
    }

    /// The two menus, copied from the shapes `view.mjs` actually emits.
    ///
    /// The refusal text is `CHOICE_BLOCKED["hard-stop"]` verbatim rather than a
    /// paraphrase: this fixture is the only place the phone's rendering of that sentence
    /// can be looked at, and a fixture that reworded it would be checking the wrong
    /// string against the wrong screen.
    ///
    /// ★2026-08-08 (監査 S8-20). The same rule binds every `label` below, and it was
    /// broken here: the escape button read 「中止(Escape)」, a string that exists nowhere
    /// in rc-backend. `ConversationView` draws `Text(button.label)` verbatim, so the
    /// screenshots taken off this fixture showed a button production had never emitted --
    /// and the Sprint 7 wording fix in `ConversationViewModel` was reasoned from that
    /// screenshot. A fixture written *prettier* than production cannot be caught by
    /// looking: the review passes, and only the defect stays invisible.
    ///
    /// `rc-backend/test/fixture-labels-producible.test.mjs` now feeds these options and
    /// key kinds back through `choiceView` and requires the buttons here to be in what it
    /// can emit, so rewording a label without changing the server turns the suite red.
    private static func choiceDisplay(for state: HistoryFetchingFixture.State) -> PollDisplay? {
        switch state {
        case .choice:
            return PollDisplay(choice: ChoiceView(
                show: true,
                reason: "This is a permission/trust confirmation. The phone offers no controls for it (a standing rule: automation does not press safety prompts). Handle it on the desk.",
                head: ["Claude requests permission to run:", "  rm -rf ./build"],
                options: [
                    ChoiceOption(n: 1, label: "Yes"),
                    ChoiceOption(n: 2, label: "Yes, and don't ask again"),
                    ChoiceOption(n: 3, label: "No, tell Claude what to do differently"),
                ],
                buttons: [],
                digest: "fixture-hard-stop",
                // ★直値だがサーバと縛られている: `fixture-labels-producible.test.mjs` が
                //   この head/options を `choiceView` に食わせ直し、出た risk と此処が
                //   一致する事を要求する。ズレたら赤くなるので、写しが古くならない。
                risk: ChoiceRisk(
                    tier: "danger",
                    notice: "This action is hard to undo. Read it before you tap.",
                    signals: [ChoiceRiskSignal(id: "recursive-delete", why: "ファイルを再帰的に消します")],
                    version: 1
                )
            ))
        case .choiceKeys:
            return PollDisplay(choice: ChoiceView(
                show: true,
                reason: "",
                head: ["Apply this change?"],
                options: [
                    ChoiceOption(n: 1, label: "Yes"),
                    ChoiceOption(n: 2, label: "No"),
                ],
                buttons: [
                    ChoiceButton(key: "1", label: "1. Yes"),
                    ChoiceButton(key: "2", label: "2. No"),
                    ChoiceButton(key: "escape", label: "Escape(Cancel)"),
                ],
                digest: "fixture-benign"
            ))
        case .threeRoles, .degraded, .stalled, .busy, .long, .search, .searchUnreachable:
            return nil
        }
    }

    /// Distinct per classification on purpose: one shared string would let a test that
    /// launched the wrong fixture still find its anchor and report green.
    private static func liveAnchorText(for classification: ScreenBody.Classification) -> String {
        switch classification {
        case .busy: return "live row (working) arrived"
        case .choice: return "live row (awaiting confirm) arrived"
        case .sendable, .unknown, .unrecognized: return "live row arrived"
        }
    }
}

#endif
