import SwiftUI

/// Spec §2-1 / §5-1. No default host is shown anywhere on this screen -- the
/// placeholder is a bare scheme, not a real or example tailnet address (hard
/// constraint: no hardcoded host in source, not even as a placeholder).
///
/// ★2026-08-08(監査 X2-6、DESIGN §2.65)。この画面には**2通りの来かた**が在る。
/// 初回(何も知らない)と、401 で落とされた後(通っていた鍵が拒まれた)。以前は
/// どちらも同じ白紙で、後者は「なぜ戻されたか」も「どの URL に居たか」も出さなかった。
/// `notice` はその差を運ぶ唯一の入力で、`nil` なら画面は従来どおり初回の顔になる。
struct KeyEntryView: View {
    @StateObject private var viewModel: KeyEntryViewModel

    /// 断りの文。`nil` の時は節ごと出さない —— 初回の画面に空の枠を残さない為。
    ///
    /// `private` にしていないのは検査の都合(`KeyEntryViewTests` ⑤)。純関数の
    /// `sentence(for:)` だけを測ると、`init` が `notice` を捨てる実装が緑のまま通る。
    let noticeText: String?

    /// - Parameter clients: 背後の3つの口。**既定値を置かない**。
    ///
    ///   2026-08-08 まで此処は何も渡しておらず、`KeyEntryViewModel` 側の既定値
    ///   (本物の HTTP client 2つと `KeychainCredentialStore`)がそのまま生きていた ——
    ///   UI 検査の面に出ているこの画面が**開発機の実 Keychain** を握っていた事になる。
    ///   露見しなかったのは接続ボタンを押す検査が1本も無かったから。理由の全文は
    ///   `ios/Sources/Core/KeyEntryClients.swift`。
    init(clients: KeyEntryClients,
         notice: SignOutNotice? = nil,
         onSaved: @escaping (Credentials) -> Void) {
        self.noticeText = Self.sentence(for: notice)
        // URL は**届いた上で 401 が返った**ので正しい事が観測済み。打ち直させない。
        _viewModel = StateObject(wrappedValue: KeyEntryViewModel(clients: clients,
                                                                initialBaseURL: notice?.baseURL,
                                                                onSaved: onSaved))
    }

    var body: some View {
        Form {
            if let noticeText {
                Section {
                    Text(noticeText)
                        .accessibilityIdentifier("keyEntry.signOutNotice")
                }
            }

            Section {
                // ★確かめている間は両方とも触れない。打てる欄を残すと、返事を待つ間に
                // 打ち替えた値と**今飛んでいる要求が確かめている値**が食い違う ——
                // その状態で返って来た「鍵が違います」は、画面に見えている鍵の話ではない。
                TextField("Base URL", text: $viewModel.baseURLText, prompt: Text("https://"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .disabled(viewModel.isChecking)
                    .accessibilityIdentifier("keyEntry.baseURL")
                SecureField("API Key", text: $viewModel.apiKeyText)
                    .disabled(viewModel.isChecking)
                    .accessibilityIdentifier("keyEntry.apiKey")
            } footer: {
                // 2026-08-08(監査 X2-8)。此処は以前、押してから最大16秒**空白**だった。
                // 出るのは丸い印だけで、何を待っているのか・いつ諦めるのかは何処にも
                // 書いていない。DESIGN §2.68。
                //
                // 2つは排他。`submit()` が先頭で `errorMessage = nil` にするので、
                // 走っている間に古い赤が下に居座る事は無い。
                if let inFlight = viewModel.inFlightText {
                    Text(inFlight)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("keyEntry.inFlight")
                } else if let message = viewModel.errorMessage {
                    Text(message)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("keyEntry.error")
                }
            }

            Section {
                Button {
                    Task { await viewModel.submit() }
                } label: {
                    if viewModel.isChecking {
                        ProgressView()
                    } else {
                        Text("Connect")
                    }
                }
                .disabled(viewModel.isChecking || viewModel.baseURLText.isEmpty || viewModel.apiKeyText.isEmpty)
                .accessibilityIdentifier("keyEntry.submit")
            } footer: {
                // 識別子は 2026-08-08(監査 X2-7)に付けた。それまで此処が版の**唯一**の
                // 出所だったのに、名前が無いのでどの検査からも見えていなかった ——
                // 「出ている」を主張していたのは人の記憶だけ。
                Text(BuildInfo.line)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("keyEntry.buildInfo")
            }
        }
        .rcThemedSurface()
        .navigationTitle("Remote Mini")
    }

    /// 断り → 文。view body から出してあるのは `ConversationView.color(for:)` と同じ理由で、
    /// body の中に書くと画面の規則なのにどの検査からも触れなくなるから。
    ///
    /// ★色を付けない。赤は下の `keyEntry.error` が持っていて、あちらは「**今入れた物**が
    /// 悪い」の意味。断りは入力の誤りではなく**さっき起きた事実**なので、同じ色にすると
    /// 入れてもいない鍵を責められているように読める。節を分けるだけで役割は伝わる。
    ///
    /// ★`~/.rc-backend/api.key` の様な**電話から観測できない場所**は書かない。書けば
    /// 尤もらしいが、この app はその path を一度も見ていないので、edith 側で置き場が
    /// 変わった日から静かに嘘になる。鍵の在り処は `PRE-DEPARTURE-2026-08-20.md` の仕事。
    static func sentence(for notice: SignOutNotice?) -> String? {
        guard let notice else { return nil }
        switch notice.reason {
        case .keyRejected:
            // URL 欄に前の値が入っている事まで言う。言わないと、埋まっている欄を見た側は
            // 「前回の入力が残っている」のか「app が復元した」のか判らず、消してから
            // 打ち直す —— 打ち直しを省く為に入れたのに、省けない。
            if notice.baseURL != nil {
                return "The key that used to work was rejected by the server. The URL is kept from before — re-enter just the key."
            }
            return "The key that used to work was rejected by the server. Enter it again."
        }
    }
}
