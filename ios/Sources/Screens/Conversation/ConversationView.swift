import SwiftUI
import PhotosUI

/// The Conversation screen (Sprint 3 brief §3). Renders `ConversationViewModel`'s
/// `phase`/`loadEarlierState` -- display only, same split `ListView`/`ListViewModel`
/// already establishes.
struct ConversationView: View {
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

    init(viewModel: @autoclosure @escaping () -> ConversationViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel())
    }

    var body: some View {
        content
            .background(RCBackdrop())
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
                    ScrollView {
                        Text("No messages yet")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                            .padding(.top, 80)
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
                    .onChange(of: pickedPhoto) { _, item in
                        guard let item else { return }
                        Task { await sendPicked(item) }
                    }
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

            // 留守中に何が起きたか(2026-08-26)。★**常設の状態帯とは別枠**。
            //   §9-4 の「常設の状態帯は同時に1枠だけ」は「今どうなっているか」を争う
            //   帯の話で、これは「留守の間に何が在ったか」= 一度読めば済む物。
            //   同じ枠を争わせると、届かない / 応答が読めない / 送信待ちのどれかを押し出す。
            // ★取れなかった時は**何も出さない**。要約が無い事は異常ではないので、
            //   「要約を取れませんでした」を常設で出すと、直しようの無い帯が居座る。
            if let d = viewModel.awayDigest, !d.line.isEmpty {
                Text(d.line)
                    .font(.caption)
                    .foregroundStyle(d.shouldUrge ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
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

                TextField("Message", text: $viewModel.draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
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
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(RCTheme.usesGlass ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(Color(.systemGray6)),
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
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        // glass の系では自分の発言を accent の淡い面に(地の光彩と同系で
                        // 「自分の色」が付く)。glass でない系は従来の柔らかい灰のまま。
                        .background(RCTheme.usesGlass ? RCTheme.accent.opacity(0.26) : Color(.systemGray5),
                                    in: RoundedRectangle(cornerRadius: 18))
                }
            }

        case .assistant, .unknown:
            VStack(alignment: .leading, spacing: 3) {
                // Brief §0-a-3: `display.who` verbatim -- never reconstructed from `role`.
                Text(entry.display.who)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                Text(entry.text)
                    .font(.body)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
