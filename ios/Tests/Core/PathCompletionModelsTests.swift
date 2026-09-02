import XCTest
@testable import RemoteMini

/// `PathCompletionResponse` / `PathSuggestion` / `PathKind` の**復号の緩さ**を、
/// 鍵ごとに名指しで固定する。
///
/// ★緩い所と固い所が混ざっている型なので、混ざり方そのものを検査に書く:
///   `paths` / `truncated` = 必須(欠けたら復号ごと落とす)
///   `reason`              = 省略可(答えられた時は `null`)
///   `kind`                = 知らない語も受ける(`.unrecognized`)
///   どれも「緩くした時に出る嘘」の重さで選んである。
final class PathCompletionModelsTests: XCTestCase {

    private func decode(_ json: String) -> PathCompletionResponse? {
        try? JSONDecoder().decode(PathCompletionResponse.self, from: Data(json.utf8))
    }

    func testTheOrdinaryBodyDecodes() {
        let r = decode(#"{"paths":[{"path":"src","kind":"dir"}],"truncated":false,"reason":null}"#)
        XCTAssertEqual(r?.paths, [PathSuggestion(path: "src", kind: .dir)])
        XCTAssertEqual(r?.truncated, false)
        XCTAssertNil(r?.reason)
    }

    /// ★`truncated` を `?? false` で受けない。緩く受けた時の嘘が
    ///   **「之で全部です」**になるから —— 「もっと在る」を隠すのが、此の画面で
    ///   一番出してはいけない形(`TranscriptSearchResponse.matched` と同じ判断)。
    func testAMissingTruncatedIsRejectedRatherThanReadAsFalse() {
        XCTAssertNil(decode(#"{"paths":[],"reason":null}"#))
    }

    func testAMissingPathsIsRejectedRatherThanReadAsEmpty() {
        XCTAssertNil(decode(#"{"truncated":false,"reason":null}"#))
    }

    /// `reason` は鍵ごと無くてもよい。**電話にとって `null` と不在は同じ事実**で、
    /// 区別する道も必要も無い。
    func testAnAbsentReasonIsTheSameAsANullReason() {
        XCTAssertNil(decode(#"{"paths":[],"truncated":false}"#)?.reason)
        XCTAssertEqual(decode(#"{"paths":[],"truncated":false,"reason":"no_cwd"}"#)?.reason, "no_cwd")
    }

    /// ★知らない `kind` は `.unrecognized`。**`.file` に化かさない** ——
    ///   `file` に丸めると電話は「差したら終わり」の扱いをするので、実は dir だった物で
    ///   人が止まる(降りる道が画面から消える)。
    func testAnUnknownKindLandsOnUnrecognizedNotOnFile() {
        let r = decode(#"{"paths":[{"path":"x","kind":"socket"}],"truncated":false}"#)
        XCTAssertEqual(r?.paths.first?.kind, .unrecognized)
        XCTAssertNotEqual(r?.paths.first?.kind, .file)
    }

    /// 項目に `path` が無ければ其の応答ごと落とす(名前の無い候補は差せない)。
    func testASuggestionWithoutAPathIsRejected() {
        XCTAssertNil(decode(#"{"paths":[{"kind":"file"}],"truncated":false}"#))
    }

    /// ★机が鍵を増やしても壊れない(電話は知っている鍵だけ読む)。
    ///   線に鍵が増える事は、電話の版が古い時に必ず起きる。
    func testExtraServerKeysAreIgnored() {
        let r = decode(#"{"paths":[{"path":"a","kind":"file","bytes":12}],"truncated":false,"scanned":9}"#)
        XCTAssertEqual(r?.paths, [PathSuggestion(path: "a", kind: .file)])
    }

    /// 断りの語は**机と同じ綴り**。片側だけ変わった日に此処が赤くなる。
    func testTheRefusalWordsMatchTheDeskSpelling() {
        XCTAssertEqual(PathCompletionReason.noCwd, "no_cwd")
        XCTAssertEqual(PathCompletionReason.unreadable, "cwd_unreadable")
    }
}
