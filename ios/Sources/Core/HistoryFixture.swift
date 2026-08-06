import Foundation

#if DEBUG

/// DEBUG-only fixture data source for the Conversation screen, same pattern as
/// `SessionsListingFixture` (Sprint 2): selected via `RC_UI_FIXTURE`, holds no
/// hostname/URL, never touches the Keychain.
struct HistoryFetchingFixture: HistoryFetching {
    enum State: String {
        /// All 3 wire roles + a "load earlier" button in one screenshot -- brief
        /// §4-b's Simulator screenshot requirement.
        case threeRoles = "conversation-3roles"
        /// Sprint 4 brief §7 DoD item 6: the quiet 1-line staged-degradation banner
        /// (`UnreadableMeter.Stage.degraded`). History content is irrelevant to this
        /// screenshot -- reuses `threeRolesResponse` rather than a second literal --
        /// what makes the banner actually appear is `PollFetchingFixture`, selected
        /// off this same case in `RootView`.
        case degraded = "conversation-degraded"
        /// Sprint 4 brief §7 DoD item 6: the warning + `[再試行]`/`[読み直す]` banner
        /// (`UnreadableMeter.Stage.stalled`). Same reasoning as `.degraded`.
        case stalled = "conversation-stalled"
        /// 2026-08-06: the two screen classifications the composer/interrupt table
        /// actually turns on. Every state above drives `poll()` to `.unreadable`, so
        /// `screen` stays `nil` in all of them and the UI layer had **no** way to
        /// reach the rule Tom's ruling is about (「返答待ちであれ作業中であれいつでも
        /// 見て、干渉できればいい」). History content is irrelevant to both -- what
        /// makes them differ is `PollFetchingFixture`, selected off these same cases.
        case busy = "conversation-busy"
        /// The one classification that legitimately takes the composer away, and the
        /// only place `interruptAllowedOnChoiceScreen` is observable end-to-end.
        case choice = "conversation-choice"
    }

    let state: State

    func fetch(baseURL: URL, apiKey: String, sessionID: String, limit: Int) async -> Result<HistoryResponse, SessionsFetchError> {
        switch state {
        case .threeRoles, .degraded, .stalled, .busy, .choice:
            return .success(Self.threeRolesResponse)
        }
    }

    private static let threeRolesResponse = HistoryResponse(
        history: [
            HistoryEntry(role: .user, text: "予約の状況を確認して", display: .init(who: "Tom")),
            HistoryEntry(role: .assistant, text: "確認します。少々お待ちください。", display: .init(who: "Claude")),
            HistoryEntry(role: .tool, text: "⚙ Bash", display: .init(who: "道具")),
            HistoryEntry(role: .assistant, text: "予約が2件見つかりました。詳細を送ります。", display: .init(who: "Claude")),
        ],
        // truncated: true so the DoD screenshot also shows the "以前を読む" button
        // alongside all 3 role types in the same frame.
        truncated: true
    )
}

#endif

/// Exists in every configuration; the `RC_UI_FIXTURE` check itself is `#if
/// DEBUG`-gated below -- same shape as `SessionsListingFactory`. `RootView` uses this
/// to decide whether to bypass List/Key-entry/`AppState` entirely and show
/// `ConversationView` directly against canned data.
enum ConversationHistoryFactory {
    #if DEBUG
    static var fixtureState: HistoryFetchingFixture.State? {
        ProcessInfo.processInfo.environment["RC_UI_FIXTURE"].flatMap(HistoryFetchingFixture.State.init(rawValue:))
    }
    #endif
}
