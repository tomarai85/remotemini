import SwiftUI
import PhotosUI
import os

/// The Conversation screen (Sprint 3 brief §3). Renders `ConversationViewModel`'s
/// `phase`/`loadEarlierState` -- display only, same split `ListView`/`ListViewModel`
/// already establishes.
struct ConversationView: View {

    /// 机の画面に上限の告知が出ている時、送る面に出す一文。出さない時は `nil`。
    ///
    /// ★**送信は断らない。** `ConversationViewModel.swift` の既存の裁定(体験側監査 #4 への
    ///   返答)がこう決めている ——「計器は片側にしか外れず、外れるのは常に『通るのに断る』側」。
    ///   Codex 2026-08-30 は確認を1回挟む案(soft interlock)を推したが、採らない:
    ///   今日実際に Tom を止めたのは `limited` ではなく口座のトークン失効(`relogin_required`)で、
    ///   机は3回とも答えていた。**`limited` の経路で実害が出た観測は無い**ので、
    ///   推定の上に摩擦を1つ載せるのは既存裁定と釣り合わない。見せる。断らない。
    ///
    /// ★`nil`(線が何も言わなかった)と `false` を同じ扱いにする —— どちらも
    ///   「告知は見えていない」であって、区別が行動を変えない。
    ///   区別が行動を変えないなら、画面に持ち込まない。
    static func limitedNotice(_ screen: ScreenBody?) -> String? {
        guard screen?.limited == true else { return nil }
        return "The desk shows a usage-limit notice — it will not answer until that clears"
    }

    /// 写真ピッカーの選択。★選ばれた事と送れた事は別なので、状態を分けて持つ。
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var attachBusy = false
    /// 結果の1文。**「送れました」で丸めない**(置けたが載っていない状態が実在する)。
    @State private var attachNotice: String?
    @StateObject private var viewModel: ConversationViewModel
    /// Brief §3-c's `.notFound` row: "一覧へ戻る", not a retry. `NavigationStack`
    /// already supplies a back chevron when this view is pushed from `ListView` in
    /// the real app, but the DEBUG fixture path presents this view as its own root
    /// (no back chevron there -- see `RC_UI_FIXTURE`'s entry point), and the brief's
    /// per-case table calls out "一覧へ戻る" as part of what this state shows, not as
    /// an assumption about whatever chrome happens to be pushed above it. `dismiss()`
    /// is a no-op with nothing to dismiss in the rootless fixture case; in the real,
    /// pushed case it pops back to List exactly like the nav bar's own back button.
    @Environment(\.dismiss) private var dismiss
    /// N4 (brief §1-a item 5): background -> foreground on THIS screen runs the same
    /// resync procedure as a gap notice or the stage-2 auto-recovery.
    @Environment(\.scenePhase) private var scenePhase
    /// N4 の番人。`@State` なのは、判定が**1辺では決まらない**から —— 「途中で背面に
    /// 居たか」を `.onChange` の呼び出しを跨いで憶える必要が在る。Sprint 4 から
    /// 2026-08-08 まで此処は `(old, new)` の対を見る純関数で、その条件
    /// (`.background -> .active`)は iOS が一度も配らない辺だった = N4 は一度も
    /// 発火していない。実測列と経緯は `ForegroundResume` の doc に全文。
    @State private var resumeGate = ForegroundResume()

    /// 一番下の錨の id。行の identity は `Array.enumerated()` の `Int` offset なので、
    /// ぶつからない型(`String`)を選んでいる -- `Int` にすると、たまたま同じ番号の行が
    /// 在る時に `scrollTo` がどちらへ行くか決まらない。
    private static let bottomAnchorID = "conversation.bottomAnchor"

    /// ★「今この人は一番下を見ているか」。追従の条件であって、追従の結果ではない。
    ///
    /// 錨(高さ1の透明な目印)が `LazyVStack` に作られている間だけ真。iOS 17 には
    /// スクロール位置を直接読む口が無い(`onScrollGeometryChange` は iOS 18)ので、
    /// 「見えているかどうか」を `onAppear`/`onDisappear` で測っている。
    @State private var isPinnedToBottom = true

    /// 開いた直後の着地がまだ終わっていない。
    ///
    /// ★之に `isPinnedToBottom` を使わない。`LazyVStack` は窓の外へ先回りして作るので、
    ///   錨の `onAppear` は**下端に着く前に**発火し得る —— 之を終端条件にすると、
    ///   着く前に補正を止めてしまう。(2026-08-31 Codex が「錨の onAppear は下端が
    ///   見えている証拠ではない」を此の設計の最大の穴として指摘し、私が自分で挙げていた
    ///   弱点と一致した。だから終端は下の `distanceToBottom` = 倒れた瞬間に測ったのと
    ///   同じ量 で決める。)
    @State private var initialLandingPending = true

    /// 補正の回数の栓。**原因への手当てではなく、輪が回り続けない為の belt**。
    /// 高さが微小に振動する版図では終端条件が満たされ続けない事が有り得る、という
    /// 指摘への備え。此処へ到達する事自体が欠陥の合図なので、到達したら記録に残す。
    private static let maxLandingCorrections = 12
    @State private var landingCorrections = 0

    /// 之まで最も下端に近付いた距離。**直近の値ではなく最良値**を憶える。
    ///
    /// ★2026-08-31、批評で捕まった欠陥: 初版は「今回が直近より縮んでいなければ降りる」
    ///   だった。しかし此の欠陥の中身は「寄せた後に行が実体化して**内容が伸びる**」事
    ///   なので、1 回の pass で「寄せは 170pt 詰めたが高さが 190pt 伸びた」= 距離が
    ///   **増える**事が普通に起きる。其の一過性の 1 回で `pending = false` にすると
    ///   **回復経路が無いまま恒久的に諦める** —— しかも負荷下(= 倒れる条件)で最も
    ///   踏みやすい。最良値と「足踏みの回数」で見る。
    @State private var bestLandingDistance: CGFloat = .infinity
    /// **最初に測った**下端までの距離。★終わりの値だけでは「補正が要らなかった」と
    /// 「大きく手前から引き戻した」が同じ見た目になる —— 実際に破壊口の実験で
    /// 両者がバイト単位で同一の読み出しになり、何も判らなかった(2026-08-31)。
    /// 出発点と回数を出して初めて、輪が働いた事を主張できる。
    @State private var firstLandingDistance: CGFloat = .nan
    /// 最良値を更新できなかった連続回数。
    private static let maxStalledLandingPasses = 3
    @State private var stalledLandingPasses = 0

    /// 内容と窓の実測。着地の判断だけに使う。
    ///
    /// ★輪(preference → state → body → layout → preference)は**既に在る**。
    ///   初版の註は「layout に影響する物を書かないので輪はできない」と書いていたが偽で、
    ///   `contentMetrics` → `distanceToBottom` → `reassertLanding` → `scrollTo` → layout
    ///   → preference と閉じている。輪を切っているのは「影響しない事」ではなく
    ///   **`initialLandingPending` の門**。門は `onPreferenceChange` の**代入より前**に
    ///   置く事(後ろに置くと、着地が終わった後も毎フレーム @State を書き続ける)。
    @State private var contentMetrics = ConversationContentMetrics()
    @State private var viewportHeight: CGFloat = 0

    /// 内容の上端の y を読む座標系の名前。
    private static let scrollSpace = "conversation.scroll"

    private static let landingLog = Logger(subsystem: "com.tomtim.mobilework", category: "conversation")

    /// 下端まであと何 pt 残っているか。0 以下 = 着いている。
    ///
    /// ★2026-08-31 の失敗記録が測ったのと同じ式: 内容 3308.0 + 寄せ (-2430.7) - 窓 501.7
    ///   = 375.6pt。**欠陥を検出した式を、そのまま修正の終端条件に使う**。
    ///
    /// ★★375.6pt は **約 7 行分**(1行 38.6pt + 間隔 16 = 54.6pt、375.6/54.6 = 6.9)。
    ///   最初 此処に「約 3 行」と書いたのは誤り —— 3 は「088/089/090 が実体化して
    ///   いなかった」の方の数で、**実体化していない行数と、足りない距離を混ぜていた**。
    ///   実際に見えていた帯は 075-084 で、085-087 は作られていたが画面の外。
    ///   (幾何の検算: 3308 = 16 + Σ行 + 60*16 + 1 + 16 → Σ行 2315 → 1行 38.6pt)
    private var distanceToBottom: CGFloat {
        contentMetrics.contentHeight + contentMetrics.contentTop - viewportHeight
    }

    /// 着地の読み出し。`<状態> <下端までの pt>` の 1 行。
    ///
    /// 状態 = `pending`(まだ着地の最中)/ `settled`(終わった)。
    /// **通っても倒れても**検査が此れを刷る事で、二値でなく連続量が毎回 残る。
    /// 窓の高さが 0(まだ layout 前)の間は `unmeasured` —— 0 と混ぜない。
    private var landingReadout: String {
        let state = initialLandingPending ? "pending" : "settled"
        // ★生の 3 値も出す。`unmeasured` とだけ返していた初版では、
        //   「窓が測れていない」のか「内容が測れていない」のか判らず、
        //   1 回 6 分の走行を無駄にした(2026-08-31 実測)。
        //   計器の出力は**次の一手が決まる粒度**で出す。
        //
        // ★★`MainThreadHog` は `#if DEBUG` の中にしか存在しない。之を `#if` の外で
        //   参照して **Release(= 電話用の構成)だけ**コンパイルが落ちた
        //   (`cannot find 'MainThreadHog' in scope`、2026-08-31 実測)。
        //   simulator の検査 759 件は **Debug しか組まない**ので一度も当たらず、
        //   電話へ焼くまで判らなかった。DEBUG 限定の物を参照する行は、
        //   参照する側も同じ `#if` の中へ入れる事。
        #if DEBUG
        let hog = MainThreadHog.isArmed ? "hog" : "nohog"
        let sab = ProcessInfo.processInfo.environment["RC_UI_LANDING_SABOTAGE"] != nil ? "sab" : "nosab"
        #else
        let hog = "nohog"
        let sab = "nosab"
        #endif
        // ★`first` と `corr` が此の読み出しの芯。終わりの値だけでは
        //   「補正が要らなかった」と「大きく手前から引き戻した」が区別できない。
        let raw = String(format: "first=%.1f corr=%d %@ h=%.1f top=%.1f v=%.1f",
                         firstLandingDistance, landingCorrections, sab,
                         contentMetrics.contentHeight, contentMetrics.contentTop, viewportHeight)
        guard viewportHeight > 0, contentMetrics.contentHeight > 0 else {
            return "unmeasured \(hog) \(raw)"
        }
        return "\(state) \(String(format: "%.1f", distanceToBottom)) \(hog) \(raw)"
    }

