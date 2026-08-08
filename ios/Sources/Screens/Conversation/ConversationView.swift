import SwiftUI

/// The Conversation screen (Sprint 3 brief §3). Renders `ConversationViewModel`'s
/// `phase`/`loadEarlierState` -- display only, same split `ListView`/`ListViewModel`
/// already establishes.
struct ConversationView: View {
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

    init(viewModel: @autoclosure @escaping () -> ConversationViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel())
    }

    var body: some View {
        content
            // Brief §3-c: the title comes from the List row that navigated here and
            // survives any failure phase below -- never re-derived from `/history`
            // (which carries no title), never blanked while retrying.
            .navigationTitle(viewModel.title)
            .navigationBarTitleDisplayMode(.inline)
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
                message: "会話を読み込めませんでした",
                identifier: "conversation.unreachable"
            )

        case .malformedBody:
            // Brief §3-c: must never render as an empty conversation -- "broken" and
            // "genuinely nothing said yet" are never the same bucket.
            failureView(
                message: "応答の形が読めません",
                identifier: "conversation.malformedBody"
            )

        case .notFound:
            // Brief §3-c's table, this row specifically: retrying a 404 just 404s
            // again, so this is the one failure phase with NO "再試行" button --
            // `failureView` above always renders one, which is exactly why this
            // case has its own view rather than reusing that helper.
            VStack(spacing: 12) {
                Text("この会話はもう在りません(一覧が古いのかもしれません)")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Button("一覧に戻る") { dismiss() }
                    .accessibilityIdentifier("conversation.notFound.backToList")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    ScrollView {
                        Text("まだ発言がありません")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                            .padding(.top, 80)
                            .frame(maxWidth: .infinity)
                    }
                    .accessibilityIdentifier("conversation.empty")
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 10) {
                                // No wire-provided id (brief §1-a: history entries carry
                                // none) -- position is stable for a screen that never
                                // reorders or removes rendered entries in place.
                                ForEach(Array(viewModel.entries.enumerated()), id: \.offset) { _, entry in
                                    EntryBubble(entry: entry)
                                }
                                // 一番下の錨。行の identity は `Int`(enumerated の
                                // offset)なので、ぶつからない `String` を id にする。
                                Color.clear
                                    .frame(height: 1)
                                    .id(Self.bottomAnchorID)
                                    .onAppear { isPinnedToBottom = true }
                                    .onDisappear { isPinnedToBottom = false }
                            }
                            .padding()
                        }
                        .onAppear {
                            // 開いた瞬間は無条件で一番下。
                            //
                            // `.defaultScrollAnchor(.bottom)`(iOS 17)を**使わない**の
                            // は、あれが「内容の大きさが変わる度に下端を保つ」修飾子
                            // だから -- 「以前を読む」で前に足した時も下端に留まり、
                            // 上へ遡って読んでいる最中の追記でも引き摺り下ろす。
                            // 寄せる条件を自分で持てなくなる。
                            proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                        }
                        .onChange(of: viewModel.tailToken) { _, _ in
                            // ★下端に居る時だけ追う。上へ遡って読んでいる最中に机が
                            // 喋ったからといって引き摺り下ろすと、この画面で一番長い
                            // 操作(読む事)ができなくなる。
                            guard isPinnedToBottom else { return }
                            withAnimation { proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom) }
                        }
                        .onChange(of: viewModel.earlierRevealToken) { _, _ in
                            // 「以前を読む」の後。足す前に一番古かった行を**下端**へ
                            // 置く = 新しく出た古い行で画面が埋まる。ここで下端へ
                            // 寄せてしまう(= `tailToken` と同じ扱いにする)と、押した
                            // 行為そのものが画面から消える。
                            guard let index = viewModel.earlierRevealIndex else { return }
                            proxy.scrollTo(index, anchor: .bottom)
                        }
                    }
                }
                loadEarlierFooter
                composer
            }
        }
    }

    /// Sprint 5's whole visible surface: a text field, a send button, and the band
    /// that reports what came back.
    ///
    /// Placed below `loadEarlierFooter` so it sits at the bottom of the screen where a
    /// composer belongs. It renders only inside `.loaded` -- there is nothing to send
    /// INTO a conversation that failed to load, and a composer over a failure view
    /// would invite typing into a screen whose session may not exist.
    @ViewBuilder
    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if viewModel.isBackendUnreachable {
                // Spec §5-4, the same component List draws. Sits above both banners:
                // "nothing is getting through" is the frame the other two sentences
                // have to be read inside.
                UnreachableBanner(
                    failures: viewModel.reachability.consecutiveFailures,
                    context: .conversation,
                    identifier: "conversation.unreachable"
                )
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

            HStack(alignment: .bottom, spacing: 8) {
                // Left of the field, deliberately far from the send button: these two
                // do opposite things and a mis-tap on a phone in one hand is the
                // ordinary case, not the edge case.
                Button {
                    Task { await viewModel.interrupt() }
                } label: {
                    if viewModel.isInterrupting {
                        ProgressView()
                    } else {
                        Image(systemName: "stop.circle")
                            .font(.title2)
                    }
                }
                .disabled(!viewModel.canInterrupt)
                .accessibilityLabel("割り込む")
                .accessibilityIdentifier("conversation.interruptButton")

                TextField("メッセージ", text: $viewModel.draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)
                    .disabled(!viewModel.composerEnabled)
                    .accessibilityIdentifier("conversation.composerField")

                Button {
                    Task { await viewModel.send() }
                } label: {
                    // 取り直しの間も回す(DESIGN §2.52)。要求は飛び終わっているが
                    // 届いたか分からないので、ボタンは伏せたまま = 二重配達を作らない。
                    if viewModel.isSending || viewModel.isVerifyingSend {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                    }
                }
                .disabled(!viewModel.canSend)
                .accessibilityIdentifier("conversation.sendButton")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
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

    private func failureView(message: String, identifier: String) -> some View {
        VStack(spacing: 12) {
            Text(message).font(.headline)
            Button("再試行") { Task { await viewModel.load() } }
                .accessibilityIdentifier("conversation.retry")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier(identifier)
    }

    /// Brief §3-b-2's table, rendered. The two message wordings are never swapped
    /// for each other's row -- asserting the numeric ceiling ("最新 500 件まで") when
    /// the ceiling was never actually reached would assert an unobserved cause.
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
                    Text("これより古い発言は在りますが、今回は読み込めませんでした")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("conversation.loadEarlierMessage")
                }
                Button {
                    Task { await viewModel.loadEarlier() }
                } label: {
                    if viewModel.loadEarlierState == .loading {
                        ProgressView()
                    } else if viewModel.loadEarlierState == .stalledRetry {
                        Text("もう一度試す")
                    } else {
                        Text("以前を読む")
                    }
                }
                .disabled(viewModel.loadEarlierState == .loading)
                .accessibilityIdentifier("conversation.loadEarlier")
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(.bar)

        case .atCeiling:
            Text("これより古い発言は在りますが、電話には最新 500 件までしか出せません")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(.bar)
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
            degradationBanner
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
                Text("更新が遅れています")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("最終確認 \(lastReadableTimeText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("conversation.lastReadableAt")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("conversation.degraded")

        case .stalled:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Text("応答が確認できません")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                    Text("最終確認 \(lastReadableTimeText)")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("conversation.lastReadableAt")
                }
                HStack(spacing: 16) {
                    Button("再試行") { viewModel.retryPollingNow() }
                        .accessibilityIdentifier("conversation.stalled.retry")
                    Button("読み直す") { viewModel.rereadNow() }
                        .accessibilityIdentifier("conversation.stalled.reread")
                }
                .font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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

    var body: some View {
        switch entry.role {
        case .tool:
            // Not a prose bubble: a short one-line label (brief §0-a-2 -- e.g. "⚙
            // Bash"), and a real fraction of a conversation can be `tool` rows
            // (13/25 in one observed transcript), so this must stay visually
            // lightweight or it would dominate the screen.
            HStack(spacing: 6) {
                Text(entry.display.who)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(entry.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .user:
            HStack {
                Spacer(minLength: 40)
                bubble(filled: true)
            }

        case .assistant, .unknown:
            HStack {
                bubble(filled: false)
                Spacer(minLength: 40)
            }
        }
    }

    private func bubble(filled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            // Brief §0-a-3: `display.who` verbatim -- never reconstructed from `role`.
            Text(entry.display.who)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(filled ? Color.white.opacity(0.85) : Color.secondary)
            Text(entry.text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(filled ? Color.accentColor.opacity(0.85) : Color.gray.opacity(0.12))
        .foregroundStyle(filled ? Color.white : Color.primary)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            if !filled {
                RoundedRectangle(cornerRadius: 14).stroke(Color.secondary.opacity(0.3))
            }
        }
    }
}
