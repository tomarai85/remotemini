import XCTest
@testable import RemoteMini

/// 「なぜ繋がっていないか」を名乗る面の**規則**(2026-08-16、DESIGN §2.100)。
///
/// 想定している誤実装と、それを落とす対照:
///
/// | 誤実装 | 落とす対照 |
/// |---|---|
/// | 理由が違っても同じ文を出す(= 直す前の白紙と同じ情報量) | ① |
/// | 判らない時に尤もらしい理由を選ぶ(「種が無い」と言い切る) | ② |
/// | 押しても何も起きないボタンを全部の理由に出す | ③ |
/// | 行動が在る理由でボタンを出さない(復旧路が消える) | ④ |
/// | 断りの文を此処にも書き写す(2箇所になり、片方だけ腐る) | ⑤ |
///
/// ★UI 検査(`FirstRunUITests`)との役割分担: 此処は**規則**、あちらは**画素**。
/// 純関数だけ緑で body が描かない形は S8-5 / X2-6 で2回踏んでいるので、両方要る。
final class DisconnectedViewTests: XCTestCase {
    private static let url = URL(string: "https://example.invalid")!

    /// ★① 4本の理由が**別々の文**になる。
    ///
    /// 文言そのものは測らない(文は変わる)。測るのは「同じ文が2つ以上の理由に
    /// 使い回されていない」事 —— 使い回した瞬間、画面の情報量は白紙に戻る。
    func testEveryReasonGetsItsOwnSentence() {
        let notice = SignOutNotice(reason: .keyRejected, baseURL: Self.url)
        let sentences = [
            DisconnectedView.headline(for: .seedAbsent, notice: nil),
            DisconnectedView.headline(for: .seedRejected, notice: nil),
            DisconnectedView.headline(for: .storeUnreadable, notice: nil),
            DisconnectedView.headline(for: .keyRejected, notice: notice),
            DisconnectedView.headline(for: .unexplained, notice: nil)
        ]

        XCTAssertEqual(Set(sentences).count, sentences.count,
                       "★理由が違うのに同じ文を出す実装を落とす(白紙と同じ情報量に戻る)")
        for sentence in sentences {
            XCTAssertFalse(sentence.isEmpty, "空の文は『名乗っていない』と同じ")
        }
    }

    /// ★② 判らない時に、尤もらしい理由へ寄せない。
    ///
    /// `build.sh` の `build_rev` が「判らなかった事を『汚れている』と言い換えない」為に
    /// 枠を持っているのと同じ趣旨。此処で `seedAbsent` の文へ寄せると、机に繋がらない
    /// 本当の原因を探す人が**焼き直しに時間を溶かす**。
    func testTheUnexplainedCaseDoesNotBorrowAnotherReasonsSentence() {
        let unexplained = DisconnectedView.headline(for: .unexplained, notice: nil)

        XCTAssertNotEqual(unexplained, DisconnectedView.headline(for: .seedAbsent, notice: nil))
        XCTAssertNotEqual(unexplained, DisconnectedView.headline(for: .seedRejected, notice: nil))
    }

    /// ★③④ 主行動は「押せる物が在る理由」にだけ出る。
    func testThePrimaryActionExistsOnlyWhereSomethingCanActuallyBeDone() {
        XCTAssertEqual(DisconnectedView.primaryAction(for: .seedRejected), .retryWithBundledSeed)
        XCTAssertEqual(DisconnectedView.primaryAction(for: .storeUnreadable), .reloadStore)

        XCTAssertNil(DisconnectedView.primaryAction(for: .seedAbsent),
                     "★押しても何も起きないボタンを出す実装を落とす(故障が『押し方が悪い』に化ける)")
        XCTAssertNil(DisconnectedView.primaryAction(for: .keyRejected))
        XCTAssertNil(DisconnectedView.primaryAction(for: .unexplained))
    }

    /// ★⑤ 断りの文は `KeyEntryView` から**借りる**。書き写さない。
    ///
    /// 錨も同じ検査に置く: 借り元が現に文を持ち得る事を先に確かめないと、
    /// 「両方 nil で一致」でも緑になる。
    func testTheRejectedKeySentenceIsBorrowedNotCopied() {
        let notice = SignOutNotice(reason: .keyRejected, baseURL: Self.url)

        XCTAssertNotNil(KeyEntryView.sentence(for: notice), "錨: 借り元は文を持ち得る")
        XCTAssertEqual(DisconnectedView.headline(for: .keyRejected, notice: notice),
                       KeyEntryView.sentence(for: notice),
                       "★同じ文を2箇所に書く実装を落とす(片方だけ腐る)")
    }

    /// ★断りが**無い**まま `.keyRejected` に落ちた時も、空欄にしない。
    /// (`clearCredentials` が断りを書いた直後に殺された電話が此処へ来る)
    ///
    /// ★錨は「空でない」ではなく**実値**に置く。空でない事だけを見ると、此処が
    /// 3つ目の文言を発明した実装も緑になる —— 落としたいのは正にそれで、
    /// URL を持たない断りの文は `KeyEntryView` が既に持っている(borrow 元と同じ)。
    func testTheRejectedKeyFaceStillSaysSomethingWithoutANotice() {
        let sentence = DisconnectedView.headline(for: .keyRejected, notice: nil)
        let borrowedWithoutURL = KeyEntryView.sentence(for: SignOutNotice(reason: .keyRejected, baseURL: nil))

        XCTAssertNotNil(borrowedWithoutURL, "錨: 借り元は URL 無しの断りにも文を持つ")
        XCTAssertEqual(sentence, borrowedWithoutURL,
                       "★3つ目の文言を此処で発明する実装を落とす(同じ状況に2つの言い方が生える)")
        XCTAssertFalse(sentence.isEmpty)
    }
}
