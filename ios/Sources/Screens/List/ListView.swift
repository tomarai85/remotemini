import SwiftUI

/// The List screen (Sprint 2 brief §3/§4/§4-a). Renders `ListViewModel.phase` --
/// see that type for the full state-machine rationale; this file is display only.
struct ListView: View {
    @StateObject private var viewModel: ListViewModel
    /// REQUIREMENTS §4-5/§5-8 の口。**既定値を持たせない**(呼ぶ側が必ず渡す)——
    /// Sprint 8 が同じ形で3回再発させた欠陥がこれで、fixture の画面が既定の本物の
    /// クライアントを握ったまま `ui-fixture.invalid` へ本当に飛んでいた
    /// (`RootView.swift` の `ConversationClients` の注釈が経緯)。既定値が無ければ、
    /// 口を1つ足した時に検査側を書き忘れるとコンパイルが通らない。
    @StateObject private var accountViewModel: AccountViewModel
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
    /// 名前・保管・戻し依頼の口。**既定値を持たせない**(`ConversationClients` と同じ理由 —
    /// 既定を本物にすると fixture の面が `ui-fixture.invalid` へ本当に飛ぶ。Sprint 8 で3回)。
    private let renamer: SessionRenaming
    private let archiver: SessionArchiving
    private let returner: ReturnRequesting
    private let archivedLister: ArchivedListing

    /// rename の面の状態。alert 1枚 + 結果の1行。
    @AppStorage("RCListStyle") private var listStyleRaw: String = RCListStyle.current.rawValue
    private var listStyle: RCListStyle { RCListStyle(rawValue: listStyleRaw) ?? .current }

    /// 初回の待ちが始まった時刻。★`@State` なので `ListView` が作られた瞬間に決まる ——
    /// 初回取得の `.task` が走り出すのと同じ生存期間で、ここが計りたい待ちの起点。
    @State private var initialWaitStartedAt = Date()
    @State private var renameTarget: SessionRow?
    @State private var renameText = ""
    @State private var renameNotice: String?
    @State private var returnTarget: SessionRow?
    @State private var returnNotice: String?

    init(
        viewModel: @autoclosure @escaping () -> ListViewModel,
        accountViewModel: @autoclosure @escaping () -> AccountViewModel,
        baseURL: URL,
        apiKey: String,
        renamer: SessionRenaming,
        archiver: SessionArchiving,
        returner: ReturnRequesting,
        archivedLister: ArchivedListing,
        onUnauthorized: @escaping () -> Void
    ) {
        _viewModel = StateObject(wrappedValue: viewModel())
        _accountViewModel = StateObject(wrappedValue: accountViewModel())
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.renamer = renamer
        self.archiver = archiver
        self.returner = returner
        self.archivedLister = archivedLister
        self.onUnauthorized = onUnauthorized
    }

