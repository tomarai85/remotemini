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
        case .threeRoles, .long:
            // No degradation intended for this state -- 0 means the very first call
            // already falls through to the "hold forever" branch below, so
            // `unreadableStage` never leaves `.normal`.
            //
            // `.long` は位置(開いた時どこに居るか / 「以前を読む」の後どこへ寄るか)
            // だけを測る為の状態なので、ライブ行もバナーも出さない -- 画面に他の
            // 動きが在ると、位置が動いた理由がどちらか言えなくなる。
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
        case .threeRoles, .degraded, .stalled, .long: return nil
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
            screen: ScreenBody(classification: classification),
            display: choiceDisplay(for: state),
            queued: nil,
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
                reason: "これは許可・信頼の確認画面です。電話からは操作を出しません(自動化に安全確認を押させない、という決め事)。机で確認してください。",
                head: ["Claude requests permission to run:", "  rm -rf ./build"],
                options: [
                    ChoiceOption(n: 1, label: "Yes"),
                    ChoiceOption(n: 2, label: "Yes, and don't ask again"),
                    ChoiceOption(n: 3, label: "No, tell Claude what to do differently"),
                ],
                buttons: [],
                digest: "fixture-hard-stop"
            ))
        case .choiceKeys:
            return PollDisplay(choice: ChoiceView(
                show: true,
                reason: "",
                head: ["この変更を適用しますか？"],
                options: [
                    ChoiceOption(n: 1, label: "はい"),
                    ChoiceOption(n: 2, label: "いいえ"),
                ],
                buttons: [
                    ChoiceButton(key: "1", label: "1. はい"),
                    ChoiceButton(key: "2", label: "2. いいえ"),
                    ChoiceButton(key: "escape", label: "Escape(中止)"),
                ],
                digest: "fixture-benign"
            ))
        case .threeRoles, .degraded, .stalled, .busy, .long:
            return nil
        }
    }

    /// Distinct per classification on purpose: one shared string would let a test that
    /// launched the wrong fixture still find its anchor and report green.
    private static func liveAnchorText(for classification: ScreenBody.Classification) -> String {
        switch classification {
        case .busy: return "ライブ(作業中)の行が届いた"
        case .choice: return "ライブ(確認待ち)の行が届いた"
        case .sendable, .unknown, .unrecognized: return "ライブの行が届いた"
        }
    }
}

#endif
