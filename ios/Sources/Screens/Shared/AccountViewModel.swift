import Foundation

/// Drives the account label + switch control (REQUIREMENTS §4-5 / §5-8).
///
/// ★The state machine is deliberately four cases, not "a string plus an isLoading
/// flag". The distinction that has to survive is between **"we have not asked yet"**
/// and **"we asked and the fleet could not name an account"** -- collapsing them puts
/// an empty label on screen in both, and an empty label reads as "no account", which
/// is the one thing the phone must not say when it simply has not looked.
@MainActor
final class AccountViewModel: ObservableObject {
    enum Phase: Equatable {
        /// Nothing asked yet. Show no label at all (not a blank one).
        case idle
        /// A read is in flight and no previous value is known.
        case loading
        /// The account the backend named. `switching` says whether a change is in
        /// flight *on top of* a known value -- the old label stays visible while the
        /// switch runs, because a label that blanks out mid-switch cannot be told
        /// apart from a switch that wiped the account.
        case loaded(account: String, switching: Bool)
        /// A human-readable reason. Carries the reason rather than a bare flag: the
        /// server distinguishes "fleet-account itself failed" (500, with the script's
        /// message) from "wrong key" (401), and those need different actions from the
        /// person holding the phone.
        case failed(reason: String)
    }

    @Published private(set) var phase: Phase = .idle

    /// 発行した操作の世代。**遅れて着いた古い読み取りが、新しい結果を上書きしない**為。
    ///
    /// ★Codex 2026-08-12 が名指しした操作列: 会話画面から一覧へ戻ると `.task` が
    ///   `load()` を撃つ。其の読み取りが飛んでいる最中に切替を押すと、
    ///   `advance()` が B を書いた**後**に古い `load()` が A を返し、画面が A に戻る。
    ///   画面は A、机は B —— 電話が嘘をつく形で、しかも本人は切替が成功したのを見ている。
    ///
    /// ★時刻でも「飛んでいる最中か」の旗でもなく**世代**にしたのは、旗だと
    ///   「2本目の読み取りが1本目より先に着く」場合を見分けられない為。
    ///   自分より新しい世代が既に居たら、其の結果は**捨てる**(相を触らない)。
    private var generation = 0

    private let reader: AccountReading
    private let advancer: AccountAdvancing
    private let baseURL: URL
    private let apiKey: String
    private let onUnauthorized: () -> Void

    init(
        reader: AccountReading,
        advancer: AccountAdvancing,
        baseURL: URL,
        apiKey: String,
        onUnauthorized: @escaping () -> Void
    ) {
        self.reader = reader
        self.advancer = advancer
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.onUnauthorized = onUnauthorized
    }

    /// Safe to call on every appearance: a read has no side effect on the fleet.
    ///
    /// 背面から戻った時にも呼ぶ(`AccountBar` の `.onChange(of: scenePhase)`)。
    /// 呼ばないと、他所で口座を変えて戻って来た時に**画面だけが古い**まま残る
    /// —— 一覧が同じ理由で `ForegroundResume` を持っているのと同じ穴。
    func load() async {
        generation += 1
        let mine = generation
        if case .loaded = phase {} else { phase = .loading }
        let result = await reader.current(baseURL: baseURL, apiKey: apiKey)
        // ★自分より新しい操作が始まっていたら、此の結果は**古い**。捨てる。
        guard mine == generation else { return }
        apply(result)
    }

    /// Advances the fleet to the next account.
    ///
    /// ★No retry here, and none may be added -- `server.mjs`'s own comment on
    /// `/api/account/next` records why: the script has already advanced the account by
    /// the time it can time out, so a 500 does not mean "nothing happened". Retrying
    /// would step twice and report once. Instead, on **any** failure this re-reads the
    /// current account, so the label ends up showing where the fleet actually landed
    /// rather than where the phone assumed it landed.
    func advance() async {
        guard case .loaded(let account, let switching) = phase, !switching else { return }
        // 切替も世代を進める。飛んでいる読み取りより**必ず新しい**ので、
        // 遅れて着いた読み取りは上で捨てられる。
        generation += 1
        phase = .loaded(account: account, switching: true)

        switch await advancer.next(baseURL: baseURL, apiKey: apiKey) {
        case .success(let state):
            phase = .loaded(account: state.account, switching: false)
        case .failure(.unauthorized):
            phase = .failed(reason: "鍵が拒まれました")
            onUnauthorized()
        case .failure(.cancelled):
            // Not an error worth showing: re-read and let the truth win.
            await load()
        case .failure(let error):
            // Show the failure, then correct the label from the server. The reason is
            // captured *before* the re-read so a successful re-read cannot hide that
            // the switch itself failed.
            let reason = Self.message(for: error)
            apply(await reader.current(baseURL: baseURL, apiKey: apiKey), fallbackReason: reason)
            if case .loaded(let account, _) = phase {
                phase = .failed(reason: "\(reason)(現在: \(account))")
            }
        }
    }

    private func apply(_ result: Result<AccountState, AccountError>, fallbackReason: String? = nil) {
        switch result {
        case .success(let state):
            phase = .loaded(account: state.account, switching: false)
        case .failure(.unauthorized):
            phase = .failed(reason: fallbackReason ?? "鍵が拒まれました")
            onUnauthorized()
        case .failure(let error):
            phase = .failed(reason: fallbackReason ?? Self.message(for: error))
        }
    }

    /// Wording lives here, not in the view: the view renders whatever it is handed, so
    /// the strings are reachable from unit tests without standing up SwiftUI.
    static func message(for error: AccountError) -> String {
        switch error {
        case .unreachable: return "机に届きません"
        case .cancelled: return "取り消されました"
        case .unauthorized: return "鍵が拒まれました"
        case .backend(let detail): return "机の側で失敗しました: \(detail)"
        case .unexpectedStatus(let code): return "想定外の応答 (\(code))"
        case .malformedBody: return "応答の形が読めません"
        }
    }
}
