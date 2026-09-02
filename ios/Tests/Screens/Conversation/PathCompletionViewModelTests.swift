import XCTest
@testable import RemoteMini

/// `ConversationViewModel` の `@` 補完まわり(2026-09-02)。
///
/// ★測るのは「候補が出る」ではなく、**出さない・撃たない・捨てる**の3つ。
///   出る事は client の検査が既に持っていて、此処にしか無い性質は
///   「打鍵ごとに撃たない」「もう画面に無い問いの答えを置かない」だから。
@MainActor
final class PathCompletionViewModelTests: XCTestCase {

    /// 問いを記録し、待たされる補完の口。
    private final class RecordingPaths: PathCompleting {
        private(set) var queries: [String] = []
        private(set) var limits: [Int] = []
        var resultQueue: [Result<PathCompletionResponse, SessionsFetchError>] = []
        /// `MockURLProtocol.deliveryDelay` と同じ理由 —— 本当の中断点が無いと、
        /// 「飛んでいる最中」を覗く窓が開かない。
        var deliveryDelay: Duration = .zero

        func complete(
            baseURL: URL, apiKey: String, sessionID: String, query: String, limit: Int
        ) async -> Result<PathCompletionResponse, SessionsFetchError> {
            queries.append(query)
            limits.append(limit)
            if deliveryDelay > .zero { try? await Task.sleep(for: deliveryDelay) }
            guard !resultQueue.isEmpty else { return .failure(.unreachable) }
            return resultQueue.removeFirst()
        }
    }

    private struct SilentHistory: HistoryFetching {
        func fetch(baseURL: URL, apiKey: String, sessionID: String, limit: Int) async
            -> Result<HistoryResponse, SessionsFetchError> { .failure(.unreachable) }
        func search(baseURL: URL, apiKey: String, sessionID: String, limit: Int, query: String) async
            -> Result<TranscriptSearchResponse, SessionsFetchError> { .failure(.unreachable) }
    }

    private struct SilentPoll: PollFetching {
        func poll(baseURL: URL, apiKey: String, sessionID: String, cursor: PollCursor, waitMs: Int) async -> PollOutcome {
            try? await Task.sleep(for: .seconds(3600))
            return .cancelled
        }
    }

    private var unauthorizedCount = 0

    /// 待ちは**0 秒**を既定にする。250ms を本当に待つと、検査1本ごとに実時間が乗り、
    /// 遅い機械で落ちる非決定な検査になる(壁時計に結果を預けた検査は緑の理由を言えない)。
    private func makeViewModel(
        paths: PathCompleting,
        debounce: TimeInterval = 0
    ) -> ConversationViewModel {
        unauthorizedCount = 0
        return ConversationViewModel(
            // 書き込み側の3経路は木に在る作り物をそのまま使う(`WriteFixture`)。
            // 此の検査は1つも押さないので、返らない物で足りる —— 検査ごとに
            // 空の stub を書き足すと、本物の口が増えた日に此処だけが古くなる。
            clients: ConversationClients(
                history: SilentHistory(),
                poll: SilentPoll(),
                send: MessageSendingFixture(),
                interrupt: InterruptingFixture(),
                choice: ChoiceSendingFixture(),
                clearQueue: QueueClearingFixture(),
                paths: paths
            ),
            draftStore: InMemoryDraftStore(),
            baseURL: URL(string: "https://unit-test.invalid")!,
            apiKey: "unit-test-fixture-key-not-real",
            sessionID: "sess-0001",
            title: "t",
            onUnauthorized: { [weak self] in self?.unauthorizedCount += 1 },
            pathCompletionDebounce: debounce
        )
    }

    private func response(
        _ items: [PathSuggestion], truncated: Bool = false, reason: String? = nil
    ) -> Result<PathCompletionResponse, SessionsFetchError> {
        .success(PathCompletionResponse(paths: items, truncated: truncated, reason: reason))
    }

    /// 待ちを跨いだ `Task` が終わるまで譲る。回数で待つのは、待ちが 0 でも
    /// `Task.sleep(0)` と `await` が数回のスケジュール境界を作る為。
    private func settle(_ times: Int = 12) async {
        for _ in 0..<times { await Task.yield() }
    }

    // MARK: - 撃つ / 撃たない

    func testTypingAMentionAsksTheDeskForThatPrefix() async {
        let paths = RecordingPaths()
        paths.resultQueue = [response([PathSuggestion(path: "src/wire.mjs", kind: .file)])]
        let vm = makeViewModel(paths: paths)

        vm.draft = "見て @src/wi"
        await settle()

        XCTAssertEqual(paths.queries, ["src/wi"])
        XCTAssertEqual(paths.limits, [ConversationViewModel.pathCompletionLimit])
        XCTAssertEqual(vm.pathSuggestions, [PathSuggestion(path: "src/wire.mjs", kind: .file)])
    }

