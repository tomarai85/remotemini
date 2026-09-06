import SwiftUI

/// 其の会話の下で何が走っているかを電話で見る画面(対照表 #8「半分その一」、2026-09-05)。
/// 公式の remote control の言い方では「the device shows any subagents and workflows the
/// session already has running in the background」。**止める方(`x` を押す)は別の段**で、
/// 此処は打鍵を1つも要らない読むだけの画面(`research/subagent-stop-panel-design-2026-09-04.md`)。
///
/// 遷移は `DiffView` と同じ push(このアプリに `.sheet` はどこにも無い)。
struct SubagentsView: View {
    @StateObject private var viewModel: SubagentsViewModel

    init(viewModel: @autoclosure @escaping () -> SubagentsViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel())
    }

    var body: some View {
        content
            .background(RCBackdrop())
            .navigationTitle("Running")
            .navigationBarTitleDisplayMode(.inline)
            .task { await viewModel.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .loading:
            ScrollView {
                ProgressView()
                    .padding(.top, 80)
                    .accessibilityIdentifier("subagents.loading")
            }

        case .failed(let message):
            VStack(spacing: 12) {
                Text(message)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Button {
                    Task { await viewModel.load() }
                } label: {
                    Text("Retry").tapTarget()
                }
                .accessibilityIdentifier("subagents.retry")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("subagents.failed")

        case .loaded(let body):
            loadedContent(body)
        }
    }

    @ViewBuilder
    private func loadedContent(_ body: SubagentsBody) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // ★机が決めた1文を**そのまま**出す。空配列には意味が3つ在り(本当に居ない /
                //   dir が読めない / 終わったかを知らない)、其の見分けは机が既に済ませて
                //   `display.note` に畳んである。電話が綴りで組み直すと、同じ判断が2箇所に散る。
                Text(body.display.note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("subagents.note")

                ForEach(body.subagents) { row in
                    SubagentRowCard(row: row)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("subagents.list")
    }
}

/// 1本ぶんの札。**要約を主役にする** —— 人が最初に読みたいのは種別ではなく
/// 「何をさせている物か」で、其れは呼んだ側が書いた `description` に在る。
private struct SubagentRowCard: View {
    let row: SubagentRow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(row.description ?? row.agentType ?? row.agentId)
                .font(.callout)
                .accessibilityIdentifier("subagents.row.title")

            HStack(spacing: 8) {
                // ★状態の言葉は机が持つ(`display.state`)。電話は `state` の綴りで
                //   分岐せず描くだけ —— `unknown` を「作業中」に丸める道を作らない。
                Text(row.display.state)
                    .accessibilityIdentifier("subagents.row.state")
                if let type = row.agentType {
                    Text(type)
                }
                if let model = row.model {
                    Text(model)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(.thinMaterial))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("subagents.row")
    }
}
