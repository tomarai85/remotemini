import XCTest
@testable import RemoteMini

/// 焼き込まれた2つの値 → 種、の変換だけを見る(2026-08-11)。
///
/// ★此処で落としたい誤実装は全部「**もっともらしい文字列**が届く」形。
/// 刻印が失敗した時に `nil` が来るなら誰でも気付くが、実際に来るのは
/// `${RC_BASE_URL}` や空文字で、それを種として蒔くと電話は
/// 「サーバに届かない」「鍵が違う」と、**刻印とは無関係な故障**を名乗る。
/// Tom は机から遠い所で、その嘘の症状を追う事になる。
///
/// | 誤実装 | 落とす対照 |
/// |---|---|
/// | 未解決の `${...}` をそのまま種にする | ① |
/// | 空文字 / 空白だけを種にする | ② ③ |
/// | `http` や scheme 無しを通す | ④ ⑤ |
/// | 片方だけ埋まっていれば蒔く | ⑥ |
/// | 前後の空白を落とさない | ⑦ |
final class ProvisioningTests: XCTestCase {
    private static let url = "https://desk.invalid"
    private static let key = "seed-key"

    /// 各否定の**隣に置く肯定**。`seed` が丸ごと `nil` を返す実装になった時、
    /// ①〜⑥が揃って緑のまま通るのを止める為に在る(2026-08-11、`vacuous-gate` の指摘)。
    ///
    /// ★兄弟の⑦だけでは足りない理由: 錨が1本だと、落ちるのも1本。
    /// 「此の形**だけ**が落ちる」は、同じ検査の中で両側を見せて初めて主張になる。
    private func assertOnlyTheMalformedShapeIsRejected(
        baseURL: String?, apiKey: String?, line: UInt = #line
    ) {
        XCTAssertNil(Provisioning.seed(baseURL: baseURL, apiKey: apiKey), line: line)
        XCTAssertNotNil(Provisioning.seed(baseURL: Self.url, apiKey: Self.key),
                        "★錨: 整った刻印は種になる(此処が nil なら上の nil は何も示していない)",
                        line: line)
    }

    /// ★① xcodegen は未定義の変数を**文字列として書く**(実測 2.45.3、
    /// `BuildInfo.displayRev` の doc)。だから此れは例外ではなく通常の届き方。
    func testAnUnresolvedTemplateIsNotASeed() {
        assertOnlyTheMalformedShapeIsRejected(baseURL: "${RC_BASE_URL}", apiKey: Self.key)
        assertOnlyTheMalformedShapeIsRejected(baseURL: Self.url, apiKey: "${RC_API_KEY}")
    }

    /// ② 空文字は種ではない。空の鍵で 401 を貰うと「拒まれた」と「入っていない」の
    /// 区別が画面上で付かなくなる。
    func testAnEmptyValueIsNotASeed() {
        assertOnlyTheMalformedShapeIsRejected(baseURL: "", apiKey: Self.key)
        assertOnlyTheMalformedShapeIsRejected(baseURL: Self.url, apiKey: "")
    }

    /// ③ 空白だけも同じ。PlistBuddy に空文字を渡すと此の形で残る事が在る。
    func testAWhitespaceOnlyValueIsNotASeed() {
        assertOnlyTheMalformedShapeIsRejected(baseURL: "   ", apiKey: Self.key)
        assertOnlyTheMalformedShapeIsRejected(baseURL: Self.url, apiKey: "\n \t")
    }

    /// ④ 平文の宛先は種にしない。机は `tailscale serve` の 443 でしか受けていない上に、
    /// ATS の例外を置いていない前提が黙って崩れる。
    func testAPlaintextURLIsNotASeed() {
        assertOnlyTheMalformedShapeIsRejected(baseURL: "http://desk.invalid", apiKey: Self.key)
    }

    /// ⑤ scheme も host も無い文字列を `URL(string:)` は受け取ってしまう。
    func testAHostlessStringIsNotASeed() {
        assertOnlyTheMalformedShapeIsRejected(baseURL: "desk.invalid", apiKey: Self.key)
        assertOnlyTheMalformedShapeIsRejected(baseURL: "https://", apiKey: Self.key)
    }

