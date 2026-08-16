import Foundation

#if DEBUG

/// DEBUG-only fixture for `AccountReading`/`AccountAdvancing`/`AccountSelecting`, same
/// convention as `PollFetchingFixture` and `SessionsListingFixture`: selected via
/// `RC_UI_ACCOUNT_FIXTURE`, holds no hostname/URL, never touches the network or the
/// Keychain.
///
/// ★It exists for the same reason `PollFetchingFixture` does, and the reason is not
/// convenience. Before that file, one DEBUG branch quietly kept a *real* client and
/// made real requests during UI runs. The rule this project settled on is that every
/// fixture state gets an explicit fixture for **every** client on the screen -- so
/// adding an account control obliges this file, not "later".
/// (`.harness/spec-native-shell-2026-08-05.md` §2.57 records the shape of the defect
/// where a fixture screen still held real clients on a few seams.)
///
/// A `final class`: the switch has to be observable across calls (the switch-count is
/// what the UI test asserts on), and an existential held in a `let` cannot dispatch to
/// a `mutating` struct method.
final class AccountFixture: AccountReading, AccountAdvancing, AccountSelecting {
    enum State: String {
        /// The ordinary case: named accounts, one of which cannot be selected.
        case rotating = "account-rotating"
        /// 一覧が読めない(机の台本の出力形式が変わった形)。名指しは出せず、矢印だけが残る。
        case listingUnreadable = "account-listing-unreadable"
        /// 一覧は読めるが、机が**その名前を断る**(400)。口座は動かない。
        case refuses = "account-refuses"
        /// `fleet-account` itself failing on the backend (500 with a reason).
        case backendFails = "account-backend-fails"
        /// The backend unreachable.
        case unreachable = "account-unreachable"
    }

    private let state: State
    /// 4本。うち `sdgs` は**トークンが欠けている** = 一覧には出るが選べない行。
    /// 選べない行を1本必ず含めるのは、其の行が「消える」実装が UI 検査で緑にならない為。
    private static let names = ["team", "biz", "sdgs", "tom"]
    private static let tokenless = "sdgs"
    private var index = 0
    private(set) var advanceCount = 0
    private(set) var selectCount = 0
    /// 最後に名指しで頼まれた名前。UI 検査が「押した行が机へ届いたか」を測る為。
    private(set) var lastSelected: String?

    init(state: State) {
        self.state = state
    }

    func current(baseURL: URL, apiKey: String) async -> Result<AccountState, AccountError> {
        switch state {
        case .rotating, .refuses:
            return .success(listing())
        case .listingUnreadable:
            return .success(unreadableListing())
        case .backendFails:
            return .failure(.backend("fleet-account failed: fixture"))
        case .unreachable:
            return .failure(.unreachable)
        }
    }

    func select(name: String, baseURL: URL, apiKey: String) async -> Result<AccountState, AccountError> {
        selectCount += 1
        lastSelected = name
        switch state {
        case .rotating:
            guard let hit = Self.names.firstIndex(of: name) else {
                return .failure(.refused("That account is not in the list."))
            }
            index = hit
            return .success(listing())
        case .refuses:
            // ★断りは副作用の**前**に返る = `index` を動かさない。此処を動かすと、
            //   「断られたのに画面だけ切り替わる」実装が検査で緑になる。
            return .failure(.refused("That account's token is missing on edith."))
        case .listingUnreadable:
            return .failure(.refused("The account list is unreadable, so switching is unavailable."))
        case .backendFails:
            return .failure(.backend("fleet-account <name> failed: fixture"))
        case .unreachable:
            return .failure(.unreachable)
        }
    }

    func next(baseURL: URL, apiKey: String) async -> Result<AccountState, AccountError> {
        advanceCount += 1
        switch state {
        case .rotating, .refuses:
            index = (index + 1) % Self.names.count
            return .success(listing())
        case .listingUnreadable:
            // 矢印は一覧が読めなくても押せる(退避路)。机は**進めた上で**、読めないまま返す。
            //
            // ★`index` を動かすのが此処の要点(2026-08-15 に直した。それ以前は註だけが
            //   「進めた上で」と言い、code は動かしていなかった —— 註と code が食い違い、
            //   UI 検査⑪が赤で捕まえた)。机の側の実際の順序は
            //   `fleet-account --next` が口座を進める -> その後の一覧の読み取りが
            //   形式違いで潰れる、なので **口座は動いていて一覧だけが読めない**。
            //   進めない fixture にすると「退避路を押しても何も起きない」実装が緑になる。
            index = (index + 1) % Self.names.count
            return .success(unreadableListing())
        case .backendFails:
            // ★The fixture advances `index` here even though it reports failure --
            // that is not sloppiness, it is the real contract. `server.mjs` states
            // that `fleet-account --next` has already changed the account by the time
            // it can time out, so "500" and "the account did not move" are different
            // claims. A fixture that left the index alone would let a wrong
            // implementation (one that retries on 500) look correct.
            index = (index + 1) % Self.names.count
            return .failure(.backend("fleet-account --next failed: fixture"))
        case .unreachable:
            return .failure(.unreachable)
        }
    }

    private func listing() -> AccountState {
        AccountState(
            current: Self.names[index],
            accounts: Self.names.enumerated().map { offset, name in
                let hasToken = name != Self.tokenless
                return AccountRow(
                    name: name,
                    hasToken: hasToken,
                    active: offset == index,
                    selectable: hasToken,
                    blocked: hasToken ? nil : "That account's token is missing on edith."
                )
            },
            ok: true,
            statusMessage: nil,
            anomalyMessages: [],
            raw: nil,
            rawTruncated: false
        )
    }

    private func unreadableListing() -> AccountState {
        AccountState(
            current: Self.names[index],
            accounts: [],
            ok: false,
            statusMessage: "Account list rows were unreadable (fleet-account's output format may have changed). A partial list is withheld rather than shown.",
            anomalyMessages: [],
            // ★生の出力も `index` に追随させる。固定文字列にすると、矢印を押した後に
            //   「現用 = biz」と「生の出力 = 現用: team」が同じ画面で食い違う ——
            //   fixture が自分で嘘の画面を作る形になる。
            raw: "現用: \(Self.names[index])\n優先順 (.order):\n  -> 1. \(Self.names[index])  ???\n",
            // fixture の生出力は 2000 字に遠く届かないので、切れていない側が正しい。
            rawTruncated: false
        )
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
