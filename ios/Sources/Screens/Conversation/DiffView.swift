import SwiftUI

/// 差分(diff)を電話で読む画面(対照表 #4、2026-09-02)。一覧の ± バッジ(#5、未着手)が
/// 「幾ら変わったか」を出すのに対し、此処は**何が変わったか**を返す -- 会話画面の
/// 工具帯から `NavigationLink` で押して開く(此のアプリの他の全画面と同じ push 遷移、
/// `AccountBar`/`ArchivedListView` と同じ形。`.sheet` はこのアプリのどこにも無い)。
struct DiffView: View {
    @StateObject private var viewModel: DiffViewModel

    init(viewModel: @autoclosure @escaping () -> DiffViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel())
    }

    var body: some View {
        content
            .background(RCBackdrop())
            .navigationTitle("Diff")
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
            ContentUnavailableView(
                Self.reasonTitle(reason),
                systemImage: "folder.badge.questionmark",
                description: Text(Self.reasonDetail(reason))
            )
            .accessibilityIdentifier("diff.reason")
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
                        DiffFileCard(file: file)
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

    private static func reasonTitle(_ reason: String) -> String {
        switch reason {
        case "not_a_repo": return "Not a git repository"
        case "no_cwd", "cwd_missing": return "No working directory"
        default: return "Nothing to show"
        }
    }

    private static func reasonDetail(_ reason: String) -> String {
        switch reason {
        case "not_a_repo": return "This conversation's folder isn't tracked by git."
        case "no_cwd": return "This conversation has no recorded working directory."
        case "cwd_missing": return "That folder no longer exists on the desk."
        case "git_failed": return "The desk couldn't read git here."
        default: return "The desk had nothing to show for this conversation."
        }
    }
}

/// 1 ファイルぶんのカード。`path` / `staged` チップ / `+added -removed` / 塊(hunks)。
private struct DiffFileCard: View {
    let file: DiffFile

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if file.binary {
                Text("Binary file")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(file.hunks.enumerated()), id: \.offset) { _, hunk in
                    DiffHunkView(hunk: hunk)
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
private struct DiffHunkView: View {
    let hunk: DiffHunk

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(hunk.header)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
            ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                DiffLineView(line: line)
            }
        }
    }
}

private struct DiffLineView: View {
    let line: DiffLine

    var body: some View {
        Text(prefixedText)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .background(background)
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
