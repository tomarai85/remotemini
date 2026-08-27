import XCTest
@testable import RemoteMini

/// ★此のファイルの本文(JSON)は**手で書いていない**。`rc-backend/src/digest.mjs` を
/// Friday の上で実際に走らせた出力を貼ってある(2026-08-26):
///
///     node -e 'import("./src/digest.mjs").then(d => { ... d.digestOf(recs, {...}) ... })'
///
/// 手で組んだ本文は「電話が読める形」を検査するだけで、**机が本当に其の形を出すか**は
/// 一度も測らない —— 監査 S8-24 が数えた「電話の Decodable 28 本のうち机と突き合わせ
/// られていたのは 6 本」の正体が之。`AccountClientTests` と同じ規約に従う。
///
/// ★実物を採って初めて判った事が 2 つ在り、どちらも手で組んでいたら書かなかった:
///   1. 窓を全部読めなかった時、`counts` **も** `tools` **も** `fileTargets` **も** `null` で来る。
///      片方だけ想像していたら、残りで落ちるか 0 に潰していた。
///   2. `lastAssistant` と `lastAt` は **`complete=false` でも入って来る**。
///      「不完全 = 何も信じない」と丸めると、読めている物まで捨てる事になる。
final class DigestClientTests: XCTestCase {

    // 実サーバ出力(2026-08-26、Friday 上の src/digest.mjs)
    private let completeJSON = """
    {"digest":{"complete":true,"incompleteReason":null,"window":{"requestedFromIso":"2026-08-26T11:00:00.000Z","observedFromIso":"2026-08-26T11:01:00.000Z","toIso":"2026-08-26T12:00:00.000Z","minutes":60},"counts":{"user":1,"assistant":1,"tool":1},"tools":[{"name":"Read","n":1}],"fileTargets":["/a/b.txt"],"fileTargetsTotal":1,"lastAssistant":"done","lastAt":"2026-08-26T11:02:00.000Z"},"attention":"unknown","action":{"level":"unknown","reason":"screen-unreadable"},"line":"60m · 1 replies · 1 tool calls · 1 file targets — cannot tell if it needs you (screen-unreadable)."}
    """

    private let incompleteJSON = """
    {"digest":{"complete":false,"incompleteReason":"scan-budget","window":{"requestedFromIso":"2026-08-26T11:00:00.000Z","observedFromIso":null,"toIso":"2026-08-26T12:00:00.000Z","minutes":60},"counts":null,"tools":null,"fileTargets":null,"fileTargetsTotal":null,"lastAssistant":"done","lastAt":"2026-08-26T11:02:00.000Z"},"attention":"unknown","action":{"level":"unknown","reason":"screen-unreadable"},"line":"Could not read the whole window — counts withheld on purpose — cannot tell if it needs you (screen-unreadable)."}
    """

    private let emptyJSON = """
    {"digest":{"complete":true,"incompleteReason":null,"window":{"requestedFromIso":"2026-08-26T11:00:00.000Z","observedFromIso":null,"toIso":"2026-08-26T12:00:00.000Z","minutes":60},"counts":{"user":0,"assistant":0,"tool":0},"tools":[],"fileTargets":[],"fileTargetsTotal":0,"lastAssistant":null,"lastAt":null},"attention":"unknown","action":{"level":"unknown","reason":"screen-unreadable"},"line":"60m · 0 replies · 0 tool calls — cannot tell if it needs you (screen-unreadable)."}
    """

    private func parse(_ s: String) throws -> SessionDigest {
        try DigestParser.parse(Data(s.utf8))
    }

    func test_読めた窓は件数をそのまま持つ() throws {
        let d = try parse(completeJSON)
        XCTAssertTrue(d.complete)
        XCTAssertEqual(d.counts, .init(user: 1, assistant: 1, tool: 1))
        XCTAssertEqual(d.fileTargets, ["/a/b.txt"])
        XCTAssertEqual(d.fileTargetsTotal, 1)
        XCTAssertEqual(d.lastAssistant, "done")
        XCTAssertEqual(d.windowMinutes, 60)
    }

