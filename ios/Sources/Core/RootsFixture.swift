import Foundation

#if DEBUG

/// roots の口の作り物(UI 検査 / スクリーンショット用、2026-09-03、対照表 #11)。`DiffFetchingFixture` と同じ形。
///
/// 3 状態 = fixture 1 状態につき UI 検査 1 本:
///   - `roots-sample`  = root 2 本。`~/Infra` の下に `ios` / `rc-backend` / `research`(`ios` の下に更に 2 つ)、
///                       `~/Personal` は空。`start` は受け付ける。
///   - `roots-none`    = 台帳が無い(`roots: []` + `no_roots`)。
///   - `roots-outside` = 一覧と補完は sample と同じで、`start` だけ `outside_roots` を返す。
final class RootsBrowsingFixture: RootsBrowsing {
    enum State: String {
        case sample = "roots-sample"
        case none = "roots-none"
        case outside = "roots-outside"
    }

    let state: State
    /// 検査が「押しても送らない」を数える為の記録(dir を押しただけで増えてはいけない)。
    private(set) var startCalls: [(rootIndex: Int, path: String)] = []

    init(state: State) { self.state = state }

    /// `RC_UI_ROOTS_FIXTURE` を読む —— `RC_UI_FIXTURE` に相乗りさせない(`RC_UI_DIFF_FIXTURE` と同じ理由:
    /// 複数の fixture が 1 つの綴りを取り合うと、片方が変えたら他方も黙って変わる)。
    static func fromEnvironment() -> RootsBrowsingFixture? {
        guard let raw = ProcessInfo.processInfo.environment["RC_UI_ROOTS_FIXTURE"],
              let state = State(rawValue: raw) else { return nil }
        return RootsBrowsingFixture(state: state)
    }

    private static let sampleRoots = [DeskRoot(index: 0, label: "~/Infra"), DeskRoot(index: 1, label: "~/Personal")]
    private static let sampleDirs: [Int: [String]] = [
        0: ["ios", "rc-backend", "research", "ios/Sources", "ios/Tests", "rc-backend/src"],
        1: [],
    ]

    func list(baseURL: URL, apiKey: String) async -> Result<RootsResponse, SessionsFetchError> {
        switch state {
        case .none: return .success(RootsResponse(roots: [], reason: RootsWire.noRoots))
        case .sample, .outside: return .success(RootsResponse(roots: Self.sampleRoots, reason: nil))
        }
    }

    func paths(baseURL: URL, apiKey: String, rootIndex: Int, query: String, limit: Int) async -> Result<PathCompletionResponse, SessionsFetchError> {
        guard let dirs = Self.sampleDirs[rootIndex] else {
            return .failure(.contractViolation(ResponseContractViolation(status: 404, code: nil)))
        }
        let hits = dirs.filter { $0.hasPrefix(query) }.prefix(limit).map { PathSuggestion(path: $0, kind: .dir) }
        return .success(PathCompletionResponse(paths: Array(hits), truncated: false, reason: nil))
    }

    func start(baseURL: URL, apiKey: String, rootIndex: Int, path: String) async -> StartInRootOutcome {
        startCalls.append((rootIndex, path))
        switch state {
        case .none: return .noRoots
        case .outside: return .outsideRoots
        case .sample: return .started
        }
    }
}

#endif
