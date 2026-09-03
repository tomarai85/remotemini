import SwiftUI

/// 机の roots の下から dir を選んで、其処で新しい会話を始める(2026-09-03、対照表 #11、Tom 裁定 = roots の下だけ)。
///
/// 形: root の一覧 → 押すと其の下の dir → 更に押すと降りる → **「Start here」で始める**。
/// ★dir を押すのは**降りる**だけで、何も始めない(規約「押しても送らない」)。起動は明示のボタン 1 つ。
/// ★現在地は root の札 + 相対 path で出す。絶対 path は電話にも来ない(線に出ない)。
/// ★台帳が無い(`no_roots`)は空表 + 1 文。断りではなく「受ける場所が 0 件」なので赤くしない。
struct DirectoryPickerView: View {
    let browser: RootsBrowsing
    let baseURL: URL
    let apiKey: String
    /// 机が受け付けた後に呼ぶ(一覧を引き直す)。少し置いてから引くのは呼び手の判断。
    let onStarted: () async -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var roots: [DeskRoot] = []
    @State private var noRoots = false
    @State private var loadError: String?
    @State private var selectedRoot: DeskRoot?
    /// root からの相対 path(空 = root 自身)。
    @State private var relativePath = ""
    @State private var entries: [PathSuggestion] = []
    @State private var truncated = false
    @State private var notice: String?
    @State private var starting = false

    private static let pathLimit = 80

    var body: some View {
        NavigationStack {
            List {
                if let selectedRoot {
                    locationSection(root: selectedRoot)
                    entriesSection(root: selectedRoot)
                } else {
                    rootsSection
                }
                if let notice {
                    Section {
                        Text(notice)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("roots.notice")
                    }
                }
            }
            .accessibilityIdentifier("roots.sheet")
            .navigationTitle(selectedRoot == nil ? "New session" : "Pick a folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }.accessibilityIdentifier("roots.close")
                }
                if let selectedRoot {
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            Task { await start(root: selectedRoot) }
                        } label: {
                            if starting { ProgressView() } else { Text("Start here") }
                        }
                        .disabled(starting)
                        .accessibilityIdentifier("roots.start")
                    }
                }
            }
            .task { await loadRoots() }
        }
    }

    // MARK: - 面

    @ViewBuilder private var rootsSection: some View {
        if noRoots {
            Section {
                Text("No directories are allowed on the desk yet.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("roots.empty")
            } footer: {
                Text("Add lines to ~/.rc-backend/roots on the desk to allow places.")
            }
        } else if let loadError {
            Section { Text(loadError).foregroundStyle(.secondary).accessibilityIdentifier("roots.error") }
        } else {
            Section("Allowed roots") {
                ForEach(roots) { root in
                    Button {
                        Task { await enter(root: root, path: "") }
                    } label: {
                        Label(root.label, systemImage: "folder")
                    }
                    .accessibilityIdentifier("roots.root.\(root.index)")
                }
            }
        }
    }

    private func locationSection(root: DeskRoot) -> some View {
        Section {
            Text(here(root: root))
                .font(.subheadline.monospaced())
                .accessibilityIdentifier("roots.here")
            Button {
                Task { await up(root: root) }
            } label: {
                Label(relativePath.isEmpty ? "All roots" : "Up one level", systemImage: "arrow.up.left")
            }
            .accessibilityIdentifier("roots.up")
        } header: {
            Text("Here")
        }
    }

    @ViewBuilder private func entriesSection(root: DeskRoot) -> some View {
        Section {
            if entries.isEmpty {
                Text("No folders inside. Start here, or go up.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("roots.noEntries")
            }
            ForEach(entries, id: \.path) { entry in
                Button {
                    Task { await enter(root: root, path: entry.path) }
                } label: {
                    Label(lastSegment(entry.path), systemImage: "folder")
                }
                .accessibilityIdentifier("roots.entry.\(entry.path)")
            }
            if truncated {
                Text("…").foregroundStyle(.secondary).accessibilityIdentifier("roots.truncated")
            }
        } header: {
            Text("Folders")
        }
    }

    private func here(root: DeskRoot) -> String {
        relativePath.isEmpty ? root.label : "\(root.label)/\(relativePath)"
    }

    private func lastSegment(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    // MARK: - 動き

    private func loadRoots() async {
        switch await browser.list(baseURL: baseURL, apiKey: apiKey) {
        case .success(let body):
            roots = body.roots
            noRoots = body.hasNoRoots || body.roots.isEmpty
            loadError = nil
        case .failure(.unauthorized):
            loadError = NewSessionOutcome.unauthorized.text
        case .failure:
            loadError = NewSessionOutcome.unreachable.text
        }
    }

    /// dir を押す = **降りるだけ**。何も始めない。
    private func enter(root: DeskRoot, path: String) async {
        selectedRoot = root
        relativePath = path
        notice = nil
        await loadEntries(root: root)
    }

    private func up(root: DeskRoot) async {
        if relativePath.isEmpty {
            selectedRoot = nil
            entries = []
            return
        }
        var parts = relativePath.split(separator: "/").map(String.init)
        parts.removeLast()
        relativePath = parts.joined(separator: "/")
        await loadEntries(root: root)
    }

    /// 机は問いに前方一致する相対 path を幅優先で返す(深い物も混じる)。此処では**直下だけ**を並べる ——
    /// 降りる操作は 1 段ずつ、が此の面の約束。
    private func loadEntries(root: DeskRoot) async {
        let prefix = relativePath.isEmpty ? "" : relativePath + "/"
        switch await browser.paths(baseURL: baseURL, apiKey: apiKey, rootIndex: root.index, query: prefix, limit: Self.pathLimit) {
        case .success(let body):
            entries = body.paths.filter { p in
                p.kind == .dir && p.path.hasPrefix(prefix) && !p.path.dropFirst(prefix.count).contains("/")
            }
            truncated = body.truncated
        case .failure(.unauthorized):
            entries = []; truncated = false
            notice = NewSessionOutcome.unauthorized.text
        case .failure(.contractViolation(let v)) where v.status == 404:
            // root が消えた(台帳が書き換わった)。一覧へ戻す。
            selectedRoot = nil; entries = []; truncated = false
            notice = StartInRootOutcome.rootGone.text
            await loadRoots()
        case .failure:
            entries = []; truncated = false
            notice = NewSessionOutcome.unreachable.text
        }
    }

    private func start(root: DeskRoot) async {
        starting = true
        defer { starting = false }
        let outcome = await browser.start(baseURL: baseURL, apiKey: apiKey, rootIndex: root.index, path: relativePath)
        notice = outcome.text
        if outcome == .started {
            await onStarted()
        }
    }
}
