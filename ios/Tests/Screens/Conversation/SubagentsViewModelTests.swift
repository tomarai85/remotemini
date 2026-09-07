import XCTest
@testable import RemoteMini

/// `SubagentsViewModel` の止める側(対照表 #8「半分その二」、2026-09-06)。
/// 規則: 1 回目のタップは構えるだけ(送らない)/ 同じ行の 2 回目で送る / 別の行なら構えが移る /
/// 走っていない行は何もしない / 断りは机の文をそのまま / 送った後は読み直す(帯は残る)。
@MainActor
final class SubagentsViewModelTests: XCTestCase {
    private final class FakeClient: SubagentsFetching {
        var listing: SubagentsBody
        var stopResults: [Result<SubagentStopBody, SessionsFetchError>] = []
        var stopCalls: [String] = []
        var fetchCalls = 0
        init(listing: SubagentsBody) { self.listing = listing }
        func fetch(baseURL: URL, apiKey: String, sessionID: String) async -> Result<SubagentsBody, SessionsFetchError> {
            fetchCalls += 1
            return .success(listing)
        }
        func stop(baseURL: URL, apiKey: String, sessionID: String, agentID: String) async -> Result<SubagentStopBody, SessionsFetchError> {
            stopCalls.append(agentID)
            return stopResults.isEmpty ? .failure(.unreachable) : stopResults.removeFirst()
        }
    }

    private static func row(_ id: String, state: String = "running", description: String = "count slowly") -> SubagentRow {
        let json = """
        { "agentId": "\(id)", "agentType": "general-purpose", "description": "\(description)", "model": null,
          "state": "\(state)", "reason": "no-result-active", "meta": "read", "lastActivityIso": null,
          "display": { "state": "Working" } }
        """
        return try! JSONDecoder().decode(SubagentRow.self, from: Data(json.utf8))
    }
    private static func listing(_ rows: [SubagentRow]) -> SubagentsBody {
        let json = """
        { "subagents": [], "directory": "read", "parent": "read", "truncated": false,
          "counts": { "finished": 0, "running": \(rows.count), "stalled": 0, "unknown": 0 },
          "display": { "note": "\(rows.count) subagents." } }
        """
        var body = try! JSONDecoder().decode(SubagentsBody.self, from: Data(json.utf8))
        body = SubagentsBody(subagents: rows, directory: body.directory, parent: body.parent, truncated: body.truncated, counts: body.counts, display: body.display)
        return body
    }
    private static let observed = SubagentStopBody(stopped: true, reason: nil, error: nil, sent: true, escapes: 1, target: SubagentStopTarget(agentId: "a1", description: "count slowly"))
    private static let refused = SubagentStopBody(stopped: false, reason: "ambiguous", error: "More than one running agent has this exact description and nothing on the desk tells them apart. Nothing was pressed.", sent: false, escapes: 1, target: nil)

    /// 検査用の時計: 既定は「構えから 1 秒後」に進んでいる(構え→確認の最短間隔 0.5 s を越える)。
    private var clock = Date(timeIntervalSince1970: 1_000_000)
    private func makeVM(_ client: FakeClient) -> SubagentsViewModel {
        SubagentsViewModel(client: client, baseURL: URL(string: "https://unit-test.invalid")!, apiKey: "k", sessionID: "s", now: { [self] in
            clock.addTimeInterval(1.0)
            return clock
        })
    }
    private func makeVMFrozenClock(_ client: FakeClient) -> SubagentsViewModel {
        let fixed = Date(timeIntervalSince1970: 1_000_000)
        return SubagentsViewModel(client: client, baseURL: URL(string: "https://unit-test.invalid")!, apiKey: "k", sessionID: "s", now: { fixed })
    }

    func testFirstTapOnlyArmsAndSendsNothing() async {
        let client = FakeClient(listing: Self.listing([Self.row("a1"), Self.row("a2")]))
        let vm = makeVM(client)
        await vm.load()
        await vm.tapStop(Self.row("a1"))
        XCTAssertEqual(vm.armed, "a1")
        XCTAssertEqual(client.stopCalls, [], "1 回目のタップで送ってはいけない")
        XCTAssertNil(vm.stopNotice)
    }