    /// ★書きかけの `@` が無い入力では**1回も撃たない**。之が無いと、普通に文を打つ間
    ///   ずっと机の fs を舐める事になる。
    func testOrdinaryTypingNeverAsksTheDesk() async {
        let paths = RecordingPaths()
        let vm = makeViewModel(paths: paths)

        vm.draft = "ふつうの"
        vm.draft = "ふつうの文を"
        vm.draft = "ふつうの文を打つ"
        await settle()

        XCTAssertEqual(paths.queries, [])
        XCTAssertTrue(vm.pathSuggestions.isEmpty)
    }

    /// ★★**待ってから撃つ**(此処が debounce の本体)。
    ///
    /// ★之は 2026-09-02 の変異 M10 が書かせた検査。下の
    ///   `testRapidTypingCollapsesToASingleRequest` を「debounce の本体」と呼んでいたが、
    ///   **待ちを丸ごと外しても緑のままだった** —— 3 回の代入は MainActor 上で
    ///   中断点を挟まずに走るので、前の `Task` は一度も実行されないまま取り消される。
    ///   つまりあれが測っているのは**取り消し**であって待ちではない。
    ///
    /// 待ちを測るには「まだ撃っていない事」を見るしかない: `Task.yield()` は
    /// 壁時計を進めないので、何度譲っても 200ms の待ちは跨げない。跨げたなら、
    /// それは待ちが無いという事。
    func testASingleKeystrokeDoesNotFireUntilTheDebounceElapses() async {
        let paths = RecordingPaths()
        paths.resultQueue = [response([PathSuggestion(path: "src", kind: .dir)])]
        let vm = makeViewModel(paths: paths, debounce: 0.2)

        vm.draft = "@s"
        await settle()
        XCTAssertEqual(paths.queries, [], "待たずに撃っている(debounce が効いていない)")

        try? await Task.sleep(nanoseconds: 400_000_000)
        await settle()
        XCTAssertEqual(paths.queries, ["s"], "待ちが明けても撃っていない")
    }

    /// ★前の要求を**捨てる**(取り消し)。上の待ちとは別の性質で、別の変異が当たる。
    func testRapidTypingCollapsesToASingleRequest() async {
        let paths = RecordingPaths()
        paths.resultQueue = [response([PathSuggestion(path: "src", kind: .dir)])]
        let vm = makeViewModel(paths: paths, debounce: 0.05)

        vm.draft = "@s"
        vm.draft = "@sr"
        vm.draft = "@src"
        // 最後の1本が待ちを抜けるまで待つ。前の2本は待ちの中で取り消される。
        try? await Task.sleep(nanoseconds: 250_000_000)
        await settle()

        XCTAssertEqual(paths.queries, ["src"], "打鍵ごとに撃っている: \(paths.queries)")
    }

    /// ★`@` を打った直後は**空の問い**で撃つ(机は cwd の直下を返す)。
    ///   撃たない実装にすると、一段目が永久に出ない = 入口が消える。
    func testABareAtAsksForTheTopLevel() async {
        let paths = RecordingPaths()
        paths.resultQueue = [response([PathSuggestion(path: "README.md", kind: .file)])]
        let vm = makeViewModel(paths: paths)

        vm.draft = "@"
        await settle()

        XCTAssertEqual(paths.queries, [""])
    }

    /// ★`@` が消えたら候補は**その場で**消える(待たない)。待つと、消した後も
    ///   250ms のあいだ古い候補が押せる = 消した筈の物を差せる。
    func testClearingTheMentionDropsTheSuggestionsImmediately() async {
        let paths = RecordingPaths()
        paths.resultQueue = [response([PathSuggestion(path: "src", kind: .dir)], truncated: true)]
        let vm = makeViewModel(paths: paths)

        vm.draft = "@src"
        await settle()
        XCTAssertFalse(vm.pathSuggestions.isEmpty)
        XCTAssertTrue(vm.pathSuggestionsTruncated)

        vm.draft = "@src と直して" // 空白が入った = 書き終えた
        XCTAssertTrue(vm.pathSuggestions.isEmpty, "候補が残っている")
        XCTAssertFalse(vm.pathSuggestionsTruncated, "「…」だけが残っている")
    }

    // MARK: - 遅れて着いた答え

    /// ★★**もう画面に無い問いの答えを置かない**。取り消しが間に合わなかった1本が
    ///   古い候補を並べると、押した瞬間に文が壊れる。
    func testALateAnswerForAnOldQueryIsDropped() async {
        let paths = RecordingPaths()
        let vm = makeViewModel(paths: paths)

        vm.draft = "@src/"
        // `@t` の頃の答えが今ごろ着いた、という形を直に作る。
        vm.applyPathSuggestions(response([PathSuggestion(path: "test", kind: .dir)]), query: "t")

        XCTAssertTrue(vm.pathSuggestions.isEmpty, "古い問いの答えが画面に乗っている")
    }

    func testTheAnswerForTheCurrentQueryIsApplied() async {
        let paths = RecordingPaths()
        let vm = makeViewModel(paths: paths)

        vm.draft = "@src/"
        vm.applyPathSuggestions(
            response([PathSuggestion(path: "src/wire.mjs", kind: .file)], truncated: true),
            query: "src/")

        XCTAssertEqual(vm.pathSuggestions, [PathSuggestion(path: "src/wire.mjs", kind: .file)])
        XCTAssertTrue(vm.pathSuggestionsTruncated)
    }

