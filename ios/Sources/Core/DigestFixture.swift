import Foundation

#if DEBUG

/// UI 検査用の、留守中の要約の作り物。2026-08-26 新設。
///
/// ★**読み取り側**なので `WriteFixture` の「返らない」規約は採らない。あちらが返らないのは
///   「飛んでいる間」を撮る為で、要約は**開いた瞬間に読める物**が要る。倣う相手は
///   `HistoryFixture` / `PollFixture` の側。
///
/// ★本文は**手で組んでいない**。`rc-backend/src/digest.mjs` を Friday の上で実際に走らせた
///   出力(`DigestClientTests` と同じ検体)。手で組んだ本文は「電話が読める形」しか
///   検査せず、**机が本当に其の形を出すか**を一度も測らない。
///
/// ★既定を「読めた窓」にするのは、UI 検査で撮りたいのが**普通に読めている画面**だから。
///   「読めなかった窓」を撮りたい時は `state:` で名指しする —— 既定を曖昧な方に置くと、
///   撮った画は「たまたまその状態だった」になり、何を証明した画か分からなくなる。
struct DigestFetchingFixture: DigestFetching {
    enum State {
        /// 窓を全部読めた。件数が在る。
        case complete
        /// 窓を全部読めなかった。**`counts` は nil で来る**(0 ではない)。
        case incomplete
        /// 机が答えを待っている。画面が急かす側。
        case waiting
    }

    let state: State

    init(state: State = .complete) { self.state = state }

    func fetch(baseURL: URL, apiKey: String, sessionID: String) async
        -> Result<SessionDigest, SessionsFetchError>
    {
        guard let d = try? DigestParser.parse(Data(Self.body(for: state).utf8)) else {
            // 検体が壊れていたら**黙って別の物を返さない**。作り物が嘘をつくと、
            // 撮った画も検査も全部その嘘の上に乗る。
            return .failure(.malformedBody)
        }
        return .success(d)
    }

    // 2026-08-26、Friday 上の `digestOf` の実出力。
    private static func body(for state: State) -> String {
        switch state {
        case .complete:
            return """
            {"digest":{"complete":true,"incompleteReason":null,"window":{"requestedFromIso":"2026-08-26T11:00:00.000Z","observedFromIso":"2026-08-26T11:01:00.000Z","toIso":"2026-08-26T12:00:00.000Z","minutes":60},"counts":{"user":1,"assistant":1,"tool":1},"tools":[{"name":"Read","n":1}],"fileTargets":["/a/b.txt"],"fileTargetsTotal":1,"lastAssistant":"done","lastAt":"2026-08-26T11:02:00.000Z"},"attention":"none","action":{"level":"none","reason":"observed"},"line":"60m · 1 replies · 1 tool calls · 1 file targets — nothing waiting on you."}
            """
        case .incomplete:
            return """
            {"digest":{"complete":false,"incompleteReason":"scan-budget","window":{"requestedFromIso":"2026-08-26T11:00:00.000Z","observedFromIso":null,"toIso":"2026-08-26T12:00:00.000Z","minutes":60},"counts":null,"tools":null,"fileTargets":null,"fileTargetsTotal":null,"lastAssistant":"done","lastAt":"2026-08-26T11:02:00.000Z"},"attention":"unknown","action":{"level":"unknown","reason":"screen-unreadable"},"line":"Could not read the whole window — counts withheld on purpose — cannot tell if it needs you (screen-unreadable)."}
            """
        case .waiting:
            return """
            {"digest":{"complete":true,"incompleteReason":null,"window":{"requestedFromIso":"2026-08-26T11:00:00.000Z","observedFromIso":null,"toIso":"2026-08-26T12:00:00.000Z","minutes":60},"counts":{"user":0,"assistant":0,"tool":0},"tools":[],"fileTargets":[],"fileTargetsTotal":0,"lastAssistant":null,"lastAt":null},"attention":"input","action":{"level":"soon","reason":"input"},"line":"60m · 0 replies · 0 tool calls — stopped, needs a message."}
            """
        }
    }
}

#endif
