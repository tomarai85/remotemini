import Foundation

/// 鍵入力画面が背後で触る3つの口を**1つの束**にした物。
///
/// ★束ねた理由(2026-08-08、監査 X2-8 を直しに来て見つけた)。`KeyEntryViewModel.init` は
/// 3つとも**本物を既定値**にしていた:
///
/// ```
/// init(healthz: HealthzChecking = HealthzClient(),
///      sessionsProbe: SessionsAuthChecking = SessionsAuthProbe(),
///      store: CredentialStore = KeychainCredentialStore(), ...)
/// ```
///
/// そして `KeyEntryView.init` はどれも渡していなかった。つまり UI 検査の
/// `keyentry-rejected` の面に出ている鍵入力画面は、**開発機の実 Keychain** と
/// **本物の HTTP client** を握っていた。`SignOutNoticeFixture` は同じ穴を
/// `AppState` 側で塞いでいて(`NoStoredCredentials` を渡す)、その doc は
/// 「本物を渡すと検査が Tom の鍵を読む / 消す経路が生える」と書いている ——
/// その判断が `KeyEntryViewModel` の既定値には届いていなかった。
///
/// 今日まで火を噴かなかったのは、鍵入力画面の UI 検査が**接続ボタンを一度も押して
/// いなかった**から。X2-8 の検査は押す。押した瞬間に、既定の `KeychainCredentialStore`
/// へ検査が書きに行く。
///
/// これは `ios/Sources/Core/ConversationClients.swift` が会話画面について書いている
/// 話の再演で、あちらの結論をそのまま借りる: 既定値を持たせない。呼ぶ側は `live` か
/// `fixture(stallingAt:)` かを**必ず名指しする**。口が4つ目に増えた時、作り手が
/// `live` にだけ足して `fixture` を忘れたらコンパイルが通らない。
struct KeyEntryClients {
    let healthz: HealthzChecking
    let sessionsProbe: SessionsAuthChecking
    let store: CredentialStore

    /// 本番。`RootView.normalFlow` から鍵入力画面を作る経路だけが使う。
    ///
    /// `static let` ではなく計算プロパティなのは、束ねる前の既定値が「init のたびに
    /// 新しく作る」だった為 —— 束ねた事で寿命が変わると、直したはずの範囲の外に
    /// 差分が漏れる(`ConversationClients.live` と同じ理由)。
    static var live: KeyEntryClients {
        KeyEntryClients(
            healthz: HealthzClient(),
            sessionsProbe: SessionsAuthProbe(),
            store: KeychainCredentialStore()
        )
    }
}
