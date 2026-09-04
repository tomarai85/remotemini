import XCTest
@testable import RemoteMini

/// 文書の添付(対照表 #23、2026-09-03)の request の形と答えの読み分け。画像の口(`AttachClientTests`)と対。
final class AttachFileClientTests: XCTestCase {
    private let baseURL = URL(string: "https://unit-test.invalid")!
    private let text = Data("2026-09-03 12:00 INFO boot\n".utf8)

    override func setUp() { MockURLProtocol.reset() }
    override func tearDown() { MockURLProtocol.reset() }

    private static let stored = #"{"attachmentId":"0123456789abcdef0123456789abcdef","bytes":27,"name":"boot.log","ext":"log","injected":true,"injectReason":null,"swept":0}"#

    func testRequestIsAPOSTOfTheRawBytesToAttachFileWithTheNameInTheQuery() async throws {
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data(Self.stored.utf8))]
        let outcome = await AttachClient(session: MockURLProtocol.makeSession())
            .attachFile(baseURL: baseURL, apiKey: "correct-fixture-key", sessionID: "sess-abc-123", data: text, name: "boot.log")
        let url = try XCTUnwrap(MockURLProtocol.requestedURLs.last)
        XCTAssertEqual(url.path, "/api/sessions/sess-abc-123/attach-file")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first(where: { $0.name == "name" })?.value, "boot.log")
        XCTAssertEqual(MockURLProtocol.requestedMethods.last, "POST")
        XCTAssertEqual(MockURLProtocol.lastRequestHeaders?["Authorization"], "Bearer correct-fixture-key")
        XCTAssertEqual(MockURLProtocol.lastRequestHeaders?["Content-Type"], "application/octet-stream")
        XCTAssertEqual(MockURLProtocol.requestedBodies.last ?? nil, text, "本文は生の bytes のまま(multipart にしない)")
        XCTAssertEqual(MockURLProtocol.requestedTimeouts.last, max(BackendSession.writeTimeout, 60))
        XCTAssertEqual(outcome, .stored(id: "0123456789abcdef0123456789abcdef", bytes: 27, converted: false, injected: true, reason: nil))
    }

    func testTheDeskRejectionReasonSurvives() async {
        for reason in ["binary", "use-image-door", "bad-name", "too-large", "empty-body"] {
            MockURLProtocol.stubQueue = [.init(statusCode: 400, body: Data(#"{"error":"ATTACH_REJECTED","reason":"\#(reason)"}"#.utf8))]
            let outcome = await AttachClient(session: MockURLProtocol.makeSession())
                .attachFile(baseURL: baseURL, apiKey: "k", sessionID: "s", data: text, name: "x.txt")
            XCTAssertEqual(outcome, .rejected(reason: reason))
            XCTAssertFalse(AttachWording.fileText(for: outcome, name: "x.txt").isEmpty)
        }
    }

    func testStatusMappingMatchesTheImageDoor() async {
        MockURLProtocol.stubQueue = [.init(statusCode: 413, body: Data())]
        var o = await AttachClient(session: MockURLProtocol.makeSession()).attachFile(baseURL: baseURL, apiKey: "k", sessionID: "s", data: text, name: "a.txt")
        XCTAssertEqual(o, .tooLarge)
        MockURLProtocol.stubQueue = [.init(statusCode: 401, body: Data())]
        o = await AttachClient(session: MockURLProtocol.makeSession()).attachFile(baseURL: baseURL, apiKey: "k", sessionID: "s", data: text, name: "a.txt")
        XCTAssertEqual(o, .unauthorized)
        MockURLProtocol.stubQueue = [.init(statusCode: 200, body: Data("{}".utf8))]
        o = await AttachClient(session: MockURLProtocol.makeSession()).attachFile(baseURL: baseURL, apiKey: "k", sessionID: "s", data: text, name: "a.txt")
        XCTAssertEqual(o, .contractViolation(status: 200), "id の無い 200 は契約違反(黙って『送れた』にしない)")
    }

    func testWordingNamesTheFileAndNeverSaysPhoto() {
        let sent = AttachWording.fileText(for: .stored(id: "x", bytes: 4096, converted: false, injected: true, reason: nil), name: "notes.md")
        XCTAssertTrue(sent.hasPrefix("notes.md sent"), sent)
        XCTAssertFalse(sent.contains("Photo"))
        let parked = AttachWording.fileText(for: .stored(id: "x", bytes: 4096, converted: false, injected: false, reason: "no-pane"), name: "notes.md")
        XCTAssertTrue(parked.contains("could not be typed"), parked)
        XCTAssertTrue(AttachWording.fileText(for: .rejected(reason: "use-image-door"), name: "a.png").contains("photo button"))
    }
}
