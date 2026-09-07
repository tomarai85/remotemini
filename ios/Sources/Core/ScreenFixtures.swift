import Foundation

#if DEBUG
/// 画面台帳の為の fixture(2026-09-07)。`RC_UI_FIXTURE` に此の値が来たら `RootView` が其の画面を**根に据えて**描く
/// (一覧 / 会話の fixture と同じ作法。`ios/tools/shots.sh <state>` が headless で撮る)。
/// 之まで fixture が無かった 4 画面 —— Running(subagent)/ 差分 / 設定 / 保管庫 —— を UI 監査の台帳に載せる為。
/// ★製品の経路には一切触れない: 既定(環境変数なし)では `current` は nil で、何も変わらない。
/// ★本文は JSON の文字列でなく辞書で組む: 台帳の走査(`wire-key-agreement.test.mjs`)が Swift の brace を数えるので、
///   文字列の中の brace が型の境界を狂わせる。辞書なら brace が源に無い。
enum ScreenFixture: String {
    case subagentsRunning = "subagents-running"
    case subagentsMixed = "subagents-mixed"
    case subagentsEmpty = "subagents-empty"
    case diffSample = "diff-sample"
    case diffClean = "diff-clean"
    case settingsNormal = "settings-normal"
    case archivedSample = "archived-sample"

    static var current: ScreenFixture? {
        ProcessInfo.processInfo.environment["RC_UI_FIXTURE"].flatMap(ScreenFixture.init(rawValue:))
    }
}

/// 辞書 → JSON の bytes(机の実応答と同じ経路 = JSON を通す)。復号は各 fetch が自分の型で行う
/// (総称の補助関数を置くと、台帳の走査が其の `T: …` の行を型宣言と数えて狂う)。
private func fixtureData(_ object: [String: Any]) -> Data? {
    try? JSONSerialization.data(withJSONObject: object)
}

/// `GET /subagents` の代わり。形は机の `subagentsBody`(状態は 6 値)。
struct SubagentsListingFixture: SubagentsFetching {
    let state: ScreenFixture

    private static func row(_ id: String, _ description: String, _ state: String, _ reason: String, _ text: String, model: String = "claude-sonnet-5") -> [String: Any] {
        [
            "agentId": id, "agentType": "general-purpose", "description": description, "model": model,
            "state": state, "reason": reason, "meta": "read", "lastActivityIso": "2026-09-07T11:40:00.000Z",
            "display": ["state": text],
        ]
    }

    private static func counts(finished: Int = 0, running: Int = 0, stalled: Int = 0, unknown: Int = 0, stopped: Int = 0, failed: Int = 0) -> [String: Any] {
        ["finished": finished, "running": running, "stalled": stalled, "unknown": unknown, "stopped": stopped, "failed": failed]
    }

    private var object: [String: Any] {
        let blind = "Background shells and teammates are not listed here."
        switch state {
        case .subagentsRunning:
            return [
                "subagents": [
                    Self.row("a1", "count slowly", "running", "no-result-active", "Working"),
                    Self.row("a2", "count slowly", "running", "no-result-active", "Working"),
                    Self.row("a3", "Review the diff for #6", "finished", "parent-completed", "Finished", model: "claude-opus-5"),
                ],
                "directory": "read", "parent": "read", "truncated": false,
                "counts": Self.counts(finished: 1, running: 2),
                "display": ["note": "3 subagents, 2 working. \(blind)"],
            ]
        case .subagentsMixed:
            return [
                "subagents": [
                    Self.row("b1", "Security review of fleet scripts", "running", "no-result-active", "Working", model: "claude-opus-5"),
                    Self.row("b2", "count slowly", "stopped", "stopped-by-desk", "Stopped"),
                    Self.row("b3", "Implement the transcript search UI", "failed", "agent-failed", "Failed"),
                    Self.row("b4", "Warm-floor segmentation", "stalled", "no-result-idle", "No sign of life recently"),
                ],
                "directory": "read", "parent": "read", "truncated": false,
                "counts": Self.counts(running: 1, stalled: 1, stopped: 1, failed: 1),
                "display": ["note": "4 subagents, 1 working, 1 stopped, 1 failed, 1 with no recent sign of life. \(blind)"],
            ]
        default:
            return [
                "subagents": [],
                "directory": "absent", "parent": "unscanned", "truncated": false,
                "counts": Self.counts(),
                "display": ["note": "This session has no subagents. \(blind)"],
            ]
        }
    }

    func fetch(baseURL: URL, apiKey: String, sessionID: String) async -> Result<SubagentsBody, SessionsFetchError> {
        guard let data = fixtureData(object), let body = try? JSONDecoder().decode(SubagentsBody.self, from: data) else { return .failure(.unreachable) }
        return .success(body)
    }

    /// 撮影では押さない。押されても机には届かない(fixture)。
    func stop(baseURL: URL, apiKey: String, sessionID: String, agentID: String) async -> Result<SubagentStopBody, SessionsFetchError> {
        .failure(.unreachable)
    }
}

/// `GET /diff` の代わり。形は `DiffModelsTests` の実応答。
struct DiffListingFixture: DiffFetching {
    let state: ScreenFixture

    private static func line(_ kind: String, _ text: String) -> [String: Any] { ["kind": kind, "text": text] }

    private static func file(_ path: String, staged: Bool, binary: Bool = false, added: Int, removed: Int, hunks: [[String: Any]]) -> [String: Any] {
        ["path": path, "staged": staged, "binary": binary, "added": added, "removed": removed, "truncated": false, "hunks": hunks]
    }

    private var object: [String: Any] {
        switch state {
        case .diffClean:
            return ["files": [], "truncated": false, "totalBytes": 0, "reason": NSNull()]
        default:
            return [
                "files": [
                    Self.file("rc-backend/src/subagents.mjs", staged: false, added: 7, removed: 2, hunks: [[
                        "header": "@@ -139,6 +139,11 @@ function completionsIn(records)",
                        "lines": [
                            Self.line("ctx", "  const terminal = new Map();"),
                            Self.line("ctx", "  const launched = new Set();"),
                            Self.line("del", "  const done = new Set();"),
                            Self.line("add", "  // 終端は id ごとに最後の記録が勝つ"),
                            Self.line("add", "  const killed = new Map();"),
                            Self.line("add", "  const failed = new Map();"),
                            Self.line("ctx", "  for (const rec of records)"),
                        ],
                    ]]),
                    Self.file("ios/Sources/Core/SubagentModels.swift", staged: true, added: 2, removed: 0, hunks: [[
                        "header": "@@ -42,6 +42,8 @@ struct SubagentCounts",
                        "lines": [
                            Self.line("ctx", "    let unknown: Int"),
                            Self.line("add", "    let stopped: Int?"),
                            Self.line("add", "    let failed: Int?"),
                        ],
                    ]]),
                    Self.file("ios/Assets.xcassets/AppIcon.appiconset/icon.png", staged: false, binary: true, added: 0, removed: 0, hunks: []),
                ],
                "truncated": false, "totalBytes": 2140, "reason": NSNull(),
            ]
        }
    }

    func fetch(baseURL: URL, apiKey: String, sessionID: String) async -> Result<SessionDiffBody, SessionsFetchError> {
        guard let data = fixtureData(object), let body = try? JSONDecoder().decode(SessionDiffBody.self, from: data) else { return .failure(.unreachable) }
        return .success(body)
    }
}
#endif
