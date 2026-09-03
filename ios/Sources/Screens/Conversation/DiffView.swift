import SwiftUI

/// 差分(diff)を電話で読む画面(対照表 #4、2026-09-02)。一覧の ± バッジ(#5、未着手)が
/// 「幾ら変わったか」を出すのに対し、此処は**何が変わったか**を返す -- 会話画面の
/// 工具帯から `NavigationLink` で押して開く(此のアプリの他の全画面と同じ push 遷移、
/// `AccountBar`/`ArchivedListView` と同じ形。`.sheet` はこのアプリのどこにも無い)。
struct DiffView: View {
    @StateObject private var viewModel: DiffViewModel
    /// 保留中の行コメント(#6)の持ち主。`ConversationViewModel` そのものを受ける ---
    /// 会話画面へ戻っても・diff 画面を開き直しても残る事が要件で(design doc「in
    /// memory; per session」)、其の寿命は composer が既に持つ物(`draft` 等)と同じ
    /// なので、専用の型を新設せず此処へ直に渡す(`DiffViewModel` 自身は
    /// 「読むだけの脇の画面」のまま、コメントの状態は一切持たない)。
    @ObservedObject var comments: ConversationViewModel

    /// `nil` = 閉じている。alert は `Binding(get:set:)` 越しに此れを見る
    /// (`ListView` の rename alert と同じ形)。
    @State private var commentTarget: DiffCommentTarget?
    @State private var commentAlertShown = false
    @State private var commentDraft = ""

    /// 1行を指す最小限の組。`Identifiable` は要らない -- alert の開閉は
    /// `commentTarget != nil` の真偽だけで足りる(`ListView.renameTarget` と同じ)。
    struct DiffCommentTarget: Equatable {
        let path: String
        let staged: Bool
        let line: Int
        let kind: DiffLineKind
        let quotedText: String
    }

