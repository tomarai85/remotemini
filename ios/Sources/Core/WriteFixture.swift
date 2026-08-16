import Foundation

#if DEBUG

/// UI 検査用の**書き込み側**3経路(送信 / 割り込み / 打鍵)の作り物。
/// 読み取り側は `ios/Sources/Core/HistoryFixture.swift` と
/// `ios/Sources/Core/PollFixture.swift`、束ね方は
/// `ios/Sources/Core/ConversationClients.swift`。
///
/// ★3つとも**返らない**。状態で分岐しないし、成功も失敗も返さない。理由は3つ:
///
/// 1. **撮りたいのは「飛んでいる間」だけ**。Sprint 8-6 が言葉にしたのは
///    `sendInFlightNotice` / `interruptInFlightNotice` / `spins(key:inFlight:)` の
///    3つで、どれも要求が飛んでいる最中にしか存在しない。返る fixture では
///    その画面は撮れない —— 撮ろうとした瞬間には終わっている。
/// 2. **返らない事にすると、面(`RC_UI_FIXTURE`)を1つも増やさずに済む**。
///    Sprint 8-6 の積み残しは「飛んでいる最中で止まった面が無いので撮れない。
///    面を増やせば撮れるが、面が操作の数だけ増える」だった。この形なら
///    既存の7つの面のどれでも、button を押せばその画面に入る。
/// 3. **本物を握っているより正確**。直す前は既定の本物が渡っていて、押すと
///    `ui-fixture.invalid` へ本当に飛んでいた。その時スピナが何秒出るかは
///    計器ではなく **DNS が `.invalid` を蹴る速さ**で決まる —— 即座に終われば
///    撮れず、詰まれば `BackendSession.writeTimeout` の 30 秒。
///    検査の結果が環境で変わるなら、それは計器ではない。
///
/// ★「飛びっぱなし」と「即座に失敗」を撮り分けたくなったら、面ではなく
/// **2本目の環境変数**で分ける事。ただしその名前は
/// `ios/tools/ui-fixture-absence-control.sh`(Release バイナリに検査用の文字列が
/// 残っていない事を測る対照)の走査対象に**足さないと**、Release へ漏れても
/// 誰も気付かない。今は要らないので足していない。
enum WriteFixture {
    /// `PollFetchingFixture` が使う保持時間と同じ。`shots.sh` の 2 秒の待ちと
    /// XCUITest の待ちのどちらより十分に長ければよく、値そのものに意味は無い。
    static let hold: Duration = .seconds(60)

    /// 保持しきったら「何も返って来なかった」、途中で切られたら「切られた」。
    ///
    /// 打ち切りを `.unreachable` に丸めないのは本物がそうしないから ——
    /// `SendClient` も `InterruptClient` も `ChoiceClient` も、
    /// `CancellationError` と `URLError.cancelled` を `.cancelled` として
    /// 独立に返す。画面が消えた時に失敗の帯を出さないのは、その区別が
    /// 効いているから。
    static func holdThenGiveUp() async -> SendOutcome {
        do {
            try await Task.sleep(for: hold)
        } catch {
            return .cancelled
        }
        return .unreachable
    }
}

struct MessageSendingFixture: MessageSending {
    func send(baseURL: URL, apiKey: String, sessionID: String, text: String) async -> SendOutcome {
        await WriteFixture.holdThenGiveUp()
    }
}

struct InterruptingFixture: Interrupting {
    func interrupt(baseURL: URL, apiKey: String, sessionID: String) async -> SendOutcome {
        await WriteFixture.holdThenGiveUp()
    }
}

/// 取り消し(queue)も同じ理由で**返らない**(頭の3つの規約ごと)。挙動は
/// `holdThenGiveUp()` と同じ持ち方だが、返す型が `ClearQueueOutcome` なので
/// 対応する2枝(取消し / 届かない)へ写して返す。
struct QueueClearingFixture: QueueClearing {
    func clearQueue(baseURL: URL, apiKey: String, sessionID: String) async -> ClearQueueOutcome {
        switch await WriteFixture.holdThenGiveUp() {
        case .cancelled: return .error("Cancelled")
        default: return .error("Can't reach the desk")
        }
    }
}

struct ChoiceSendingFixture: ChoiceSending {
    /// `serverDigest` は `nil`。「サーバは今の指紋について何も言っていない」の意で、
    /// `ChoiceAttempt` 自身が「不在を『変わっていない』と読むな」と書いている通り、
    /// 何も届いていないこの場面で入れられる値は他に無い。
    func choose(
        baseURL: URL, apiKey: String, sessionID: String, key: String, digest: String
    ) async -> ChoiceAttempt {
        ChoiceAttempt(outcome: await WriteFixture.holdThenGiveUp(), serverDigest: nil)
    }
}

#endif
