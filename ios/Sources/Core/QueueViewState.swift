import Foundation

/// 送信待ち(まだワーカーへ書いていない番)の面。`src/view.mjs` の `queueView` の移植。
///
/// ★`nil` と `0` を混ぜない —— 向こうの註釈ごと持って来る: tmux 経路の送信待ちは
/// Claude Code の TUI が持っていて(`Press up to edit queued messages`)、我々は其の数を
/// 観測できないので `queued` は nil で来る。「観測して0だった」と「観測していない」を
/// 1つの枝に畳んだ瞬間、後から「机の会話でも 0 件と出しては?」という直し方が正しく
/// 見えてしまう。枝は `known` で分けて残す。
///
/// ★この数は**観測した瞬間の値**で、その後は勝手に古くなる。古さの境目(60秒)は
/// 一覧と同じ `Freshness` から取る —— 二つ目の境目を作らない。
struct QueueViewState: Equatable {
    let show: Bool
    let known: Bool
    let count: Int
    let text: String
    let clearLabel: String
    let ageText: String
    let stale: Bool

    static let hidden = QueueViewState(
        show: false, known: false, count: 0, text: "", clearLabel: "", ageText: "", stale: false)

    static func make(queued: Int?, fetchedAtMs: Double, nowMs: Double) -> QueueViewState {
        // 観測していない(tmux 経路 / 古いサーバ / 読めなかった本文)。断定しないので何も出さない。
        guard let q = queued else { return .hidden }
        // ★出さない枝で古さを名乗らない(数が消えた後も古さの行だけ生きる見え方になる)。
        if q <= 0 {
            return QueueViewState(show: false, known: true, count: 0,
                                  text: "", clearLabel: "", ageText: "", stale: false)
        }
        let f = Freshness.freshness(fetchedAtMs, nowMs: nowMs)
        return QueueViewState(
            show: true, known: true, count: q,
            // ★「送信待ち」= まだ Claude へ**渡していない**。渡した番は取り消せない。
            text: "\(q) queued (not yet handed to Claude)",
            clearLabel: "Cancel \(q) queued",
            ageText: f.text,
            stale: f.stale)
    }
}

/// `DELETE /api/sessions/:id/queue` の応答の読み方。`src/view.mjs` の
/// `clearQueueResult` の移植 —— 読めなかった本文を「無かった」に丸めない。
enum ClearQueueOutcome: Equatable {
    case ok(String)
    case warn(String)
    case refused(String)
    case error(String)

    var text: String {
        switch self {
        case .ok(let t), .warn(let t), .refused(let t), .error(let t): return t
        }
    }

    static func from(status: Int, dropped: Int?, serverError: String?) -> ClearQueueOutcome {
        if status == 200 {
            // 200 は必ず `dropped` を載せる(`server.mjs`)。載っていないのは「0件」ではなく「不明」。
            guard let n = dropped else {
                return .warn("Whether the cancel worked could not be confirmed. Check the screen.")
            }
            if n <= 0 { return .ok("There was nothing queued to cancel.") }
            // ★走っている番は止まらない事を必ず書く。省くと「取り消した = 全部止まった」と読める。
            return .ok("Cancelled \(n) queued sends (the one already running is not stopped).")
        }
        if status == 409 {
            let fallback = "Could not cancel."
            let e = (serverError ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return .refused(e.isEmpty ? fallback : e)
        }
        if status == 401 { return .error("The key was rejected.") }
        if status >= 500 { return .error("Server-side failure (HTTP \(status)).") }
        return .error("Unexpected response (HTTP \(status)).")
    }
}
