import SwiftUI

/// 一覧の画面の右上に出る、口座の名乗り + 設定画面への入口(REQUIREMENTS §4-5 / §9-4)。
/// 表示専用 —— 判断は全部 `AccountViewModel` の物。
///
/// ★2026-08-14 に**切替そのものを此処から出した**(Tom §9-3 / §9-4)。
///   以前は此のバーが確認シートを出して `POST /api/account/next` を撃っていた。
///   矢印1本しか無かったのは、線に候補が乗っていなかったのが半分、
///   **工具帯の1マスに切替を押し込んでいた**のがもう半分。名指しで選ぶには
///   4本の候補と各行の断り理由が要り、それは1マスに入らない。
///   バーの仕事は「今どの口座か」を名乗る事と、設定画面へ渡す事の2つに絞った。
///
/// ★`.accessibilityElement(children: .contain)` を容器に併記する理由: SwiftUI は
///   容器に付けた識別子を**子へ伝播させて中の識別子を上書きする** —— 此の repo が
///   2026-08-12 に実測し、`account.label` が画面から消えて UI 検査3本が落ちた罠。
struct AccountBar: View {
    @ObservedObject var viewModel: AccountViewModel
    /// 設定画面に渡す(机の在り処の表示に使う)。バー自身は使わない。
    let baseURL: URL
    /// 設定画面の「計器」節に渡す(走査行・鮮度)。バー自身は使わない。
    /// ★2026-08-16(spec-audit A4): 計器を一覧の面から設定へ移した。此のバーが
    ///   一覧→設定の唯一の通路なので、計器の値も此処を通る。nil = 一覧以外の面から
    ///   開いた設定(計器の節ごと出さない — 無い物を空欄で出さない)。
    var listViewModel: ListViewModel? = nil
    /// 保管の面の束(§9-1)。一覧 → 設定への通路が此処しか無いので相乗りする。
    var archiveDeps: SettingsView.ArchiveDeps? = nil

    @Environment(\.scenePhase) private var scenePhase
    /// 一覧と**同じ器**(`ForegroundResume`)。背面への出入りは `.inactive` を挟んで
    /// 2段で配られるので、`background -> active` の1辺を見る実装は決して発火しない
    /// —— 其の欠陥を5 sprint 見逃した記録が `ForegroundResume` の頭に在る。
    /// 判定を書き直さず共有する事が、同じ穴を2つ目に作らない唯一の形。
    @State private var resumeGate = ForegroundResume()

    var body: some View {
        NavigationLink {
            SettingsView(accountViewModel: viewModel, baseURL: baseURL, listViewModel: listViewModel, archiveDeps: archiveDeps)
        } label: {
            label
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("account.open")
        // ★`.task` を `EmptyView` に付けない。SwiftUI は `EmptyView` に修飾子の
        //   生存期間を付けないので、`load()` が一度も呼ばれず相が永久に `.idle` に
        //   留まる —— 単体は全部緑のまま**実機でも口座が永久に出ない**欠陥で、
        //   2026-08-12 に UI 検査5本で観測した。`NavigationLink` は常に何かを描くので
        //   此の形なら生存期間が付く。
        .task { await viewModel.load() }
        // ★背面から戻ったら読み直す(2026-08-12、Codex 指摘)。
        //   `.task` は前面復帰では再発火しないので、之が無いと
        //   「表示したまま背面 -> 机や別の端末で口座を変える -> 復帰」で
        //   **画面だけが古い口座を名乗り続ける**。電話が嘘をつく形。
        .onChange(of: scenePhase) { _, newPhase in
            if resumeGate.shouldResume(newPhase: newPhase) {
                Task { await viewModel.load() }
            }
        }
    }

    @ViewBuilder
    private var label: some View {
        switch viewModel.phase {
        case .idle, .loading:
            // ★`.idle` と `.loading` は**モデルでは別物**(片方は「まだ訊いていない」、
            //   もう片方は「訊いている最中」)だが、**描画は同じ**。空白にしないのが要点で、
            //   空白は「口座が無い」と読める —— 単に見ていないだけの時に言ってはいけない事。
            ProgressView()
                .controlSize(.small)
                .accessibilityIdentifier("account.loading")
        case .loaded(let state):
            HStack(spacing: 4) {
                if viewModel.isBusy { ProgressView().controlSize(.small) }
                Text(state.current ?? "(not set)")
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("account.label")
                // 一覧が読めていない事は**バーでも判る**様にする。設定画面を開くまで
                // 気付けないと、切替を試して初めて壊れていると知る事になる。
                if !state.ok {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("account.degraded")
                }
            }
        case .failed(let reason):
            // 失敗も押せるまま置く。行き先(設定画面)に「もう一度読む」が在るので、
            // 死んだラベルにせずに済む。
            Text(reason)
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityIdentifier("account.failed")
        }
    }
}
