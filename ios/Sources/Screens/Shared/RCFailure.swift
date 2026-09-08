import SwiftUI

/// 「読めなかった」画面の唯一の形(2026-09-07、案 C)。
///
/// 何が問題だったか(棚卸し `.harness/evidence-2026-09-07/ui-inventory.md` (a)): 同じ「もう一度」が画面ごとに 6 通りの形で
/// 実装されていた —— 素の文字ボタン / 目立つ枠 / 「Retry」と「Re-read」の 2 択。形が機能で分かれておらず、**其の画面が
/// 何時 足されたか**で分かれていた。読み手は毎回「之は同じ物か」を判断させられる。
///
/// 此の型が決める 2 つ:
///   1. 失敗の文は机の言葉を其のまま(電話は言い換えない)。
///   2. ボタンは**何を読み直すか**を言う(「Retry」だけでは、押した後に何が起きるか分からない)。
struct RCFailure: View {
    /// 机が返した失敗の一文。
    let message: String
    /// ボタンの文。**動詞 + 目的語**(例 `Read the diff again`)。「Retry」単体は使わない。
    let verb: String
    /// 既存の識別子(例 `diff.retry`)。検査と UI 自動化が指す字を変えない。
    let identifier: String
    /// 押した時にやり直す物。
    let action: () async -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text(message)
                .font(.callout)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal)
            Button {
                Task { await action() }
            } label: {
                Text(verb).tapTarget()
            }
            .accessibilityIdentifier(identifier)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }
}
