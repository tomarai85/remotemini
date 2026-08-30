import XCTest
@testable import RemoteMini

/// 机の画面に上限の告知が出ている事を、**送る面**に出す判断(CF-15、2026-08-30)。
///
/// ★測る中心は「文が出るか」ではなく **`nil` と `false` を同じに扱い、`true` だけで出る**事。
///   サーバは 2026-08-02 から `limited` を送っていて、電話は復号せず捨てていた
///   (`PollModels.swift` の註記が「この sprint は活動バッジを描かない」と理由を書いており、
///   判断は当時正しく、理由が 2026-08-30 に失効した)。
final class LimitedNoticeTests: XCTestCase {

    private func screen(_ limited: Bool?) -> ScreenBody {
        ScreenBody(classification: .sendable, limited: limited)
    }

    func test_告知が出ている時だけ文を出す() {
        XCTAssertNotNil(ConversationView.limitedNotice(screen(true)))
        XCTAssertNil(ConversationView.limitedNotice(screen(false)))
    }

    func test_線が何も言わなかった時は出さない() {
        // ★`nil` を `true` 側に寄せると、鍵を持たない古い机に繋いだ瞬間
        //   **常時**帯が出る。出っぱなしの警告は、次に本物が出た日に読まれない。
        XCTAssertNil(ConversationView.limitedNotice(screen(nil)))
        XCTAssertNil(ConversationView.limitedNotice(nil), "画面をまだ観測していない時も出さない")
    }

    func test_文に行動が読める() {
        let s = ConversationView.limitedNotice(screen(true))
        XCTAssertNotNil(s)
        // 「上限」と「答えが来ない」の両方が要る —— 片方だけだと、
        // 「送れないのか / 送れるが無駄なのか」が読めない。
        XCTAssertTrue(s?.lowercased().contains("usage-limit") == true, "上限である事が無い: \(s ?? "nil")")
        XCTAssertTrue(s?.lowercased().contains("not answer") == true, "答えが来ない事が無い: \(s ?? "nil")")
    }

    func test_分類とは独立に立つ() {
        // ★`SENDABLE` なのに答えが返らない、が此の欄の存在理由
        //   (`rc-backend/src/server.mjs` の `limited は state と独立に出す` の註記)。
        //   分類で握り潰すと、当の組み合わせが画面から消える。
        for c in [ScreenBody.Classification.sendable, .busy, .unknown, .choice] {
            XCTAssertNotNil(ConversationView.limitedNotice(ScreenBody(classification: c, limited: true)),
                            "\(c) で握り潰している")
        }
    }

    func test_線に鍵が無い机でも復号が壊れない() throws {
        // 2026-08-02 より前の机は `limited` を送らない。落ちずに nil になる事。
        let old = try JSONDecoder().decode(ScreenBody.self, from: Data(#"{"screen":"SENDABLE"}"#.utf8))
        XCTAssertNil(old.limited)
        let now = try JSONDecoder().decode(ScreenBody.self, from: Data(#"{"screen":"SENDABLE","limited":true}"#.utf8))
        XCTAssertEqual(now.limited, true, "線が送っているのに復号で落ちている = CF-15 の再演")
    }
}
