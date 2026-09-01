import XCTest
@testable import RemoteMini

/// `TranscriptSearchResponse` の復号(spec §2-a、扉A)。
///
/// ★此の suite の核心は**成功の 2 本ではなく、失敗の 2 本**(`…IsMalformedNotSuccess`)。
///   `matched` / `searchedToStart` を緩く受ける(`decodeIfPresent ?? …`)実装は、
///   成功側の検査を 1 本も落とさずに通る —— 鍵が在る body しか食わせていないので。
///   落ちるのは**鍵を落とした body を食わせた時だけ**で、それが此処の陰性対照。
///
/// 何が守られているか: `matched` の不在は「このサーバは探索していない」
/// (= `q` が落ちて素の履歴経路が返った)であって、0 でも何でもない。緩く受けると
/// 画面は**直近の履歴窓をそのまま「一致」として描く** —— 探した覚えの無い 50 行が
/// 「7 件 見つかりました」の顔で並ぶ、この機能で一番出してはいけない嘘。
final class TranscriptSearchResponseTests: XCTestCase {
    private func decode(_ json: String) -> TranscriptSearchResponse? {
        try? JSONDecoder().decode(TranscriptSearchResponse.self, from: Data(json.utf8))
    }

    // MARK: - 成功する形(机が実際に吐く 2 通り)

