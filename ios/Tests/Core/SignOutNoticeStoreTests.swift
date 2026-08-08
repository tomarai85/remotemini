import XCTest
@testable import RemoteMini

/// DESIGN §2.65。断りは「401 で落とされた」という**事実**を、app が殺されても跨いで
/// 次の鍵入力画面まで運ぶ器。此処で固定するのは文言ではなく、運べる事と、運ばない物。
///
/// 想定している誤実装と、それを落とす対照:
///
/// | 誤実装 | 落とす対照 |
/// |---|---|
/// | 断りを memory だけで持ち回す(ディスクに落ちない) | ② |
/// | `save(nil)` が消さない(古い断りが出続ける) | ③ |
/// | URL を落として理由だけ運ぶ | ① |
/// | URL の無い断りが「断り無し」に化ける | ⑥ |
/// | 壊れたバイトで落ちる / 古い版の JSON で落ちる | ④ |
/// | 後から鍵や時刻の field を足す | ⑤ |
///
/// ★②が一番効く。memory 持ち回しの実装は、この画面を**手で触っている限り緑**で、
/// iOS が背面の app を殺した時にだけ壊れる —— つまり「断りを読む → 鍵を探しに
/// 別の app へ行く → 戻る」という、この器が存在する理由そのものの筋道でだけ壊れる。
///
/// ★⑤は挙動ではなく**面**を見る。挙動の検査(往復する / 鍵が出て来ない)は、
/// 鍵の field を足した実装でも全部緑のまま通る —— 誰も鍵を入れないからで、
/// 入れられる口が空いた事は挙動からは見えない。だから key の集合そのものを固定する。
final class SignOutNoticeStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        // 実機の `UserDefaults.standard` は絶対に触らない(`DraftStoreTests` と同じ理由)。
        suiteName = "signout-notice-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private func store() -> UserDefaultsSignOutNoticeStore {
        UserDefaultsSignOutNoticeStore(defaults: defaults)
    }

    private static let url = URL(string: "https://example.invalid")!

    /// ① 理由と URL が往復する。
    func testANoticeComesBackWithBothItsReasonAndItsURL() {
        let s = store()
        s.save(SignOutNotice(reason: .keyRejected, baseURL: Self.url))

        XCTAssertEqual(s.load(), SignOutNotice(reason: .keyRejected, baseURL: Self.url))
    }

    /// ★② 書いたのとは**別のインスタンス**から読める = ディスクに落ちている。
    /// memory だけで持ち回す実装を落とす。
    func testANoticeSurvivesTheObjectThatWroteIt() {
        store().save(SignOutNotice(reason: .keyRejected, baseURL: Self.url))

        XCTAssertEqual(
            store().load()?.baseURL, Self.url,
            "★memory 持ち回しの実装を落とす(app が殺された時にだけ消える形)"
        )
    }

    /// ③ `nil` の保存が「消す」。接続に成功した後、次に開いた時に古い断りが出ない。
    func testSavingNilForgetsTheNotice() {
        let s = store()
        s.save(SignOutNotice(reason: .keyRejected, baseURL: Self.url))
        s.save(nil)

        XCTAssertNil(store().load(), "★消したと言うなら、別の目から見ても消えている事")
    }

    /// ④ 読めないバイトは `nil`。落ちない。
    ///
    /// 版が上がって形が変わった時に此処を通る。断りが読めない事は画面の機能を一つも
    /// 壊さない(白紙に戻るだけ)ので、起動を巻き込んで落ちる方が遥かに悪い。
    func testUnreadableBytesAreTreatedAsNoNoticeRatherThanACrash() {
        defaults.set(Data("これは JSON ではない".utf8),
                     forKey: UserDefaultsSignOutNoticeStore.storageKey)

        XCTAssertNil(store().load())
    }

    /// ★⑤ ディスクに落ちる**面**を固定する —— key は `reason` と `baseURL` だけ。
    ///
    /// 「鍵を書かない」を挙動で確かめる検査は書けない。この型は `apiKey` を受け取る
    /// 口を持たないので、渡す側の検査が**書けない**。それは弱点ではなく設計で、
    /// だから代わりに面を見る: 誰かが field を1つ足した瞬間に此処が赤くなる。
    func testThePersistedShapeCarriesNothingButTheReasonAndTheURL() throws {
        store().save(SignOutNotice(reason: .keyRejected, baseURL: Self.url))

        let data = try XCTUnwrap(defaults.data(forKey: UserDefaultsSignOutNoticeStore.storageKey))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(
            Set(object.keys), ["reason", "baseURL"],
            "★field が増減したら赤くする。増えた field が鍵や時刻でない事は、此処では判らない —— 判らないから止める"
        )
    }

    /// ⑥ URL の無い断りが「断り無し」に化けない。
    ///
    /// `baseURL` が `nil` の時 `JSONEncoder` は key ごと落とす。復号側がそれを
    /// 失敗として扱うと、理由まで一緒に消えて画面は白紙に戻る = 直した欠陥がそのまま復活する。
    func testANoticeWithoutAURLIsStillANotice() {
        store().save(SignOutNotice(reason: .keyRejected, baseURL: nil))

        let loaded = store().load()
        XCTAssertEqual(loaded?.reason, .keyRejected, "★URL が無くても断りは断り")
        XCTAssertNil(loaded?.baseURL)
    }
}