    // MARK: - 失敗の行き先

    /// ★取り消しでは面を触らない。触ると、速く打っている間じゅう候補が点滅する。
    func testCancellationLeavesTheCurrentSuggestionsAlone() async {
        let paths = RecordingPaths()
        let vm = makeViewModel(paths: paths)

        vm.draft = "@src/"
        vm.applyPathSuggestions(response([PathSuggestion(path: "src/wire.mjs", kind: .file)]), query: "src/")
        vm.applyPathSuggestions(.failure(.cancelled), query: "src/")

        XCTAssertEqual(vm.pathSuggestions, [PathSuggestion(path: "src/wire.mjs", kind: .file)])
    }

    /// ★届かない時は**古い候補を残さない**。補完は「今の机の中身」を名乗る物なので、
    ///   答えられない時に前の答えを出したままにすると、消えた file を差せる。
    func testAFailureClearsRatherThanLeavingStaleSuggestions() async {
        let paths = RecordingPaths()
        let vm = makeViewModel(paths: paths)

        vm.draft = "@src/"
        vm.applyPathSuggestions(response([PathSuggestion(path: "src/wire.mjs", kind: .file)]), query: "src/")
        vm.applyPathSuggestions(.failure(.unreachable), query: "src/")

        XCTAssertTrue(vm.pathSuggestions.isEmpty)
    }

    func testUnauthorizedExitsThroughTheSharedKeyPath() async {
        let paths = RecordingPaths()
        let vm = makeViewModel(paths: paths)

        vm.draft = "@src/"
        vm.applyPathSuggestions(.failure(.unauthorized), query: "src/")

        XCTAssertEqual(unauthorizedCount, 1)
        XCTAssertTrue(vm.pathSuggestions.isEmpty)
    }

    /// ★★`no_cwd` を貰ったら**以後 訊きに行かない**。会話の性質であって一時的な
    ///   不調ではないので、打鍵ごとに撃ち直しても答えは変わらない。
    func testNoWorkingDirectoryStopsAskingAltogether() async {
        let paths = RecordingPaths()
        paths.resultQueue = [
            response([], reason: PathCompletionReason.noCwd),
            response([PathSuggestion(path: "src", kind: .dir)]),
        ]
        let vm = makeViewModel(paths: paths)

        vm.draft = "@s"
        await settle()
        XCTAssertEqual(paths.queries, ["s"])
        XCTAssertTrue(vm.pathSuggestions.isEmpty)

        vm.draft = "@sr"
        await settle()
        XCTAssertEqual(paths.queries, ["s"], "作業場所が無い会話に訊き続けている")
    }

    /// ★対照: `cwd_unreadable` では**止めない**。あれは戻り得る(dir が復帰する)。
    func testAnUnreadableWorkingDirectoryDoesNotLatchOff() async {
        let paths = RecordingPaths()
        paths.resultQueue = [
            response([], reason: PathCompletionReason.unreadable),
            response([PathSuggestion(path: "src", kind: .dir)]),
        ]
        let vm = makeViewModel(paths: paths)

        vm.draft = "@s"
        await settle()
        vm.draft = "@sr"
        await settle()

        XCTAssertEqual(paths.queries, ["s", "sr"], "戻り得る不調で訊くのをやめている")
        XCTAssertEqual(vm.pathSuggestions, [PathSuggestion(path: "src", kind: .dir)])
    }

    // MARK: - 差し込み

    /// ★押しても**送らない**。入力欄が変わるだけ。
    func testPickingASuggestionOnlyEditsTheDraft() async {
        let paths = RecordingPaths()
        paths.resultQueue = [response([PathSuggestion(path: "src/wire.mjs", kind: .file)])]
        let vm = makeViewModel(paths: paths)

        vm.draft = "これ見て @src/wi"
        await settle()
        vm.applyPathSuggestion(PathSuggestion(path: "src/wire.mjs", kind: .file))

        XCTAssertEqual(vm.draft, "これ見て @src/wire.mjs ")
        XCTAssertTrue(vm.pathSuggestions.isEmpty, "選んだ後も候補列が残っている")
    }

    /// ★dir を押すと**一段 降りる**(次の問いが自動で飛ぶ)。
    func testPickingADirectoryImmediatelyAsksForItsChildren() async {
        let paths = RecordingPaths()
        paths.resultQueue = [
            response([PathSuggestion(path: "src", kind: .dir)]),
            response([PathSuggestion(path: "src/wire.mjs", kind: .file)]),
        ]
        let vm = makeViewModel(paths: paths)

        vm.draft = "@sr"
        await settle()
        vm.applyPathSuggestion(PathSuggestion(path: "src", kind: .dir))
        await settle()

        XCTAssertEqual(vm.draft, "@src/")
        XCTAssertEqual(paths.queries, ["sr", "src/"])
        XCTAssertEqual(vm.pathSuggestions, [PathSuggestion(path: "src/wire.mjs", kind: .file)])
    }
}