    func testEmptyWholeConversationBodyDecodes() {
        let r = decode(#"{"history":[],"matched":0,"searchedToStart":true}"#)
        XCTAssertEqual(r?.matched, 0)
        XCTAssertEqual(r?.coverage, .wholeConversation)
        XCTAssertEqual(r?.history.count, 0)
    }

    func testBoundedScanWithMatchesDecodes() {
        let r = decode("""
        {
          "history": [
            { "role": "user", "text": "a", "display": { "who": "Tom" } },
            { "role": "assistant", "text": "b", "display": { "who": "Claude" } }
          ],
          "matched": 7,
          "searchedToStart": false
        }
        """)
        XCTAssertEqual(r?.matched, 7)
        XCTAssertEqual(r?.coverage, .boundedScan)
        XCTAssertEqual(r?.history.count, 2)
        XCTAssertEqual(r?.history.first?.display.who, "Tom")
    }

    /// `searchedToStart` の 2 値が **`coverage` の 2 値へ本当に割れている**事。
    /// 上の 2 本は片方ずつしか見ないので、`coverage` を定数にした実装でも
    /// 片方は緑になる。
    func testTheTwoCoveragesAreNotCollapsedNegativeControl() {
        let whole = decode(#"{"history":[],"matched":0,"searchedToStart":true}"#)
        let bounded = decode(#"{"history":[],"matched":0,"searchedToStart":false}"#)
        XCTAssertNotEqual(whole?.coverage, bounded?.coverage)
    }

    // MARK: - 陰性対照: 必須鍵(spec §9 の M2)

    /// ★`matched` を落とした body は**復号に失敗**する。
    /// `decodeIfPresent(Int.self, forKey: .matched) ?? 0` へ緩めると此処だけが赤くなる。
    func testSearchBodyWithoutMatchedIsMalformedNotSuccess() {
        XCTAssertNil(
            decode(#"{"history":[],"searchedToStart":true}"#),
            "`matched` の無い body = 探索していないサーバの応答。0 件として受けてはいけない"
        )
    }

    func testSearchBodyWithoutSearchedToStartIsMalformedNotSuccess() {
        XCTAssertNil(
            decode(#"{"history":[],"matched":0}"#),
            "`searchedToStart` の無い body を既定値で受けると、0 件の 2 意味の片方が消える"
        )
    }

    /// 素の履歴応答(`{history, truncated}`)を**そのまま食わせた**時に落ちる事。
    /// 上の 2 本の合成だが、之が実際に線を流れる形なので独立に置く ——
    /// `q` を落とした要求はまさに此の body を返す。
    func testAPlainHistoryBodyDoesNotDecodeAsASearchResponse() {
        XCTAssertNil(decode("""
        {
          "history": [ { "role": "user", "text": "a", "display": { "who": "Tom" } } ],
          "truncated": false
        }
        """))
    }

    // MARK: - ★実機の机が実際に吐いていた形(2026-09-01)

    /// **これは作り話の body ではない。** friday:9443 へ GET を撃って取った実物:
    ///
    ///     探索      `{"role":"assistant","text":"…"}`
    ///     素の履歴  `{"role":"assistant","text":"…","display":{"who":"Claude"}}`
    ///
    /// 旧のハンドラは `history: r.history` と**生のまま**返しており、素の履歴が通る
    /// `.map(withWho)` を通していなかった。`HistoryEntry.display` は非 optional なので
    /// 之は復号ごと落ちる = 実機で探索すると必ず「読めない形」になる。
    /// **機能は出荷前から 100% 壊れていた**。机側は `historySearchBody` が
    /// `.map(withWho)` を通す事で直したが、電話側にも 1 本 置く:
    /// **緩めて `display` を optional にすれば通ってしまう**からで、其れをやると
    /// 発言者名の無い行が黙って並ぶ(電話は `display.who` を逐語で描き、
    /// `role` から作り直さない = `HistoryEntry` の既存規約)。
    ///
    /// ★教訓として一番効くのは、此の欠陥を**木の中の誰も捕まえられなかった**事:
    ///   fixture も私が書いた検体も、全部 `display` を入れて組んである。
    ///   検体は自分が知っている形しか名乗らない。
    func testEntriesWithoutDisplayDoNotDecodeTheShapeTheRealDeskWasSending() {
        XCTAssertNil(decode("""
        {
          "history": [ { "role": "assistant", "text": "四回目も同じパターンです。" } ],
          "matched": 5,
          "truncated": true,
          "searchedToStart": false
        }
        """), "`display` の無い項目を受けると、発言者名の無い行が黙って並ぶ")
    }

    /// 対照: 同じ body に `display` を足せば通る(上の赤が `display` 以外の理由で
    /// 出ていない事)。
    func testTheSameBodyWithDisplayDecodesNegativeControl() {
        let r = decode("""
        {
          "history": [ { "role": "assistant", "text": "四回目も同じパターンです。", "display": { "who": "Claude" } } ],
          "matched": 5,
          "truncated": true,
          "searchedToStart": false
        }
        """)
        XCTAssertEqual(r?.matched, 5)
        XCTAssertEqual(r?.coverage, .boundedScan)
    }

    // MARK: - `truncated` を読んでいない事の対照

    /// ★同じ `history`/`matched`/`searchedToStart` を持つ 2 つの body が、
    ///   `truncated` の有無・値に関わらず**同じ物へ復号する**。
    ///   `truncated` を読み始めた日に此処が赤くなる = 「読まないと決めた」が
    ///   宣言だけでなく実測で残る。
    func testTruncatedIsNotReadAtAll() {
        let without = decode(#"{"history":[],"matched":4,"searchedToStart":false}"#)
        let withTrue = decode(#"{"history":[],"matched":4,"searchedToStart":false,"truncated":true}"#)
        // 机が実際に吐くのは `truncated: !searchedToStart` = true の組だが、
        // **逆を向いた**組も同じ結果になる事まで見る(読んでいれば必ず割れる)。
        let withFalse = decode(#"{"history":[],"matched":4,"searchedToStart":false,"truncated":false}"#)
        XCTAssertNotNil(without)
        XCTAssertEqual(without, withTrue)
        XCTAssertEqual(without, withFalse)
    }

    // MARK: - `HistoryEntry` の既存規約の継承

    /// 知らない `role` は `.unknown` へ落ちて**復号は成功する**(`EntryRole` の既定)。
    /// 新しい型の中でも同じ緩さが効いている事を、此の口からも 1 本 見る ——
    /// 古い電話が 4 つ目の役割を持つ机に当たった日、探索の面だけ白紙になる形を塞ぐ。
    func testUnknownRoleStillDecodes() {
        let r = decode("""
        {
          "history": [ { "role": "oracle", "text": "a", "display": { "who": "Oracle" } } ],
          "matched": 1,
          "searchedToStart": true
        }
        """)
        XCTAssertEqual(r?.history.first?.role, .unknown)
        XCTAssertEqual(r?.history.first?.text, "a")
    }
}
