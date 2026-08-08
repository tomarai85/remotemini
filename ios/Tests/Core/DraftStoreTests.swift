import XCTest
@testable import RemoteMini

/// DESIGN §2.53。ここで固定するのは**何が残ったか**であって、文言でも呼び出し回数でもない。
///
/// 数を書かない代わりに条件で書く: **誤実装を1本ずつ名指しで落とす対照が要る**。
/// 想定している誤実装と、それを落とす対照:
///
/// | 誤実装 | 落とす対照 |
/// |---|---|
/// | セッション id を無視して1本だけ覚える | ② |
/// | 古さで捨てる規則を入れない | ④ |
/// | 同じ本文の書き込みで時刻を若返らせる | ⑤ |
/// | 復号した辞書をインスタンスに抱える(写しを持つ) | ⑥ |
///
/// ★⑤と⑥は、どちらも**単体では緑のまま**壊れる型。⑤は「開き直すだけで打ちかけが
/// 不死身になる」= 捨てる規則が永久に発火しない。⑥は「後から書いた画面が、別の
/// セッションの打ちかけを丸ごと消す」= 静かな消失。
final class DraftStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        // 実機の `UserDefaults.standard` は絶対に触らない。検査どうしが互いの
        // 打ちかけを見る上に、開発機に残留物が残る。
        suiteName = "draft-store-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private func store(now: @escaping () -> Date, maxAge: TimeInterval = 60) -> UserDefaultsDraftStore {
        UserDefaultsDraftStore(defaults: defaults, now: now, maxAge: maxAge)
    }

    /// ① 覚えて、返す。
    func testADraftComesBackForTheSameSession() {
        let s = store(now: { Date(timeIntervalSince1970: 0) })
        s.save("止めて", sessionID: "A")
        XCTAssertEqual(s.load(sessionID: "A"), "止めて")
    }

    /// ★② セッションが違えば出ない。id を無視して1本だけ覚える実装を落とす。
    func testADraftDoesNotLeakIntoAnotherSession() {
        let s = store(now: { Date(timeIntervalSince1970: 0) })
        s.save("止めて", sessionID: "A")
        XCTAssertNil(
            s.load(sessionID: "B"),
            "★セッション id を無視して1本だけ覚える実装を落とす"
        )
    }

    /// ③ 空文字は「忘れる」。送信成功で `draft` が空になる経路がここを通る。
    func testAnEmptyDraftIsForgotten() {
        let s = store(now: { Date(timeIntervalSince1970: 0) })
        s.save("止めて", sessionID: "A")
        s.save("", sessionID: "A")
        XCTAssertNil(s.load(sessionID: "A"))
    }

    /// ★④ 古い打ちかけは復元しないし、置き場からも消える。
    /// 古さで捨てる規則を入れない実装を落とす。
    func testAnExpiredDraftIsNeitherReturnedNorKept() {
        var clock = Date(timeIntervalSince1970: 0)
        let s = store(now: { clock }, maxAge: 60)
        s.save("止めて", sessionID: "A")

        clock = Date(timeIntervalSince1970: 61)
        XCTAssertNil(s.load(sessionID: "A"), "★古さで捨てる規則が無い実装を落とす")

        // 読んだ側が掃く契約なので、置き場からも消えている事を別の口から確かめる。
        // (時計を戻しても戻って来ない = 隠しただけではない)
        clock = Date(timeIntervalSince1970: 0)
        XCTAssertNil(s.load(sessionID: "A"), "捨てたと言うなら置き場から消えている事")
    }

    /// ★⑤ 同じ本文の書き込みで時刻が若返らない。
    ///
    /// 復元した本文はそのまま書き戻される(`draft` の `didSet`)。そこで時刻が
    /// 若返る実装だと、**開き直すだけで打ちかけが不死身**になり、④の規則が永久に
    /// 発火しない —— しかも④は緑のまま通る。
    func testReopeningADraftDoesNotRefreshItsAge() {
        var clock = Date(timeIntervalSince1970: 0)
        let s = store(now: { clock }, maxAge: 60)
        s.save("止めて", sessionID: "A")

        // 30秒後に「開き直して同じ本文が書き戻された」
        clock = Date(timeIntervalSince1970: 30)
        s.save("止めて", sessionID: "A")

        // 最初に書いてから61秒。若返っていなければ、もう古い。
        clock = Date(timeIntervalSince1970: 61)
        XCTAssertNil(
            s.load(sessionID: "A"),
            "★同じ本文の書き込みで時刻を若返らせる実装を落とす(開き直すだけで不死身になる)"
        )
    }

    /// ★⑥ 別々のインスタンスが互いの打ちかけを消さない。
    ///
    /// 会話画面ごとに store を作れば実際に複数存在する。復号した辞書を抱える実装だと、
    /// 後から書いた方が相手のセッションの打ちかけを丸ごと落とす —— 静かな消失で、
    /// 単体の読み書き検査は全部緑のまま。
    ///
    /// ★手順が回りくどいのには理由が2つ在り、どちらも**最初に書いた版が写しを抱える
    /// 実装を落とせなかった**事から来ている(実装より先に対照の方を直した):
    ///
    /// 1. **`first` が `second` の書き込みより後に書く**必要がある。写しが害を出すのは
    ///    「古い写しの上から書き戻した時」で、読むだけなら害は出ない。
    /// 2. **確かめるのは第三のインスタンス**でなければならない。`second` から読むと、
    ///    今度は `second` 自身の写しが答えてしまい、ディスクが壊れていても緑になる。
    func testTwoStoresOverTheSameBackingDoNotClobberEachOther() {
        let clock = { Date(timeIntervalSince1970: 0) }
        let first = store(now: clock)
        let second = store(now: clock)

        first.save("Aの打ちかけ", sessionID: "A")
        second.save("Bの打ちかけ", sessionID: "B")
        // ここで `first` が書き戻す。写しを抱えていると B を知らないまま上書きする。
        first.save("Aの打ちかけ・続き", sessionID: "A")

        // 写しを持たない第三の目で見る。
        let third = store(now: clock)
        XCTAssertEqual(
            third.load(sessionID: "B"), "Bの打ちかけ",
            "★写しを抱える実装を落とす(後から書いた画面が別セッションの打ちかけを消す)"
        )
        XCTAssertEqual(third.load(sessionID: "A"), "Aの打ちかけ・続き")
    }
}
