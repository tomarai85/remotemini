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
                        // ★fixture の面に本物の口を1つも残さない。`RC_UI_FIXTURE` が
                        //   口座の状態を名乗っていなければ、**回る fixture** に落とす
                        //   (本物の `AccountClient` には落とさない = 3回再発した形)。
                        accountViewModel: Self.fixtureAccountViewModel(),
                        baseURL: Self.fixtureBaseURL,
                        apiKey: "ui-fixture-key",
                        renamer: RenameFixture(),
                        archiver: ArchiveFixture(),
                        returner: ReturnRequestFixture(),
                        archivedLister: ArchivedListingFixture(),
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
                        title: "fixture session",
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
            // ★2026-08-27: 識別子を付けた。付ける前は、この1枚目のスピナーだけ名前が無く、
            //   UI 検査から「今どちらの待ちに居るか」を一度も見られなかった。
            //
            //   ★2枚を**1つに融合しない**のが此処の判断。見た目は既に連続している
            //   (どちらも素の `ProgressView` なので継ぎ目が無い)が、意味は別物:
            //   此方は Keychain の読みで**網を使わない**、`list.loading` は網の取得。
            //   識別子まで一緒にすると「鍵で固まった」と「机に届かない」が
            //   外から区別できなくなる —— 待たされている理由を潰す方向で、
            //   `WaitEscalation` を入れた判断と正面から衝突する。
            //   だから **別の名前を与え、連続している事の方を検査で押さえる**
            //   (`InitialWaitUITests` の連続性の検査 = どの瞬間もどちらか一方は出ている)。
            ProgressView()
                .accessibilityIdentifier("root.loading")
        } else if let credentials = appState.credentials {
            ListView(
                viewModel: ListViewModel(
                    client: SessionsClient(),
                    baseURL: credentials.baseURL,
                    apiKey: credentials.apiKey,
                    onUnauthorized: { appState.clearCredentials(rejected: credentials) }
                ),
                accountViewModel: AccountViewModel(
                    reader: AccountClient(),
                    advancer: AccountClient(),
                    selector: AccountClient(),
                    baseURL: credentials.baseURL,
                    apiKey: credentials.apiKey,
                    onUnauthorized: { appState.clearCredentials(rejected: credentials) }
                ),
                baseURL: credentials.baseURL,
                apiKey: credentials.apiKey,
                renamer: TitleClient(),
                archiver: ArchiveClient(),
                returner: ReturnRequestClient(),
                archivedLister: SessionsClient(),
                onUnauthorized: { appState.clearCredentials(rejected: credentials) }
            )
        } else {
            // 2026-08-16(DESIGN §2.100)。ここは以前 `KeyEntryView` を直に出していて、
            // 資格情報が無い起動は**理由に関わらず**「Base URL と API Key を打て」の
            // 白紙で始まっていた。名乗る面を先に置き、欄はその奥へ退避させた。
            DisconnectedView(
                // 迷子の `nil` は作らない。`disconnected` は資格情報が無い時に必ず入るが、
                // 万一入っていなければ**説明が付かない**と名乗るのが正しい(嘘の理由を
                // 選ばない)。
                reason: appState.disconnected ?? .unexplained,
                notice: appState.signOutNotice,
                clients: keyEntryClients,
                onPrimaryAction: { action in
                    switch action {
                    case .retryWithBundledSeed: await appState.retryWithBundledSeed()
                    case .reloadStore: await appState.reloadStoredCredentials()
                    }
                },
                onSaved: appState.setCredentials
            )
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

    /// 口座の口の fixture(2026-08-12)。
    ///
    /// ★**既定で本物へ落ちない**事が此の関数の全部。`RC_UI_FIXTURE` が口座の状態を
    ///   名乗っていない fixture 走行(例: 一覧だけを見る `.threeRoles`)でも、
    ///   `AccountFixture(state: .rotating)` に落とす —— 本物の `AccountClient` を
    ///   既定にすると、一覧の fixture を撮っているだけの走行が
    ///   `https://ui-fixture.invalid/api/account` へ本当に飛ぶ。
    ///   Sprint 4/5/6/7 が同じ形で4回踏んだ穴なので、此処は「名乗らなければ本物」に
    ///   しない事を構造で守る。
    private static func fixtureAccountViewModel() -> AccountViewModel {
        let fixture = AccountFixture.fromEnvironment() ?? AccountFixture(state: .rotating)
        return AccountViewModel(
            reader: fixture,
            advancer: fixture,
            selector: fixture,
            baseURL: fixtureBaseURL,
            apiKey: "ui-fixture-key",
            onUnauthorized: {}
        )
    }
    #endif
}
