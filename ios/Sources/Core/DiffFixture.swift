import Foundation

#if DEBUG

/// DEBUG-only fixture data source for `DiffView`, same pattern as
/// `HistoryFetchingFixture`(Sprint 3): selected via `RC_UI_FIXTURE`、hostname/URL を
/// 持たない、Keychain に触れない。
///
/// ★`HistoryFetchingFixture` の 9 状態(会話の中身の網羅)ほどの投資はしていない --
/// diff は 1 会話につき 1 回しか開かない読むだけの脇の画面で、UI が撃ち分ける枝は
/// 「差分が有る」「無い」「読めない」の 3 つしかない。之で全部埋まる。
struct DiffFetchingFixture: DiffFetching {
    enum State: String {
        /// 未 stage / stage 済みの両方が乗る一番賑やかな面(スクリーンショット用)。
        case sample = "diff-sample"
        /// 差分そのものが無い(`reason` は null、静かな空面)。
        case empty = "diff-empty"
        /// git 管理外(対照表 #4 の `reason:"not_a_repo"` の一文)。
        case notARepo = "diff-not-a-repo"
        /// 机が混んでいる(503 + `reason:"busy"`、2026-09-03)。何度撃ち直しても混んだまま(空面と
        /// Try again の**見た目**を撮る為)。
        case busy = "diff-busy"
        /// 1 回目は混んでいて、2 回目から読める。Try again が**本当に撃ち直している**事を
        /// 測る為(押しても同じ面なら「押した」と「効いた」が区別できない)。
        case busyThenSample = "diff-busy-then-sample"
    }

    let state: State

    /// `busyThenSample` の回数。process ごとに 1 つ(fixture は 1 会話 1 画面なので之で足りる)。
    nonisolated(unsafe) static var busyCalls = 0

    func fetch(baseURL: URL, apiKey: String, sessionID: String) async -> Result<SessionDiffBody, SessionsFetchError> {
        switch state {
        case .sample:
            return .success(Self.sample)
        case .empty:
            return .success(SessionDiffBody(files: [], truncated: false, totalBytes: 0, reason: nil))
        case .notARepo:
            return .success(SessionDiffBody(files: [], truncated: false, totalBytes: 0, reason: "not_a_repo"))
        case .busy:
            return .success(Self.busyBody)
        case .busyThenSample:
            Self.busyCalls += 1
            return .success(Self.busyCalls == 1 ? Self.busyBody : Self.sample)
        }
    }

    /// 机が 503 で返す本文と同じ形(`DiffClient` が `reason:"busy"` の 503 を success に通す)。
    private static let busyBody = SessionDiffBody(files: [], truncated: false, totalBytes: 0, reason: "busy")

    private static let sample = SessionDiffBody(
        files: [
            DiffFile(
                path: "ios/Sources/Screens/Conversation/DiffView.swift",
                staged: false, binary: false, added: 2, removed: 1, truncated: false,
                hunks: [
                    DiffHunk(header: "@@ -12,3 +12,4 @@", lines: [
                        DiffLine(kind: .ctx, text: "    var body: some View {"),
                        DiffLine(kind: .del, text: "        Text(\"old\")"),
                        DiffLine(kind: .add, text: "        Text(\"new\")"),
                        DiffLine(kind: .add, text: "        Spacer()"),
                    ]),
                ]
            ),
            DiffFile(
                path: "rc-backend/src/sessiondiff.mjs",
                staged: true, binary: false, added: 1, removed: 0, truncated: false,
                hunks: [
                    DiffHunk(header: "@@ -40,2 +40,3 @@", lines: [
                        DiffLine(kind: .ctx, text: "export const DIFF_LIMITS = Object.freeze({"),
                        DiffLine(kind: .add, text: "  maxFiles: 300,"),
                    ]),
                ]
            ),
        ],
        truncated: false,
        totalBytes: 812,
        reason: nil
    )
}

#endif

/// `AccountFixture` と同じ形(`RC_UI_ACCOUNT_FIXTURE`)。**独立した環境変数**
/// `RC_UI_DIFF_FIXTURE` を読む -- `RC_UI_FIXTURE` に相乗りさせない。
///
/// ★★2026-09-02、実装後の見直しで見つけて直した欠陥。最初は此の型も `RC_UI_FIXTURE`
///   を読んでいて、`AccountFixture` の doc が名指しで警告している**同じ壊れ方**を
///   踏んでいた: `RC_UI_FIXTURE` が `ConversationHistoryFactory` の値
///   (例 `"conversation-3roles"`)を持つ時、此の型は其の綴りを自分の `State` として
///   解決できず `nil` を返し、呼び出し側(`ConversationView.makeDiffViewModel`)は
///   `nil` を「fixture 対象外」と読んで**本物の `DiffClient`**へ倒していた —— 会話は
///   作り物なのに、diff ボタンだけ本物の机へ問い合わせに行く形。`RootView.swift` の
///   頭に在る不変条件(「fixture の面に本物の口を1つも残さない…本物の client には
///   落とさない = 3回再発した形」)への、此の回の4回目の再発だった。
///
/// ★直し方は `AccountFixture.fromEnvironment()` と同じ: 名前空間を分ける。
///   `RC_UI_DIFF_FIXTURE` が明示されていれば其れを使う。無くても、会話側が
///   fixture を名乗っている間(`ConversationHistoryFactory.fixtureState != nil`)は
///   既定 `.sample` に落ちる —— diff ボタンが本物の口を開ける事故を、
///   明示し忘れた側でも起こさない。
enum DiffFactory {
    #if DEBUG
    static var fixtureState: DiffFetchingFixture.State? {
        let raw = ProcessInfo.processInfo.environment["RC_UI_DIFF_FIXTURE"]
        if let own = raw.flatMap(DiffFetchingFixture.State.init(rawValue:)) { return own }
        return ConversationHistoryFactory.fixtureState != nil ? .sample : nil
    }
    #endif
}