    /// ★⑥ 片方だけ埋まった種を蒔かない。**半端な種は打つ画面より悪い** ——
    /// 打つ画面なら Tom が直せるが、半端な種は「一覧に着いたのに何も出ない」に化ける。
    func testAHalfFilledStampIsNotASeed() {
        assertOnlyTheMalformedShapeIsRejected(baseURL: Self.url, apiKey: nil)
        assertOnlyTheMalformedShapeIsRejected(baseURL: nil, apiKey: Self.key)
        assertOnlyTheMalformedShapeIsRejected(baseURL: nil, apiKey: nil)
    }

    /// ⑦ 両方埋まっていれば種になる。前後の空白は落とす(PlistBuddy 越しに
    /// 改行が1つ付く事が在る)。
    func testAWellFormedStampBecomesASeed() throws {
        let seed = try XCTUnwrap(Provisioning.seed(baseURL: " \(Self.url)\n", apiKey: " \(Self.key) "))
        XCTAssertEqual(seed.baseURL.absoluteString, Self.url)
        XCTAssertEqual(seed.apiKey, Self.key)
    }

    /// ⑧ 指紋は値が違えば違う。**同じ種を二度蒔かない**判定の全体が此処に乗る。
    func testTheDigestSeparatesDifferentSeeds() {
        let a = Credentials(baseURL: URL(string: Self.url)!, apiKey: "k1")
        let b = Credentials(baseURL: URL(string: Self.url)!, apiKey: "k2")
        let c = Credentials(baseURL: URL(string: "https://other.invalid")!, apiKey: "k1")

        XCTAssertEqual(SeedDigest.of(a), SeedDigest.of(a), "同じ種は同じ指紋(でないと毎回蒔き直す)")
        XCTAssertNotEqual(SeedDigest.of(a), SeedDigest.of(b), "★鍵を回した種を『同じ』と読む実装を落とす")
        XCTAssertNotEqual(SeedDigest.of(a), SeedDigest.of(c), "URL だけ変わった種も別物")
    }

    /// ⑨ 指紋に鍵の平文が出ない。`UserDefaults` は束の中の平文 plist。
    func testTheDigestDoesNotContainTheKey() {
        let creds = Credentials(baseURL: URL(string: Self.url)!, apiKey: "super-secret-key")
        let digest = SeedDigest.of(creds)

        XCTAssertFalse(digest.contains("super-secret-key"))
        XCTAssertEqual(digest.count, 16)
    }

    /// ⑪ 既知の材料 → 既知の指紋。**此の1行が `ios/tools/build.sh` との契約**。
    ///
    /// 同じ計算が二つの言語に在る(電話は此の `SeedDigest.of`、焼く側は build.sh の
    /// python 断片)。片方だけ直った日を捕まえる為に、値の正本を**此処だけ**に置き、
    /// `rc-backend/test/seed-digest-recipe.test.mjs` が此処を読んで build.sh の断片を
    /// **そのもののバイトのまま**走らせ、同じ値に落ちるかを見る。
    ///
    /// ★逃げ道を塞いである: 期待値を書き換えて此処を緑にしても、build.sh は古い値を
    /// 出し続けるので向こうが赤くなる。材料(`url` / `key`)を動かした時も同じ。
    func testTheDigestMatchesTheContractSharedWithTheBuildScript() {
        // SEED-DIGEST-CONTRACT url=https://desk.invalid key=seed-key
        let expectedDigest = "687101842a796d8d"
        let creds = Credentials(baseURL: URL(string: Self.url)!, apiKey: Self.key)

        XCTAssertEqual(SeedDigest.of(creds), expectedDigest,
                       "★焼く時に build.sh が印字する指紋と同じ値。片側だけは動かせない")
    }

    /// ⑩ `UserDefaults` 実装が跨いで覚える。`nil` の代入が消去。
    func testTheLedgerPersistsThroughUserDefaults() throws {
        let suiteName = "provisioning-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let ledger = UserDefaultsSeedLedger(defaults: defaults)
        XCTAssertNil(ledger.plantedSeedDigest)

        ledger.plantedSeedDigest = "abcdef0123456789"
        XCTAssertEqual(UserDefaultsSeedLedger(defaults: defaults).plantedSeedDigest, "abcdef0123456789",
                       "★memory にだけ持つ実装を落とす(再起動で蒔き直す)")

        ledger.plantedSeedDigest = nil
        XCTAssertNil(UserDefaultsSeedLedger(defaults: defaults).plantedSeedDigest)
    }
}