    /// 開いた直後の着地を、観測に基づいて必要なだけ撃ち直す。
    ///
    /// 時計で待たない。`LazyVStack` が行を作る度に高さが変わり、其の度に此処が呼ばれる。
    /// 高さが落ち着けば呼び出し自体が来なくなるので、待ち時間の当て推量が要らない。
    private func reassertLanding(_ proxy: ScrollViewProxy) {
        #if DEBUG
        // ★検査専用の停止口。「輪が働いた」と「輪が必要だった」は別の主張で、
        //   後者は**輪を止めた時に倒れる**事でしか示せない。
        //   実測(2026-08-31): 破壊口 ON(錨への scrollTo を飛ばす)でも着地した ——
        //   之だけでは SwiftUI 自身が下端へ行っている可能性を潰せない。
        if ProcessInfo.processInfo.environment["RC_UI_LANDING_NOLOOP"] != nil { return }
        #endif
        guard initialLandingPending else { return }
        guard viewportHeight > 0, contentMetrics.contentHeight > 0 else { return }

        let remaining = distanceToBottom
        if firstLandingDistance.isNaN { firstLandingDistance = remaining }

        if remaining <= 0.5 {                      // 着いた。之が唯一の「着地した」の証拠。
            initialLandingPending = false
            return
        }

        // 最良値を更新できたか。★1 回 増えただけで諦めない —— 行の実体化で内容が伸びる
        //   のは此の欠陥の中身そのもので、其の pass は「近付いていない」ではなく
        //   「足場が動いた」だけ。連続で足踏みした時に初めて降りる。
        if remaining < bestLandingDistance - 0.5 {
            bestLandingDistance = remaining
            stalledLandingPasses = 0
        } else {
            stalledLandingPasses += 1
            if stalledLandingPasses >= Self.maxStalledLandingPasses {
                giveUpLanding("\(Self.maxStalledLandingPasses) 回続けて近付かなかった", remaining)
                return
            }
        }

        if landingCorrections >= Self.maxLandingCorrections {
            giveUpLanding("補正 \(Self.maxLandingCorrections) 回の上限", remaining)
            return
        }

        landingCorrections += 1
        proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
    }

    /// 着地を諦める。★**必ず記録を残す**。
    ///
    /// 初版は諦める経路が無言だったので、後から「着いた」のか「諦めた」のかを
    /// 区別できなかった —— 画面は同じに見えるのに原因が別。区別が付かない記録は
    /// 記録ではない。
    private func giveUpLanding(_ why: String, _ remaining: CGFloat) {
        let msg = "会話の着地を諦めた(\(why))。下端まで \(remaining)pt 残った"
        Self.landingLog.warning("\(msg, privacy: .public)")
        initialLandingPending = false
    }

    /// 開いた時 / 画面へ戻った時に着地をやり直す為の初期化。
    private func armInitialLanding() {
        initialLandingPending = true
        landingCorrections = 0
        stalledLandingPasses = 0
        bestLandingDistance = .infinity
        firstLandingDistance = .nan
    }