    init(viewModel: @autoclosure @escaping () -> DiffViewModel, comments: ConversationViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel())
        self.comments = comments
    }

    var body: some View {
        content
            .background(RCBackdrop())
            .navigationTitle("Diff")
            .navigationBarTitleDisplayMode(.inline)
            .task { await viewModel.load() }
            // ★`isPresented` は素の Bool、対象は `presenting:` で渡す(2026-09-03)。
            //   `commentTarget != nil` から作った派生 Binding + `message` が同じ state を読む形だと、
            //   Save で `commentTarget = nil` にした瞬間に閉じるアニメーションの最中で本文が消え、
            //   alert が半透明のまま収束しなかった(iPhone-lc の画面に残像、XCUITest は app の idle
            //   待ちで 2 回 固まった)。`presenting:` は閉じ終わるまでデータを保持する SwiftUI の定石。
            .alert(
                "Comment on this line",
                isPresented: $commentAlertShown,
                presenting: commentTarget
            ) { _ in
                TextField("Comment", text: $commentDraft)
                    .accessibilityIdentifier("diff.comment.field")
                Button("Save") { saveComment() }
                    .accessibilityIdentifier("diff.comment.save")
                if isEditingExistingComment {
                    Button("Remove", role: .destructive) { removeComment() }
                        .accessibilityIdentifier("diff.comment.remove")
                }
                Button("Cancel", role: .cancel) { commentDraft = "" }
            } message: { t in
                // ★行の中身を其のまま引用する -- 之は `DiffCommentFormatter` が
                //   組む本文とは**別の写し**(此処は利用者に見せる為、其方は机へ
                //   送る為)なので、書式が揃っている事に依存しない。
                Text("\(t.path):\(t.line)\n\"\(t.quotedText)\"")
            }
    }

    private var isEditingExistingComment: Bool {
        guard let t = commentTarget else { return false }
        return comments.existingDiffComment(path: t.path, staged: t.staged, line: t.line, kind: t.kind) != nil
    }

    private func openComment(path: String, staged: Bool, line: Int, kind: DiffLineKind, quotedText: String) {
        commentDraft = comments.existingDiffComment(path: path, staged: staged, line: line, kind: kind)?.text ?? ""
        commentTarget = DiffCommentTarget(path: path, staged: staged, line: line, kind: kind, quotedText: quotedText)
        commentAlertShown = true
    }

    // ★Save / Remove では `commentTarget` を触らない。alert のボタンが押されると SwiftUI が
    //   `commentAlertShown` を false に戻して閉じる。閉じている最中に対象を消すと残像になる(上の註)。
    private func saveComment() {
        guard let t = commentTarget else { return }
        comments.upsertDiffComment(
            path: t.path, staged: t.staged, line: t.line, kind: t.kind,
            quotedText: t.quotedText, text: commentDraft
        )
        commentDraft = ""
    }

    private func removeComment() {
        guard let t = commentTarget else { return }
        comments.removeDiffComment(path: t.path, staged: t.staged, line: t.line, kind: t.kind)
        commentDraft = ""
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .loading:
            ScrollView {
                ProgressView()
                    .padding(.top, 80)
                    .accessibilityIdentifier("diff.loading")
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
                .accessibilityIdentifier("diff.retry")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("diff.failed")

        case .loaded(let response):
            loadedContent(response)
        }
    }

    @ViewBuilder
    private func loadedContent(_ response: SessionDiffBody) -> some View {
        // ★読めない事は**異常ではなく状態**(`sessiondiff.mjs` の頭書きと同じ判断)。
        //   `reason` が在れば、それは机の git が壊れたのではなく、此の会話に
        //   「読める作業木」がそもそも無い -- 静かな空面で言う。ContentUnavailableView
        //   は ListView の "That session isn't in this list" と同じ語彙。
        if let reason = response.reason {
            // ★`busy`(机が混んでいる、503)は**待てば直る**種類なので、撃ち直す導線を置く
            //   (Codex #4: 503 を「読めた」状態に通した以上、再試行の口が無いと行き止まり)。
            //   他の reason は撃ち直しても変わらない(repo が無い等)ので導線を出さない。
            // ★ボタンは `ContentUnavailableView` の `actions:` に入れない —— 其処に置くと accessibility の
            //   木に個別の要素として出ず、UI 検査(`diff.retry`)が `.any` で降りても捕まらなかった
            //   (2026-09-03 実測、写真では描けている)。外の VStack に普通の Button として置く。
            VStack(spacing: 16) {
                ContentUnavailableView {
                    Label(Self.reasonTitle(reason), systemImage: reason == "busy" ? "hourglass" : "folder.badge.questionmark")
                } description: {
                    Text(Self.reasonDetail(reason))
                }
                .accessibilityIdentifier("diff.reason")
                if reason == "busy" {
                    Button("Try again") { Task { await viewModel.load() } }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("diff.retry")
                }
            }
        } else if response.files.isEmpty {
            ContentUnavailableView(
                "No changes",
                systemImage: "checkmark.circle",
                description: Text("The working tree has nothing uncommitted.")
            )
            .accessibilityIdentifier("diff.empty")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(response.files) { file in
                        DiffFileCard(
                            file: file,
                            commentFor: { line, kind in
                                comments.existingDiffComment(path: file.path, staged: file.staged, line: line, kind: kind)
                            },
                            onTapLine: { line, kind, quotedText in
                                openComment(path: file.path, staged: file.staged, line: line, kind: kind, quotedText: quotedText)
                            }
                        )
                    }
                }
                .padding()
            }
            .safeAreaInset(edge: .bottom) {
                // ★切ったら切ったと言う(`sessiondiff.mjs` の頭書き)。数(+/-)は
                //   切っていても嘘を吐かないので、此処は「全部は出ていない」とだけ言う --
                //   何件切れたかは机も持っていない(切ったのは行、ファイルは残る)。
                if response.truncated {
                    Text("Truncated — showing partial output")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(RCTheme.composerBarFill)
                        .accessibilityIdentifier("diff.truncated")
                }
            }
        }
    }

    /// 机の `reason` → 見出し。★`reasonDetail` と**同じ語彙を同じ分岐で**持つ(2026-09-03、loop の
    ///   discovery: 見出しだけ `git_failed` を欠いていて、机の git の失敗が「Nothing to show」=
    ///   「差分が無い」の顔で出ていた)。両方を internal にして検査(`DiffViewReasonTests`)が
    ///   「見出しと本文が同じ reason を知っている」事を測る。
    static func reasonTitle(_ reason: String) -> String {
        switch reason {
        case "not_a_repo": return "Not a git repository"
        case "no_cwd", "cwd_missing": return "No working directory"
        case "git_failed": return "Git couldn't be read"
        // 机が読まないと決めた repo(`.git` が symlink、2026-09-03 の固め)。壊れたのではなく断った。
        case "unsafe_repo": return "Not read on purpose"
        // 机が混んでいて順番待ちも一杯(503 の本文の reason。再試行で直る種類)。
        case "busy": return "The desk is busy"
        default: return "Nothing to show"
        }
    }

    static func reasonDetail(_ reason: String) -> String {
        switch reason {
        case "not_a_repo": return "This conversation's folder isn't tracked by git."
        case "no_cwd": return "This conversation has no recorded working directory."
        case "cwd_missing": return "That folder no longer exists on the desk."
        case "git_failed": return "The desk couldn't read git here."
        case "unsafe_repo": return "This folder's .git is a symlink, so the desk refused to run git in it."
        case "busy": return "Too many diffs are being read at once. Wait a moment and try again."
        default: return "The desk had nothing to show for this conversation."
        }
    }

    /// 見出しと本文が名指しで知っている reason の一覧(検査が「片方だけ知っている語」を見つける為)。
    static let knownReasons: [String] = ["not_a_repo", "no_cwd", "cwd_missing", "git_failed", "unsafe_repo", "busy"]
}

