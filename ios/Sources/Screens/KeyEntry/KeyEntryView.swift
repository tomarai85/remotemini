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

    init(notice: SignOutNotice? = nil, onSaved: @escaping (Credentials) -> Void) {
        self.noticeText = Self.sentence(for: notice)
        // URL は**届いた上で 401 が返った**ので正しい事が観測済み。打ち直させない。
        _viewModel = StateObject(wrappedValue: KeyEntryViewModel(initialBaseURL: notice?.baseURL,
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
                TextField("Base URL", text: $viewModel.baseURLText, prompt: Text("https://"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .accessibilityIdentifier("keyEntry.baseURL")
                SecureField("API Key", text: $viewModel.apiKeyText)
                    .accessibilityIdentifier("keyEntry.apiKey")
            } footer: {
                if let message = viewModel.errorMessage {
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
                        Text("接続")
                    }
                }
                .disabled(viewModel.isChecking || viewModel.baseURLText.isEmpty || viewModel.apiKeyText.isEmpty)
                .accessibilityIdentifier("keyEntry.submit")
            } footer: {
                Text(BuildInfo.line)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
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
                return "通っていた鍵がサーバに拒まれました。URL は前のまま入れてあるので、鍵だけ入れ直してください。"
            }
            return "通っていた鍵がサーバに拒まれました。鍵を入れ直してください。"
        }
    }
}
