import Foundation

#if DEBUG

/// DEBUG-only fixture for `AccountReading`/`AccountAdvancing`, same convention as
/// `PollFetchingFixture` and `SessionsListingFixture`: selected via `RC_UI_FIXTURE`,
/// holds no hostname/URL, never touches the network or the Keychain.
///
/// ★It exists for the same reason `PollFetchingFixture` does, and the reason is not
/// convenience. Before that file, one DEBUG branch quietly kept a *real* client and
/// made real requests during UI runs. The rule this project settled on is that every
/// `RC_UI_FIXTURE` state gets an explicit fixture for **every** client on the screen --
/// so adding an account control to the List screen obliges this file, not "later".
/// (`.harness/spec-native-shell-2026-08-05.md` §2.57 records the shape of the defect
/// where a fixture screen still held real clients on a few seams.)
///
/// A `final class`: `advance()` has to be observable across calls (the switch-count is
/// what the UI test asserts on), and an existential held in a `let` cannot dispatch to
/// a `mutating` struct method.
final class AccountFixture: AccountReading, AccountAdvancing {
    enum State: String {
        /// The ordinary case: a named account that rotates on switch.
        case rotating = "account-rotating"
        /// `fleet-account` itself failing on the backend (500 with a reason).
        case backendFails = "account-backend-fails"
        /// The backend unreachable.
        case unreachable = "account-unreachable"
    }

    private let state: State
    /// Two names, so a UI test can prove the label actually changed rather than
    /// merely that a button was tappable.
    private static let names = ["fixture-a@example.com", "fixture-b@example.com"]
    private var index = 0
    private(set) var advanceCount = 0

    init(state: State) {
        self.state = state
    }

    func current(baseURL: URL, apiKey: String) async -> Result<AccountState, AccountError> {
        switch state {
        case .rotating:
            return .success(AccountState(account: Self.names[index % Self.names.count]))
        case .backendFails:
            return .failure(.backend("fleet-account failed: fixture"))
        case .unreachable:
            return .failure(.unreachable)
        }
    }

    func next(baseURL: URL, apiKey: String) async -> Result<AccountState, AccountError> {
        advanceCount += 1
        switch state {
        case .rotating:
            index += 1
            return .success(AccountState(account: Self.names[index % Self.names.count]))
        case .backendFails:
            // ★The fixture advances `index` here even though it reports failure --
            // that is not sloppiness, it is the real contract. `server.mjs` states
            // that `fleet-account --next` has already changed the account by the time
            // it can time out, so "500" and "the account did not move" are different
            // claims. A fixture that left the index alone would let a wrong
            // implementation (one that retries on 500) look correct.
            index += 1
            return .failure(.backend("fleet-account --next failed: fixture"))
        case .unreachable:
            return .failure(.unreachable)
        }
    }

    /// ★**独立した環境変数**を読む(`RC_UI_FIXTURE` ではない)。
    ///
    /// 経緯(2026-08-12、実測で判った): 最初は `RC_UI_FIXTURE` に相乗りさせたが、
    /// `RootView` の分岐は其の変数を**まず一覧の名前空間で**読む。口座の名前
    /// (`account-rotating` 等)は一覧の相として解釈できないので、`RootView` は
    /// `normalFlow` へ落ち、**鍵入力画面が出て一覧に一度も到達しなかった**
    /// (走行のログの `root flow:normal` が其の観測)。UI 検査5本が同じ理由で赤。
    ///
    /// 1つの変数に2つの名前空間を載せると、片方の名前がもう片方にとって
    /// 「知らない値 = 既定へ落ちる」に見える。**分けるのが正しい** —— 口座の相は
    /// 一覧の相と直交していて、`list-normal` の画面で `account-backend-fails` を
    /// 見たい、という組み合わせが実際に要る。
    static func fromEnvironment() -> AccountFixture? {
        ProcessInfo.processInfo.environment["RC_UI_ACCOUNT_FIXTURE"]
            .flatMap(State.init(rawValue:))
            .map(AccountFixture.init(state:))
    }
}

#endif
