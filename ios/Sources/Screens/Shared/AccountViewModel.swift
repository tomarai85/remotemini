import Foundation

/// 口座の表示と切替を駆動する(REQUIREMENTS §4-5 / §5-8 / §9-3)。
///
/// ★相が「文字列 + isLoading の旗」ではなく列挙なのは、**「まだ訊いていない」**と
/// **「訊いたが机が口座を名乗れなかった」**を分ける為。潰すと画面はどちらでも空白になり、
/// 空白は「口座が無い」と読める —— 単に見ていないだけの時に電話が言ってはいけない事。
///
/// ★2026-08-14 に `loaded(account: String, switching: Bool)` から `loaded(AccountState)` へ
/// 変えた。以前は**現用の名前1本**しか持っていなかったので、画面に出せる操作が矢印1つ
/// (次のアカウントへ)しか作れなかった。Tom の §9-3(「矢印のフォームでしかない」)は
/// 見た目の話に見えて、実体は**この型が候補を持っていなかった事**。
///
/// ★失敗を `.failed` に畳まない場面が在る。一覧が生きているのに切替だけが失敗した時、
/// 以前は `.failed(reason: "…(現在: team)")` へ落としていて、**一覧が画面から消えていた**
/// —— 失敗の直後こそ「今どこに居て、他に何が選べるか」が要る場面なので、向きが逆。
/// 一覧を保ったまま `lastFailure` に1行出す。
@MainActor
final class AccountViewModel: ObservableObject {
    enum Phase: Equatable {
        /// Nothing asked yet. Show no label at all (not a blank one).
        case idle
        /// A read is in flight and no previous value is known.
        case loading
        /// 机が答えた状態そのもの。`ok == false`(一覧が読めない)も此処に入る ——
        /// 読めない事は**答えの一種**であって、通信の失敗ではない。
        case loaded(AccountState)
        /// A human-readable reason. Carries the reason rather than a bare flag: the
        /// server distinguishes "fleet-account itself failed" (500, with the script's
        /// message) from "wrong key" (401), and those need different actions from the
        /// person holding the phone.
        case failed(reason: String)
    }

    @Published private(set) var phase: Phase = .idle
    /// いま切替を頼んでいる相手の名前。矢印(`next`)の時は `nil` のまま `advancing` が立つ。
    @Published private(set) var switchingTo: String?
    /// 矢印での切替が飛んでいるか。
    @Published private(set) var advancing = false
    /// 直前の操作が失敗した理由。**一覧は残したまま**出す1行。成功すると消える。
    @Published private(set) var lastFailure: String?

    /// 現用の名前(帯が描く1行)。`nil` = まだ知らない、または机が名乗れなかった。
    var currentName: String? {
        if case .loaded(let state) = phase { return state.current }
        return nil
    }

    /// 何か操作が飛んでいるか。押せるかの判定は**1箇所**に置く —— 2箇所に書くと、
    /// 片方だけ直した時に「矢印は押せないが名指しは押せる」形が生える。
    var isBusy: Bool { advancing || switchingTo != nil }

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
    private let selector: AccountSelecting
    private let baseURL: URL
    private let apiKey: String
    private let onUnauthorized: () -> Void

    init(
        reader: AccountReading,
        advancer: AccountAdvancing,
        selector: AccountSelecting,
        baseURL: URL,
        apiKey: String,
        onUnauthorized: @escaping () -> Void
    ) {
        self.reader = reader
        self.advancer = advancer
        self.selector = selector
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

    /// 名指しで切り替える(§9-3)。
    ///
    /// ★選べない行は**机へ投げない**。理由の文面は机が作った物(`row.blocked`)を
    ///   そのまま出す —— 電話側で言い換えると、机の断り方と画面の断り方が別々に腐る。
    ///   机側の門(`selectionProblem`)は消さない: 此処は往復を1つ省くだけで、
    ///   安全を担っているのは机側。
    func select(_ name: String) async {
        guard case .loaded(let state) = phase, !isBusy else { return }
        if let row = state.accounts.first(where: { $0.name == name }), !row.selectable {
            lastFailure = row.blocked ?? "そのアカウントは選べません。"
            return
        }
        generation += 1
        switchingTo = name
        lastFailure = nil

        let result = await selector.select(name: name, baseURL: baseURL, apiKey: apiKey)
        switchingTo = nil
        switch result {
        case .success(let state):
            phase = .loaded(state)
        case .failure(.unauthorized):
            lastFailure = nil
            phase = .failed(reason: "鍵が拒まれました")
            onUnauthorized()
        case .failure(.cancelled):
            // Not an error worth showing: re-read and let the truth win.
            await load()
        case .failure(.refused(let reason)):
            // ★測り直さない。断りは台本を叩く**前**に返る(`server.mjs` の `/select` は
            //   `selectionProblem` を通してから `execFileSync` する)ので、机の口座は
            //   動いていない。読み直すと「何か起きたかもしれない」という誤った印象になる。
            lastFailure = reason
        case .failure(let error):
            // 500 は副作用の有無が判らない。理由を憶えてから読み直し、**着地点**を出す。
            let reason = Self.message(for: error)
            await load()
            lastFailure = reason
        }
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
        guard case .loaded = phase, !isBusy else { return }
        // 切替も世代を進める。飛んでいる読み取りより**必ず新しい**ので、
        // 遅れて着いた読み取りは上で捨てられる。
        generation += 1
        advancing = true
        lastFailure = nil

        let result = await advancer.next(baseURL: baseURL, apiKey: apiKey)
        advancing = false
        switch result {
        case .success(let state):
            phase = .loaded(state)
        case .failure(.unauthorized):
            phase = .failed(reason: "鍵が拒まれました")
            onUnauthorized()
        case .failure(.cancelled):
            await load()
        case .failure(let error):
            // Show the failure, then correct the label from the server. The reason is
            // captured *before* the re-read so a successful re-read cannot hide that
            // the switch itself failed.
            let reason = Self.message(for: error)
            await load()
            lastFailure = reason
        }
    }

    private func apply(_ result: Result<AccountState, AccountError>) {
        switch result {
        case .success(let state):
            phase = .loaded(state)
        case .failure(.unauthorized):
            phase = .failed(reason: "鍵が拒まれました")
            onUnauthorized()
        case .failure(let error):
            phase = .failed(reason: Self.message(for: error))
        }
    }

    /// Wording lives here, not in the view: the view renders whatever it is handed, so
    /// the strings are reachable from unit tests without standing up SwiftUI.
    ///
    /// ★`.refused` の文面だけは机が作った物をそのまま通す(`src/account.mjs` が正本)。
    ///   断り方は机の門の都合で増えるので、電話が言い換えを持つと必ず片方が古びる。
    static func message(for error: AccountError) -> String {
        switch error {
        case .unreachable: return "机に届きません"
        case .cancelled: return "取り消されました"
        case .unauthorized: return "鍵が拒まれました"
        case .backend(let detail): return "机の側で失敗しました: \(detail)"
        case .refused(let reason): return reason
        case .unexpectedStatus(let code): return "想定外の応答 (\(code))"
        case .malformedBody: return "応答の形が読めません"
        }
    }
}
