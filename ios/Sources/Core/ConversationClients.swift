import Foundation

/// 会話画面が背後で叩く backend の口を**1つの束**にした物。
///
/// ★なぜ束ねたか(2026-08-08)。**1度直した後、3回続けて同じ穴を掘っていた**。
/// 以前の `ConversationViewModel.init` は口を5つ別々の引数で受け、そのうち4つに
/// **本物の client を既定値**として持たせていた(`PollClient()` / `SendClient()` /
/// `InterruptClient()` / `ChoiceClient()`)。既定が本物だという事は、渡し忘れた口が
/// 黙って production の挙動になるという事。git で辿った実際の並び:
///
/// 1. Sprint 4 —— poll を足した時、UI 検査用の会話画面が `pollClient:` を渡さず、
///    背後の `Task` が `ui-fixture.invalid` へ本当の HTTP を投げていた。直し方は
///    **呼ぶ側で引数を1つ足す**(`RootView` に1行)。`ios/Sources/Core/PollFixture.swift`
///    が自分の存在理由の1番目に書いているのがこれ。
/// 2. Sprint 5(送信)/ Sprint 6(割り込み)/ Sprint 7(打鍵)—— 口が1つ増えるたび、
///    **検査 helper には作り物の既定を足したのに `RootView` には足さなかった**。
///    3回とも。2026-08-08 に3つまとめて見つかった。
///
/// つまり Sprint 4 の直し方は**次の1回すら止められていない**。呼ぶ側に足す形は、
/// 足す事を覚えている人が居る間しか効かない。
///
/// 「引数を渡し忘れない」を人の記憶に預ける形は、一度そう決めた後で同じ穴を
/// もう一度掘っている。だから記憶ではなく**型**に持たせた: この束には既定値が無く、
/// 呼ぶ側は `live` か `fixture(state:)` かを**必ず名指しする**。口が6つ目に増えた時、
/// 作り手が `live` にだけ足して `fixture` を忘れたらコンパイルが通らない。
///
/// 同じ理由で `draftStore` は既にこの形になっていた(既定を持たせると UI 検査が
/// 実機の `UserDefaults` を触る、と `ConversationViewModel` 自身が書いている)。
/// この file はその判断を、残り5つの口へ広げただけ。
/// 渡し忘れた時の受け皿。**何もしない**(本当の HTTP を飛ばさない)。
///
/// ★`AttachClient()` を既定にした `attach` とはここが違う。あちらは「送る」口で、
///   何もしない既定にすると「送ったのに何も起きない」が黙って出る —— 本物の方が
///   まだ気付ける。要約は「読む」口なので、渡し忘れの症状は**帯が1本出ない**だけ。
///   気付きやすさの差ではなく、**間違えた時の害の差**で既定を選んでいる。
struct NoDigest: DigestFetching {
    func fetch(baseURL: URL, apiKey: String, sessionID: String) async
        -> Result<SessionDigest, SessionsFetchError> { .failure(.unreachable) }
}

struct ConversationClients {
    let history: HistoryFetching
    let poll: PollFetching
    let send: MessageSending
    let interrupt: Interrupting
    let choice: ChoiceSending
    let clearQueue: QueueClearing
    /// 2026-08-26。★既定を持たせる —— 既存の呼び手(検体を含む)を全部書き換えずに
    /// 済ませる為だが、**本番の `live` では必ず本物を渡す**。既定に頼ったまま出荷すると
    /// 「送ったのに何も起きない」が黙って出る。
    var attach: Attaching = AttachClient()

    /// 2026-08-26。留守中の要約を取りに行く口。
    ///
    /// ★`attach` と同じく既定を持たせる。**理由は既定の中身**: `DigestFetchingFixture` は
    ///   DEBUG にしか居ないので、既定に置けるのは本物か、何もしない物のどちらか。
    ///   本物を既定にすると渡し忘れが黙って production の挙動になる(この file の存在理由)。
    ///   だから既定は **何もしない物**にする —— 渡し忘れたら帯が出ないだけで、
    ///   本当の HTTP は飛ばない。`live` では必ず本物を渡す。
    var digest: DigestFetching = NoDigest()

    /// 本番。`ListView` の行から会話画面を作る経路だけが使う。
    ///
    /// `static let` ではなく計算プロパティなのは、束ねる前の既定値が
    /// 「init のたびに新しく作る」だった為 —— 束ねた事で寿命が変わると、
    /// 直したはずの範囲の外に差分が漏れる。
    static var live: ConversationClients {
        ConversationClients(
            history: HistoryClient(),
            poll: PollClient(),
            send: SendClient(),
            interrupt: InterruptClient(),
            choice: ChoiceClient(),
            clearQueue: ClearQueueClient(),
            attach: AttachClient(),
            digest: DigestFetcher()
        )
    }
}

#if DEBUG

extension ConversationClients {
    /// UI 検査(スクリーンショット / XCUITest)用。**5つ全部が作り物**。
    ///
    /// `state` を1回だけ受けて履歴と poll の両方へ配るのも意図的で、以前は
    /// 呼ぶ側が同じ値を2箇所へ手で書いていた —— 片方だけ別の状態に書き換えると、
    /// 「履歴は long、poll は choice」という**実在しない画面**が作れてしまう。
    ///
    /// 送信 / 割り込み / 打鍵の3つが状態を見ないのは、どの状態でも
    /// 「飛んだまま返らない」1通りしか要らないから(理由は
    /// `ios/Sources/Core/WriteFixture.swift`)。
    static func fixture(state: HistoryFetchingFixture.State) -> ConversationClients {
        ConversationClients(
            history: HistoryFetchingFixture(state: state),
            poll: PollFetchingFixture(historyState: state),
            send: MessageSendingFixture(),
            interrupt: InterruptingFixture(),
            choice: ChoiceSendingFixture(),
            clearQueue: QueueClearingFixture(),
            digest: DigestFetchingFixture()
        )
    }
}

#endif
