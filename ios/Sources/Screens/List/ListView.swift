import SwiftUI

/// The List screen (Sprint 2 brief §3/§4/§4-a). Renders `ListViewModel.phase` --
/// see that type for the full state-machine rationale; this file is display only.
struct ListView: View {
    @StateObject private var viewModel: ListViewModel
    @Environment(\.scenePhase) private var scenePhase
    /// 引き金 #3 の器。`@State` なのは、判定が**1辺では決まらない**から ——
    /// `.onChange` の呼び出しを跨いで「背面を通ったか」を憶える必要が在る。
    @State private var resumeGate = ForegroundResume()

    // Sprint 3 brief §1-a (List -> Conversation navigation): kept as plain
    // constructor params here rather than read off `viewModel` (which keeps its own
    // `baseURL`/`apiKey`/`onUnauthorized` private) -- `ListViewModel`'s encapsulation
    // was set by Sprint 2 for Sprint 2's own needs; loosening it just so this view can
    // build the next screen's `ConversationViewModel` would spend Sprint 2's design
    // for a Sprint 3 convenience. `RootView` already holds all three at the call site.
    private let baseURL: URL
    private let apiKey: String
    private let onUnauthorized: () -> Void

    init(
        viewModel: @autoclosure @escaping () -> ListViewModel,
        baseURL: URL,
        apiKey: String,
        onUnauthorized: @escaping () -> Void
    ) {
        _viewModel = StateObject(wrappedValue: viewModel())
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.onUnauthorized = onUnauthorized
    }

