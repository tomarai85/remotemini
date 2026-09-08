import SwiftUI

/// 其の会話の下で何が走っているかを電話で見る画面(対照表 #8「半分その一」、2026-09-05)と、
/// 名指した 1 本を止める(「半分その二」、2026-09-06)。公式の remote control の言い方では
/// 「the device shows any subagents and workflows the session already has running in the background.
/// Stop one of them from the device, and Claude Code stops that task on your machine」。
///
/// 止めるのは机の仕事(`research/subagent-stop-panel-design-2026-09-04.md`)。電話は id を名指し、
/// 机がパネルを開いて詳細で照合してから `x` を押す。電話は**画面の行の位置を送らない**。
/// ボタンは 2 段(構える → 同じ行をもう一度)。取り消せない操作を指の滑りで送らない。
///
/// 遷移は `DiffView` と同じ push(このアプリに `.sheet` はどこにも無い)。
struct SubagentsView: View {
    /// 机の 1 文を**そのまま**描く(綴りで組み直さない)。机の一覧は背景シェルとチームの一員を見ないので、其れを名乗る文も
    /// 机が `display.note` に畳む(対照表 #8 の後半の限界 2、2026-09-07)。view body の中に置くと検査から触れないので
    /// 静的関数に持ち上げてある。検査 = `SubagentsBlindSpotNoteTests`、対照 = `device-ui-subagents-note-controls.sh`。
    static func noteText(_ body: SubagentsBody) -> String { body.display.note }
    /// `subagents.note` の識別子。検査が同じ字を要求する。
    static let noteAccessibilityID = "subagents.note"

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
                Text(SubagentsView.noteText(body))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(SubagentsView.noteAccessibilityID)

                // 直前の停止の結果(成功 / 机の断りの文)。机の文をそのまま。
                if let notice = viewModel.stopNotice {
                    Text(notice)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(.thinMaterial))
                        .accessibilityIdentifier("subagents.stopNotice")
                }

                ForEach(body.subagents) { row in
                    SubagentRowCard(
                        row: row,
                        stoppable: viewModel.canStop(row),
                        armed: viewModel.armed == row.agentId,
                        stopping: viewModel.stopping == row.agentId,
                        busy: viewModel.stopping != nil,
                        onStop: { Task { await viewModel.tapStop(row) } }
                    )
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("subagents.list")
        // 一覧の余白をタップしたら構えを解く(取り消せない操作は、意図が続いている間だけ 2 回目を受ける)。
        .onTapGesture { viewModel.disarm() }
    }
}

/// 1本ぶんの札。**要約を主役にする** —— 人が最初に読みたいのは種別ではなく
/// 「何をさせている物か」で、其れは呼んだ側が書いた `description` に在る。
/// 走っている行だけ「Stop」を持つ(止める物が無い行にボタンを置かない)。
private struct SubagentRowCard: View {
    let row: SubagentRow
    let stoppable: Bool
    let armed: Bool
    let stopping: Bool
    let busy: Bool
    let onStop: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
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

            // ★止めるボタンは「走っていて、此の画面で止めていない」行だけ(`viewModel.canStop`)。之は「描くか」の
            //   分岐であって、状態の言葉の言い換えではない(言葉は上の `display.state` が机の物をそのまま出す)。
            //   id は構えても変えない(UI 検査が参照を持ち越せる。研究レビュー 2026-09-07)—— 構えは value で言う。
            if stoppable {
                Button(action: onStop) {
                    if stopping {
                        ProgressView()
                            .frame(minWidth: 44, minHeight: 44)
                    } else {
                        Text(armed ? "Confirm stop" : "Stop")
                            .font(.callout)
                            .tapTarget()
                    }
                }
                .buttonStyle(.bordered)
                .tint(armed ? .red : .secondary)
                .disabled(busy)
                .accessibilityIdentifier("subagents.row.stop")
                .accessibilityValue(stopping ? "stopping" : armed ? "armed" : "idle")
                // ★構えが**見える**(2026-09-07、案 F)。此処はアプリで唯一の「取り消せない操作の 2 段タップ」なのに、
                //   ラベルも色も 1 フレームで入れ替わっていた —— 押した手応えが無いと、人は 1 度目を見落として 2 度押す。
                //   `armed` / `stopping` が変わった時だけ動く(値駆動。時間で動く物は置かない)。
                .animation(.snappy(duration: 0.2), value: armed)
                .animation(.snappy(duration: 0.2), value: stopping)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(.thinMaterial))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("subagents.row")
    }
}
