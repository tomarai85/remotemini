import XCTest
@testable import RemoteMini

/// 外(通知)から来た URL の**解釈**。
///
/// ★何故 単体で切るのか(2026-08-31、実測)────────────────────────────────────
/// 端から端まで(URL を投げる → 会話が開く)を 1 本で測ろうとして `simctl openurl` を
/// 使ったが、iOS が必ず **「Open in "Remote Mini"?」の確認**を挟むので、
/// アプリに URL が届く前で止まった。冷えた起動でも同じ(ホーム画面の上に同じ確認が出た)。
/// 外から URL を投げる経路は、**機械だけでは最後まで測れない**。
///
/// だから鎖を測れる継ぎ目で切る:
///   URL の解釈  → 此のファイル(純粋な関数なので確実に測れる)
///   着地       → `RC_UI_DEEPLINK` で id を差し、画で見る(`DeepLink.init` の註)
///
/// ★測る中心は「正しい形を受ける」ではなく **「知らない形を受けない」**。
///   受け口が寛容だと、外から来た文字列で画面が勝手に動く。
@MainActor
final class DeepLinkTests: XCTestCase {

    private func idFor(_ s: String) -> String? {
        let link = DeepLink()
        link.pendingSessionID = nil          // 種(DEBUG の口)を消してから測る
        guard let url = URL(string: s) else { return nil }
        link.handle(url)
        return link.pendingSessionID
    }

    func test_正しい形は会話のidを取り出す() {
        XCTAssertEqual(idFor("remotemini://session/abc123"), "abc123")
        XCTAssertEqual(idFor("remotemini://session/fixture-choice-001"), "fixture-choice-001")
    }

    func test_別のschemeは受けない() {
        // ★他のアプリの scheme を横取りしない。
        XCTAssertNil(idFor("http://session/abc123"))
        XCTAssertNil(idFor("someother://session/abc123"))
    }

    func test_知らないhostは受けない() {
        // ★将来 `remotemini://settings` 等が増えた時、此処が「解釈できない = 何かする」に
        //   倒れていると、外から来た文字列で画面が予期せず動く。
        XCTAssertNil(idFor("remotemini://settings/abc123"))
        XCTAssertNil(idFor("remotemini://open/abc123"))
    }

    func test_idが無い形は受けない() {
        XCTAssertNil(idFor("remotemini://session"))
        XCTAssertNil(idFor("remotemini://session/"))
    }

    func test_消費すると消える() {
        // ★残すと、会話から一覧へ戻った瞬間に同じ id がもう一度 拾われ、
        //   押していないのに画面が飛び続ける。
        let link = DeepLink()
        link.handle(URL(string: "remotemini://session/abc")!)
        XCTAssertEqual(link.pendingSessionID, "abc")
        link.consume()
        XCTAssertNil(link.pendingSessionID)
    }
}