    var body: some View {
        ZStack(alignment: .top) {
            content
            if showsRefreshingIndicator {
                ProgressView()
                    .padding(8)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.top, 6)
                    .accessibilityIdentifier("list.refreshing")
            }
        }
        // ★帯は**相ごとではなく此処で一度だけ**貼る(2026-08-08 / 監査 X2-7)。
        // 以前は `content` の中の3つの case にだけ `.safeAreaInset` が付いていて、
        // 失敗している3相(`.initialLoading` / `.retryable` / `.unreachable`)では
        // 帯ごと消えていた。帯には版の名乗りが載るので、「古いビルドで動いていないか」を
        // 最も疑う場面で版が見えない、という向きの欠け方をしていた。
        // 走査行を持つかは `ListViewModel.Phase.scanLine` が答える(default 無しの
        // switch なので、新しい相はそれを答えずには足せない)。
        .safeAreaInset(edge: .bottom) { footer(scanLine: viewModel.phase.scanLine) }
        .navigationTitle("セッション")
        .refreshable { await viewModel.refresh() } // pull-to-refresh (brief §3-d trigger #2)
        .task { await viewModel.refresh() } // initial display (brief §3-d trigger #1)
        // Foreground-resume (brief §3-d trigger #3). No timer anywhere in this screen
        // (§2-2/§3-c): this is the one non-user-initiated refresh trigger, and it
        // fires once per background round trip, not on an interval.
        //
        // ★2026-08-08 実測で此処は**2つ**欠けていた。どちらも画面には出ない類:
        //   ① 此処は Sprint 3 から `oldPhase` を捨てて `newPhase == .active` だけを
        //      見ていた。iOS は起動そのものを `.inactive -> .active` で通すので、
        //      直上の `.task` の初回取得と重なって**起動のたびに2回**机側へ走査が
        //      飛んでいた。通知バナーや Control Center の上下でも同じ。
        //   ② では会話画面が Sprint 4 で置いた
        //      `oldPhase == .background && newPhase == .active` を借りれば済むかと
        //      いうと済まない —— その辺は iOS が**一度も配らない**(復帰は
        //      `background -> inactive -> active` の2段)。つまり会話側の N4 も
        //      発火していなかった。実測列は `ForegroundResume` の doc に全文。
        //   だから直しは条件の借用ではなく、履歴を憶える器の共有になった。
        .onChange(of: scenePhase) { _, newPhase in
            if resumeGate.shouldResume(newPhase: newPhase) {
                Task { await viewModel.refresh() }
            }
        }
    }

    private var showsRefreshingIndicator: Bool {
        guard viewModel.isRefreshing else { return false }
        if case .initialLoading = viewModel.phase { return false } // that phase already shows its own spinner
        return true
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .initialLoading:
            ScrollView {
                ProgressView()
                    .padding(.top, 80)
                    .accessibilityIdentifier("list.loading")
            }

        case .empty:
            ScrollView {
                Text("会話がありません")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 80)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("list.empty")
            }

        case .paneFault(let reason, let detail, let sessions, _):
            VStack(spacing: 0) {
                faultBanner(reason: reason, detail: detail)
                    .accessibilityIdentifier("list.paneFault")
                if sessions.isEmpty {
                    // Brief §4: paneFault + no sessions shows the banner ALONE --
                    // never stacked with "会話がありません" or any other filler.
                    ScrollView { Color.clear.frame(height: 1) }
                } else {
                    rows(sessions, grayedOut: false)
                }
            }

        case .list(let sessions, _):
            rows(sessions, grayedOut: false)

        case .retryable(let priorSessions):
            VStack(spacing: 0) {
                if let sessions = priorSessions {
                    // 1-2 failures with a prior list: keep it, un-grayed, with a
                    // subtle one-line notice -- explicitly NOT a red banner
                    // (brief §4-a).
                    noticeBar("しばらく取得できていません。前回の一覧を表示しています。", identifier: "list.retryable")
                    rows(sessions, grayedOut: false)
                } else {
                    // The third, distinct state (brief §4-a): a failed first fetch
                    // with nothing to fall back on -- not `.empty`, not a bare
                    // spinner.
                    ScrollView {
                        Text("まだ取れていません")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                            .padding(.top, 80)
                            .frame(maxWidth: .infinity)
                            .accessibilityIdentifier("list.retryable")
                    }
                }
                retryButton()
            }

        case .unreachable(let priorSessions):
            VStack(spacing: 0) {
                // Spec §5-4, shared with Conversation as of Sprint 6. The old
                // hand-rolled banner here led with 「バックエンドに接続できません」,
                // which named a cause this screen cannot observe -- see
                // `UnreachableBanner`'s doc. Keeps its own a11y id in ADDITION to the
                // component's `shared.unreachable`, because Sprint 2's tests and the
                // §5-2 screen table both refer to `list.unreachable` by name.
                UnreachableBanner(
                    failures: viewModel.reachability.consecutiveFailures,
                    context: .list,
                    identifier: "list.unreachable"
                )
                if let sessions = priorSessions {
                    // Brief §4-a: gray out, never replace with an empty list.
                    rows(sessions, grayedOut: true)
                } else {
                    ScrollView { Color.clear.frame(height: 1) }
                }
                retryButton()
            }
        }
    }

    @ViewBuilder
    private func rows(_ sessions: [SessionRow], grayedOut: Bool) -> some View {
        List(sessions, id: \.id) { row in
            // Trailing-closure `NavigationLink(destination:label:)`: the destination
            // closure is only evaluated on actual navigation, so this does not
            // eagerly construct a `ConversationViewModel` (and issue no fetch until
            // `ConversationView`'s own `.task` runs) per row just because the List
            // rendered.
            NavigationLink {
                ConversationView(viewModel: makeConversationViewModel(for: row))
            } label: {
                SessionRowView(row: row, nowMs: Date().timeIntervalSince1970 * 1000)
            }
        }
        .listStyle(.plain)
        .opacity(grayedOut ? 0.5 : 1)
        .disabled(grayedOut)
    }

    /// ★この関数が**開くたびに新しい ViewModel を作る**事が、DESIGN §2.53 の理由その物。
    /// 打ちかけを ViewModel の平のプロパティに置いておくと、会話から一覧へ戻って開き直す
    /// だけで消える —— OS も網も机も関係しない。`draftStore` を渡す事で、打ちかけの寿命が
    /// 「画面」ではなく「セッション」に付く。
    ///
    /// store を毎回作り直しているのは、`UserDefaultsDraftStore` が読み書きのたびに
    /// 全部を読み直す設計だから(写しを抱えないので、複数インスタンスが互いの
    /// セッションを消さない)。「共有インスタンスにする」という呼ぶ側の約束に
    /// 正しさを預けない為の形で、`DraftStoreTests` の⑥がそれを固定している。
    private func makeConversationViewModel(for row: SessionRow) -> ConversationViewModel {
        ConversationViewModel(
            clients: .live,
            draftStore: UserDefaultsDraftStore(),
            baseURL: baseURL,
            apiKey: apiKey,
            sessionID: row.id,
            title: row.displayTitle,
            onUnauthorized: onUnauthorized
        )
    }

    /// `scanLine == nil` = 机側の走査行をまだ一度も受け取っていない相。行ごと出さない
    /// (空文字を出すと「走査が空だった」に読めるので、無い物は無いままにする)。
    /// 版の行はその場合も出る —— 取得が失敗している時こそ「電話が古いのでは」を疑う。
    private func footer(scanLine: String?) -> some View {
        VStack(spacing: 2) {
            freshnessLine()
            if let scanLine {
                Text(scanLine) // brief §3-b: rendered verbatim, never reassembled client-side
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("list.scanLine")
            }
            Text(BuildInfo.line)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("list.buildInfo")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.bar)
    }

    @ViewBuilder
    private func freshnessLine() -> some View {
        // Re-evaluated at every redraw (this computed property runs whenever body
        // does) rather than on a timer -- brief §2-2/§3-c forbid polling here.
        if viewModel.lastFetchedAtMs > 0 {
            let freshness = Freshness.freshness(viewModel.lastFetchedAtMs, nowMs: Date().timeIntervalSince1970 * 1000)
            Text(freshness.text)
                .font(.caption)
                .foregroundStyle(freshness.stale ? .orange : .secondary)
                .accessibilityIdentifier("list.freshness")
        }
    }

    private func noticeBar(_ message: String, identifier: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(.bar)
            .accessibilityIdentifier(identifier)
    }

    /// paneFault only, as of Sprint 6 -- the unreachable arm moved to the shared
    /// `UnreachableBanner`. The `style` parameter went with it rather than being kept
    /// "in case": a two-case enum with one live case is a branch nothing exercises,
    /// which this project has repeatedly measured as the shape that looks like a
    /// guard and measures nothing.
    private func faultBanner(reason: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(reason).font(.subheadline.weight(.semibold))
            Text(detail).font(.caption)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.orange.opacity(0.15))
        .foregroundStyle(Color.orange)
    }

    private func retryButton() -> some View {
        Button {
            Task { await viewModel.refresh() }
        } label: {
            // ★X2-3。`.padding()` は Button の**外**に在るので、広く見えるのに
            // 押せるのは文字の上だけだった。旅程で「一覧が出ない」は最も起きやすい
            // 失敗で、これはその時に押す唯一の的。
            Text("再試行").tapTarget()
        }
        .padding()
        .accessibilityIdentifier("list.retry")
    }
}

private struct SessionRowView: View {
    let row: SessionRow
    let nowMs: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.displayTitle)
                    .font(row.display.route.kind == .choice ? .headline.bold() : .headline)
                Spacer()
                Text(RelTime.relTime(row.updatedAt, nowMs: nowMs))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(row.display.subtitle) // server-computed (brief §3-a) -- rendered as-is, never reassembled
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(alignment: .top, spacing: 6) {
                Text(row.display.route.short)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(routeColor)
                Text(row.display.route.text)
                    // Never truncated to one line -- brief §3-a: up to 92 characters.
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .listRowBackground(row.display.route.kind == .choice ? Color.red.opacity(0.08) : nil)
    }

    /// Brief §3-a: distinct visual treatment per `kind`, `choice` carrying the
    /// strongest emphasis (the only state where Enter on the desk side becomes an
    /// approval/charge).
    private var routeColor: Color {
        switch row.display.route.kind {
        case .choice: return .red
        case .tmux: return .primary
        case .worker: return .blue
        case .blocked: return .orange
        case .unknown: return .gray
        }
    }
}