/// 1 ファイルぶんのカード。`path` / `staged` チップ / `+added -removed` / 塊(hunks)。
private struct DiffFileCard: View {
    let file: DiffFile
    /// #6: 此の file の1行(番号 + 種類)へ既存のコメントが在るか。`nil` を返す口を
    /// `DiffView` が閉じているので、此処は `ConversationViewModel` を一切知らない。
    let commentFor: (Int, DiffLineKind) -> DiffComment?
    /// 長押しされた1行(番号・種類・其の行の中身)を `DiffView` へ渡すだけ -- alert を
    /// 開くかどうかの判断は持たない。
    let onTapLine: (Int, DiffLineKind, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if file.binary {
                Text("Binary file")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(file.hunks.enumerated()), id: \.offset) { hunkIndex, hunk in
                    DiffHunkView(
                        hunk: hunk, fileID: file.id, hunkIndex: hunkIndex,
                        commentFor: commentFor, onTapLine: onTapLine
                    )
                }
                if file.truncated {
                    Text("This file was cut off")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(RCCard())
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(file.path)
                .font(.system(.footnote, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 8)
            if file.staged {
                Text("staged")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(RCTheme.accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .modifier(RCChip(tint: RCTheme.accent))
            }
            if !file.binary {
                Text("+\(file.added)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.green)
                Text("-\(file.removed)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(RCTheme.danger)
            }
        }
    }
}

/// 1 塊(hunk)。頭書きは机の生の文字列のまま出す(電話は解釈しない -- `sessiondiff.mjs`
/// の doc「電話は『ファイルの一覧 → その中の塊』で読む」に対応する、塊の中身の描き方)。
///
/// ★行番号は此処で1回だけ計算する(`DiffLineLocator.lineNumbers`)。`hunk.lines` と
///   **同じ長さ・同じ順**の配列なので、ForEach の位置番号でそのまま引ける。之は
///   表示に使わず(header は生文字列のまま)、#6 のコメントの宛先としてのみ使う裏の値。
private struct DiffHunkView: View {
    let hunk: DiffHunk
    /// #6: markers/tap のコールバックが file 単位ではなく hunk 単位で一意な行を
    /// 要らないので、此処では file レベルの `commentFor`/`onTapLine` を其の侭下ろす。
    let fileID: String
    /// accessibility identifier だけに使う(header の生文字列を identifier へ埋め込むと
    /// 空白・記号が混じって脆くなる -- ForEach の位置番号の方が安定する)。
    let hunkIndex: Int
    let commentFor: (Int, DiffLineKind) -> DiffComment?
    let onTapLine: (Int, DiffLineKind, String) -> Void

    var body: some View {
        let numbers = DiffLineLocator.lineNumbers(header: hunk.header, lines: hunk.lines)
        VStack(alignment: .leading, spacing: 2) {
            Text(hunk.header)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
            ForEach(Array(hunk.lines.enumerated()), id: \.offset) { index, line in
                let number = numbers[index]
                let comment = number.flatMap { commentFor($0, line.kind) }
                DiffLineView(
                    line: line,
                    comment: comment,
                    // ★header が解けなかった行(`number == nil`)は長押しを受け付けない
                    //   -- 宛先(行番号)が無いコメントは机へ送っても読み手が特定できない。
                    //   異常ではなく「此の行だけ機能の対象外」という状態(此の file の
                    //   doc「読めない事は異常ではなく状態」と同じ判断)。
                    onTap: number.map { n in { onTapLine(n, line.kind, line.text) } }
                )
                .accessibilityIdentifier("diff.line.\(fileID).\(hunkIndex).\(index)")
                // ★2026-09-02 実測: `DiffLineView` の中で `Rectangle()` に付けた
                //   独立の識別子(`diff.line.hasComment`)は XCUITest から一度も
                //   見つからなかった(`iPhone-lc` 実測、marker が存在するのに
                //   waitForExistence が timeout)。SwiftUI が `.accessibilityIdentifier`
                //   を持つ此の親 view の下で、装飾用の子 shape を独立要素として
                //   出さない(既に確立済みの `.accessibilityIdentifier` を持つ此の行
                //   要素の下では潰れる)形を実測で確認したので、代わりに**同じ行の
                //   accessibility value** で持たせる -- 此処は行の識別子と同じく
                //   実測で見つかる事を確認済みの経路。
                .accessibilityValue(comment != nil ? "has-comment" : "")
            }
        }
    }
}

private struct DiffLineView: View {
    let line: DiffLine
    /// #6: 此の行に既に付いているコメント(在れば)。見た目のマーカーを出すだけで、
    /// 中身(文面)は alert 側でしか読まない -- 一覧の行に文字を流し込むと、
    /// 長いコメントで diff 自体が読みにくくなる。
    let comment: DiffComment?
    let onTap: (() -> Void)?

    var body: some View {
        Text(prefixedText)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .background(background)
            .overlay(alignment: .leading) {
                // マーカー: コメントが在る行だけ縦線を足す。文言は積まない
                // (上の doc の理由)。★此の shape 自身に accessibility identifier は
                //   持たせない -- `DiffHunkView` が同じ事実を行の `accessibilityValue`
                //   で持つ(其方の doc に実測の経緯)。此処は見た目専用。
                if comment != nil {
                    Rectangle()
                        .fill(RCTheme.accent)
                        .frame(width: 3)
                }
            }
            .contentShape(Rectangle())
            .onLongPressGesture {
                onTap?()
            }
    }

    /// 記号(`+`/`-`)は `kind` から電話が組む -- 机は色(`kind`)しか送らない
    /// (`sessiondiff.mjs`: 「行の text から先頭の記号を落とす(色は kind が持つ)」)。
    private var prefixedText: String {
        switch line.kind {
        case .add: return "+ " + line.text
        case .del: return "- " + line.text
        case .ctx, .unknown: return "  " + line.text
        }
    }

    private var foreground: Color {
        switch line.kind {
        case .add: return .green
        case .del: return RCTheme.danger
        case .ctx, .unknown: return .primary
        }
    }

    private var background: Color {
        switch line.kind {
        case .add: return .green.opacity(0.12)
        case .del: return RCTheme.danger.opacity(0.12)
        case .ctx, .unknown: return .clear
        }
    }
}
