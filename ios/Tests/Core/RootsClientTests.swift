import XCTest
@testable import RemoteMini

/// roots の口の**復号と分岐**、そして **request の形**(対照表 #11、2026-09-03)。
/// 線の形は机の `rootsBody` / `rootsroute.mjs` と対。request の 5 次元(URL / method / header / body / timeout)は
/// `MockURLProtocol` の記録欄で見る(`request-shape.test.mjs` が「見ていない次元」を赤にする)。
final class RootsClientTests: XCTestCase {
    private let baseURL = URL(string: "https://unit-test.invalid")!

    override func setUp() { MockURLProtocol.reset() }
    override func tearDown() { MockURLProtocol.reset() }

    // MARK: - 要求の形

    func testListIsAGETOfApiRootsWithTheBearerKeyAndTheReadTimeout() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(#"{"roots":[],"reason":"no_roots"}"#.utf8))]
        let r = await RootsClient(session: MockURLProtocol.makeSession()).list(baseURL: baseURL, apiKey: "correct-fixture-key")
        XCTAssertEqual(MockURLProtocol.requestedURLs.last?.path, "/api/roots")
        XCTAssertEqual(MockURLProtocol.requestedMethods.last, "GET")
        XCTAssertEqual(MockURLProtocol.lastRequestHeaders?["Authorization"], "Bearer correct-fixture-key")
        XCTAssertEqual(MockURLProtocol.requestedTimeouts.last, BackendSession.interactiveTimeout, "読む口は interactiveTimeout")
        let body = MockURLProtocol.requestedBodies.last ?? nil
        XCTAssertTrue(body == nil || body?.isEmpty == true, "GET に本文を付けている")
        guard case .success(let decoded) = r else { return XCTFail("\(r)") }
        XCTAssertTrue(decoded.hasNoRoots)
    }

