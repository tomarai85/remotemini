import XCTest
@testable import RemoteMini

/// 対照表 #8 の後半の限界 2(2026-09-07): 机の一覧(`GET /subagents`)は背景シェルとチームの一員を**見ない**。
/// 机は其れを `display.note` の 1 文で毎回名乗り、電話は**其の文をそのまま描く**。
///
/// 此処で守る物は「電話が綴りで組み直さない」の 1 点。机と電話で言葉が分かれると、必ず片方だけ腐る。
/// 文の正本は `rc-backend/src/wire.mjs` の `SUBAGENTS_BLIND_SPOT`。Node 側の `subagents-note.test.mjs` が此のファイルに
/// 同じ字が在る事を要求するので、どちらかを変えれば両方の検査が赤になる。
final class SubagentsBlindSpotNoteTests: XCTestCase {
    /// 机の文(wire.mjs と同じ字)。
    static let deskSentence = "Background shells and teammates are not listed here."

    private static func body(note: String, running: Int = 1) -> SubagentsBody {
        let rows = (0..<running).map { i in
            """
            { "agentId": "a\(i)", "agentType": "general-purpose", "description": "count slowly", "model": null,
              "state": "running", "reason": "no-result-active", "meta": "read", "lastActivityIso": null,
              "display": { "state": "Working" } }
            """
        }.joined(separator: ",")
        let json = """
        { "subagents": [\(rows)], "directory": "read", "parent": "read", "truncated": false,
          "counts": { "finished": 0, "running": \(running), "stalled": 0, "unknown": 0 },
          "display": { "note": "\(note)" } }
        """
        return try! JSONDecoder().decode(SubagentsBody.self, from: Data(json.utf8))
    }

    /// 机の文は数の文の後ろに付いて届く。電話は其の全文を其のまま出す。
    func testTheDeskSentenceReachesTheScreenVerbatim() {
        let note = "1 subagent, 1 working. \(Self.deskSentence)"
        let shown = SubagentsView.noteText(Self.body(note: note))
        XCTAssertEqual(shown, note)
        XCTAssertTrue(shown.hasSuffix(Self.deskSentence))
    }

    /// 1 本も居ない時も同じ文が付く(机が決める。電話は数で分岐しない)。
    func testAnEmptyListingKeepsTheSentence() {
        let note = "This session has no subagents. \(Self.deskSentence)"
        XCTAssertEqual(SubagentsView.noteText(Self.body(note: note, running: 0)), note)
    }

    /// ★否定対照: 机が文を付けなかった時、電話は自分で足さない(足す実装は「机の判断」を 2 箇所に散らす)。
    /// 電話が数から文を組む実装(例 "1 subagents.")でも赤になる —— 机の文と 1 字も違ってはいけない。
    func testThePhoneNeitherInventsNorRewritesTheSentence() {
        let bare = "1 subagent, 1 working."
        let shown = SubagentsView.noteText(Self.body(note: bare))
        XCTAssertEqual(shown, bare)
        XCTAssertFalse(shown.contains(Self.deskSentence))
        XCTAssertNotEqual(shown, "1 subagents.")
    }

    /// 識別子は検査と UI 自動化が指す字。変えれば此処が赤になる。
    func testTheAccessibilityIdentifierIsStable() {
        XCTAssertEqual(SubagentsView.noteAccessibilityID, "subagents.note")
    }
}