    /// ★★守る一線: **読めなかった窓を「静かだった」に見せない。**
    /// `counts` を 0 に潰すと、画面には「0 replies」と出る = 「何も起きなかった」に読める。
    /// 実際は「数えられなかった」。机が `null` に意味を持たせているので、受けも捨てない。
    func test_読めなかった窓は件数をnilのまま持つ_0に潰さない() throws {
        let d = try parse(incompleteJSON)
        XCTAssertFalse(d.complete)
        XCTAssertNil(d.counts, "counts を 0 に潰すと『静かだった』に見える")
        XCTAssertEqual(d.incompleteReason, "scan-budget")
    }

    /// 実物を採って初めて判った所: 不完全でも `lastAssistant` は入って来る。
    /// 「不完全 = 何も信じない」と丸めると、読めている物まで捨てる。
    func test_不完全でも読めている物は捨てない() throws {
        let d = try parse(incompleteJSON)
        XCTAssertEqual(d.lastAssistant, "done")
        XCTAssertEqual(d.windowMinutes, 60)
    }

    /// 本当に 0 件だった窓は、`counts` が **在って** 全部 0。上の「読めなかった」と別物。
    func test_本当に空の窓は0件として持つ() throws {
        let d = try parse(emptyJSON)
        XCTAssertTrue(d.complete)
        XCTAssertEqual(d.counts, .init(user: 0, assistant: 0, tool: 0))
        XCTAssertNil(d.lastAssistant)
    }

    /// ★文面は机が作る。電話は組み立てない(語彙が 2 箇所に分かれると片方が腐る)。
    func test_行はサーバの文をそのまま持つ() throws {
        XCTAssertTrue(try parse(completeJSON).line.contains("1 replies"))
        XCTAssertTrue(try parse(incompleteJSON).line.contains("counts withheld on purpose"))
    }

    /// ★`unknown` で画面が急かさない。**役に立たない急かしは信号ごと殺す**
    /// (Codex 2026-08-26: 正直だが役に立たない状態を人に見せると無視される様になる)。
    func test_unknownでは急かさない() throws {
        for s in [completeJSON, incompleteJSON, emptyJSON] {
            let d = try parse(s)
            XCTAssertEqual(d.attention, .unknown)
            XCTAssertEqual(d.action, .unknown)
            XCTAssertFalse(d.shouldUrge, "unknown で急かしている")
        }
    }

    /// 急かすのは `choice|input` × `now|soon` の時だけ。
    func test_急かす組み合わせだけ急かす() throws {
        let urge = [("input", "now"), ("input", "soon"), ("choice", "now"), ("choice", "soon")]
        let quiet = [("none", "now"), ("unknown", "now"), ("input", "none"), ("input", "unknown")]
        for (a, l) in urge {
            XCTAssertTrue(try parse(shaped(a, l)).shouldUrge, "\(a)/\(l) で急かしていない")
        }
        for (a, l) in quiet {
            XCTAssertFalse(try parse(shaped(a, l)).shouldUrge, "\(a)/\(l) で急かしている")
        }
    }

    /// ★知らない値を握り潰さない。`unrecognized` は `unknown` と**別物**:
    /// あちらは机が「判らない」と言った状態、こちらは電話が「知らない」状態。
    /// 同じにすると、机が新しい状態を増やした日に画面が黙って嘘を描く。
    func test_知らない値はunrecognizedでunknownと混ぜない() throws {
        let d = try parse(shaped("brand-new-state", "brand-new-level"))
        XCTAssertEqual(d.attention, .unrecognized)
        XCTAssertEqual(d.action, .unrecognized)
        XCTAssertFalse(d.shouldUrge)
    }

    /// 形が違う物は**推測せずに落とす**(足りない物を作らない)。
    func test_形が違えば落とす() {
        XCTAssertThrowsError(try parse("{}"))
        XCTAssertThrowsError(try parse("not json"))
        XCTAssertThrowsError(try parse("[]"))
    }

    /// `complete` が来ていない古い応答を「完全」と決めつけない。
    func test_completeが無い応答を完全と決めつけない() throws {
        let s = """
        {"digest":{"counts":{"user":1,"assistant":0,"tool":0}},"attention":"input","action":{"level":"now"},"line":"x"}
        """
        XCTAssertFalse(try parse(s).complete, "complete が無いのに完全だと決めた")
    }

    private func shaped(_ attention: String, _ level: String) -> String {
        """
        {"digest":{"complete":true,"counts":{"user":0,"assistant":0,"tool":0},"window":{"minutes":60}},\
        "attention":"\(attention)","action":{"level":"\(level)"},"line":"x"}
        """
    }
}