    func testPathsAddressesTheRootByIndexAndAlwaysSendsTheQuery() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(#"{"paths":[{"path":"ios","kind":"dir"}],"truncated":false,"reason":null}"#.utf8))]
        let r = await RootsClient(session: MockURLProtocol.makeSession())
            .paths(baseURL: baseURL, apiKey: "k", rootIndex: 2, query: "", limit: 80)
        let url = MockURLProtocol.requestedURLs.last
        XCTAssertEqual(url?.path, "/api/roots/2/paths")
        let items = URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first(where: { $0.name == "q" })?.value, "", "空の問いでも `q=` を送る(空 = 直下だけ、が入口)")
        XCTAssertEqual(items.first(where: { $0.name == "limit" })?.value, "80")
        XCTAssertEqual(MockURLProtocol.requestedMethods.last, "GET")
        XCTAssertEqual(MockURLProtocol.requestedTimeouts.last, BackendSession.interactiveTimeout)
        guard case .success(let decoded) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(decoded.paths.map(\.path), ["ios"])
    }

    func testStartIsAPOSTWithTheRelativePathAsJSONAndTheWriteTimeout() async throws {
        MockURLProtocol.stubQueue = [.init(statusCode: 202, body: Data(#"{"started":true,"window":"@9","pane":"%9"}"#.utf8))]
        let outcome = await RootsClient(session: MockURLProtocol.makeSession())
            .start(baseURL: baseURL, apiKey: "correct-fixture-key", rootIndex: 0, path: "ios/Sources")
        XCTAssertEqual(outcome, .started)
        XCTAssertEqual(MockURLProtocol.requestedURLs.last?.path, "/api/roots/0/new")
        XCTAssertEqual(MockURLProtocol.requestedMethods.last, "POST")
        XCTAssertEqual(MockURLProtocol.lastRequestHeaders?["Authorization"], "Bearer correct-fixture-key")
        XCTAssertEqual(MockURLProtocol.lastRequestHeaders?["Content-Type"], "application/json")
        XCTAssertEqual(MockURLProtocol.requestedTimeouts.last, BackendSession.writeTimeout, "始める口は writeTimeout")
        let body = try XCTUnwrap(MockURLProtocol.requestedBodies.last ?? nil)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(json, ["path": "ios/Sources"], "本文は root からの相対 path 1 鍵だけ(絶対 path を送らない)")
    }

    func testTheDeskReasonSurvivesOn400() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 400, body: Data(#"{"error":"outside the desk roots","reason":"outside_roots"}"#.utf8))]
        let outcome = await RootsClient(session: MockURLProtocol.makeSession())
            .start(baseURL: baseURL, apiKey: "k", rootIndex: 0, path: "../x")
        XCTAssertEqual(outcome, .outsideRoots)
    }

    // MARK: - 答えの読み方


    func testRootsResponseDecodesIndexAndLabelOnly() throws {
        let json = #"{"roots":[{"index":0,"label":"~/Infra"},{"index":1,"label":"/opt/w"}],"reason":null}"#
        let r = try JSONDecoder().decode(RootsResponse.self, from: Data(json.utf8))
        XCTAssertEqual(r.roots, [DeskRoot(index: 0, label: "~/Infra"), DeskRoot(index: 1, label: "/opt/w")])
        XCTAssertNil(r.reason)
        XCTAssertFalse(r.hasNoRoots)
        // 机が余計な鍵(例: path)を足しても読めるが、電話は其れを持たない = 型に欄が無い
        let extra = #"{"roots":[{"index":0,"label":"~/Infra","path":"/Users/x/Infra"}],"reason":null}"#
        XCTAssertEqual(try JSONDecoder().decode(RootsResponse.self, from: Data(extra.utf8)).roots.first?.label, "~/Infra")
        let none = try JSONDecoder().decode(RootsResponse.self, from: Data(#"{"roots":[],"reason":"no_roots"}"#.utf8))
        XCTAssertTrue(none.hasNoRoots)
    }

    func testMissingRootsKeyFailsDecodingInsteadOfShowingAnEmptyList() {
        XCTAssertThrowsError(try JSONDecoder().decode(RootsResponse.self, from: Data(#"{"reason":null}"#.utf8)),
                             "`roots` が無い応答を空の一覧と読むと「台帳が空」の嘘になる")
        XCTAssertThrowsError(try JSONDecoder().decode(RootsResponse.self, from: Data(#"{"roots":[{"label":"x"}]}"#.utf8)),
                             "index の無い root は指せない")
    }

    func testStartOutcomeMapsStatusAndReason() {
        XCTAssertEqual(StartInRootOutcome.from(status: 202, reason: nil), .started)
        XCTAssertEqual(StartInRootOutcome.from(status: 400, reason: "outside_roots"), .outsideRoots)
        XCTAssertEqual(StartInRootOutcome.from(status: 400, reason: "no_roots"), .noRoots)
        XCTAssertEqual(StartInRootOutcome.from(status: 409, reason: "cwd_gone"), .cwdGone)
        XCTAssertEqual(StartInRootOutcome.from(status: 404, reason: nil), .rootGone)
        XCTAssertEqual(StartInRootOutcome.from(status: 401, reason: nil), .unauthorized)
        XCTAssertEqual(StartInRootOutcome.from(status: 502, reason: "tmux_failed"), .deskRefused)
        XCTAssertEqual(StartInRootOutcome.from(status: 500, reason: nil), .unreachable)
        // 文は全部 1 行で、改行(= Enter)を含まない
        for o in [StartInRootOutcome.started, .outsideRoots, .noRoots, .cwdGone, .rootGone, .deskRefused, .unauthorized, .unreachable] {
            XCTAssertFalse(o.text.isEmpty); XCTAssertFalse(o.text.contains("\n"))
        }
        XCTAssertEqual(StartInRootOutcome.started.text, NewSessionOutcome.started.text, "始まった時の文は既存の口と同じ")
    }

    func testUnknownReasonOn400FallsBackToUnreachableRatherThanStarted() {
        XCTAssertEqual(StartInRootOutcome.from(status: 400, reason: "bad_body"), .unreachable)
        XCTAssertEqual(StartInRootOutcome.from(status: 400, reason: nil), .unreachable)
        XCTAssertNotEqual(StartInRootOutcome.from(status: 400, reason: "something_new"), .started)
    }
}
