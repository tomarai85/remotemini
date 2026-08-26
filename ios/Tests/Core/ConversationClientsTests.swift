import XCTest
@testable import RemoteMini

/// `ConversationClients` の対照(2026-08-08)。
///
/// ★測っているのは**面**であって挙動ではない。この束が出来た理由は
/// 「口を1つ足した時に検査側へ配り忘れる」が Sprint 5 / 6 / 7 と**3回続いた**事で、
/// 挙動の検査ではそれを捕まえられない —— 忘れられた口は**本物として正しく動く**から。
/// だから `fixture` の5つ全部が作り物である事を型で確かめ、`live` の5つ全部が
/// 本物である事を**同じ形で**確かめる。
///
/// 後者(`live` 側)が錨。`is` の書き方そのものが壊れて常に真になる病気だと、
/// `fixture` 側の緑と見分けが付かない。2つを反対向きに置いて初めて、
/// 緑が「測れて緑」だと言える。
final class ConversationClientsTests: XCTestCase {
    private let baseURL = URL(string: "https://unit-test.invalid")!
    private let apiKey = "unit-test-fixture-key-not-real"
    private let sessionID = "sess-0001"

    // MARK: - ① 面: fixture は5つ全部が作り物

    func testFixtureBundleHandsOutFixturesForEveryClient() {
        let c = ConversationClients.fixture(state: .threeRoles)

        XCTAssertTrue(c.history is HistoryFetchingFixture, "履歴が作り物でない")
        XCTAssertTrue(c.poll is PollFetchingFixture, "poll が作り物でない")
        XCTAssertTrue(c.send is MessageSendingFixture, "送信が作り物でない")
        XCTAssertTrue(c.interrupt is InterruptingFixture, "割り込みが作り物でない")
        XCTAssertTrue(c.choice is ChoiceSendingFixture, "打鍵が作り物でない")
    }

    // MARK: - ② 錨: live は5つ全部が本物

    func testLiveBundleHandsOutRealClientsForEveryClient() {
        let c = ConversationClients.live

        XCTAssertTrue(c.history is HistoryClient, "履歴が本物でない")
        XCTAssertTrue(c.poll is PollClient, "poll が本物でない")
        XCTAssertTrue(c.send is SendClient, "送信が本物でない")
        XCTAssertTrue(c.interrupt is InterruptClient, "割り込みが本物でない")
        XCTAssertTrue(c.choice is ChoiceClient, "打鍵が本物でない")
    }

    // MARK: - ③ 状態が履歴と poll の両方へ届いている

    /// 以前は呼ぶ側が同じ状態を2箇所へ手で書いていて、片方だけ書き換えると
    /// 実在しない画面(履歴は long / poll は choice)が作れた。束が1回だけ受けて
    /// 配る形になった事を、両側から観測して固定する。
    ///
    /// poll 側は保持している状態が `private` なので、値ではなく**振る舞い**で読む:
    /// `.busy` は読める分類を持つ状態なので初回が `.success` で返る。状態が
    /// 届いていなければ初回は 60 秒返らず、この検査は時間切れで落ちる。
    func testFixtureBundleGivesTheSameStateToHistoryAndPoll() async {
        let c = ConversationClients.fixture(state: .busy)

        XCTAssertEqual((c.history as? HistoryFetchingFixture)?.state, .busy)

        let outcome = await c.poll.poll(
            baseURL: baseURL, apiKey: apiKey, sessionID: sessionID,
            cursor: .empty, waitMs: 1
        )
        guard case .success = outcome else {
            return XCTFail("poll に .busy が届いていない(初回が読める応答で返らなかった): \(outcome)")
        }
    }

    // MARK: - ④ 書き込み側3経路は「飛んだまま返らない」

    func testSendFixtureHoldsAndThenReportsCancelled() async throws {
        try await assertHoldsThenCancels(.send)
    }

    func testInterruptFixtureHoldsAndThenReportsCancelled() async throws {
        try await assertHoldsThenCancels(.interrupt)
    }

    func testChoiceFixtureHoldsAndThenReportsCancelled() async throws {
        try await assertHoldsThenCancels(.choice)
    }

    /// 指紋は付けない。「サーバは今の画面について何も言っていない」であって
    /// 「変わっていない」ではない(`ChoiceAttempt` 自身の ★)。不在を
    /// 「変わっていない」と読む側の実装が入り込んだ時、此処が落ちる。
    func testChoiceFixtureNeverReportsAServerDigest() async {
        let url = baseURL, apiKeyValue = apiKey, sid = sessionID
        let task = Task {
            await ChoiceSendingFixture().choose(
                baseURL: url, apiKey: apiKeyValue, sessionID: sid, key: "1", digest: "d-aaa", confirm: nil
            )
        }
        task.cancel()

        let attempt = await task.value
        XCTAssertEqual(attempt.outcome, .cancelled)
        XCTAssertNil(attempt.serverDigest)
    }

    // MARK: - 道具

    private enum WritePath {
        case send, interrupt, choice
    }

    /// 2つを1回で測る: **待っている間は返らない**事と、**切られたら
    /// `.unreachable` ではなく `.cancelled` を返す**事。
    ///
    /// 後半が要るのは、`try?` で握り潰す実装だと打ち切りが「届かなかった」に
    /// 化けるから —— 画面が消えただけで失敗の帯が出る形になり、本物3つが
    /// わざわざ独立に持っている区別が作り物の側だけで消える。
    private func assertHoldsThenCancels(
        _ path: WritePath,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let url = baseURL, apiKeyValue = apiKey, sid = sessionID
        let box = OutcomeBox()

        let task = Task {
            let outcome: SendOutcome
            switch path {
            case .send:
                outcome = await MessageSendingFixture().send(
                    baseURL: url, apiKey: apiKeyValue, sessionID: sid, text: "x"
                )
            case .interrupt:
                outcome = await InterruptingFixture().interrupt(
                    baseURL: url, apiKey: apiKeyValue, sessionID: sid
                )
            case .choice:
                outcome = await ChoiceSendingFixture().choose(
                    baseURL: url, apiKey: apiKeyValue, sessionID: sid, key: "1", digest: "d-aaa", confirm: nil
                ).outcome
            }
            await box.set(outcome)
        }

        try await Task.sleep(for: .milliseconds(250))
        let midFlight = await box.value
        XCTAssertNil(
            midFlight,
            "待っている間に返ってしまった: \(String(describing: midFlight))",
            file: file, line: line
        )

        task.cancel()
        await task.value
        let settled = await box.value
        XCTAssertEqual(settled, .cancelled, "打ち切りが .cancelled にならなかった", file: file, line: line)
    }

    private actor OutcomeBox {
        private(set) var value: SendOutcome?
        func set(_ outcome: SendOutcome) { value = outcome }
    }
}
