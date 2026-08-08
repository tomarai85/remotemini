import SwiftUI

/// Sprint 1 wired only Key-entry; Sprint 2 added the List screen; Sprint 3 adds
/// Conversation, reached only by tapping a List row (`ListView`'s `NavigationLink`)
/// -- there is no direct Key-entry -> Conversation path.
struct RootView: View {
    @StateObject private var appState = AppState.forLaunch()

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
                        // Sprint 8(2026-08-08): 口を1つずつ渡す形をやめた。以前は
                        // 履歴と poll だけを差し替えていて、**送信 / 割り込み / 打鍵の
                        // 3つは既定の本物のまま**残り、押せば `ui-fixture.invalid` へ
                        // 本当に飛ぶ状態だった。Sprint 4 が poll について此処へ1行
                        // 足して直した欠陥が、Sprint 5 / 6 / 7 と**3回続けて再発**して
                        // いた事になる。束は既定値を持たないので、口が増えても
                        // 検査側を書き忘れるとコンパイルが通らない ——
                        // `ios/Sources/Core/ConversationClients.swift`。
                        clients: .fixture(state: conversationFixtureState),
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
            KeyEntryView(clients: keyEntryClients, notice: appState.signOutNotice, onSaved: appState.setCredentials)
        }
    }

    /// 鍵入力画面が握る3つの口。Release では必ず `.live`。
    ///
    /// ★`KeyEntryViewModel` の既定値ではなく**此処**で選ぶ理由(2026-08-08、監査 X2-8)。
    /// 既定値の形だった間、`KeyEntryView` は何も渡していなかったので、UI 検査に出ている
    /// 鍵入力画面が**開発機の実 Keychain と本物の HTTP client**を握っていた。既定値は
    /// 「渡し忘れ」を静かに埋めるので、埋まった事に誰も気付けない ——
    /// `ios/Sources/Core/KeyEntryClients.swift` は既定値を持たない。
    ///
    /// 上の2つの fixture と違って此処が `normalFlow` の**中**に居るのは、鍵入力画面が
    /// 「`AppState` が鍵は無いと答えた」時にだけ現れる面だから(`AppState.forLaunch()` の
    /// doc と同じ話)。迂回して直接描くと、断りが disk から画面まで通る事が測れなくなる。
    private var keyEntryClients: KeyEntryClients {
        #if DEBUG
        if KeyEntryProbeFixture.fromEnvironment() != nil {
            return .fixture(stallingAt: .key)
        }
        if SignOutNoticeFixture.fromEnvironment() != nil {
            return .fixture(stallingAt: .url)
        }
        #endif
        return .live
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