    var body: some View {
        ZStack(alignment: .top) {
            RCBackdrop()
            content
            if showsRefreshingIndicator {
                ProgressView()
                    .padding(8)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.top, 6)
                    .accessibilityIdentifier("list.refreshing")
            }
        }
        // ★一覧の面そのものの錨(2026-08-16)。走査行の常設表示を設定画面へ移した後も、
        //   UI 検査は「一覧に着いた」と「取得が何回走ったか」を測る必要が在る。
        //   識別子はどの相でも在る此の容器に、走査行は**描かずに** accessibilityValue で
        //   持たせる(画素には出ない = §9-4 を守り、検査からは読める = 錨が残る)。
        //   `.contain` は子の識別子を上書きしない為(AccountBar の註に在る実測の罠)。
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("list.root")
        .accessibilityValue(viewModel.phase.scanLine ?? "")
        // ★2026-08-16(spec-audit A4 / §9-4): 常設の脚(走査行・鮮度・版の3行)は
        //   設定画面の「計器」節へ移した。此の面に残るのは**古い時にだけ**出る警告1本 ——
        //   鮮度は使う人への警告なので面に残り、計器は診断なので別画面が正しい。
        //   版の名乗りは settings.buildInfo / disconnected.buildInfo / keyEntry.buildInfo の
        //   3面に居る(BuildIdentityUITests が同一ビルドを名乗る事を見張る)。
        .safeAreaInset(edge: .bottom) { staleWarning }
        .navigationTitle("Sessions")
        // 口座は**脚ではなく上**に置く(2026-08-12、REQUIREMENTS §4-5/§5-8)。脚は既に
        // 鮮度 / 走査行 / 版の3行を載せていて、其処に4行目を足すと**版の名乗りが押し出される** ——
        // 版は「古いビルドで動いていないか」を最も疑う場面で見える必要が在り、
        // 監査 X2-7 が同じ向きの欠け方を1度直している。口座は其の面を踏まない。
        //
        // ★2026-08-14(§9-4): 此のマスは**名乗りと入口だけ**になった。切替の操作一式
        //   (候補4本 + 各行の断り理由 + 退避路)は設定画面へ移した ——
        //   工具帯の1マスに入る量ではなく、押し込めば此処もまた「1画面に全部」になる。
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                AccountBar(viewModel: accountViewModel, baseURL: baseURL, listViewModel: viewModel,
                           archiveDeps: .init(apiKey: apiKey, lister: archivedLister, archiver: archiver))
            }
        }
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
            // ★注意の限界(既定10秒)までは**何一つ変えない**。実測のサーバ応答は
            //   0.1-0.3 秒(2026-08-27 friday 本番)なので、普段の起動はこの帯域で終わり、
            //   見た目は従来と同じ無言のスピナーのまま。
            //   Apple HIG 逐語 "Avoid labeling a spinning progress indicator." に反しない
            //   のは此処 —— 文言を足すのではなく、限界を超えた時に**表現ごと**替える。
            //   判定は `WaitEscalation`(時計を持たない純関数)に置いてあるので、
            //   規則は UI を起こさずに検べられる。
            TimelineView(.periodic(from: initialWaitStartedAt, by: 1)) { ctx in
                ScrollView {
                    switch WaitEscalation.stage(
                        elapsedSeconds: ctx.date.timeIntervalSince(initialWaitStartedAt)
                    ) {
                    case .normal:
                        ProgressView()
                            .padding(.top, 80)
                            .accessibilityIdentifier("list.loading")
                    case .abnormal:
                        // ★スピナーを消す。回り続ける輪を残したまま説明を足すと、
                        //   「進んでいる」と「止まっている」が同じ画面に同居する。
                        VStack(spacing: 12) {
                            faultBanner(headline: WaitEscalation.abnormalHeadline,
                                        body: WaitEscalation.abnormalBody)
                            retryButton()
                        }
                        .padding(.top, 40)
                        // ★`.accessibilityElement(children: .contain)` が要る。
                        //   識別子だけを `VStack` に付けても、SwiftUI は素の並びを
                        //   アクセシビリティの要素として公開しないので、UI 検査から
                        //   **一度も見つけられない**(2026-08-27、UI 検査を書いて初めて
                        //   判った)。錨を置いた気になって到達不能、は grep の対照では
                        //   捕まらない型 —— 画を出す検査だけが物を言える。
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("list.loading.slow")
                    }
                }
            }

        case .empty:
            ScrollView {
                Text("No sessions")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 80)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("list.empty")
            }

        case .paneFault(let headline, let body, let sessions, _):
            VStack(spacing: 0) {
                faultBanner(headline: headline, body: body)
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
                    noticeBar("Updates have been failing for a while. Showing the last list.", identifier: "list.retryable")
                    rows(sessions, grayedOut: false)
                } else {
                    // The third, distinct state (brief §4-a): a failed first fetch
                    // with nothing to fall back on -- not `.empty`, not a bare
                    // spinner.
                    ScrollView {
                        Text("Nothing fetched yet")
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
                SessionRowView(row: row, nowMs: Date().timeIntervalSince1970 * 1000, style: listStyle)
            }
            // 行の操作(長押し = iOS の標準の置き場)。名前(A1)・保管(§9-1)・戻し(§9-2)。
            .contextMenu {
                Button {
                    renameText = row.displayTitle
                    renameTarget = row
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                Button {
                    Task { await archive(row) }
                } label: {
                    Label("Archive", systemImage: "archivebox")
                }
                if row.isCheckout {
                    Button {
                        returnTarget = row
                    } label: {
                        Label("Return to MacBook…", systemImage: "arrow.uturn.backward.circle")
                    }
                }
            }
            // swipe でも外せる(§9-1「Tom が選んで外せ」— 長押しより1動作少ない道)。
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button {
                    Task { await archive(row) }
                } label: {
                    Label("Archive", systemImage: "archivebox")
                }
                .tint(.indigo)
            }
            // カード化(2026-08-17)。行の面は SessionRowView が自分で描くので、
            // List 側の標準装飾(区切り線・行背景)は全部降ろす。
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: listStyle.listRowVerticalInset, leading: 16,
                                      bottom: listStyle.listRowVerticalInset, trailing: 10))
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .opacity(grayedOut ? 0.5 : 1)
        .disabled(grayedOut)
        .alert("Rename", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("Name (1–60 characters)", text: $renameText)
            Button("Save") { Task { await submitRename(clear: false) } }
            Button("Clear name", role: .destructive) { Task { await submitRename(clear: true) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Sets this session's name in the list. Clearing it restores the automatic title.")
        }
        .alert("Can't rename", isPresented: Binding(
            get: { renameNotice != nil },
            set: { if !$0 { renameNotice = nil } }
        )) {
            Button("Close", role: .cancel) {}
        } message: {
            Text(renameNotice ?? "")
        }
        .confirmationDialog("Return to MacBook", isPresented: Binding(
            get: { returnTarget != nil },
            set: { if !$0 { returnTarget = nil } }
        ), titleVisibility: .visible) {
            Button("Queue the return") { Task { await submitReturnRequest() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This only queues a request. The work returns when the MacBook is next open, and only after its safety checks (e.g. conflicts with local edits) pass.")
        }
        .alert("Return request", isPresented: Binding(
            get: { returnNotice != nil },
            set: { if !$0 { returnNotice = nil } }
        )) {
            Button("Close", role: .cancel) {}
        } message: {
            Text(returnNotice ?? "")
        }
    }

    /// alert の「保存」/「名前を外す」から。成功 = 一覧を読み直す(名前はサーバの台帳が正本。
    /// 手元の行を書き換えて済ませると、次の取得で黙って戻る形の嘘になる)。
    private func submitRename(clear: Bool) async {
        guard let target = renameTarget else { return }
        renameTarget = nil
        let title = clear ? nil : renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !clear, title?.isEmpty != false || (title?.count ?? 0) > 60 {
            renameNotice = "Names are 1–60 characters (no line breaks)."
            return
        }
        switch await renamer.rename(baseURL: baseURL, apiKey: apiKey, sessionID: target.id, title: title) {
        case .renamed:
            await viewModel.refresh()
        case .rejected:
            renameNotice = "Names are 1–60 characters (no line breaks)."
        case .unreachable:
            renameNotice = "Couldn't reach the desk. Try again."
        case .unauthorized:
            onUnauthorized()
        }
    }

    /// §9-1: 一覧から外す。成功 = 読み直し(行が消える事が「外れた事が画面で判る」)。
    /// 戻す口は設定画面の「保管した会話」(消えた物の行き先が無いと削除に見える)。
    private func archive(_ row: SessionRow) async {
        switch await archiver.setArchived(baseURL: baseURL, apiKey: apiKey, sessionID: row.id, archived: true) {
        case .done:
            await viewModel.refresh()
        case .unreachable:
            renameNotice = "Couldn't reach the desk. Try again."
        case .unauthorized:
            onUnauthorized()
        }
    }

    /// §9-2: 「MBP へ戻す」の**依頼**。確認を挟む(取り返しに手間の掛かる操作)。
    private func submitReturnRequest() async {
        guard let target = returnTarget else { return }
        returnTarget = nil
        switch await returner.requestReturn(baseURL: baseURL, apiKey: apiKey, sessionID: target.id) {
        case .requested(_, let already):
            returnNotice = already
                ? "This work is already queued to return. It returns when the MacBook is next open."
                : "Queued. It returns when the MacBook is next open (the phone can't run the return itself)."
            await viewModel.refresh()
        case .notACheckout(let message):
            returnNotice = message
        case .unreachable:
            returnNotice = "Couldn't reach the desk. Try again."
        case .unauthorized:
            onUnauthorized()
        }
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

    /// 古い時に**だけ**出る警告(§9-4 の後も面に残る唯一の計器)。
    /// 新鮮な間は何も描かない — 常設の脚は設定画面の「計器」節へ移った(2026-08-16)。
    /// 識別子 `list.freshness` は据え置き(RemoteMiniUITests の鮮度検査の錨)。
    @ViewBuilder
    private var staleWarning: some View {
        // Re-evaluated at every redraw (this computed property runs whenever body
        // does) rather than on a timer -- brief §2-2/§3-c forbid polling here.
        if viewModel.lastFetchedAtMs > 0 {
            let freshness = Freshness.freshness(viewModel.lastFetchedAtMs, nowMs: Date().timeIntervalSince1970 * 1000)
            if freshness.stale {
                Text(freshness.text)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 4)
                    .background(.bar)
                    .accessibilityIdentifier("list.freshness")
            }
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
    ///
    /// ★2026-08-08(監査 S8-22)。以前の引数は `reason` / `detail` で、見出しに
    ///   `panes-unreadable`、本文に生の JS エラー文をそのまま描いていた —— 旅程で一番
    ///   踏みそうな画面(一覧が出ない)が、日本語ですらなかった。文は `ListViewModel.Phase`
    ///   が既に読める形で持っている(出所は `blocked.mjs` の `paneFaultView`)ので、
    ///   此処は貼るだけ。
    ///
    ///   本文を `.primary` にしてあるのは、橙の上に橙の小さい字を置くと**故障の説明が
    ///   一番読みにくい**からで、見出しだけ橙に残して「警告である」事を保つ。長さも
    ///   `blockedMessage` 並みの1〜2文に伸びたので `.footnote` + `fixedSize` で、
    ///   端末の幅に関係なく畳んで全部出す(切り捨てない)。
    ///   ★色そのものの可読性は測っていない —— GUI を開かない約束なので、見た目は
    ///   人の目でしか確かめられない(WORKLOG の「測れていない事」に出す)。
    private func faultBanner(headline: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(headline)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.orange)
            Text(body)
                .font(.footnote)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.orange.opacity(0.15))
    }

    private func retryButton() -> some View {
        Button {
            Task { await viewModel.refresh() }
        } label: {
            // ★X2-3。`.padding()` は Button の**外**に在るので、広く見えるのに
            // 押せるのは文字の上だけだった。旅程で「一覧が出ない」は最も起きやすい
            // 失敗で、これはその時に押す唯一の的。
            Text("Retry").tapTarget()
        }
        .padding()
        .accessibilityIdentifier("list.retry")
    }
}

// ★`private` を外した(2026-08-27)。判定(`statusWord` / `statusColor`)を検査が
//   直接叩く為で、**判定を写さない**という一線を守る唯一の形。
//   写した検査は、写しが本体とずれた日に「検査は緑、画面は嘘」を作る。
struct SessionRowView: View {
    let row: SessionRow
    let nowMs: Double
    /// 2026-08-26: 選定用。寸法と動きだけがここで分岐する(色・地・glass は不変)。
    var style: RCListStyle = .current
    @State private var appeared = false

    /// 2026-08-14 の UI 作り直し(Tom「UIも論外」)。北極星 = Claude の公式アプリの
    /// 会話一覧: **状態の点 + 題名 + 一行の内容 + 相対時刻**だけが前に出て、
    /// 計器類は後ろへ下がる。
    ///
    /// ★変えたのは**見た目の層だけ**。サーバの文(`route.text` / `subtitle`)は今も
    ///   逐語で描く(「壊れた時の診断を電話側で言い換えない」契約は生きている)——
    ///   demote したのは**視覚の序列**であって、内容ではない。
    /// ★状態の言葉は `kind` の **enum** から引く(下の `statusWord`)。線の文字列を
    ///   再組成しているのではなく、既に型で届いた分類に表示名を与えている —— 
    ///   「文字列を読み直して判断しない」規約と両立する。
    var body: some View {
        VStack(alignment: .leading, spacing: style.rowSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                // 本家 RC の識別意匠(teardown §2): 机で開いている会話は
                // **コンピュータのアイコン + 緑の点**。それ以外は点だけ。
                statusMark
                Text(row.displayTitle)
                    .font(style.titleFont)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(RelTime.relTime(row.updatedAt, nowMs: nowMs))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Text(row.display.subtitle) // server-computed (brief §3-a) -- rendered as-is, never reassembled
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(style.subtitleLines)
                .padding(.leading, 24)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                // §9-2: 機体の名乗り。押す前に「今どちらの機体に居るか」が読める事が先。
                if row.isCheckout {
                    Text(row.machine?.returnRequestedAt != nil ? "Return queued" : "From MacBook")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(RCTheme.violet)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(RCTheme.violet.opacity(0.12), in: Capsule())
                        .accessibilityIdentifier("list.machineBadge")
                }
                if let word = statusWord {
                    Text(word)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(statusColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(statusColor.opacity(0.12), in: Capsule())
                }
                // 診断の原文は**壊れている行にだけ**出す(2026-08-16、§9-4「一覧の行に
                // 内部語を並べない」)。健康な行では status の言葉が全てで、原文は
                // 説明でなく雑音になる。壊れた行(blocked / unknown)では原文こそが
                // 次の一手の説明なので、そこでは消さない。
                if showsDiagnostic {
                    Text(row.display.route.text)
                        .font(.caption2)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.leading, 24)
        }
        .padding(style.cardPadding)
        // 面はカードが持つ(List の行背景は clear)。描き方の正本は RCCard —
        // choice 行だけ橙で名指しする理由もあちらに書いてある。
        .modifier(RCCard(emphasized: row.display.route.kind == .choice))
        // ★入場の動き(案 C のみ)。持たない案では opacity も offset も 1/0 に固定され、
        //   animation 自体を張らない —— 「動かない」を「動きが 0 秒」で代用しない。
        .opacity(style.animatesEntry ? (appeared ? 1 : 0) : 1)
        .offset(y: style.animatesEntry ? (appeared ? 0 : 14) : 0)
        .onAppear {
            guard style.animatesEntry, !appeared else { appeared = true; return }
            withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { appeared = true }
        }
    }

    /// 机で開いている会話の印。アイコンは SF Symbols の desktopcomputer(本家の意匠)。
    @ViewBuilder
    private var statusMark: some View {
        if row.display.route.kind == .tmux {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .overlay(alignment: .topTrailing) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 7, height: 7)
                        .offset(x: 3, y: -2)
                }
                .frame(width: 16)
        } else {
            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)
                .padding(.top, 1)
                .frame(width: 16)
        }
    }

    private var showsDiagnostic: Bool {
        switch row.display.route.kind {
        case .blocked, .unknown: return true
        case .choice, .tmux, .worker: return false
        }
    }

    /// Brief §3-a: distinct visual treatment per `kind`, `choice` carrying the
    /// strongest emphasis (the only state where Enter on the desk side becomes an
    /// approval/charge).
    private var statusColor: Color { SessionRowView.statusColor(for: row) }

    /// ★view の外から呼べる形にした(2026-08-27)。判定は**1箇所のまま**で、
    ///   検査が同じ関数を叩ける様にしただけ —— 検査用に判定を写すと、
    ///   写しが本体とずれた日に「検査は緑、画面は嘘」が作れる。
    static func statusColor(for row: SessionRow) -> Color {
        // ★札と色は**同じ判定**から出す。札が「返事が要る」なのに色が緑だと、
        //   一瞥では緑しか見えず、急ぎが半分しか伝わらない。
        if row.requiresOwnerInput == true { return .orange }
        switch row.display.route.kind {
        case .choice: return .orange
        case .tmux: return .green
        case .worker: return .blue
        case .blocked: return .secondary
        case .unknown: return .secondary
        }
    }

    /// 人の言葉。`nil` = 静かな状態(章を付けるほどの事ではない)。
    ///
    /// ★**枠は1つ**(2026-08-27)。§9-4 の「常設の状態帯は同時に1枠だけ」と同じ判断で、
    ///   1つの行が2つの急ぎを言うのは「帯3段」の縮小版になる。
    ///   `choice` は「返事が要る」の**理由の1つ**であって、別の札ではない。
    ///
    /// ★判定は机が持つ(`requiresOwnerInput`)。以前は `route.kind == .choice` だけを
    ///   見ていたが、実測すると生きた 2 本とも `route = null` で**一度も出ていなかった**。
    ///   一方 digest は同じ会話を「待っている」と判定していた —— 開くまで知れない、が
    ///   まさに取り戻したい死に時間だった(2026-08-26 に 60 分観測)。
    ///
    /// ★`nil`(古いサーバ / 判らない)は札を出さない。**判らない事を急ぎに見せない**。
    private var statusWord: String? { SessionRowView.statusWord(for: row) }

    /// ★view の外から呼べる形にした(2026-08-27)。理由は `statusColor` と同じ。
    static func statusWord(for row: SessionRow) -> String? {
        if row.requiresOwnerInput == true { return "Needs your input" }
        switch row.display.route.kind {
        case .choice: return "Needs your input"   // 机が古くて印を出さない版への保険
        case .tmux: return "On desktop"
        case .worker: return nil
        case .blocked: return "Unavailable"
        case .unknown: return nil
        }
    }
}
