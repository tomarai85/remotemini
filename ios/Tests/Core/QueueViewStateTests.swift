import XCTest
@testable import RemoteMini

/// `QueueViewState` / `ClearQueueOutcome` — `src/view.mjs` の `queueView` /
/// `clearQueueResult` の移植の検査。的は向こうの `test/view.test.mjs` と同じ判断に
/// 置く(片側だけ動けば赤になる様に、**判断**を写す。文言の突き合わせは
/// wire-vocabulary-agreement の持ち分)。
final class QueueViewStateTests: XCTestCase {

    // MARK: - nil と 0 を混ぜない(此の型が在る理由そのもの)

    /// tmux 経路 / 古いサーバ = 観測していない。断定しないので何も出さない。
    func testAnUnobservedQueueShowsNothingAndClaimsNothing() {
        // ★錨(vacuous-gate): 同じ入力の nil だけを 1 へ替えると出る事を先に固定する。
        //   之が無いと「常に hidden を返す実装」でも下の否定2件は緑のまま
        //   —— 否定だけの検査は、機能ごと消えた壊れ方を測れない。
        XCTAssertTrue(QueueViewState.make(queued: 1, fetchedAtMs: 1000, nowMs: 2000).show,
                      "1件でも出ない = 面ごと死んでいる(以下の否定は何も測っていない)")

        let v = QueueViewState.make(queued: nil, fetchedAtMs: 1000, nowMs: 2000)
        XCTAssertFalse(v.show)
        XCTAssertFalse(v.known, "観測していないのに known = 「観測して無かった」という嘘")
    }

    /// 観測して0だった。出さないが、**観測した事**は残る。
    func testAnObservedZeroIsKnownButHidden() {
        let v = QueueViewState.make(queued: 0, fetchedAtMs: 1000, nowMs: 2000)
        XCTAssertFalse(v.show)
        XCTAssertTrue(v.known)
        // ★出さない枝で古さを名乗らない(数が消えた後も古さの行だけ生きる見え方になる)
        XCTAssertEqual(v.ageText, "")
        XCTAssertFalse(v.stale)
    }

    func testAPositiveCountShowsTheStripWithCountAndWarning() {
        let now = 10_000.0
        let v = QueueViewState.make(queued: 2, fetchedAtMs: now - 1000, nowMs: now)
        XCTAssertTrue(v.show)
        XCTAssertEqual(v.count, 2)
        XCTAssertTrue(v.text.contains("2 件"))
        // ★「まだ Claude に渡していません」は面の一部。落とすと「取り消し = 走っている番も
        //   止まる」と読める(サーバの route 註釈が2つを畳むなと書いている)。
        XCTAssertTrue(v.text.contains("まだ Claude に渡していません"))
        XCTAssertTrue(v.clearLabel.contains("2 件"))
        XCTAssertFalse(v.stale)
    }

    /// 古さの境目(60秒)は一覧と**同じ関数**から来る。此処で 60 を直書きして測ると
    /// 写しになるので、`Freshness` 自身に同じ入力を与えて一致を見る。
    func testStalenessComesFromTheSharedFreshnessBoundary() {
        let now = 100_000.0
        let fetched = now - 61_000
        let v = QueueViewState.make(queued: 1, fetchedAtMs: fetched, nowMs: now)
        let f = Freshness.freshness(fetched, nowMs: now)
        XCTAssertEqual(v.stale, f.stale)
        XCTAssertEqual(v.ageText, f.text)
        XCTAssertTrue(v.stale, "61秒前の値が新鮮に見えている")
    }

    // MARK: - 取り消しの応答の読み方

    func testADroppedCountIsReportedWithTheRunningTurnCaveat() {
        let o = ClearQueueOutcome.from(status: 200, dropped: 3, serverError: nil)
        XCTAssertEqual(o, .ok("3 件の送信を取り消しました(いま動いている番は止まりません)。"))
    }

    func testZeroDroppedSaysThereWasNothingToCancel() {
        let o = ClearQueueOutcome.from(status: 200, dropped: 0, serverError: nil)
        XCTAssertEqual(o, .ok("取り消す送信は残っていませんでした。"))
    }

    /// 200 は必ず `dropped` を載せる(server.mjs)。載っていないのは「0件」ではなく**不明**。
    func testAMissingDroppedFieldIsUnknownNotZero() {
        let o = ClearQueueOutcome.from(status: 200, dropped: nil, serverError: nil)
        guard case .warn(let t) = o else { return XCTFail("不明を \(o) に丸めた") }
        XCTAssertTrue(t.contains("確認できません"))
    }

    /// 409 は設計された断り。サーバの人向けの文をそのまま見せる。
    func testARefusalCarriesTheServersOwnSentence() {
        let o = ClearQueueOutcome.from(
            status: 409, dropped: nil,
            serverError: "この会話は机で開かれています。待っている送信は Claude Code 自身が持っているので、電話からは取り消せません。")
        guard case .refused(let t) = o else { return XCTFail("断りを \(o) に丸めた") }
        XCTAssertTrue(t.contains("机で開かれています"))
    }

    func testARefusalWithoutASentenceStillSaysSomething() {
        let o = ClearQueueOutcome.from(status: 409, dropped: nil, serverError: "  ")
        XCTAssertEqual(o, .refused("取り消せませんでした。"))
    }

    /// 入力(503 / 418)は `test/view.test.mjs` の clearQueueResult の検査と**同じ値**。
    /// port-coverage-gate が両側を突き合わせるので、JS 側が入力を足すと此処の写し漏れが赤になる。
    func testAuthAndServerErrorsAreTheirOwnKinds() {
        XCTAssertEqual(ClearQueueOutcome.from(status: 401, dropped: nil, serverError: nil),
                       .error("鍵が通りませんでした。"))
        guard case .error(let t) = ClearQueueOutcome.from(status: 503, dropped: nil, serverError: nil)
        else { return XCTFail() }
        XCTAssertTrue(t.contains("503"), "5xx の status が文から落ちた: \(t)")
        // 4xx でも 5xx でもない想定外(JS 側と同じ 418)は「想定していない応答」の枝。
        guard case .error(let u) = ClearQueueOutcome.from(status: 418, dropped: nil, serverError: nil)
        else { return XCTFail() }
        XCTAssertTrue(u.contains("418"), "想定外の status が文から落ちた: \(u)")
    }
}