    init(viewModel: @autoclosure @escaping () -> ConversationViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel())
    }

    /// 検索欄の文字。**要求はこれが変わっても飛ばない**(`.onSubmit(of: .search)` だけ)。
    @State private var searchText = ""
    /// 検索が有効か。`.searchable(isPresented:)` の札。
    ///
    /// ★「有効」を `searchText.isEmpty` で代用しない。取り消しボタンを押した瞬間に
    ///   文字だけ消えて面が残る / 文字を全部消しただけで面が畳まれる、の 2 通りが
    ///   同じ式から出てしまう。畳むのは利用者が畳んだ時だけ。
    @State private var isSearchPresented = false

    var body: some View {
        content
            .background(RCBackdrop())
            // ★置き場は `.navigationBarDrawer(displayMode: .always)`(→ spec D-A)。
            //   `.automatic` はスクロールで欄を畳むので、**ナビ周りの高さが動く** ——
            //   その高さは着地の輪が測る `viewportHeight` そのもので、2026-08-31 に
            //   1 セッション掛けて閉じたばかりの輪へ、開閉の度に変動を注ぎ込む事になる。
            //   `.always` なら欄は常に 1 行ぶん場所を取る代わりに、高さが動かない。
            .searchable(
                text: $searchText,
                isPresented: $isSearchPresented,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search this transcript"
            )
            // ★打鍵ごとに撃たない(→ spec D-B / §7)。机の 1 回は「最大 1 MiB の
            //   後方読み + 走査した全行の `JSON.parse`」で、しかも**未確定の日本語入力**
            //   (= どこにも一致しない = `limit` に届かない = 毎回 1 MiB を読み切る)で
            //   負荷が最大になる。同じ機械で Claude Code のセッションが走っている。
            //   debounce も解にならない(IME の変換中の停止は普通に 300ms を超える)。
            .onSubmit(of: .search) {
                Task { await viewModel.search(query: searchText) }
            }
            .onChange(of: isSearchPresented) { _, presented in
                // 畳んだら結果を捨てる。保持すると「前に探した語の結果」が
                // 今の転写と食い違ったまま残る面ができる。
                if !presented { viewModel.cancelSearch() }
            }
            // Brief §3-c: the title comes from the List row that navigated here and
            // survives any failure phase below -- never re-derived from `/history`
            // (which carries no title), never blanked while retrying.
            .navigationTitle(viewModel.title)
            .navigationBarTitleDisplayMode(.inline)
            // ★diff(#4、2026-09-02、対照表 "今日から着手できる上位5件" #3)。押して開く
            //   `NavigationLink` -- このアプリのどの画面も `.sheet` を使っていない
            //   (`AccountBar`/`ArchivedListView` と同じ push 遷移)。`SessionRow.diff`
            //   (#5、± バッジ)には依存しない -- 一覧に載る数と、此処が開く中身は別の型
            //   (`SessionDiffBody`、main 側 `gitdiff.mjs`/`SessionRow.diff` と衝突しない
            //   名前を付けてある)。
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        DiffView(viewModel: makeDiffViewModel())
                    } label: {
                        Image(systemName: "plusminus")
                    }
                    .accessibilityIdentifier("conversation.diff.open")
                }
            }
            .task { await viewModel.load() }
            // Brief §2-b: the poll loop belongs to this screen, not to the app -- it
            // must not keep running once nobody is looking at it (nav pop, or the
            // fixture/UI-test host tearing the view down).
            .onDisappear { viewModel.stopPolling() }
            // N4's guard, now in `ForegroundResume` (S8-5). It lived here as
            // `shouldResumeOnForeground` from Sprint 4 until the List screen was
            // measured -- at which point the actual `scenePhase` sequence iOS delivers
            // turned out to make the old condition (`oldPhase == .background &&
            // newPhase == .active`) UNSATISFIABLE, i.e. this resync has never once
            // fired since Sprint 4. Full measurement in that type's doc.
            .onChange(of: scenePhase) { _, newPhase in
                if resumeGate.shouldResume(newPhase: newPhase) {
                    viewModel.handleForegroundResume()
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .initialLoading:
            ScrollView {
                ProgressView()
                    .padding(.top, 80)
                    .accessibilityIdentifier("conversation.loading")
            }

        case .unreachable:
            failureView(
                message: "Couldn't load the session",
                identifier: "conversation.unreachable"
            )

        case .malformedBody:
            // Brief §3-c: must never render as an empty conversation -- "broken" and
            // "genuinely nothing said yet" are never the same bucket.
            failureView(
                message: "The response shape is unreadable",
                identifier: "conversation.malformedBody"
            )

        case .notFound:
            // Brief §3-c's table, this row specifically: retrying a 404 just 404s
            // again, so this is the one failure phase with NO "再試行" button --
            // `failureView` above always renders one, which is exactly why this
            // case has its own view rather than reusing that helper.
            VStack(spacing: 12) {
                Text("This session no longer exists (the list may be stale)")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Button {
                    dismiss()
                } label: {
                    Text("Back to sessions").tapTarget()
                }
                .accessibilityIdentifier("conversation.notFound.backToList")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // ★2026-08-08(監査 X2-3)。`choiceCard` が同じ穴で一度直っているのに、
            // 入れ物に識別子を付けた面が此処を含めて4つ残っていた —— 付けた時点で
            // SwiftUI は中身を1つの要素に畳むので、**中のボタンは XCUITest からも
            // VoiceOver からも触れない**。「一覧に戻る」はこの画面の唯一の出口。
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("conversation.notFound")

        case .contractViolation(let violation):
            // DoD row 6, the visible half. Deliberately NOT a copy of the `.notFound`
            // view above: no "一覧に戻る" button, because the most likely cause of
            // reaching here is that this app asked for a path the server does not
            // serve -- and sending the user back to the list would present a bug in
            // the phone as a fact about their conversation. There is also no "再試行",
            // for the same reason `.notFound` has none: a response the phone is not
            // permitted to interpret does not become interpretable on the second try.
            //
            // The text is `violation.displayText` -- one fixed sentence with the status
            // and code appended as diagnostics. That is the whole of what the phone
            // knows, stated as what arrived rather than as an explanation of why.
            VStack(spacing: 12) {
                Text(violation.displayText)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("conversation.contractViolation")

        case .loaded:
            VStack(spacing: 0) {
                statusBanners
                if viewModel.entries.isEmpty {
                    // ★灰色の1行が余白の中で浮くのをやめる(2026-08-29、Tom「洗練されていない」)。
                    //   空の面は**製品が壊れている様に見える所**なので、記号 + 一言で
                    //   「ここに何を書けばいいか」まで言う(空状態は説明の場所であって空白ではない)。
                    ScrollView {
                        VStack(spacing: 10) {
                            Image(systemName: "text.bubble")
                                .font(.system(size: 34, weight: .light))
                                .foregroundStyle(.secondary)
                            Text("No messages yet")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                            Text("Type below to start this conversation on the desk.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 32)
                        }
                        .padding(.top, 96)
                        .frame(maxWidth: .infinity)
                    }
                    .accessibilityIdentifier("conversation.empty")
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 16) {
                                // No wire-provided id (brief §1-a: history entries carry
                                // none) -- position is stable for a screen that never
                                // reorders or removes rendered entries in place.
                                ForEach(Array(viewModel.entries.enumerated()), id: \.offset) { _, entry in
                                    EntryBubble(entry: entry)
                                        // ★2026-09-02: 届いた行は下から入る。
                                        //   `id` は offset なので末尾に足された行だけが
                                        //   挿入として扱われ、既存の行は動かない。
                                        .transition(.asymmetric(
                                            insertion: .move(edge: .bottom).combined(with: .opacity),
                                            removal: .opacity))
                                }
                                // 一番下の錨。行の identity は `Int`(enumerated の
                                // offset)なので、ぶつからない `String` を id にする。
                                Color.clear
                                    .frame(height: 1)
                                    .id(Self.bottomAnchorID)
                                    .onAppear { isPinnedToBottom = true }
                                    .onDisappear { isPinnedToBottom = false }
                            }
                            // ★動かすのは **`live` が増えた時だけ**。`entries.count` を鍵にすると
                            //   初回読込の 90 行が一斉に滑り込んで来る(画面が 1 秒 揺れる)。
                            //   `live` は机からの追記だけが増やすので、届いた瞬間にしか動かない。
                            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: viewModel.live.count)
                            .padding()
                            // 内容の高さと寄せを測る。`background` なので layout は変わらない。
                            .background(
                                GeometryReader { g in
                                    Color.clear.preference(
                                        key: ConversationContentMetricsKey.self,
                                        value: ConversationContentMetrics(
                                            contentHeight: g.size.height,
                                            contentTop: g.frame(in: .named(Self.scrollSpace)).minY
                                        )
                                    )
                                }
                            )
                        }
                        .coordinateSpace(name: Self.scrollSpace)
                        // ★★着地の結果を**連続量として読み出せる様にする**(2026-08-31)。
                        //
                        //   之まで此の欠陥は「倒れたか / 通ったか」の二値として扱っていて、
                        //   緑の走行は何も残さなかった。実際には毎回「下端まであと何 pt で
                        //   終わったか」が測れる —— 直前の 10 走行(5/5 + 5/5)は、
                        //   記録していれば **10 個の標本**だった。今は 10 bit しか残っていない。
                        //
                        //   門を代入の前へ置いた結果、`contentMetrics` は**着地が終わった
                        //   pass で凍結する**ので、其の凍結値が「結局どれだけ手前で終わったか」
                        //   そのもの。読み出しは既に無料で手に入っている。
                        //
                        //   ★`overlay` の**別要素**に付ける。`ScrollView` 自身へ識別子を
                        //     付けると SwiftUI が中身を 1 つの要素へ畳み、**中の行が
                        //     XCUITest からも VoiceOver からも触れなくなる**
                        //     (此の file が同じ穴を 3 回 踏んでいる)。
                        .overlay(alignment: .topLeading) {
                            Color.clear
                                .frame(width: 1, height: 1)
                                .accessibilityElement()
                                .accessibilityIdentifier("conversation.landingDistance")
                                .accessibilityValue(landingReadout)
                                .allowsHitTesting(false)
                        }
                        // 窓の高さ。同じく `background` なので layout は変わらない。
                        .background(
                            GeometryReader { g in
                                Color.clear.preference(
                                    key: ConversationViewportHeightKey.self,
                                    value: g.size.height
                                )
                            }
                        )
                        .onAppear {
                            // 開いた瞬間は無条件で一番下。
                            //
                            // ★之は**一発では決まらない**(2026-08-31、実物を捕獲)。
                            //   錨は 44 行ぶん下に在り、`scrollTo` は
                            //   「実体化 → layout → 位置を測り直す」を反復して寄って行く。
                            //   混んだ機械では此の反復が run-loop の予算で打ち切られ、
                            //   **途中で止まる**。実測で下端まで 375.6pt(約 7 行)残った。
                            //
                            //   ★機構を 2026-08-31 に**訂正した**。初めは「行の高さが可変
                            //     なので錨の位置の推定が外れる」と書いたが、此の画面の
                            //     fixture は全行 1 行の等質(`HistoryFixture` の `longTail`)
                            //     で高さは 2 値しかなく、内容の 11.4% にあたる 375.6pt の
                            //     推定誤差が出る余地が無い。窓の収縮でも説明できない
                            //     (窓 812 - 上端 110 = 702 が上限なので、説明できるのは
                            //      高々 200.3pt)。**残るのは「寄せの反復が完走しない」**。
                            //     予算枯渇なら (i) 負荷依存 (ii) 誤差でなく大きく外す
                            //     (iii) 単独走行では起きない —— 観測 3 点と全部 合う。
                            //
                            //   だから下の `onPreferenceChange` で、観測しながら撃ち直す。
                            //   終端は高さではなく**下端までの距離**で決める(距離で見れば、
                            //   高さが動かないまま寄せだけ足りない形も正しく捉えられる)。
                            //
                            // `.defaultScrollAnchor(.bottom)`(iOS 17)を**使わない**の
                            // は、あれが「内容の大きさが変わる度に下端を保つ」修飾子
                            // だから -- 「以前を読む」で前に足した時も下端に留まり、
                            // 上へ遡って読んでいる最中の追記でも引き摺り下ろす。
                            // 寄せる条件を自分で持てなくなる。
                            armInitialLanding()
                            #if DEBUG
                            // ★**わざと手前に着地させる口**(検査専用、環境変数が明示的に
                            //   渡された時だけ)。
                            //
                            //   之が要る理由: 実物の欠陥は 1 回しか捕まっておらず、
                            //   2 通りの機械負荷でも主スレッド占有 14ms でも再現しない。
                            //   再現を待っていると、補正の輪が**本当に引き戻せるのか**を
                            //   永久に確かめられない —— 実測では距離が最初から 0 以下
                            //   (`settled -1.7`)なので、輪は armed のまま一度も発火しない。
                            //   確率に頼らず、**故障の形そのものを注入して**測る。
                            if ProcessInfo.processInfo.environment["RC_UI_LANDING_SABOTAGE"] != nil {
                                proxy.scrollTo(0, anchor: .top)   // 一番上 = 最大に手前
                                return
                            }
                            #endif
                            proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                        }
                        // ★★門を**代入の前**に置く(2026-08-31、批評で捕まった)。
                        //   `contentMetrics.contentTop` は生のスクロール位置なので、
                        //   指で送る度に毎フレーム変わる。門を `reassertLanding` の中だけに
                        //   置くと、着地が終わった後も**画面の寿命いっぱい毎フレーム
                        //   @State を書き、body を作り直す**。body は `viewModel.entries` を
                        //   2回 読み、其れは毎アクセス `MergeHistory.merge` を回す computed
                        //   (`ConversationViewModel` の該当 doc)。長い会話ほど重い =
                        //   **此の修正が対象にしている当の画面で一番重くなる**。
                        //   修正前には存在しなかった費用なので、門で塞ぐ。
                        .onPreferenceChange(ConversationContentMetricsKey.self) { m in
                            guard initialLandingPending else { return }
                            contentMetrics = m
                            reassertLanding(proxy)
                        }
                        .onPreferenceChange(ConversationViewportHeightKey.self) { h in
                            guard initialLandingPending else { return }
                            viewportHeight = h
                            reassertLanding(proxy)
                        }
                        .onChange(of: viewModel.tailToken) { _, _ in
                            // ★下端に居る時だけ追う。上へ遡って読んでいる最中に机が
                            // 喋ったからといって引き摺り下ろすと、この画面で一番長い
                            // 操作(読む事)ができなくなる。
                            //
                            // ★初回の着地の期間は此処で終わる。以後 内容が伸びても補正は
                            //   走らない = 遡って読んでいる人を引き摺らない。
                            initialLandingPending = false
                            guard isPinnedToBottom else { return }
                            withAnimation { proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom) }
                        }
                        .onChange(of: viewModel.earlierRevealToken) { _, _ in
                            // 「以前を読む」の後。足す前に一番古かった行を**下端**へ
                            // 置く = 新しく出た古い行で画面が埋まる。ここで下端へ
                            // 寄せてしまう(= `tailToken` と同じ扱いにする)と、押した
                            // 行為そのものが画面から消える。
                            //
                            // ★初回の着地の期間は此処でも終わる。押した瞬間に止めないと、
                            //   前に足した分だけ内容が伸びて補正が発火し、下端へ引き摺って
                            //   此の分岐の意図を打ち消す。
                            initialLandingPending = false
                            guard let index = viewModel.earlierRevealIndex else { return }
                            proxy.scrollTo(index, anchor: .bottom)
                        }
                    }
                }
                // ★探索が有効な間は**描かない**(→ spec §2-d)。
                //   composer を残すと、探しながら机へ送れてしまう(送信ボタンが
                //   結果の面の下で生きる)。`loadEarlierFooter` を残すと、探索中に
                //   `currentLimit` と `history` が黙って動く = 転写の窓が
                //   「探しただけ」で変わる。
                //   ★下書きは失われない —— `ConversationViewModel.draft` は `didSet` で
                //     打鍵ごとに `draftStore` へ書かれるので、面を消しても値は残る。
                if !isSearchPresented {
                    loadEarlierFooter
                    composer
                        .onChange(of: pickedPhoto) { _, item in
                            guard let item else { return }
                            Task { await sendPicked(item) }
                        }
                }
            }
            // ★**重ねる**。差し替え(`if isSearching { 結果 } else { 転写 }`)を採らない
            //   (→ spec D-A / §6-a)。差し替えると取り消しで転写の `ScrollView` の
            //   `.onAppear` が再発火し、`armInitialLanding()` が
            //   `landingCorrections` / `firstLandingDistance` を初期化する ——
            //   上へ遡って読んでいた人が、取り消した瞬間に下端へ引き戻される。
            //   `overlay` なら転写は階層に残るので `.onAppear` は再発火せず、
            //   門(`initialLandingPending`)は既に閉じているので背後で layout が
            //   続いても `@State` は 1 つも書かれない。
            //   之が壊れていない事は `conversation.landingDistance` の読み出しが
            //   検索の開閉を跨いでバイト単位で同一である事で測る。
            .overlay {
                if isSearchPresented { searchResultsPanel }
            }
        }
    }

    // MARK: - 探索の面(2026-09-01)

    /// 転写の上に重なる結果の面。
    ///
    /// ★地は転写と同じ(`RCBackdrop`)。灰色(`.bar`)を敷かないのは、この画面で
    ///   灰色が「電話の道具」を意味する材質として既に予約されている為(§2.63 の裁定)。
    ///   所属は**上端の区切り 1 本と見出し行**で示す。
    /// ★行は `EntryBubble` を**そのまま**使う。転写と結果で本文の描画器を 2 本 置くと
    ///   片方だけが古くなる(机が `entriesFromRecord` を 1 本にしているのと同じ判断)。
    @ViewBuilder
    private var searchResultsPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            searchHeader
            searchStatusLines
            searchRows
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(RCBackdrop())
    }

    /// 面から出る口。
    ///
    /// ★之は spec に無い。実機で測って**穴が在ったから足した**(2026-09-01):
    ///   `.searchable` の "Cancel" は**入力中しか出ない**。`displayMode: .always` で
    ///   欄を常設した上で `\n` で確定すると、編集が終わって Cancel が消え、
    ///   `isPresented` は真のまま —— 結果の面から出る手が画面に 1 つも無くなる。
    ///   composer も「以前を読む」も隠してあるので、**会話が使えなくなる**。
    ///   実測: `testTheDraftSurvivesOpeningAndCancellingASearch` が
    ///   「Cancel が 5 秒 現れない」で落ちた。spec は `.searchable` が取り消しを
    ///   常に用意する前提で書かれていて、其の前提が偽だった。
    ///   ★面を消す機構は SwiftUI 側に頼らず、自分が持っている札(`isSearchPresented`)で
    ///     閉じる。閉じれば `onChange` が結果も捨てる。
    private var searchHeader: some View {
        HStack {
            Text("Results")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                isSearchPresented = false
            } label: {
                Text("Done").tapTarget()
            }
            .accessibilityIdentifier("conversation.search.close")
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }

    /// 独立した事実は独立した行に置く(`statusBanners` の既存規約と同じ)。
    /// 1 行に詰めると、片方だけが真の時に嘘が混ざる。
    @ViewBuilder
    private var searchStatusLines: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch viewModel.searchState {
            case .idle:
                // 面は `isSearchPresented` の間ずっと出るので、まだ何も探していない
                // 間に**空の板**になる。spec の表には無い行だが、空白は
                // 「壊れている様に見える所」なので、次に何をすればいいかまで言う。
                Text("Type a word and press return.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("conversation.search.hint")

            case .running:
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Searching…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("conversation.search.busy")

            case .results(let r):
                Text("\(r.matched) matches")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("conversation.search.summary")
                // ★S3 と S4 は**独立**。両方 真なら 2 行とも出る。
                if r.isCapped {
                    Text("Showing the newest \(r.rows.count).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("conversation.search.shownCap")
                }
                if r.coverage == .boundedScan {
                    // ★数量も時刻も言わない。電話は `scanned` を持っていない
                    //   (ルートが転送していない)ので、言えるのは
                    //   「頭までは見ていない」だけ。
                    Text("The search stopped before the start of this conversation.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("conversation.search.boundedScan")
                }

            case .emptyWhole:
                // ★この面**だけ**が言い切りの文を出せる。
                Text("No match anywhere in this conversation.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("conversation.search.emptyWhole")

            case .emptyBounded:
                Text("No match in the part that was searched. "
                     + "The search stopped before the start of this conversation.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("conversation.search.emptyBounded")

            case .failed(let why, let query):
                Text(Self.searchFailureText(why))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("conversation.search.failed")
                Button {
                    Task { await viewModel.search(query: query) }
                } label: {
                    // ★`.tapTarget()` は **label の内側**に当てる(`TapTarget.swift` の
                    //   註: 外に当てると layout の枠だけ育って、押せる領域は文字のまま残る)。
                    Text("Try again").tapTarget()
                }
                .accessibilityIdentifier("conversation.search.retry")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    static func searchFailureText(_ why: TranscriptSearchFailure) -> String {
        switch why {
        case .unreachable: return "Couldn't reach the desk."
        case .malformedBody: return "The desk's answer wasn't in a form this app can read."
        }
    }

    @ViewBuilder
    private var searchRows: some View {
        if case .results(let r) = viewModel.searchState {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    // ★行は**押せない**(→ spec §5)。押せる見た目も出さない。
                    //   机は一致の位置を返しておらず(`scanned` も offset も線に無い)、
                    //   `HistoryEntry` は id も時刻も持たない。本文で転写を引く手は
                    //   在るが、当たるのは読み込み済みの窓の中だけ = **探索が要る場面
                    //   ほど当たらない**上、同じ本文が複数在れば最初の 1 件に当たる。
                    //   跳び先が間違っている事の在る UI は、跳べない UI より悪い。
                    //   ★**行を短く切らない**(`lineLimit` を付けない)。付けると
                    //     一致箇所が見えている範囲の外に在る行が「誤検出」に見える。
                    ForEach(Array(r.rows.enumerated()), id: \.offset) { _, entry in
                        EntryBubble(entry: entry)
                    }
                    // 出さない機能の理由を黙らない。
                    Text("Results can't jump into the transcript yet — "
                         + "the desk doesn't say where each match sits.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                        .accessibilityIdentifier("conversation.search.noJumpNote")
                }
                .padding()
            }
        } else {
            Spacer(minLength: 0)
        }
    }

    /// Sprint 5's whole visible surface: a text field, a send button, and the band
    /// that reports what came back.
    ///
    /// Placed below `loadEarlierFooter` so it sits at the bottom of the screen where a
    /// composer belongs. It renders only inside `.loaded` -- there is nothing to send
    /// INTO a conversation that failed to load, and a composer over a failure view
    /// would invite typing into a screen whose session may not exist.
    // ★`@ViewBuilder` を外した(2026-08-31)。此処は View を組む関数ではなく
    //   `async` の手続き。上の doc は composer の物で、属性だけが取り残されていた
    //   —— 間に doc コメントが挟まったので、属性が**次の宣言**に付いていた。
    //   コンパイラも「明示的な `return` で result builder が無効」と警告していた。
    /// 選ばれた写真を机へ送る。
    ///
    /// ★ここで**画像を作り直さない**。机側が形式を先頭バイトで判定し、HEIC は向こうで
    ///   JPEG へ変換する。電話でも変換すると判定の材料が2箇所で変わり、
    ///   「どちらの変換が原因か」が切り分けられなくなる。運ぶのは撮った物そのまま。
    private func sendPicked(_ item: PhotosPickerItem) async {
        attachBusy = true
        attachNotice = nil
        defer { attachBusy = false; pickedPhoto = nil }

        guard let data = try? await item.loadTransferable(type: Data.self), !data.isEmpty else {
            attachNotice = "Could not read that photo."
            return
        }
        let outcome = await viewModel.attach(image: data)
        attachNotice = AttachWording.text(for: outcome)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            // ★2026-08-16(§9-4 / spec-audit A5): 常設の**状態**帯は同時に1枠だけ。
            //   優先順 = 届かない > 応答が読めない > 送信待ち。以前は3つが独立に描かれ、
            //   悪い日には全部が同時に積み上がった(Tom の「帯3段」)。
            //   ★操作の**答え**の帯(send/interrupt/choice/queueBanner)は畳まない —
            //   あれは押した直後だけ出る返事で、どの操作の返事かの帰属が畳むと壊れる
            //   (各 banner の註に実測の経緯)。畳んだのは常設の状態だけ。
            standingStatusSlot

            // ★机が**今**どうなっているか(2026-08-29)。留守中の要約(下の awayDigest)は
            //   「留守の間に何が在ったか」で、これは「今」— 別の問い、別の枠。
            //   ★観測できていない時は**何も出さない**。「Idle」と「読めていない」を
            //   同じ言葉にすると、机が見えない事故が「静かで正常」に見える。
            if let working = viewModel.deskIsWorking {
                HStack(spacing: 6) {
                    Circle()
                        .fill(working ? RCTheme.accent : Color.secondary)
                        .frame(width: 7, height: 7)
                    // ★「止まっている」と「**あなたを待っている**」は別(2026-08-31)。
                    //   `.choice`(承認/選択の画面)でも `deskIsWorking == false` になるので、
                    //   以前は机が返事を待って止まっている時に **`Idle`** と出ていた ——
                    //   此の app の存在理由そのものの状態で、語が逆を向いていた。
                    // 2026-09-02: 走っている道具の名前を添える(対照表 #7)。「Working」だけだと
                    // 10 分間 何をしているか判らない。名前は転写の末尾から(机の口は増やさない)。
                    Text(working ? (viewModel.currentTool.map { "Working · \($0)" } ?? "Working")
                         : (viewModel.screen?.classification == .choice ? "Waiting on you" : "Idle"))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("conversation.deskState")
            }

            // ★会話が今 何で走っているか(2026-09-02、対照表 #14-16)。公式は接続端末に
            //   現用モデルを出す。此処は**読むだけ** —— 選ぶ操作は別の裁定(D4)に触る。
            //   ★無ければ出さない。古い机は送らないし、要約が取れない間も無い。
            if let sess = viewModel.awayDigest?.session, let line = sess.line {
                HStack(spacing: 5) {
                    Image(systemName: "cpu")
                        .font(.caption2)
                    Text(line)
                        .font(.caption2.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("conversation.sessionRuntime")
            }

            // 留守中に何が起きたか(2026-08-26)。★**常設の状態帯とは別枠**。
            //   §9-4 の「常設の状態帯は同時に1枠だけ」は「今どうなっているか」を争う
            //   帯の話で、これは「留守の間に何が在ったか」= 一度読めば済む物。
            //   同じ枠を争わせると、届かない / 応答が読めない / 送信待ちのどれかを押し出す。
            // ★取れなかった時は**何も出さない**。要約が無い事は異常ではないので、
            //   「要約を取れませんでした」を常設で出すと、直しようの無い帯が居座る。
            if let d = viewModel.awayDigest, !d.line.isEmpty {
                // ★裸のオレンジの1行をやめる(2026-08-29)。地の上に生の警告色を置くと
                //   帯が「壊れている」に見え、実際には「留守中の要約」でしかない。
                //   チップに入れて、色は**文字と縁だけ**に持たせる(面は glass の系のまま)。
                Text(d.line)
                    .font(.caption)
                    .foregroundStyle(d.shouldUrge ? AnyShapeStyle(RCTheme.caution) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .modifier(RCChip(tint: d.shouldUrge ? RCTheme.caution : RCTheme.surfaceStroke))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("conversation.awayDigest")
            }

            if let banner = viewModel.queueBanner {
                // 専用の band(sendBanner / interruptBanner と同じ理由 —— 主語を混ぜない)。
                Text(banner.text)
                    .font(.caption)
                    .foregroundStyle(Self.color(forQueue: banner))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("conversation.queueBanner")
            }

            if let banner = viewModel.sendBanner {
                Text(banner.text)
                    .font(.caption)
                    .foregroundStyle(Self.color(for: banner.tone))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("conversation.sendBanner")
            }

            // Its own row, never merged with `sendBanner` above -- see
            // `ConversationViewModel.interruptBanner`. These two are the operations
            // most likely to be fired seconds apart, and one slot would make the
            // surviving sentence unattributable.
            if let banner = viewModel.interruptBanner {
                Text(banner.text)
                    .font(.caption)
                    .foregroundStyle(Self.color(for: banner.tone))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("conversation.interruptBanner")
            }

            if let reason = viewModel.interruptDisabledReason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("conversation.interruptDisabledReason")
            }

            // ★DESIGN §2.56: 割り込みが飛んでいる間の一文。割り込みの帯の**続き**に置く
            // (banner → 押せない理由 → 飛んでいる)—— 3操作が同じ縦列に文を出す画面で、
            // 読み手が「これはどの操作の話か」を位置で判別できる様に。
            //
            // 下の送信と同じ `.secondary` の caption。§2.54 の2つの理由がそのまま効く:
            // `interruptBanner` は `interrupt()` の入口で明示的に `nil` にされるし、
            // `ResultDisplay.Tone` に中立色が無い。
            if let notice = viewModel.interruptInFlightNotice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("conversation.interruptInFlightNotice")
            }

            // ★DESIGN §2.54: 要求が飛んでいる間の一文。
            //
            // **`sendBanner` に入れない。** 理由は2つあり、どちらも構造的:
            //
            // 1. `send()` は入口で `sendBanner = nil` を明示的にやっていて、そこには
            //    理由が書いてある —— 前回の「送りました」が飛んでいる送信の下に残ると、
            //    古い成功が今回の結果として読まれる。あの空白は事故ではなく設計で、
            //    ここに文を入れるのはその設計を壊しに行く方向。
            // 2. `ResultDisplay.Tone` は ok / refused / error / warn の4つで、**中立が
            //    無い**。まだ何も起きていない状態を warn で塗ると、warn という色が
            //    「気にしなくていい事」を指し始める —— 一番使われる色を鈍らせる取引。
            //
            // なので下の `composerDisabledReason` と同じ、電話が今の状態を説明する
            // `.secondary` の行に置く。この画面は既に「操作の答え(SendBanner)」と
            // 「状態の説明(secondary caption)」を型で分けていて、§2.52 の
            // 「途中経過は答えではない」を**文言でなく置き場所で**守れる。
            if let notice = viewModel.sendInFlightNotice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("conversation.sendInFlightNotice")
            }

            if let reason = viewModel.composerDisabledReason {
                // Shown IN ADDITION to the disabled field, not instead of it: a
                // composer that vanishes tells the user nothing about why, and the two
                // states this can be in (`CHOICE`, `UNKNOWN`) both need explaining.
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("conversation.composerDisabledReason")
            }

            // Below the reason line on purpose: that line says 「下の選択肢から選んで
            // ください」, so the card it points at has to be underneath it. And above
            // the field rather than up in `statusBanners`, because this is the one
            // thing on screen the user is being asked to *do* -- it belongs where the
            // thumb already is, not at the far end of the screen from it.
            choiceCard

            // ★DESIGN §2.56: 打鍵が飛んでいる間の一文。**カードの中に置かない。**
            //
            // 理由が構造的: カードは `visibleChoice` が決めていて、飛んでいる最中に
            // poll が `CHOICE` でない画面を届けるとカードは消える。中に置いた文は
            // その時**一緒に消える** —— 押した直後に画面から全部消えるのが、この節が
            // 直している当の症状。外に置けば、カードが消えても「今飛んでいる」は残る。
            //
            // 代わりに失う物(どの鍵を押したのか)は下のボタン側のスピナが持つ。
            // 文は「飛んでいる事」、スピナは「どれを押したか」で、分担が違う。
            if let notice = viewModel.choiceInFlightNotice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("conversation.choiceInFlightNotice")
            }

            // ★添付の結果は composer のすぐ上に出す。入力欄にパスが載ったのかどうかを、
            //   入力欄を見る前に読める位置に置く為(「送れました」だけだと、載っていない
            //   時に人は入力欄を見て『消えた』と思う)。
            if let notice = attachNotice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("conversation.attachNotice")
            }

            // ★上限の告知(2026-08-30、CF-15)。**composer の直ぐ上**に置く ——
            //   一覧にも同じ事実は出るが、送るのは此処で、判断が要るのも此処。
            //   前の画面で見た事は、次の画面で忘れる。
            //
            // ★★2026-08-31: 此処へ**移した**。以前は `if RCTheme.usesGlass` の **else 側**、
            //   しかも `HStack` の子として置かれていた。既定の variant は `.glassFull` なので
            //   `usesGlass == true` = **電話では一度も描かれていなかった**。
            //   非 glass の系でも壊れていて、`HStack` の兄弟なので入力欄の**左**に
            //   縦長の列として出る(註が言う「直ぐ上」にならない)。
            //   検査(`LimitedNoticeTests`)は純関数 `limitedNotice()` しか見ていないので
            //   **緑のまま死んでいた** —— 描画に触れない検査は、描かれない事を検出しない。
            if let notice = Self.limitedNotice(viewModel.screen) {
                Text(notice)
                    .font(.caption2)
                    .foregroundStyle(RCTheme.caution)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("conversation.limitedNotice")
            }

            // ★机の slash command を画面に出す(2026-08-31、調査の3位)。
            //
            //   `POST .../messages` は本文を pane に打って Enter を押すので、
            //   `/compact` `/context` `/model` は**机の側では既に動く** ——
            //   机の拒否規則(`deny.mjs`)も先頭の `/` を弾かない事を実測した。
            //   つまり能力は前から在って、**画面に存在が出ていなかっただけ**。
            //
            // ★押しても**送らない**。入力欄へ差し込むだけで、送るかどうかは人が決める
            //   —— 写真の添付が既に同じ規約(パスを差すだけで Enter は打たない)で、
            //   机を操作する物を「1タップで実行」にしない事に一貫性が要る。
            //   `/compact` は会話を畳む破壊的な操作なので、尚更 確認の余地を残す。
            //
            // ★出すのは移動中に効く 3 つだけ。一覧にすると探す物になる。
            if viewModel.composerEnabled {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(["/compact", "/context", "/model"], id: \.self) { cmd in
                            Button {
                                // 既に何か打っていれば消さない。前に足す。
                                viewModel.draft = viewModel.draft.isEmpty
                                    ? "\(cmd) " : "\(cmd) " + viewModel.draft
                            } label: {
                                Text(cmd)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(RCTheme.accent)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .modifier(RCChip(tint: RCTheme.surfaceStroke))
                            }
                            .accessibilityIdentifier("conversation.slash.\(cmd.dropFirst())")
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // ★`@` のパス補完(2026-09-02、公式との対照表 #10)。
            //
            //   置き場も作りも **slash のチップと同じ**にする —— 入力欄の上に横1本、
            //   押すと差すだけで**送らない**。写真の添付・slash と同じ規約で、
            //   机を触る物を「1タップで実行」にしない一貫性を崩さない。
            //
            // ★出るのは `draft` の末尾が `@` + 文字列の時だけ(判定は `PathMention`)。
            //   候補が 0 件なら帯ごと出さない —— 空の帯は「探したが無い」ではなく
            //   「壊れている」に見える。
            //
            // ★★`truncated` の「…」を**隠さない**。机は上限に当たると途中で切るので、
            //   切った事を言わないと、人は「此の3つが全部」と読んで探すのをやめる。
            //   押せないただの印にしてあるのは、押して起きる事が何も無いから。
            if viewModel.composerEnabled && !viewModel.pathSuggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(viewModel.pathSuggestions.enumerated()), id: \.offset) { index, item in
                            Button {
                                viewModel.applyPathSuggestion(item)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: item.kind == .dir ? "folder" : "doc")
                                        .font(.caption2)
                                    Text(item.path)
                                        .font(.caption.weight(.medium))
                                        .lineLimit(1)
                                }
                                .foregroundStyle(RCTheme.accent)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .modifier(RCChip(tint: RCTheme.surfaceStroke))
                            }
                            .accessibilityIdentifier("conversation.pathSuggestion.\(index)")
                            .accessibilityLabel(item.path)
                        }
                        if viewModel.pathSuggestionsTruncated {
                            Text("…")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .modifier(RCChip(tint: RCTheme.surfaceStroke))
                                .accessibilityIdentifier("conversation.pathSuggestionsTruncated")
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(alignment: .bottom, spacing: 8) {
                // Left of the field, deliberately far from the send button: these two
                // do opposite things and a mis-tap on a phone in one hand is the
                // ordinary case, not the edge case.
                Button {
                    Task { await viewModel.interrupt() }
                } label: {
                    // ★`Group` で束ねて `.tapTarget()` を**内側**に当てる(X2-3)。
                    // 枝ごとに当てると、飛んでいる間の `ProgressView` に付け忘れた時に
                    // 「押し直しを止めたい局面でだけ的が縮む」が起きる —— 実測で
                    // idle 25.33×26.0 に対し飛行中は 20.0×20.0 だった。
                    Group {
                        if viewModel.isInterrupting {
                            ProgressView()
                        } else {
                            Image(systemName: "stop.circle")
                                .font(.title2)
                        }
                    }
                    .tapTarget()
                    // ★見た目だけで状態を語る(2026-08-29)。押せる範囲は変えない ——
                    //   机が動いていると**判った**時だけ濃く、止まっていると**判った**時は淡く、
                    //   判らない時は中間。「押せない」に見せないのが要点で、
                    //   `interruptEnabled` の裁定(いつでも干渉できる)はそのまま生きている。
                    .opacity(viewModel.deskIsWorking == false ? 0.45 : 1)
                }
                .disabled(!viewModel.canInterrupt)
                .accessibilityLabel("Interrupt")
                .accessibilityIdentifier("conversation.interruptButton")

                // ★写真(2026-08-26)。研究の1位で、**電話でしか出来ない用途** ——
                //   手の中の端末で起きているバグを、机まで持って行かずに撮って送る。
                //   置いた後もパスを差し込むだけで**送信はしない**(送るかは人が決める)。
                PhotosPicker(selection: $pickedPhoto, matching: .images, photoLibrary: .shared()) {
                    Image(systemName: attachBusy ? "hourglass" : "photo.on.rectangle")
                        .font(.system(size: 22))
                        .foregroundStyle(viewModel.composerEnabled ? Color.accentColor : Color.secondary)
                        .frame(width: 34, height: 34)
                }
                .disabled(!viewModel.composerEnabled || attachBusy)
                .accessibilityIdentifier("conversation.attachButton")
                .accessibilityLabel("Attach a photo")

                // ★`.roundedBorder` を使わない(2026-08-29、Tom「黒い箱が洗練されていない」)。
                //   あの様式は暗い系で**真っ黒な矩形**を描き、面に穴が空いた様に見える。
                //
                // ★★2026-09-01: 枝を消した。上の直しは長い間 `if RCTheme.usesGlass` の
                //   **ガラス側にしか入っておらず**、else 側は `.roundedBorder` のままだった。
                //   既定が graphite(平らな面)に替わった瞬間に直しが 1 行も効かなくなり、
                //   実測の画で入力欄の中が **(0,0,0) の純黒**に戻っていた —— 此の配色で
                //   唯一の純黒で、しかも視線が最初に行く場所。
                //   分岐が在る限り「片側だけ直す」が何度でも起きるので、**分岐そのものを
                //   token 1 個(`RCTheme.composerFieldFill`)へ畳んだ**。縁は
                //   `surfaceStroke` が graphite で `.clear` なので自動で消える。
                TextField("Message", text: $viewModel.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(RCTheme.composerFieldFill)
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .strokeBorder(RCTheme.surfaceStroke, lineWidth: 1)
                            )
                    )
                    .lineLimit(1...5)
                    .disabled(!viewModel.composerEnabled)
                    .accessibilityIdentifier("conversation.composerField")

                Button {
                    Task { await viewModel.send() }
                } label: {
                    // 取り直しの間も回す(DESIGN §2.52)。要求は飛び終わっているが
                    // 届いたか分からないので、ボタンは伏せたまま = 二重配達を作らない。
                    Group {
                        if viewModel.isSending || viewModel.isVerifyingSend {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.title2)
                                // 打てる時だけ色が点く(2026-08-29、Tom「矢印とか、大丈夫なんかねぇ」)。
                                // 灰色の矢印は「壊れている」に見え、accent の矢印は「押せ」に見える。
                                // `canSend` は本当に押せるかなので、見た目と能力がここでは一致する。
                                .foregroundStyle(viewModel.canSend
                                    ? AnyShapeStyle(RCTheme.accent) : AnyShapeStyle(.tertiary))
                        }
                    }
                    .tapTarget()
                }
                .disabled(!viewModel.canSend)
                .accessibilityIdentifier("conversation.sendButton")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        // ★`bar-is-composer-only` の錨(2026-08-18)は「**帯を composer 以外に敷くな**」で
        //   あって「`.bar` という綴りである事」ではない。置き場は今まで通り動かさない。
        //
        // ★★2026-09-01: 枝を消し、面を下の 1 個の token へ畳んだ。
        //   (token 名を此の註に素で書かない —— `bar-is-composer-only.test.mjs` は
        //    「其の綴りが此の file に丁度 1 回」で composer 以外への流出を測るので、
        //    註で言及するだけで 2 箇所に数えられて赤くなる。実測済み。)
        //   ・入力欄で踏んだのと同じ理由 —— 枝が在ると「片側だけ直す」が何度でも起きる。
        //   ・平らな側は `.bar`(中立灰、実測 (31,33,35))から配色の面へ。**帯が
        //     「電話の道具」を意味する事は変えていない** —— 転写の地より明るい層で在る、
        //     が意味の担い手であって、灰色の系統ではない。
        //   ・★`RCTheme.surface` を直に書かないのが要点。あれはカードもチップも使う
        //     汎用トークンで、綴りが衝突して `bar-is-composer-only.test.mjs` の
        //     **前提ごと壊れた**(検査 2 本が赤)。帯には帯の名前が要る。
        .background {
            Rectangle()
                .fill(RCTheme.composerBarFill)
                .overlay(alignment: .top) {
                    Rectangle().fill(RCTheme.surfaceStroke).frame(height: 0.5)
                }
                .ignoresSafeArea(edges: .bottom)
        }
    }

    /// The ONLY thing `kind` is allowed to change. The text is always the server's;
    /// this picks a colour for it, and an unrecognized `kind` (already mapped to
    /// `.warn` by `ResultDisplay.tone`) lands on the neutral one rather than
    /// borrowing either success or failure.
    /// Internal rather than `private` for the same reason as
    /// `ForegroundResume.shouldResume`: it is a pure decision lifted out of the view
    /// body so that it can be asserted directly (`ConversationViewTests`). A `private`
    /// helper here would be a rule about what the user sees that no test can reach.
    static func color(for tone: ResultDisplay.Tone) -> Color {
        switch tone {
        case .ok: return .secondary
        case .warn: return .orange
        case .refused: return .orange
        case .error: return .red
        }
    }

    /// queue の band の色。上と同じ「検査から届く場所に置く」規約。対応は
    /// `clearQueueResult`(src/view.mjs)の kind と1対1。
    static func color(forQueue outcome: ClearQueueOutcome) -> Color {
        switch outcome {
        case .ok: return .secondary
        case .warn, .refused: return .orange
        case .error: return .red
        }
    }

    /// 常設の状態帯の1枠(§9-4)。同時に出るのは最も重い1つだけ。
    /// 識別子は中身の物がそのまま出る(検査の錨は変えない)。
    @ViewBuilder
    private var standingStatusSlot: some View {
        if viewModel.isBackendUnreachable {
            UnreachableBanner(
                failures: viewModel.reachability.consecutiveFailures,
                context: .conversation,
                identifier: "conversation.unreachable"
            )
        } else {
            queueStrip(viewModel.queueView(nowMs: Date().timeIntervalSince1970 * 1000))
        }
    }

    /// 送信待ちの面。`show` が偽なら何も描かない(空の帯を出すと「0件」という
    /// 観測の主張に見える —— `QueueViewState` の頭の nil/0 の区別ごと守る)。
    @ViewBuilder
    private func queueStrip(_ q: QueueViewState) -> some View {
        if q.show {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(q.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("conversation.queueText")
                    // 古さは値の一部(poll が止まった時こそ「2分前の値」が要る)。
                    Text(q.ageText)
                        .font(.caption2)
                        .foregroundStyle(q.stale ? Color.orange : Color.secondary)
                        .accessibilityIdentifier("conversation.queueAge")
                }
                Spacer(minLength: 8)
                Button(q.clearLabel) {
                    Task { await viewModel.clearQueue() }
                }
                .font(.caption)
                .buttonStyle(.bordered)
                .disabled(viewModel.isClearingQueue)
                .accessibilityIdentifier("conversation.queueClear")
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("conversation.queueStrip")
        }
    }

    /// ★2026-08-08(§2.56): 選択肢のボタンが回るかどうか。
    ///
    /// `color(for:)` と同じ理由で `static` かつ internal —— view body の中に
    /// `viewModel.inFlightChoiceKey == button.key` と直接書くと、それは**画面の規則**なのに
    /// どの検査からも触れない。S8-5 で判ったのはまさにこれの裏側で、
    /// 「規則は正しいが画面に繋がっていない」も「画面には在るが誰も測れない」も
    /// 同じ穴の両側。純関数に出せば `ConversationViewTests` が直接撃てる。
    ///
    /// ★`inFlight != nil` ではなく **`==` である事**が測る対象。前者だと全ボタンが
    /// 一斉に回り、「押した鍵だけが回る」という当の性質が消えたまま緑になる。
    static func spins(key: String, inFlight: String?) -> Bool {
        inFlight == key
    }

    /// `DiffFactory`(`ConversationHistoryFactory` と同じ形)-- `RC_UI_FIXTURE` が
    /// 立っていれば fixture の client を、無ければ本物の `DiffClient` を渡す。
    private func makeDiffViewModel() -> DiffViewModel {
        #if DEBUG
        if let state = DiffFactory.fixtureState {
            return DiffViewModel(
                client: DiffFetchingFixture(state: state),
                baseURL: viewModel.baseURL, apiKey: viewModel.apiKey, sessionID: viewModel.sessionID
            )
        }
        #endif
        return DiffViewModel(baseURL: viewModel.baseURL, apiKey: viewModel.apiKey, sessionID: viewModel.sessionID)
    }

    private func failureView(message: String, identifier: String) -> some View {
        VStack(spacing: 12) {
            Text(message).font(.headline)
            Button {
                Task { await viewModel.load() }
            } label: {
                Text("Retry").tapTarget()
            }
            .accessibilityIdentifier("conversation.retry")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // ★X2-3。此処が一番静かだった: 入れ物の識別子は引数で来るので、
        // `conversation.unreachable` と `conversation.retry` は名前が親子に見えず、
        // 前方一致の走査では取れない。畳まれている事は brace の入れ子でしか判らない。
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    /// Brief §3-b-2's table, rendered. The two message wordings are never swapped
    /// for each other's row -- asserting the numeric ceiling ("最新 500 件まで") when
    /// the ceiling was never actually reached would assert an unobserved cause.
    ///
    /// ★§2.63: **灰色の帯(`.bar`)を敷かない。** 敷いていた頃、この入口は転写の続きを
    /// 読む物なのに composer の道具に見えていた —— 撮った3枚で帯の上端が文字より
    /// 上に在り、行の地は composer と同じ 246、転写は 255 だった(2026-08-08 実測)。
    /// 灰色はこの画面で「電話の道具」を意味する材質なので、それを敷いた時点で
    /// 所属が変わる。位置は動かさない: 遡る入口が画面の上端に在ると、遡る為に
    /// 先ず遡らないと押せない。親指の側に固定で在る事の方が要る。
    @ViewBuilder
    private var loadEarlierFooter: some View {
        switch viewModel.loadEarlierState {
        case .hidden:
            EmptyView()

        case .available, .loading, .stalledRetry:
            VStack(spacing: 4) {
                if viewModel.loadEarlierState == .stalledRetry {
                    // Brief §3-b-3: a persistent line, not a toast -- a disappearing
                    // message would lose the "older messages exist" STATE, not just
                    // an event.
                    Text("Older messages exist, but couldn't be loaded this time")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("conversation.loadEarlierMessage")
                }
                Button {
                    Task { await viewModel.loadEarlier() }
                } label: {
                    Group {
                        if viewModel.loadEarlierState == .loading {
                            ProgressView()
                        } else if viewModel.loadEarlierState == .stalledRetry {
                            Text("Try again")
                        } else {
                            Text("Load earlier")
                        }
                    }
                    .tapTarget()
                }
                .disabled(viewModel.loadEarlierState == .loading)
                .accessibilityIdentifier("conversation.loadEarlier")
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)

        case .atCeiling:
            Text("Older messages exist, but the phone shows at most the latest 500")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("conversation.loadEarlierCeiling")
        }
    }

    /// Brief §4 gap-notice display + brief §1-b's "D-A" choice badge + the
    /// `UnreadableMeter` staged banner, stacked in that order above the message
    /// list. All 3 are independent of each other -- a gap notice and a stalled poll
    /// loop can both be true at once, and each renders (or doesn't) on its own.
    @ViewBuilder
    private var statusBanners: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let notice = viewModel.latestGapNotice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("conversation.gapNotice")
            }
            // Sprint 6's `conversation.choiceBadge` lived here and rendered nothing but
            // `reason`. Sprint 7 moved the whole menu to `choiceCard` down in the
            // composer, and the badge went with it rather than staying as a second copy
            // of the same sentence: two places showing one refusal is how the two drift
            // apart later.
            //
            // ★2026-08-16(§9-4「帯3段」): 「届かない」が composer 側に出ている間は
            //   劣化の帯を引っ込める — 「応答が確認できません」は「届かない」の下位情報で、
            //   両方出すと同じ事を2枚の帯で言う。届かないが消えた時に、劣化がまだ
            //   続いていれば此処が再び出る(状態は消していない。描画だけ譲る)。
            if !viewModel.isBackendUnreachable {
                degradationBanner
            }
        }
        .padding(.horizontal)
        .padding(.top, 6)
    }

    /// The menu the desk is waiting on, and -- when the server allowed it -- the keys
    /// that answer it.
    ///
    /// ★Nothing here decides what is pressable. `buttons` is computed server-side by
    /// `view.mjs`'s `choiceView`, which emits keys only for a menu `classifyChoice`
    /// matched against its allowlist; a permission or trust prompt arrives with an
    /// empty `buttons` and a `reason` instead. So this view has exactly two jobs: draw
    /// what arrived, and never draw a control the server did not send. Any local
    /// "…but this one looks safe" would be the phone re-deciding a safety question that
    /// was already decided where the screen can actually be read.
    ///
    /// The three states, in the order the code tests them:
    ///
    /// 1. **keys offered** -- buttons, disabled while a press is in flight or while the
    ///    card is stale, with `staleChoiceReason` underneath saying which.
    /// 2. **no keys** -- the server's `reason`, verbatim. This is the hard-stop case
    ///    among others, and its wording is `view.mjs`'s `CHOICE_BLOCKED`, not this
    ///    file's.
    /// 3. **`show == false`** -- nothing at all; the screen is not a menu.
    @ViewBuilder
    private var choiceCard: some View {
        // `visibleChoice` is the ONE place that decides a card exists (`show`, plus the
        // phone's own check that the last observed screen has not left `CHOICE`). The view
        // must not re-derive that from `choiceView` -- two answers to one question is how
        // the composer sentence and the card ended up contradicting each other once already.
        if let choice = viewModel.visibleChoice {
            VStack(alignment: .leading, spacing: 6) {
                // ★危険度の帯(2026-08-26)。**押せる物は1つも変えていない** ——
                //   何が押せるかは `choice.canPress` と `choice.buttons` が今まで通り決める。
                //   ここが変えるのは「読む前に押す」を止めるだけの視覚の重さ。
                //   ★`unmatched` では何も描かない。サーバが空の notice を返すのは、
                //     「当たらなかった」を「安全です」と言い換える材料を渡さない為で、
                //     ここで独自に「問題ありません」を足したら、その設計を電話側が壊す事になる。
                // ★unmatched でも1行出す(2026-08-26、Codex の反論を採用)。
                //   帯が出ない事そのものが「安全」の合図として読まれるので、沈黙をやめて
                //   「検査していない」と明言する。ただし色は付けず地味に置く ——
                //   全ての要求に色帯が出ると、本物の danger が埋もれる。
                if !choice.risk.notice.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: choice.risk.isDanger
                              ? "exclamationmark.triangle.fill"
                              : (choice.risk.isCaution ? "arrow.up.forward.app" : "questionmark.circle"))
                            .font(.caption)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(choice.risk.notice)
                                .font(.caption.weight(.semibold))
                                .fixedSize(horizontal: false, vertical: true)
                            // 何が怖いかを人の言葉で。id は出さない(機械用の語を人に読ませない)。
                            ForEach(choice.risk.signals, id: \.id) { sig in
                                Text("・\(sig.why)")
                                    .font(.caption2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .foregroundStyle(choice.risk.isDanger ? RCTheme.danger
                                     : (choice.risk.isCaution ? RCTheme.caution : Color.secondary))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .background(
                        // unmatched は**地の色を付けない**。色帯は「読め」の合図で、
                        // 毎回出す物ではない。文だけ置いて、色は本物に取っておく。
                        (choice.risk.isDanger ? RCTheme.danger
                         : (choice.risk.isCaution ? RCTheme.caution : Color.clear)).opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )
                    .accessibilityIdentifier("conversation.choiceRisk")
                    .accessibilityValue(choice.risk.tier)
                }

                ForEach(Array(choice.head.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.caption.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Options the server did NOT give a key for, printed as plain text.
                //
                // The ones it did are already drawn as buttons carrying the same
                // 「N. ラベル」 label, so printing every option would show each of those
                // twice. Printing only the leftovers keeps the property that matters --
                // the user sees every choice the desk is offering -- while the fact that
                // an option appears without a button becomes information rather than
                // noise: it is the server declining to hand the phone that key.
                ForEach(unkeyedOptions(of: choice), id: \.n) { option in
                    Text("\(option.n). \(option.label)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if choice.canPress {
                    // Full width and stacked, not a wrapped row: the `enter`/`escape`
                    // labels embed the option they would land on (「決定(2. …で決定)」),
                    // so they are sentences, and a phone-width row would truncate the
                    // very part that says what the key does.
                    // ★構えている事を画面に出す(2026-08-26)。出さないと「押しても何も
                    //   起きなかった」に見え、2回押す設計そのものが利用者から消える。
                    if let notice = viewModel.dangerNotice, viewModel.isArmed(for: choice.digest) {
                        Text("Tap again to confirm — \(notice)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(RCTheme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("conversation.dangerArmed")
                    }
                    ForEach(choice.buttons, id: \.key) { button in
                        HStack(spacing: 6) {
                            // 溝。★§2.62: スピナは**ボタンの外**に置く。
                            //
                            // 最初はボタンの label の `HStack` の中に在った。回すべき鍵の
                            // 判定は正しく、押した鍵にだけ出ていたのに、`.disabled` が
                            // ボタンの subtree ごと淡くするので**スピナも一緒に淡くなった**。
                            // 撮って測ったら、スピナが居る行と居ない行で一番濃い画素が
                            // どちらも 212 —— 押した鍵の唯一の手掛かりが、押していない鍵と
                            // 見分けが付かない状態で出ていた(2026-08-08 実測)。
                            //
                            // 文の側に鍵の名を足す案は採らない。この画面は既に
                            // 「理由」「選べません」「飛んでいます」と3つ文が並んでおり、
                            // 4つ目を足すと**読む物が増えて手掛かりは埋もれる**。
                            // 直すのは色ではなく**位置** —— 伏せられる木から出す。
                            //
                            // 幅を固定して常に置くのは、回り始めた瞬間に行が横へ
                            // ずれない為。空でも溝は在る。
                            ZStack {
                                // ★§2.56: 押した鍵**だけ**が回る。全部回すと「どれを
                                // 押したか」が消える —— 打鍵は3操作の中で唯一、同時に
                                // 複数の的が画面に並ぶ操作なので、ここだけは
                                // 「飛んでいる」より「何が飛んでいる」の方が要る。
                                if Self.spins(key: button.key, inFlight: viewModel.inFlightChoiceKey) {
                                    ProgressView()
                                }
                            }
                            .frame(width: 20)

                            Button {
                                Task { await viewModel.choose(key: button.key) }
                            } label: {
                                Text(button.label)
                                    .font(.callout)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    // ★X2-3。実測 33.33pt。此処は誤タップが**別の答えの
                                    // 送信**になる唯一の面なので、下限割れの害が他と違う。
                                    // `.bordered` の内側に当てるので、枠(見えている物)と
                                    // 当たり判定(押せる物)が一緒に育つ。
                                    .tapTarget()
                            }
                            .buttonStyle(.bordered)
                            .disabled(!viewModel.choiceEnabled)
                            .accessibilityIdentifier("conversation.choiceButton.\(button.key)")
                        }
                    }

                    if let stale = viewModel.staleChoiceReason {
                        Text(stale)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("conversation.choiceStale")
                    }
                } else if !choice.reason.isEmpty {
                    Text(choice.reason)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("conversation.choiceReason")
                }

                // Its own band for the same reason `interruptBanner` is: this answers a
                // keystroke, and merging it with the send or interrupt slot would leave
                // the reader unable to tell which of three operations the surviving
                // sentence belongs to.
                if let banner = viewModel.choiceBanner {
                    Text(banner.text)
                        .font(.caption)
                        .foregroundStyle(Self.color(for: banner.tone))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("conversation.choiceBanner")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // 承認カードは操作の層なので glass の面を持つ(HIG: glass は操作の層)。
            // 橙の名指し(= choice だけ別格)は RCCard の emphasized が持つ。
            .padding(12)
            .modifier(RCCard(emphasized: true))
            // ★`.accessibilityElement(children: .contain)` is not decoration -- without
            // it this identifier propagates DOWN and overwrites every child's own.
            // Measured 2026-08-08: the card rendered perfectly (screenshot) while
            // `conversation.choiceButton.1` and `conversation.choiceReason` were both
            // absent from the accessibility tree, because the container's identifier
            // had replaced theirs. A UI test that only ever asked "does the card
            // exist?" would have gone green on a screen whose every button was
            // unaddressable -- which is also how a VoiceOver user would have met it.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("conversation.choiceCard")
        }
    }

    /// Options with no digit button drawn for them -- see `choiceCard`'s comment.
    ///
    /// Compares against the keys the server actually sent rather than against
    /// `1...options.count`: the two differ exactly when the server withheld a key, and
    /// that is the case this exists to surface.
    private func unkeyedOptions(of choice: ChoiceView) -> [ChoiceOption] {
        guard choice.canPress else { return choice.options }
        let keyed = Set(choice.buttons.map(\.key))
        return choice.options.filter { !keyed.contains(String($0.n)) }
    }

    /// Brief §3-b's 3-row table, the 2 non-`.normal` rows: a quiet 1-line notice at
    /// stage 1 (`.degraded`, no buttons), a warning + `[再試行]`/`[読み直す]` at
    /// stage 2 (`.stalled`) -- `[再試行]`/`[読み直す]` map to
    /// `retryPollingNow()`/`rereadNow()` respectively (see those two methods' own doc
    /// comments in `ConversationViewModel` for the judgment call behind which is
    /// which).
    @ViewBuilder
    private var degradationBanner: some View {
        switch viewModel.unreadableStage {
        case .normal:
            EmptyView()

        case .degraded:
            HStack(spacing: 4) {
                Text("Updates are lagging")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Last confirmed \(lastReadableTimeText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("conversation.lastReadableAt")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // ★X2-3。ボタンは無いが `conversation.lastReadableAt` を畳んでいた。
            // `TapTargetUITests` はこの面で **`.contain` が効いている事そのもの**を
            // 測る —— 下の `.stalled` と違い、此処には的が無いので「寸法が通った」に
            // 紛れずに、畳みの解除だけを単独で見られる唯一の面。
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("conversation.degraded")

        case .stalled:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Text("No response confirmed")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                    Text("Last confirmed \(lastReadableTimeText)")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("conversation.lastReadableAt")
                }
                HStack(spacing: 16) {
                    Button {
                        viewModel.retryPollingNow()
                    } label: {
                        Text("Retry").tapTarget()
                    }
                    .accessibilityIdentifier("conversation.stalled.retry")
                    Button {
                        viewModel.rereadNow()
                    } label: {
                        Text("Re-read").tapTarget()
                    }
                    .accessibilityIdentifier("conversation.stalled.reread")
                }
                .font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // ★X2-3。この2つは画面で一番小さい的(`.font(.caption)`)であり、かつ
            // **一番追い詰められた時に押す物**。しかも畳まれていて、寸法を測る以前に
            // 触る事すらできなかった —— 「居るか」しか聞かない検査では緑のままだった。
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("conversation.stalled")
        }
    }

    private var lastReadableTimeText: String {
        guard let lastReadableAt = viewModel.lastReadableAt else { return "--:--:--" }
        return Self.clockFormatter.string(from: lastReadableAt)
    }

    /// `en_US_POSIX` + a fixed `HH:mm:ss` pattern -- brief §3-b's banner text always
    /// shows a clock time; a locale-dependent format would make the DoD screenshot
    /// (and any UI test asserting on this string) depend on the Simulator's region
    /// setting.
    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}

/// One history row. 3 wire roles get distinct treatment (brief §3-a); `.unknown`
/// (an unrecognized future `role` value, `EntryRole`'s decode fallback) renders
/// exactly like `.assistant` -- never dropped, never a blank row.
private struct EntryBubble: View {
    let entry: HistoryEntry

    /// ★**文字の左端**を 3 branch で 1 本に揃える為の内側 inset(2026-08-31)。
    ///
    /// 直す前は同じ会話の中に版面が 3 種類 立っていた:
    ///   assistant の本文  x = 16(水平 padding 無し)
    ///   tool の行        x = 26(Capsule の内側 10)
    ///   user の本文      右端 W-30(bubble の内側 14)
    /// tool 行は観測された転写の 13/25 を占める(下の註)ので、此の 10pt の差は
    /// 画面の半分近くに出る。Tom の「列がズレてる」は比喩ではなく之。
    ///
    /// ★揃えるのは**箱の左端ではなく文字の左端**。箱(Capsule / bubble)は
    ///   それぞれ違う形をしていて良いが、中の文字が乗る線は 1 本でなければ
    ///   縦に読めない。だから各 branch は「箱の内側 inset を此の値に合わせる」。
    private static let textInset: CGFloat = 10

    var body: some View {
        switch entry.role {
        case .tool:
            // Not a prose bubble: a short one-line label (brief §0-a-2 -- e.g. "⚙
            // Bash"), and a real fraction of a conversation can be `tool` rows
            // (13/25 in one observed transcript), so this must stay visually
            // lightweight or it would dominate the screen.
            // 2026-08-14: 公式アプリの「活動チップ」の型(丸めた薄い背景の1行)。
            HStack(spacing: 5) {
                Text(entry.display.who)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(entry.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, Self.textInset)
            .padding(.vertical, 4)
            // ★2026-09-01: 平らな側を `Color(.systemGray6)`(中立灰)から配色の面へ。
            //   系統の混在の直し —— 詳細は `RCTheme.surfaceElevated` の頭。
            .background(RCTheme.usesGlass ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(RCTheme.surface),
                        in: Capsule())
            .frame(maxWidth: .infinity, alignment: .leading)

        // 2026-08-14 の UI 作り直し。北極星 = Claude の公式アプリ:
        //   **自分の発言だけがバブル**(右寄せ・柔らかい灰)、Claude の応答は
        //   バブル無しの素のテキスト(左・全幅)。灰色の枠線バブルの応酬は
        //   「開発ツールの見た目」の主因だったので落とした。
        //   `display.who` の逐語描画(§0-a-3)はどちらの枝でも生きている。
        case .user:
            HStack {
                Spacer(minLength: 48)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(entry.text)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, Self.textInset)
                        .padding(.vertical, 9)
                        // glass の系では自分の発言を accent の淡い面に(地の光彩と同系で
                        // 「自分の色」が付く)。glass でない系は従来の柔らかい灰のまま。
                        // ★2026-09-01: 平らな側を `Color(.systemGray5)`(中立灰)から
                        //   配色の 1 段上の面へ。実測で泡 (44,44,46) / 面 (26,30,38) と
                        //   灰色の系統が割れていた。
                        .background(RCTheme.usesGlass ? RCTheme.accent.opacity(0.26) : RCTheme.surfaceElevated,
                                    in: RoundedRectangle(cornerRadius: 18))
                }
            }

        case .assistant, .unknown:
            VStack(alignment: .leading, spacing: 3) {
                // Brief §0-a-3: `display.who` verbatim -- never reconstructed from `role`.
                Text(entry.display.who)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(entry.text)
                    .font(.body)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // ★面は足さない(2026-08-14 の裁定 = Claude の応答はバブル無しの素のテキスト)。
            //   足すのは inset だけ —— 見た目は変えずに、文字が tool 行と同じ線へ乗る。
            .padding(.horizontal, Self.textInset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// 会話の内容が、窓に対して今どこに居るか。
///
/// ★之は **倒れた瞬間に測った量そのもの**。2026-08-31 の失敗記録:
///   内容 3308.0 / 窓 501.7 / 寄せ -2430.7 → 下端まで 375.6pt(約 3 行)残っていた。
///   欠陥を検出した式を、そのまま修正の終端条件に使う。
private struct ConversationContentMetrics: Equatable {
    /// `LazyVStack` 全体の高さ。行が実体化するに連れて変わる。
    var contentHeight: CGFloat = 0
    /// 内容の上端の y(`ScrollView` の座標系)。下へ寄る程 負。
    var contentTop: CGFloat = 0
}

private struct ConversationContentMetricsKey: PreferenceKey {
    static var defaultValue = ConversationContentMetrics()
    /// ★**既定値を出す兄弟に上書きさせない**(2026-08-31、実測で捕まえた)。
    ///
    /// `reduce` は兄弟を順に畳む。無条件の `value = nextValue()` だと、
    /// 実測を出す子(内容の `background`)の**後**に既定値を出す子
    /// (`overlay` / 窓側の `background`)が来た時点で 0 に戻る。
    /// 実測: `LANDING-DISTANCE=unmeasured nohog h=0.0 top=0.0 v=501.7` ——
    /// 窓側の key には最初から `if next > 0` の門が在ったので生き残り、
    /// 内容側だけが 0 になっていた。**同じ file の中で片方だけ守っていた。**
    ///
    /// ★之が効いていた間、閉ループは `guard contentHeight > 0` で毎回 即 return
    ///   していた = **補正は一度も走っていない**。759 件の緑は「補正が効いた」
    ///   ではなく「補正が死んでいた」の観測だった。
    static func reduce(value: inout ConversationContentMetrics,
                       nextValue: () -> ConversationContentMetrics) {
        let next = nextValue()
        if next.contentHeight > 0 { value = next }
    }
}

private struct ConversationViewportHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 { value = next }
    }
}
