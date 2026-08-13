import SwiftUI

/// The account label + switch control (REQUIREMENTS §4-5 / §5-8). Display only --
/// every decision is `AccountViewModel`'s.
///
/// ★Why the switch is behind a confirmation and not a bare button: `POST
/// /api/account/next` mutates fleet-wide state, and the phone is a device operated
/// with a thumb while walking. The requirement is "スムーズに" (smooth), which is
/// satisfied by two taps in one place; it is not satisfied by an account that changes
/// because a pocket brushed the screen.
///
/// ★Why `.accessibilityElement(children: .contain)` is on the container: attaching an
/// identifier to a container in SwiftUI propagates it to the children and overwrites
/// every identifier underneath -- a trap this project has already been bitten by and
/// records in its handoff. Any container carrying an identifier must pair it with this.
struct AccountBar: View {
    @ObservedObject var viewModel: AccountViewModel
    @State private var confirming = false
    @Environment(\.scenePhase) private var scenePhase
    /// 一覧と**同じ器**(`ForegroundResume`)。背面への出入りは `.inactive` を挟んで
    /// 2段で配られるので、`background -> active` の1辺を見る実装は決して発火しない
    /// —— 其の欠陥を5 sprint 見逃した記録が `ForegroundResume` の頭に在る。
    /// 判定を書き直さず共有する事が、同じ穴を2つ目に作らない唯一の形。
    @State private var resumeGate = ForegroundResume()

    var body: some View {
        Group {
            switch viewModel.phase {
            case .idle, .loading:
                // ★`.idle` と `.loading` は**モデルでは別物**(片方は「まだ訊いていない」、
                //   もう片方は「訊いている最中」)だが、**描画は同じ**。
                //
                //   最初の版は `.idle` に `EmptyView()` を返していた。単体は全部緑のまま
                //   UI 検査5本が落ち、原因は表示ではなく**下の `.task` が繋がらない事**
                //   だった —— SwiftUI は `EmptyView` に修飾子の生存期間を付けないので、
                //   `load()` が一度も呼ばれず相は永久に `.idle` に留まる。
                //   検査の都合ではなく**実機でも口座が永久に出ない**欠陥で、
                //   `AccountViewModel` の単体をいくら足しても届かない層に在った
                //   (此の repo が M8 / M9 / M17 で繰り返し測っている形)。
                //
                //   「まだ訊いていない」を空白で表すのは、**空白が主張を持たない**という
                //   前提に立っていた。実際には空白は「描く物が無い」= 修飾子も付かない、
                //   という別の意味を持っていた。
                ProgressView()
                    .controlSize(.small)
                    .accessibilityIdentifier("account.loading")
            case .loaded(let account, let switching):
                Button {
                    confirming = true
                } label: {
                    HStack(spacing: 4) {
                        if switching { ProgressView().controlSize(.small) }
                        Text(account)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .accessibilityIdentifier("account.label")
                    }
                }
                .buttonStyle(.plain)
                .disabled(switching)
                // ★`Button` は容器なので、識別子を付けると**子へ伝播して中の
                //   `account.label` を上書きする**(此の repo の引き継ぎが明記している罠。
                //   2026-08-12 に実測: `account.label` が画面から消え、UI 検査3本が
                //   「口座のラベルが画面に無い」で落ちた)。`children: .contain` を
                //   併記して初めて、押せる容器と読める中身が両立する。
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("account.switch")
                .confirmationDialog(
                    "アカウントを切り替えますか",
                    isPresented: $confirming,
                    titleVisibility: .visible
                ) {
                    Button("次のアカウントへ") {
                        Task { await viewModel.advance() }
                    }
                    .accessibilityIdentifier("account.confirm")
                    // ★識別子を付けない。`role: .cancel` は iOS が確認シートの別枠に
                    //   描くので識別子が付かず(2026-08-12 実測)、付けた振りをすると
                    //   「在るのに測れない錨」になる。負の対照は取消を押す形ではなく
                    //   「1回目のタップで動かない」を直に測る形にした(AccountUITests ⑤)。
                    Button("やめる", role: .cancel) {}
                } message: {
                    Text("現在: \(account)")
                }
            case .failed(let reason):
                // Failures stay tappable: the recovery for "机に届きません" is to try
                // again, and a dead label gives the person nothing to press.
                Button {
                    Task { await viewModel.load() }
                } label: {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("account.failed")
            }
        }
        .accessibilityElement(children: .contain)
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
}
