import Foundation

/// **鍵を持たない電話が最初に着く面**を UI 検査から開ける種(2026-08-11)。
///
/// ★此処が在る理由。2026-08-11 に Tom が実機で開いた最初の画面は
/// 「Base URL と API Key を打て」という欄だった。数十本の検査が一度も赤くならなかったのは、
/// **製品の入口に計器が無かった**から —— `RootView` の既存 fixture 3つのうち
/// 一覧と会話は `AppState` を丸ごと迂回し、鍵入力側の2つ(`SignOutNoticeFixture` /
/// `KeyEntryProbeFixture`)は鍵の**無い**金庫を渡して鍵入力画面が出る事を確かめていた。
/// 「鍵が無い電話が一覧に着く」を見る面が一つも無く、私はスクリーンショットで毎回
/// 一覧を見て**アプリは一覧から始まる**と信じていた。
///
/// ★だから此の種が渡すのは金庫でも断りでもなく **`ProvisioningSource`**。
/// 金庫は空(`InMemoryCredentialStore`)、記録も空で、一覧に着けるかどうかは
/// 「焼き込みの種が `AppState` を通って `normalFlow` まで届くか」だけで決まる。
/// 種蒔きを外せば `keyEntry.baseURL` が出て赤くなる —— それが此の面の全ての仕事。
///
/// ★本物の刻印は握らせない。焼いた機械の `Info.plist` に本物の鍵が入っている日に
/// `BundleProvisioning` を握らせると、検査の結果が**その機械で誰が最後に焼いたか**で
/// 変わる。`NoStoredCredentials` の doc と同じ話で、これは検査ではなくなる。
///
/// Release では此の型ごと存在しない(`#if DEBUG`)。`RC_UI_FIXTURE` の綴りが
/// Release バイナリに1つも出ない事は `ios/tools/ui-fixture-absence-control.sh` が測る。
#if DEBUG
enum ProvisioningFixture: String, ProvisioningSource {
    /// 焼き込みの種を持って起動する電話。金庫は空、断りも無い = 新品の初回起動。
    case seeded = "provisioned-seed"

    /// 種にする URL。RFC 2606 の予約 TLD で、姉家族の fixture と同じ値
    /// (本物のホストは source / placeholder / fixture のどれにも書かない、が硬い制約)。
    ///
    /// ★此処は `RootView.fixtureBaseURL` と違って**本当に呼ばれる**。一覧は本物の
    /// `SessionsClient` を握るので、この面の一覧は取得に失敗した相で描かれる。
    /// それで構わない —— 測るのは「どの画面に着いたか」であって一覧の中身ではなく、
    /// 一覧の容器(`list.root`)は失敗した相でも必ず在る(`ListView` の
    /// `.safeAreaInset`)。逆に口まで作り物にすると、また入口を迂回した面が1つ増える。
    static let baseURL = URL(string: "https://ui-fixture.invalid")!

    var seed: Credentials? {
        switch self {
        case .seeded:
            return Credentials(baseURL: Self.baseURL, apiKey: "ui-fixture-key")
        }
    }

    /// 起動時の環境変数から種を選ぶ。UI 検査の launch 以外、および知らない名前の時は `nil`。
    ///
    /// 環境変数を読む所を fixture の file の中に置く理由は
    /// `ios/Sources/Core/SignOutNoticeFixture.swift` に在る通り。守るのは
    /// `rc-backend/test/fixture-reader-declared.test.mjs`。
    static func fromEnvironment() -> ProvisioningFixture? {
        ProcessInfo.processInfo.environment["RC_UI_FIXTURE"].flatMap(ProvisioningFixture.init(rawValue:))
    }
}

/// 空で始まり、書けば覚える金庫。`NoStoredCredentials` との違いは**書ける**事だけ。
///
/// 書ける形にするのは、本番の筋道(空の Keychain に種を保存して先へ進む)と
/// 同じ手順をこの面でも踏ませる為。**この面が保存の有無を測る訳ではない** ——
/// 一度の起動なら保存を落としても memory の資格情報で一覧に着くので、
/// 「二度目の起動で打たされない」= 保存が効いている事を落とすのは
/// `Tests/AppStateTests.swift` の側。開発機の実 Keychain を触らないという
/// `NoStoredCredentials` の一番の仕事は、こちらもそのまま守る。
final class InMemoryCredentialStore: CredentialStore {
    private var stored: Credentials?

    init(stored: Credentials? = nil) {
        self.stored = stored
    }

    func load() throws -> Credentials? { stored }
    func save(_ credentials: Credentials) throws { stored = credentials }
    func clear() throws { stored = nil }
}
#endif
