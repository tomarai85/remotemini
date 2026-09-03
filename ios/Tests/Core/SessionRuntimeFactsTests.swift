import XCTest
@testable import RemoteMini

/// 会話の状態帯に出る「今 何で走っているか」の 1 行(`SessionDigest.Session.line`、対照表 #14-16)。
///
/// ★本文(JSON)の `session` の形は机の `digestOf` → `sessionOf` が出す物をそのまま写す
///   (`rc-backend/test/digest-session.test.mjs` と同じ鍵、`wire-key-agreement` が両側を縛る)。
///
/// 守る 3 点:
///   1. `contextTokens` は**在る時だけ**帯に載る。古い机(鍵ごと無い)/ 取れなかった机(null)は
///      `model · branch` だけで、欄を「?」や「0 ctx」で埋めない。
///   2. 数は短い形(`38.7k ctx`)。生の 5 桁を帯に出さない。
///   3. 全部無ければ `line` は nil(帯そのものを出さない)。
final class SessionRuntimeFactsTests: XCTestCase {

    private func envelope(session: String) -> String {
        """
        {"digest":{"complete":true,"incompleteReason":null,"window":{"requestedFromIso":"2026-09-03T14:00:00.000Z","observedFromIso":"2026-09-03T14:01:00.000Z","toIso":"2026-09-03T15:00:00.000Z","minutes":60},"counts":{"user":1,"assistant":1,"tool":0},"tools":[],"fileTargets":[],"fileTargetsTotal":0,"lastAssistant":"done","lastAt":"2026-09-03T14:02:00.000Z","session":\(session)},"attention":"none","action":{"level":"none","reason":null},"line":"1 replies — still working."}
        """
    }

    private func parse(_ session: String) throws -> SessionDigest.Session? {
        try DigestParser.parse(Data(envelope(session: session).utf8)).session
    }

    // MARK: - 復号

    func test_机が出す形をそのまま読む_contextTokens込み() throws {
        let s = try XCTUnwrap(parse(#"{"model":"claude-opus-5","gitBranch":"main","version":"2.1.240","contextTokens":38717}"#))
        XCTAssertEqual(s.model, "claude-opus-5")
        XCTAssertEqual(s.gitBranch, "main")
        XCTAssertEqual(s.version, "2.1.240")
        XCTAssertEqual(s.contextTokens, 38717)
        XCTAssertEqual(s.line, "claude-opus-5 · main · 38.7k ctx")
    }

    func test_古い机_鍵ごと無い_はmodelとbranchだけ() throws {
        let s = try XCTUnwrap(parse(#"{"model":"claude-opus-5","gitBranch":"main","version":"2.1.240"}"#))
        XCTAssertNil(s.contextTokens)
        XCTAssertEqual(s.line, "claude-opus-5 · main")
        XCTAssertFalse(try XCTUnwrap(s.line).contains("ctx"), "無い物を帯に出している")
    }

    func test_取れなかった机_null_も同じ扱い_0に潰さない() throws {
        let s = try XCTUnwrap(parse(#"{"model":"claude-opus-5","gitBranch":"main","version":null,"contextTokens":null}"#))
        XCTAssertNil(s.contextTokens, "null を 0 に潰すと『0 ctx』という嘘が帯に出る")
        XCTAssertEqual(s.line, "claude-opus-5 · main")
    }

    func test_全部無ければ帯そのものを出さない() throws {
        let s = try XCTUnwrap(parse(#"{"model":null,"gitBranch":null,"version":null,"contextTokens":null}"#))
        XCTAssertNil(s.line)
    }

    func test_数だけ在る時は数だけの帯() throws {
        let s = try XCTUnwrap(parse(#"{"model":null,"gitBranch":null,"version":null,"contextTokens":512}"#))
        XCTAssertEqual(s.line, "512 ctx")
    }

    // MARK: - 短い数

    func test_短い数_境界() {
        typealias S = SessionDigest.Session
        XCTAssertEqual(S.compact(0), "0")
        XCTAssertEqual(S.compact(999), "999")
        XCTAssertEqual(S.compact(1_000), "1.0k")
        XCTAssertEqual(S.compact(1_049), "1.0k")
        XCTAssertEqual(S.compact(1_050), "1.1k")
        XCTAssertEqual(S.compact(38_717), "38.7k")
        XCTAssertEqual(S.compact(99_949), "99.9k")
        XCTAssertEqual(S.compact(99_950), "100k", "「100.0k」を出さない")
        XCTAssertEqual(S.compact(123_456), "123k")
        XCTAssertEqual(S.compact(1_234_567), "1235k")
    }

    func test_帯に生の桁を出さない() throws {
        let s = try XCTUnwrap(parse(#"{"model":"m","gitBranch":"b","version":null,"contextTokens":38717}"#))
        XCTAssertFalse(try XCTUnwrap(s.line).contains("38717"))
    }

    // MARK: - 壊れた値(Codex #3 の 4)

    func test_負の値は帯に出さない() throws {
        let s = try XCTUnwrap(parse(#"{"model":"m","gitBranch":"b","version":null,"contextTokens":-1}"#))
        XCTAssertEqual(s.contextTokens, -1, "受けた値は其のまま持つ")
        XCTAssertNil(s.displayableContextTokens)
        XCTAssertEqual(s.line, "m · b", "「-1 ctx」を描いている")
    }

    func test_天井を超える値は帯に出さず_丸めも落ちない() throws {
        let s = try XCTUnwrap(parse(#"{"model":"m","gitBranch":"b","version":null,"contextTokens":9223372036854775807}"#))
        XCTAssertEqual(s.contextTokens, Int.max)
        XCTAssertNil(s.displayableContextTokens)
        XCTAssertEqual(s.line, "m · b")
        // 直に丸めても trap しない(`n + 50` の overflow)
        XCTAssertEqual(SessionDigest.Session.compact(Int.max), "1000000k")
        XCTAssertEqual(SessionDigest.Session.compact(-5), "0")
    }

    func test_Intに入らない数や型違いは其の1項だけnilで_要約全体は読める() throws {
        // 1e308 は JSON として正当だが Int に入らない。以前は digest 丸ごと復号に失敗した
        let big = try XCTUnwrap(parse(#"{"model":"claude-opus-5","gitBranch":"main","version":null,"contextTokens":1e308}"#))
        XCTAssertNil(big.contextTokens)
        XCTAssertEqual(big.line, "claude-opus-5 · main")
        let str = try XCTUnwrap(parse(#"{"model":"claude-opus-5","gitBranch":"main","version":null,"contextTokens":"38717"}"#))
        XCTAssertNil(str.contextTokens)
        XCTAssertEqual(str.model, "claude-opus-5", "他の欄は今まで通り読める")
    }
}
