import SwiftUI

/// Spec §5-4's banner, in one place. Both List and Conversation render THIS -- the
/// spec asks for it by name: 「List/Conversation 共通のコンポーネントとして文言・見た目を
/// 1箇所にまとめる」.
///
/// ★It states what was measured and never names a cause. §5-5's own table lists three
/// possible causes for this state (電波 / edith 停止 / tailnet 切断) and the phone can
/// distinguish none of them. The pre-Sprint-6 List wording led with
/// 「バックエンドに接続できません」, which asserts the third-to-first of those as fact --
/// and did so even when the streak was actually made of contract violations, because
/// `ListViewModel` counts those too (see `ReachabilityMeter`'s doc). Leading with the
/// observation instead makes the sentence true for every streak that can reach it, and
/// costs the reader nothing: the second line already told them what to do.
///
/// No dismiss affordance, by spec: 「手動で『消す』操作は用意しない」. It goes away when
/// a request succeeds, and only then.
struct UnreachableBanner: View {
    /// Where this banner is drawn, which decides only the trailing hint -- the two
    /// screens can do different things about it (List can retry the listing; a
    /// Conversation's poll loop retries itself on its own backoff).
    enum Context {
        case list
        case conversation
    }

    let failures: Int
    let context: Context
    /// Supplied by the call site rather than fixed here. Sprint 2's tests and the
    /// spec's §5-2 screen table already name `list.unreachable`, and stacking a
    /// second `.accessibilityIdentifier` on the outside of this view to preserve
    /// that would leave which of the two wins as a question answerable only by
    /// running a UI test -- which this project cannot do on demand (no GUI on this
    /// machine). One identifier, chosen by the caller, has no such question.
    let identifier: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("バックエンドから応答がありません")
                .font(.subheadline.weight(.semibold))
            Text(detail)
                .font(.caption)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.red.opacity(0.15))
        .foregroundStyle(Color.red)
        .accessibilityIdentifier(identifier)
    }

    /// The count is printed rather than hard-coded to "3回": the banner stays up past
    /// the threshold, and a phone that has failed 40 times in a row saying "3回連続" is
    /// stating a stale measurement as the current one.
    private var detail: String {
        switch context {
        case .list:
            return "\(failures)回続けて取得に失敗しました。しばらくしてから再試行してください"
        case .conversation:
            return "\(failures)回続けて取得に失敗しました。表示は最後に読めた時点のままです"
        }
    }
}
