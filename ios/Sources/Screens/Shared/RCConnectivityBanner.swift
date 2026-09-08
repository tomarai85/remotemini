import SwiftUI

/// 机との間の異常を描く**唯一の帯**(2026-09-08、案 D)。文言と段は `Connectivity`(純関数)が決め、此処は其の段の
/// 強さから見た目だけを決める。
///
/// 之まで: 共有の赤い帯 / 会話だけの 3 段階の行 / 設定の口座行 —— 同じ「机との間が怪しい」に 3 つの見た目が在り、
/// 段階の梯子なのに**実装された場所**で形が分かれていた(棚卸し (a))。今は形が 1 つで、段は色と太さだけが変わる。
struct RCConnectivityBanner: View {
    let stage: Connectivity.Stage
    let identifier: String
    /// 段が `noResponse` の時だけ出す手当て(会話の「今すぐ確認」「読み直す」)。無ければ出さない。
    var actions: [Action] = []

    struct Action: Identifiable {
        let id: String
        let label: String
        let run: () -> Void
    }

    private var message: Connectivity.Message { Connectivity.message(for: stage) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(message.title)
                .font(.caption.weight(.semibold))
            Text(message.detail)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            if !actions.isEmpty {
                HStack(spacing: 16) {
                    ForEach(actions) { a in
                        Button(action: a.run) {
                            Text(a.label).tapTarget()
                        }
                        .accessibilityIdentifier(a.id)
                    }
                }
                .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(background)
        .foregroundStyle(tint)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
        // ★段が変わる時だけ動く(2026-09-07、案 F と同じ値駆動)。
        .animation(.snappy(duration: 0.25), value: message)
    }

    /// 色は段の強さだけから決める(文言と 2 箇所で決めない)。
    private var tint: Color {
        switch message.severity {
        case .note: return .secondary
        case .caution: return RCTheme.caution
        case .alarm: return .red
        }
    }

    @ViewBuilder
    private var background: some View {
        switch message.severity {
        case .note: RCTheme.surface
        case .caution: RCTheme.caution.opacity(0.12)
        case .alarm: Color.red.opacity(0.15)
        }
    }
}
