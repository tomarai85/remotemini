import XCTest
@testable import RemoteMini

/// `AttachClient.attach` — 2026-08-26。
///
/// この suite が中心に据える性質は1つだけで、他の client とは違う所にある:
/// **「置けた」と「入力欄に載った」は別の事実で、混ぜてはいけない。**
///
/// 机の tmux が居ない時、画像は正しく保存されているのにパスは差し込まれない。
/// そこを「送れました」に丸めると、Tom は入力欄を見て「消えた」と思う ——
/// この repo が `interrupted` / `stopped` や `accepted` / `applied` で
/// 繰り返し守ってきた線と同じ形。だから検査の重心は文言と分岐に置いてある。
final class AttachClientTests: XCTestCase {
    private let baseURL = URL(string: "https://unit-test.invalid")!
    private let png = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])

    override func setUp() { MockURLProtocol.reset() }
    override func tearDown() { MockURLProtocol.reset() }

    // MARK: - 要求の形

    func testRequestIsAPOSTOfTheRawBytesWithTheBearerKey() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(Self.storedBody.utf8))]

        _ = await AttachClient(session: MockURLProtocol.makeSession())
            .attach(baseURL: baseURL, apiKey: "correct-fixture-key", sessionID: "sess-abc-123", image: png)

        XCTAssertEqual(MockURLProtocol.requestedURLs.last?.path, "/api/sessions/sess-abc-123/attach")
        XCTAssertEqual(MockURLProtocol.requestedMethods.last, "POST")
        XCTAssertEqual(MockURLProtocol.lastRequestHeaders?["Authorization"], "Bearer correct-fixture-key")
    }

    /// ★multipart にしない。単一利用者・単一ファイルなので境界を組む理由が無く、
    /// 組めば「境界の解析」という壊れ方を1つ増やすだけになる。
    func testBodyIsTheImageItselfNotAnEnvelope() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(Self.storedBody.utf8))]

        _ = await AttachClient(session: MockURLProtocol.makeSession())
            .attach(baseURL: baseURL, apiKey: "k", sessionID: "s", image: png)

        XCTAssertEqual(MockURLProtocol.requestedBodies.last ?? nil, png)
        XCTAssertEqual(MockURLProtocol.requestedBodies.count, 1)
    }

    /// ★書き込みの既定より長く待つ。本文が大きく、机側で HEIC の変換まで走るので、
    /// 既定のままだと**変換が終わる前に電話が諦める** = 置けているのに失敗に見える。
    func testTimeoutIsLongerThanAnOrdinaryWrite() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(Self.storedBody.utf8))]

        _ = await AttachClient(session: MockURLProtocol.makeSession())
            .attach(baseURL: baseURL, apiKey: "k", sessionID: "s", image: png)

        let t = MockURLProtocol.requestedTimeouts.last
        XCTAssertNotNil(t)
        XCTAssertGreaterThanOrEqual(t ?? 0, BackendSession.writeTimeout)
        XCTAssertGreaterThanOrEqual(t ?? 0, 60)
    }

    // MARK: - ★置けた / 載った の分離(この suite の本題)

    func testInjectedTrueSaysThePathIsInTheComposer() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(Self.storedBody.utf8))]
        let out = await AttachClient(session: MockURLProtocol.makeSession())
            .attach(baseURL: baseURL, apiKey: "k", sessionID: "s", image: png)

        guard case let .stored(id, _, _, injected, _) = out else { return XCTFail("\(out)") }
        XCTAssertEqual(id, "abc123")
        XCTAssertTrue(injected)
        XCTAssertTrue(AttachWording.text(for: out).contains("composer"))
    }

    /// ★保存されたのに載っていない時、「送れました」と言わない。
    func testStoredButNotInjectedNeverClaimsItWasSent() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(Self.notInjectedBody.utf8))]
        let out = await AttachClient(session: MockURLProtocol.makeSession())
            .attach(baseURL: baseURL, apiKey: "k", sessionID: "s", image: png)

        guard case let .stored(_, _, _, injected, reason) = out else { return XCTFail("\(out)") }
        XCTAssertFalse(injected)
        XCTAssertEqual(reason, "tmux-unavailable")

        let text = AttachWording.text(for: out)
        XCTAssertFalse(text.contains("Photo sent"), "載っていないのに送れたと言った: \(text)")
        XCTAssertTrue(text.contains("could not be typed"), text)
        XCTAssertTrue(text.contains("tmux-unavailable"), "理由を落とした: \(text)")
    }

    func testConversionIsNamedSoTheUserKnowsTheFileChanged() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(Self.convertedBody.utf8))]
        let out = await AttachClient(session: MockURLProtocol.makeSession())
            .attach(baseURL: baseURL, apiKey: "k", sessionID: "s", image: png)
        XCTAssertTrue(AttachWording.text(for: out).contains("JPEG"))
    }

    // MARK: - 断りの理由を潰さない

    func testEachRejectionReasonGetsItsOwnSentence() async {
        let cases: [(String, String)] = [
            ("unknown-format", "not a PNG"),
            ("too-many-pixels", "too large in pixels"),
            ("too-large", "too big"),
            ("empty-body", "Nothing was attached"),
        ]
        for (reason, expect) in cases {
            MockURLProtocol.reset()
            MockURLProtocol.stubQueue = [.init(statusCode: 400,
                body: Data("{\"error\":\"ATTACH_REJECTED\",\"reason\":\"\(reason)\"}".utf8))]
            let out = await AttachClient(session: MockURLProtocol.makeSession())
                .attach(baseURL: baseURL, apiKey: "k", sessionID: "s", image: png)
            XCTAssertEqual(out, .rejected(reason: reason))
            XCTAssertTrue(AttachWording.text(for: out).contains(expect),
                          "\(reason) -> \(AttachWording.text(for: out))")
        }
    }

    /// ★知らない理由でも**理由そのものを見せる**。「失敗しました」に丸めると、
    /// 撮り直せば直るのか諦めるのかが利用者に判らない。
    func testAnUnknownReasonIsStillCarriedToTheUser() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 400,
            body: Data("{\"error\":\"ATTACH_REJECTED\",\"reason\":\"brand-new-thing\"}".utf8))]
        let out = await AttachClient(session: MockURLProtocol.makeSession())
            .attach(baseURL: baseURL, apiKey: "k", sessionID: "s", image: png)
        XCTAssertTrue(AttachWording.text(for: out).contains("brand-new-thing"))
    }

    // MARK: - 回復の分岐

    func testUnauthorizedAndNotFoundAndTooLargeAreTheirOwnCases() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 401, body: Data())]
        var out = await AttachClient(session: MockURLProtocol.makeSession())
            .attach(baseURL: baseURL, apiKey: "k", sessionID: "s", image: png)
        XCTAssertEqual(out, .unauthorized)

        MockURLProtocol.reset()
        MockURLProtocol.stubQueue = [.init(statusCode: 413, body: Data())]
        out = await AttachClient(session: MockURLProtocol.makeSession())
            .attach(baseURL: baseURL, apiKey: "k", sessionID: "s", image: png)
        XCTAssertEqual(out, .tooLarge)

        MockURLProtocol.reset()
        MockURLProtocol.stubQueue = [.init(statusCode: 404,
            body: Data("{\"code\":\"SESSION_NOT_FOUND\"}".utf8))]
        out = await AttachClient(session: MockURLProtocol.makeSession())
            .attach(baseURL: baseURL, apiKey: "k", sessionID: "s", image: png)
        XCTAssertEqual(out, .sessionNotFound)
    }

    /// 200 なのに id が無い = 知らない形。**成功に丸めない。**
    func testATwoHundredWithoutAnIdIsAContractViolation() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data("{\"ok\":true}".utf8))]
        let out = await AttachClient(session: MockURLProtocol.makeSession())
            .attach(baseURL: baseURL, apiKey: "k", sessionID: "s", image: png)
        XCTAssertEqual(out, .contractViolation(status: 200))
    }

    /// ★どの文にも「安全」「成功」で丸める語を置かない、の代わりに:
    /// **絶対パスが電話へ来ない**事を測る。来ていたら置き場が API に固まっている。
    func testTheWireCarriesNoAbsolutePath() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(Self.storedBody.utf8))]
        let out = await AttachClient(session: MockURLProtocol.makeSession())
            .attach(baseURL: baseURL, apiKey: "k", sessionID: "s", image: png)
        let text = AttachWording.text(for: out)
        XCTAssertFalse(text.contains("/Users/"), "置き場のパスが人の目に出た: \(text)")
        XCTAssertFalse(text.contains(".rc-backend"), text)
    }

    // MARK: - 検体

    private static let storedBody = """
    {"attachmentId":"abc123","bytes":157722,"format":"png","converted":false,
     "injected":true,"injectReason":null,"swept":0}
    """
    private static let notInjectedBody = """
    {"attachmentId":"abc123","bytes":157722,"format":"png","converted":false,
     "injected":false,"injectReason":"tmux-unavailable","swept":0}
    """
    private static let convertedBody = """
    {"attachmentId":"abc123","bytes":42510,"format":"heic","converted":true,
     "injected":true,"injectReason":null,"swept":0}
    """
}
