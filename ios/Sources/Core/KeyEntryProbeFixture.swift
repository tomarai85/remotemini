import Foundation

#if DEBUG

/// 鍵入力画面の**確かめている最中**を UI 検査から開ける種(DESIGN §2.68、監査 X2-8)。
///
/// ★撮りたいのは「飛んでいる間」だけなので、口は**返らない**。
/// `ios/Sources/Core/WriteFixture.swift` が会話画面の書き込み3経路について書いた判断を
/// そのまま借りる —— 返る fixture ではその画面は撮れない(撮ろうとした瞬間には
/// 終わっている)し、本物を握らせると何秒出るかは計器ではなく **DNS が `.invalid` を
/// 蹴る速さ**で決まる。検査の結果が環境で変わるなら、それは計器ではない。
///
/// ★ただし WriteFixture の「面を1つも増やさずに済む」はここでは半分しか効かない。
/// あちらの3つ(送信 / 割り込み / 打鍵)は**並んだ別々の操作**なので、どの面からでも
/// button を押せばその1つに入れる。こちらの2つは**1つの操作の連続した段**で、
/// 2段目(鍵)へは1段目(URL)を**通り抜けないと**辿り着けない。1段目が返らない面に
/// 居る限り2段目の文は永久に出ないので、段の数だけ面が要る。
///
/// 増やしたのは1つだけ(`keyentry-slow-key`)。1段目で止まる面は既存の
/// `keyentry-rejected` がそのまま使える —— あの面の口も本物ではなくこの束になった
/// (理由は `ios/Sources/Core/KeyEntryClients.swift`)ので、押せば1段目で止まる。
///
/// Release では此の型ごと存在しない(`#if DEBUG`)。`RootView` が読むのも DEBUG の
/// 中だけ。`RC_UI_FIXTURE` の綴りが Release バイナリに1つも出ない事は
/// `ios/tools/ui-fixture-absence-control.sh` が strings で測る。
enum KeyEntryProbeFixture: String {
    /// URL の段は即座に通り、**鍵の段で止まる**面。
    ///
    /// 断りは付かない(初回の顔)。断り付きの面と直交させてあるのは、此処で測るのが
    /// 「確かめている最中に何と書いてあるか」だけで、なぜこの画面に来たかは関係ないから。
    case stallsOnKey = "keyentry-slow-key"

    /// 起動時の環境変数から種を選ぶ。UI 検査の launch 以外、および知らない名前の時は `nil`。
    ///
    /// ★環境変数を**読む所は fixture の file の中**に置く。姉家族3つ
    /// (`SessionsListingFactory.fixtureState` / `ConversationHistoryFactory.fixtureState` /
    /// `SignOutNoticeFixture.fromEnvironment`)が既にそうで、揃える理由は
    /// `ios/Sources/Core/SignOutNoticeFixture.swift` に書いてある通り —— 本番の file に
    /// 読み口を置くと、`ui-fixture-absence-control.sh` の宣言に本番の file を足す事に
    /// なる。守るのは `rc-backend/test/fixture-reader-declared.test.mjs`。
    static func fromEnvironment() -> KeyEntryProbeFixture? {
        ProcessInfo.processInfo.environment["RC_UI_FIXTURE"].flatMap(KeyEntryProbeFixture.init(rawValue:))
    }

    /// `WriteFixture.hold` と同じ値・同じ意味。XCUITest の待ちより十分に長ければよく、
    /// 値そのものに意味は無い。
    static let hold: Duration = .seconds(60)

    /// 保持しきっても打ち切られても、呼ぶ側から見えるのは「返って来なかった」だけ。
    ///
    /// 本物2つ(`HealthzClient` / `SessionsAuthProbe`)が `catch` で
    /// `.unreachable` に畳んでいるので、打ち切りを別扱いしないのは真似ではなく一致。
    static func stall() async {
        try? await Task.sleep(for: hold)
    }
}

extension KeyEntryClients {
    /// どの段で止まる束か。
    enum Stall {
        /// 1段目(サーバに届くか)で止まる。
        case url
        /// 1段目は通り、2段目(鍵が通るか)で止まる。
        case key
    }

    /// UI 検査用。**3つ全部が作り物**。
    ///
    /// `store` を必ず作り物にするのが此の束の一番の仕事。UI 検査は開発機の上で走るので、
    /// 本物の `KeychainCredentialStore` を握らせると「接続ボタンを押す検査」が
    /// 開発機の Keychain へ書きに行く(`SignOutNoticeFixture.NoStoredCredentials` の
    /// doc と同じ話)。此処では止まる段より手前で必ず失敗するので保存には到達しないが、
    /// **到達しないから安全**は経路が在る事の言い換えでしかない。
    static func fixture(stallingAt stall: Stall) -> KeyEntryClients {
        KeyEntryClients(
            healthz: stall == .url ? StallingHealthzFixture() : PassingHealthzFixture(),
            sessionsProbe: StallingSessionsAuthFixture(),
            store: NoStoredCredentials()
        )
    }
}

/// 1段目で止まる。
struct StallingHealthzFixture: HealthzChecking {
    func check(baseURL: URL) async -> Result<HealthzResult, HealthzError> {
        await KeyEntryProbeFixture.stall()
        return .failure(.unreachable)
    }
}

/// 1段目を即座に通す。2段目の文を出す為だけに在る。
///
/// `version` に `ui-fixture` と入れてあるのは、この値が万一画面や log に出た時に
/// **本物の机の版と読み違えられない**為。`pid` の 0 も同じ意図で、実在しない値。
struct PassingHealthzFixture: HealthzChecking {
    func check(baseURL: URL) async -> Result<HealthzResult, HealthzError> {
        .success(HealthzResult(ok: true, pid: 0, uptimeSeconds: 0, version: "ui-fixture"))
    }
}

/// 2段目で止まる。1段目が止まる面では此処まで来ない。
struct StallingSessionsAuthFixture: SessionsAuthChecking {
    func check(baseURL: URL, apiKey: String) async -> SessionsAuthProbe.Outcome {
        await KeyEntryProbeFixture.stall()
        return .unreachable
    }
}

#endif