    func testSecondTapOnTheSameRowSendsOnceAndReloads() async {
        let client = FakeClient(listing: Self.listing([Self.row("a1"), Self.row("a2")]))
        client.stopResults = [.success(Self.observed)]
        let vm = makeVM(client)
        await vm.load()
        await vm.tapStop(Self.row("a1"))
        await vm.tapStop(Self.row("a1"))
        XCTAssertEqual(client.stopCalls, ["a1"])
        XCTAssertNil(vm.armed)
        XCTAssertNil(vm.stopping)
        XCTAssertEqual(vm.stopNotice, "Stopped “count slowly”.")
        XCTAssertEqual(client.fetchCalls, 2, "送った後は一覧を読み直す")
        XCTAssertEqual(vm.stopNotice, "Stopped “count slowly”.", "読み直しても帯は残る")
    }

    func testTappingAnotherRowMovesTheArmingInsteadOfSending() async {
        let client = FakeClient(listing: Self.listing([Self.row("a1"), Self.row("a2")]))
        let vm = makeVM(client)
        await vm.load()
        await vm.tapStop(Self.row("a1"))
        await vm.tapStop(Self.row("a2"))
        XCTAssertEqual(vm.armed, "a2")
        XCTAssertEqual(client.stopCalls, [])
        vm.disarm()
        XCTAssertNil(vm.armed)
    }

    func testRefusalShowsTheDeskSentenceVerbatimAndDoesNotRearm() async {
        let client = FakeClient(listing: Self.listing([Self.row("a1"), Self.row("a2")]))
        client.stopResults = [.success(Self.refused)]
        let vm = makeVM(client)
        await vm.load()
        await vm.tapStop(Self.row("a1"))
        await vm.tapStop(Self.row("a1"))
        XCTAssertEqual(vm.stopNotice, Self.refused.error)
        XCTAssertNil(vm.armed)
        XCTAssertEqual(client.stopCalls, ["a1"], "断られても撃ち直さない")
    }

    func testARowThatIsNotRunningNeverArmsNorSends() async {
        let client = FakeClient(listing: Self.listing([Self.row("a1", state: "finished")]))
        let vm = makeVM(client)
        await vm.load()
        await vm.tapStop(Self.row("a1", state: "finished"))
        await vm.tapStop(Self.row("a1", state: "finished"))
        XCTAssertNil(vm.armed)
        XCTAssertEqual(client.stopCalls, [])
    }

    func testTwoTapsInsideTheConfirmDelayAreOneGestureAndDoNotSend() async {
        // 研究レビュー 2026-09-07 #1: 一動作の二度打ちで構え+送信にならない。
        let client = FakeClient(listing: Self.listing([Self.row("a1")]))
        client.stopResults = [.success(Self.observed)]
        let vm = makeVMFrozenClock(client)
        await vm.load()
        await vm.tapStop(Self.row("a1"))
        await vm.tapStop(Self.row("a1"))
        XCTAssertEqual(client.stopCalls, [], "構えの直後の 2 回目は送らない")
        XCTAssertEqual(vm.armed, "a1", "構えは残る(意図が続いていれば次のタップで送れる)")
    }

    func testAfterAStopTheRowLosesItsButtonEvenIfTheDeskStillSaysRunning() async {
        // 研究レビュー 2026-09-07 #3: 「Stopped」の帯の下に「Working」+「Stop」が出て再タップを誘わない。
        let client = FakeClient(listing: Self.listing([Self.row("a1"), Self.row("a2")]))
        client.stopResults = [.success(Self.observed)]
        let vm = makeVM(client)
        await vm.load()
        XCTAssertTrue(vm.canStop(Self.row("a1")))
        await vm.tapStop(Self.row("a1"))
        await vm.tapStop(Self.row("a1"))
        XCTAssertEqual(client.stopCalls, ["a1"])
        XCTAssertFalse(vm.canStop(Self.row("a1")), "止めた id にはボタンを出さない(行が running に見えても)")
        XCTAssertTrue(vm.canStop(Self.row("a2")), "隣の行は止められる")
        await vm.tapStop(Self.row("a1"))
        await vm.tapStop(Self.row("a1"))
        XCTAssertEqual(client.stopCalls, ["a1"], "止めた id へは二度と送らない")
    }

    func testTransportFailureShowsTheFixedSentence() async {
        let client = FakeClient(listing: Self.listing([Self.row("a1")]))
        client.stopResults = [.failure(.unreachable)]
        let vm = makeVM(client)
        await vm.load()
        await vm.tapStop(Self.row("a1"))
        await vm.tapStop(Self.row("a1"))
        XCTAssertEqual(vm.stopNotice, "Couldn't reach the desk.")
        XCTAssertNil(vm.stopping)
    }
}
