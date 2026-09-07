import Foundation

/// `SubagentsView` の状態機(対照表 #8「半分その一」、2026-09-05 / 「半分その二」= 止める、2026-09-06)。
/// `DiffViewModel` の写し —— 脇の画面で、poll も送信も持たないので、
/// `.notFound`/`.unauthorized` の app 全体のルーティングは持ち込まず、失敗は
/// 此の画面の中で完結する 1 文の帯にする(同じ判断の理由はあちらの頭書き)。
///
/// 止める側の規則(`research/subagent-stop-panel-design-2026-09-04.md` + 研究レビュー 2026-09-07):
///   - 電話は id を名指すだけ。照合(prompt と道具列)と打鍵は机。電話は**画面の行の位置を送らない**。
///   - 1 回目のタップは「構え」(`armed`)、同じ行の 2 回目で送る。別の行をタップすれば構えが移る。
///     止めるのは取り消せない操作なので、指の滑りで送らない。★構えから `confirmDelay` 未満の 2 回目は
///     **一動作の二度打ち**と読んで送らない(構えたまま)。
///   - 断り(409)は机の文(`error`)を**そのまま**帯に出す。電話が言い換えない。
///   - 送った後は一覧を読み直す。止めた直後の行はしばらく `running` のままかもしれない(机の生死は転写の
///     鮮度で決まる)ので、帯が「止まった」を言い、行は行で正直に描く。★ただし此の画面で止めた id の
///     ボタンは出さない(`stoppedHere`)—— 「Working」の下の「Stop」が再タップを誘うのを塞ぐ。
@MainActor
final class SubagentsViewModel: ObservableObject {
    enum Phase: Equatable {
        case loading
        case loaded(SubagentsBody)
        case failed(String)
    }

    /// 構えから確認までの最短間隔。之より短い 2 回目は一動作の二度打ちと読む。
    static let confirmDelay: TimeInterval = 0.5

    @Published private(set) var phase: Phase = .loading
    /// 構えている行の agentId(2 回目のタップで送る)。
    @Published private(set) var armed: String?
    /// 机が打鍵している間の行の agentId(ボタンは回る印になり、二度打ちできない)。
    @Published private(set) var stopping: String?
    /// 直前の停止の結果の 1 文(成功も断りも)。次の停止か読み直しで消える。
    @Published private(set) var stopNotice: String?
    /// 此の画面で「止まった」と机が言った id。行が `running` に見えていてもボタンを出さない。
    @Published private(set) var stoppedHere: Set<String> = []

    private var armedAt: Date?
    private let client: SubagentsFetching
    private let baseURL: URL
    private let apiKey: String
    private let sessionID: String
    private let now: () -> Date

    init(client: SubagentsFetching = SubagentsClient(), baseURL: URL, apiKey: String, sessionID: String, now: @escaping () -> Date = Date.init) {
        self.client = client
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.sessionID = sessionID
        self.now = now
    }

    func load() async {
        phase = .loading
        armed = nil
        armedAt = nil
        switch await client.fetch(baseURL: baseURL, apiKey: apiKey, sessionID: sessionID) {
        case .success(let response):
            phase = .loaded(response)
        case .failure(.cancelled):
            // 画面を閉じた瞬間に「読めませんでした」を一瞬見せない(`DiffViewModel` と同じ)。
            break
        case .failure(let error):
            phase = .failed(Self.text(for: error))
        }
    }

    /// 行に「Stop」を出すか: 走っていて、此の画面で止めていない行だけ。
    func canStop(_ row: SubagentRow) -> Bool {
        row.state == "running" && !stoppedHere.contains(row.agentId)
    }

    /// 行の「Stop」を押した。1 回目 = 構える、同じ行の 2 回目(`confirmDelay` 以上後)= 送る。走っていない行は何もしない。
    func tapStop(_ row: SubagentRow) async {
        guard stopping == nil, canStop(row) else { return }
        if armed != row.agentId {
            armed = row.agentId
            armedAt = now()
            stopNotice = nil
            return
        }
        // 一動作の二度打ち(構えた直後)は送らない。構えは残す(意図が続いているなら次のタップで送れる)。
        if let at = armedAt, now().timeIntervalSince(at) < Self.confirmDelay {
            return
        }
        armed = nil
        armedAt = nil
        stopping = row.agentId
        defer { stopping = nil }
        switch await client.stop(baseURL: baseURL, apiKey: apiKey, sessionID: sessionID, agentID: row.agentId) {
        case .success(let body):
            if body.stopped {
                stopNotice = "Stopped “\(row.description ?? row.agentId)”."
                stoppedHere.insert(row.agentId)
            } else {
                // ★机の文をそのまま。`reason` は電話が分岐に使わない(語彙は机が持つ)。
                stopNotice = body.error ?? "The desk did not stop it and gave no reason."
            }
            // 一覧を読み直す(止めた直後は行がまだ running に見える事がある = 帯が真実を言う)。
            await reloadKeepingNotice()
        case .failure(.cancelled):
            break
        case .failure(let error):
            stopNotice = Self.text(for: error)
        }
    }

    /// 構えを解く(別の場所をタップした / 画面を離れた)。
    func disarm() {
        armed = nil
        armedAt = nil
    }

    private func reloadKeepingNotice() async {
        let notice = stopNotice
        switch await client.fetch(baseURL: baseURL, apiKey: apiKey, sessionID: sessionID) {
        case .success(let response):
            phase = .loaded(response)
        case .failure(.cancelled):
            break
        case .failure(let error):
            phase = .failed(Self.text(for: error))
        }
        stopNotice = notice
    }

    /// 誤りごとに固定の1文。電話が状況ごとの説明を創作しない —— 何が届いたかだけを言う。
    private static func text(for error: SessionsFetchError) -> String {
        switch error {
        case .unauthorized:
            return "Sign-in expired. Reopen this conversation to sign in again."
        case .notFound:
            return "That conversation is gone."
        case .malformedBody:
            return "The response shape is unreadable."
        case .contractViolation(let violation):
            return violation.displayText
        case .unreachable:
            return "Couldn't reach the desk."
        case .anchorGone:
            // 錨の窓だけが作る値。此の口は 409 を返さないので到達しないが、網羅は崩さない。
            return "That part of the history changed."
        case .cancelled:
            // `load()` は此のケースで `phase` を触らない(上を見よ)。網羅を崩すと、
            // 5 つ目の case が生えた日にコンパイラが黙って通す。
            return ""
        }
    }
}
