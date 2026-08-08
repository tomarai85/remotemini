import SwiftUI

/// Sprint 1 wired only Key-entry; Sprint 2 added the List screen; Sprint 3 adds
/// Conversation, reached only by tapping a List row (`ListView`'s `NavigationLink`)
/// -- there is no direct Key-entry -> Conversation path.
struct RootView: View {
    @StateObject private var appState = AppState()

    var body: some View {
        NavigationStack {
            Group {
                #if DEBUG
                if let fixtureState = SessionsListingFactory.fixtureState {
                    // RemoteMiniUITests path (brief §5-b): bypasses Key-entry and
                    // `AppState` entirely -- the fixture needs no stored credential
                    // and must never touch the Keychain.
                    ListView(
                        viewModel: ListViewModel(
                            client: SessionsListingFixture(state: fixtureState),
                            baseURL: Self.fixtureBaseURL,
                            apiKey: "ui-fixture-key",
                            onUnauthorized: {}
                        ),
                        baseURL: Self.fixtureBaseURL,
                        apiKey: "ui-fixture-key",
                        onUnauthorized: {}
                    )
                } else if let conversationFixtureState = ConversationHistoryFactory.fixtureState {
                    // Sprint 3 brief §4-b: a second, independent `RC_UI_FIXTURE`
                    // namespace -- bypasses List too, straight to Conversation, so a
                    // screenshot can be taken without a List fixture row to tap.
                    ConversationView(viewModel: ConversationViewModel(
                        client: HistoryFetchingFixture(state: conversationFixtureState),
                        // Sprint 4: without this, the poll loop would default to a
                        // real `PollClient()` and make real network attempts against
                        // the inert fixture host in the background -- see
                        // `PollFetchingFixture`'s own doc for the full reasoning.
                        pollClient: PollFetchingFixture(historyState: conversationFixtureState),
                        // DESIGN §2.53: ここは UI 検査(スクリーンショット)の面。本物の
                        // store を渡すと**開発機の `UserDefaults` に検査の打ちかけが残り**、
                        // 検査どうしが互いの打ちかけを見る。覚えない実装を明示的に渡す。
                        draftStore: InMemoryDraftStore(),
                        baseURL: Self.fixtureBaseURL,
                        apiKey: "ui-fixture-key",
                        sessionID: "fixture-session",
                        title: "fixture 会話",
                        onUnauthorized: {}
                    ))
                } else {
                    normalFlow
                }
                #else
                normalFlow
                #endif
            }
        }
        .task {
            #if DEBUG
            if let fixtureState = SessionsListingFactory.fixtureState {
                // Sprint 2 DoD diagnostic line -- same convention as Sprint 1's
                // `KeyEntryViewModel.swift` `print("healthz ok:...")` line, grepped
                // for via `xcrun simctl launch --console` instead of `devicectl`
                // (no physical iPhone; the simulator is fully headless-controllable
                // via `simctl`). No key, no host -- only the fixture name, and this
                // whole branch (including this line) is `#if DEBUG`, so it cannot
                // print from a Release binary regardless of what `RC_UI_FIXTURE` is
                // set to. See `ios/tools/ui-fixture-behavior-control.sh`.
                print("root flow:fixture state:\(fixtureState)")
                return
            }
            if let conversationFixtureState = ConversationHistoryFactory.fixtureState {
                print("root flow:fixture state:\(conversationFixtureState)")
                return
            }
            #endif
            print("root flow:normal")
            await appState.loadStoredCredentials()
        }
    }

    @ViewBuilder
    private var normalFlow: some View {
        if appState.isLoadingCredentials {
            ProgressView()
        } else if let credentials = appState.credentials {
            ListView(
                viewModel: ListViewModel(
                    client: SessionsClient(),
                    baseURL: credentials.baseURL,
                    apiKey: credentials.apiKey,
                    onUnauthorized: { appState.clearCredentials() }
                ),
                baseURL: credentials.baseURL,
                apiKey: credentials.apiKey,
                onUnauthorized: { appState.clearCredentials() }
            )
        } else {
            KeyEntryView(onSaved: appState.setCredentials)
        }
    }

    #if DEBUG
    /// Never dereferenced for networking -- `SessionsListingFixture` returns canned
    /// data regardless of what it's called with. An RFC 2606 reserved TLD anyway
    /// (same convention `MockURLProtocol`'s tests use), so a wiring mistake here
    /// could not reach a live host even by accident. Not a hardcoded *server* host:
    /// this is inert filler for a parameter the fixture ignores.
    private static let fixtureBaseURL = URL(string: "https://ui-fixture.invalid")!
    #endif
}

enum BuildInfo {
    /// 版を画面に出す。実機に入っている物が「今ビルドした物」かを、
    /// 電話を見るだけで言い切れるようにする(配備待ちを prose に手写しした
    /// 2026-08-04 の失敗と同じ型を、器の側でも作らない為)。
    static var line: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "v\(short) (\(build))"
    }
}
