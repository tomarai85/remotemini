import Foundation

/// UI 検査から「401 で落とされた直後の鍵入力画面」を作る種(DESIGN §2.65)。
///
/// ★此処が在る理由は S8-5 と同じ穴を X2-6 で繰り返さない為。`KeyEntryView.noticeText(for:)`
/// は純関数なので単体で幾らでも測れるが、単体が答えるのは「どんな文を作るべきか」だけで、
/// **その文が画面に出るか**は一つも答えない。S8-5 は正にその差で落ちた —— 規則は正しく、
/// 画面に繋がっていなかった。だから此処では**disk の断り → `AppState` → `normalFlow` →
/// `KeyEntryView` の body** という本物の鎖を、種を1つ置くだけで通す。
///
/// 面は増えるが、増やさない道は「画面に出る事を測らない」しか無かった。`RootView` の
/// 既存2つの fixture(一覧 / 会話)は `AppState` を**迂回**する形なので、鍵入力画面には
/// 使えない —— 鍵入力画面は `AppState` が「鍵が無い」と答えた時にだけ現れる面だから。
///
/// Release では此の型の中身ごと存在しない(`#if DEBUG`)。`RootView` が読むのも
/// DEBUG の中だけで、Release は素の `AppState()` を組む。
#if DEBUG
enum SignOutNoticeFixture: String {
    /// 通っていた鍵が拒まれた直後。URL は前のまま入っている。
    case keyRejected = "keyentry-rejected"

    /// 種にする URL。`RootView.fixtureBaseURL` と同じ RFC 2606 の予約 TLD ——
    /// 画面に出す為だけの値で、この app は fixture 中に一度も外へ出ない。
    /// (本物のホストは source / placeholder / fixture のどれにも書かない、が硬い制約)
    static let baseURL = URL(string: "https://ui-fixture.invalid")!

    var notice: SignOutNotice {
        switch self {
        case .keyRejected:
            return SignOutNotice(reason: .keyRejected, baseURL: Self.baseURL)
        }
    }

    /// 起動時の環境変数から種を選ぶ。UI 検査の launch 以外、および知らない名前の時は `nil`。
    ///
    /// ★環境変数を**読む所は fixture の file の中**に置く。姉家族2つ
    /// (`SessionsListingFactory.fixtureState` / `ConversationHistoryFactory.fixtureState`)が
    /// 既にそうなっていて、揃える理由が2つ在る:
    ///   1. Release バイナリに `RC_UI_FIXTURE` の綴りが1つも出ない事を測る対照
    ///      (`ui-fixture-absence-control.sh`)は、頭の controls-for 行に名前が在る file を
    ///      触った commit でしか呼ばれない。読む所を `AppState.swift` に置くと、
    ///      **本番の file** を宣言に足す事になり、鍵の持ち回りを1行直す度に
    ///      Release ビルドが回る。
    ///   2. 逆に足さないと、環境変数を読む file が対照の視野の外に出る。
    /// 最初 `AppState.forLaunch()` の中に直に書いて commit したら
    /// `fixture-reader-declared.test.mjs` が正にその 2. で門を閉めた。此の形はその訂正。
    static func fromEnvironment() -> SignOutNoticeFixture? {
        ProcessInfo.processInfo.environment["RC_UI_FIXTURE"].flatMap(SignOutNoticeFixture.init(rawValue:))
    }
}

/// 鍵を一つも持っていない金庫。fixture の時だけ `AppState` に渡る。
///
/// ★`KeychainCredentialStore` を渡さないのが要点。UI 検査は開発機の実 Keychain の上で
/// 走るので、本物を渡すと「検査が Tom の鍵を読む / 消す」経路が生える。読むだけに見えても、
/// `clearCredentials()` を通る検査を1本足した日に消す側へ変わる。
final class NoStoredCredentials: CredentialStore {
    func load() throws -> Credentials? { nil }
    func save(_ credentials: Credentials) throws {}
    func clear() throws {}
}
#endif
