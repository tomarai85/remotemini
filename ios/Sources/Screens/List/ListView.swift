import SwiftUI

/// The List screen (Sprint 2 brief §3/§4/§4-a). Renders `ListViewModel.phase` --
/// see that type for the full state-machine rationale; this file is display only.
struct ListView: View {
    @StateObject private var viewModel: ListViewModel
    @Environment(\.scenePhase) private var scenePhase

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
        .navigationTitle("セッション")
        .refreshable { await viewModel.refresh() } // pull-to-refresh (brief §3-d trigger #2)
        .task { await viewModel.refresh() } // initial display (brief §3-d trigger #1)
        .onChange(of: scenePhase) { _, newPhase in
            // Foreground-resume (brief §3-d trigger #3). No timer anywhere in this
            // screen (§2-2/§3-c): this is the one non-user-initiated refresh trigger,
            // and it fires once per foreground transition, not on an interval.
            if newPhase == .active {
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

        case .empty(let scanLine):
            ScrollView {
                Text("会話がありません")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 80)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("list.empty")
            }
            .safeAreaInset(edge: .bottom) { footer(scanLine: scanLine) }

        case .paneFault(let reason, let detail, let sessions, let scanLine):
            VStack(spacing: 0) {
                faultBanner(reason: reason, detail: detail, style: .paneFault)
                    .accessibilityIdentifier("list.paneFault")
                if sessions.isEmpty {
                    // Brief §4: paneFault + no sessions shows the banner ALONE --
                    // never stacked with "会話がありません" or any other filler.
                    ScrollView { Color.clear.frame(height: 1) }
                } else {
                    rows(sessions, grayedOut: false)
                }
            }
            .safeAreaInset(edge: .bottom) { footer(scanLine: scanLine) }

        case .list(let sessions, let scanLine):
            rows(sessions, grayedOut: false)
                .safeAreaInset(edge: .bottom) { footer(scanLine: scanLine) }

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
                faultBanner(
                    reason: "バックエンドに接続できません",
                    detail: "3回連続で取得に失敗しました。しばらくしてから再試行してください",
                    style: .unreachable
                )
                .accessibilityIdentifier("list.unreachable")
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

    private func makeConversationViewModel(for row: SessionRow) -> ConversationViewModel {
        ConversationViewModel(
            client: HistoryClient(),
            baseURL: baseURL,
            apiKey: apiKey,
            sessionID: row.id,
            title: row.displayTitle,
            onUnauthorized: onUnauthorized
        )
    }

    private func footer(scanLine: String) -> some View {
        VStack(spacing: 2) {
            freshnessLine()
            Text(scanLine) // brief §3-b: rendered verbatim, never reassembled client-side
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("list.scanLine")
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

    private enum BannerStyle { case paneFault, unreachable }

    private func faultBanner(reason: String, detail: String, style: BannerStyle) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(reason).font(.subheadline.weight(.semibold))
            Text(detail).font(.caption)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(style == .unreachable ? Color.red.opacity(0.15) : Color.orange.opacity(0.15))
        .foregroundStyle(style == .unreachable ? Color.red : Color.orange)
    }

    private func retryButton() -> some View {
        Button("再試行") {
            Task { await viewModel.refresh() }
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
