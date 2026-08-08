import XCTest
import SwiftUI
@testable import RemoteMini

/// DESIGN §2.65。401 で戻された鍵入力画面が出す**断りの文**。
///
/// 想定している誤実装と、それを落とす対照:
///
/// | 誤実装 | 落とす対照 |
/// |---|---|
/// | 初回の画面にも空の断りの節が出る | ① |
/// | 断りを1文に畳み、URL が無い時も「前のまま入れてある」と言う | ③ |
/// | 何をすれば良いか書かない(理由だけ告げて終わる) | ②③ |
/// | 鍵入力画面の 401(「鍵が違います」)と同じ文にする | ④ |
/// | `init` が `notice` を受け取るが捨てる | ★⑤ |
///
/// ★⑤が此の file の要。①〜④は `static func` を直に叩くだけなので、`init` が
/// `notice` を丸ごと無視する実装でも**全部緑のまま通る** —— 純関数は正しく、画面に
/// 繋がっていない、という S8-5 と同じ形。だから view を実際に組んで、組んだ物が文を
/// 握っているかを見る。
///
/// ★ここでも足りない最後の一歩(body の `if let` が本当に描くか)は、単体では届かない。
/// そこは `ios/UITests/KeyEntryUITests.swift` が simulator で `keyEntry.signOutNotice` を
/// 探して埋める。単体2本 + UI 1本で、disk から画素まで切れ目が無くなる。
@MainActor
final class KeyEntryViewTests: XCTestCase {
    private static let url = URL(string: "https://example.invalid")!

    /// 組む時に渡す3つの口。**`.live` は使わない**。
    ///
    /// 単体検査は開発機の上で走るので、本物の `KeychainCredentialStore` を握らせた
    /// 時点で Tom の鍵を読む / 消す経路が生える(`ios/Sources/Core/KeyEntryClients.swift`)。
    /// 下の3本は接続を押さないが、「押さないから安全」は経路が在る事の言い換えでしかない。
    private var clients: KeyEntryClients { .fixture(stallingAt: .url) }

    private func text(_ notice: SignOutNotice?) -> String? {
        KeyEntryView.sentence(for: notice)
    }

    /// ① 断りが無ければ文も無い。初回の画面に空の枠を残さない。
    func testNoNoticeMeansNoSentence() {
        XCTAssertNil(text(nil))
    }

    /// ② URL が在る時は、欄が埋まっている理由まで言う。
    ///
    /// 言わないと、埋まった欄を見た側は「前回の打ちかけが残っている」のか
    /// 「app が復元した」のか判らず、消してから打ち直す —— 打ち直しを省く為に
    /// 入れたのに省けない。
    func testWithAURLTheSentenceExplainsWhyTheFieldIsAlreadyFilled() throws {
        let sentence = try XCTUnwrap(text(SignOutNotice(reason: .keyRejected, baseURL: Self.url)))

        XCTAssertTrue(sentence.contains("前のまま"), "★欄が埋まっている理由を言わない実装を落とす")
        XCTAssertTrue(sentence.contains("鍵"), "次の一手(鍵を入れ直す)まで言う")
    }

    /// ★③ URL が無い時に「前のまま入れてある」と言わない。
    ///
    /// 2文を1文に畳んだ実装がここで落ちる。畳むと、空欄を前にして
    /// 「URL は入れてあります」と言う画面になり、Tom は入っていない物を探す。
    func testWithoutAURLTheSentenceDoesNotClaimTheFieldWasFilled() throws {
        let sentence = try XCTUnwrap(text(SignOutNotice(reason: .keyRejected, baseURL: nil)))

        XCTAssertFalse(sentence.contains("前のまま"), "★入れていない物を入れたと言う実装を落とす")
        XCTAssertTrue(sentence.contains("鍵"), "理由だけ告げて終わらない")
    }

    /// ④ 鍵入力画面が自分で出す 401 の文とは別物。
    ///
    /// あちらは「**今入れた鍵**は通らない」、こちらは「**通っていた鍵**が通らなくなった」。
    /// 同じ 401 でも次の一手が違う(前者は打ち直し、後者は机の側で鍵が変わった疑い)。
    func testTheNoticeIsNotTheSameSentenceAsARejectedFreshKey() throws {
        let sentence = try XCTUnwrap(text(SignOutNotice(reason: .keyRejected, baseURL: Self.url)))

        XCTAssertNotEqual(sentence, "鍵が違います")
    }

    /// ★⑤ 組んだ view が実際にその文を握っている。
    ///
    /// ①〜④は `static func` を直に叩くので、`init` が `notice` を捨てる実装でも全部
    /// 緑になる。此処だけが「画面の側が受け取った」を見る。
    ///
    /// `viewModel` には触れない —— `@StateObject` は view 階層に載る前に中身を読むと
    /// 落ちる。読むのは `init` が決めた文だけで、それで足りる。
    func testTheViewBuiltWithANoticeCarriesTheSentence() {
        let view = KeyEntryView(clients: clients, notice: SignOutNotice(reason: .keyRejected, baseURL: Self.url)) { _ in }

        XCTAssertEqual(view.noticeText, text(SignOutNotice(reason: .keyRejected, baseURL: Self.url)),
                       "★notice を受け取って捨てる init を落とす")
    }

    /// ⑥ 断り無しで組んだ view は文を持たない(= 初回の顔のまま)。
    ///
    /// ★錨を同じ検査の中に置く。「無い」だけを見ると、`noticeText` が**何を渡しても
    /// 常に nil** な実装(繋ぎ忘れ・型が変わって握り潰し)でも緑になる —— 落としたい
    /// 誤実装と区別が付かない。同じ口(`view.noticeText`)が現に文を持ち得る事を先に
    /// 固定してから、断り無しの時だけ空である事を見る。
    ///
    /// ⑤も同じ派生に肯定を言っているが、あちらは**文の中身**の検査で、こちらの
    /// 「常に nil」を守る為に在るのではない。錨は遠くの兄弟ではなく、直に食う派生の
    /// 隣に置く(`rc-backend/tools/vacuous-scan.py` の頭)。
    func testTheViewBuiltWithoutANoticeCarriesNothing() {
        let withNotice = KeyEntryView(clients: clients, notice: SignOutNotice(reason: .keyRejected, baseURL: Self.url)) { _ in }
        XCTAssertNotNil(withNotice.noticeText, "前提: 同じ口が文を持ち得る")

        let view = KeyEntryView(clients: clients, onSaved: { _ in })

        XCTAssertNil(view.noticeText)
    }
}
