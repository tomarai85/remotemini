import SwiftUI

/// 保管した会話の一覧(§9-1 の行き先、2026-08-16)。
///
/// ★「外す」が削除に見えない為の面。行は読むだけ + 「一覧へ戻す」だけを置く —
///   会話を開く導線は付けない(保管は「今の仕事から外した」の意思表示で、
///   此処から会話に入れると一覧を2枚持つ事になる。戻してから開くのが1本道)。
struct ArchivedListView: View {
    let baseURL: URL
    let apiKey: String
    /// 口は注入(既定値を持たせない — fixture の面に本物の口を残さない、いつもの規約)。
    let lister: ArchivedListing
    let archiver: SessionArchiving

    @State private var rows: [SessionRow] = []
    @State private var phase: Phase = .loading
    @State private var notice: String?

    enum Phase: Equatable { case loading, loaded, failed }

    var body: some View {
        List {
            if phase == .loading {
                HStack { ProgressView().controlSize(.small); Text("Loading").foregroundStyle(.secondary) }
            } else if phase == .failed {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Couldn't load").foregroundStyle(.orange)
                    Button("Reload") { Task { await load() } }
                }
            } else if rows.isEmpty {
                Text("No archived sessions")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("archived.empty")
            } else {
                ForEach(rows, id: \.id) { row in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.displayTitle).font(.body)
                            Text(row.display.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button("Restore") { Task { await restore(row) } }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("archived.restore.\(row.id)")
                    }
                }
            }
        }
        .navigationTitle("Archived")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("archived.root")
        .task { await load() }
        .alert("Archive", isPresented: Binding(
            get: { notice != nil }, set: { if !$0 { notice = nil } }
        )) {
            Button("Close", role: .cancel) {}
        } message: { Text(notice ?? "") }
    }

    private func load() async {
        phase = .loading
        switch await lister.fetchArchived(baseURL: baseURL, apiKey: apiKey) {
        case .success(let response):
            rows = response.sessions
            phase = .loaded
        case .failure:
            phase = .failed
        }
    }

    private func restore(_ row: SessionRow) async {
        switch await archiver.setArchived(baseURL: baseURL, apiKey: apiKey, sessionID: row.id, archived: false) {
        case .done:
            await load()   // 消えた事を描画で確かめる(手元の配列を弄って済ませない)
        case .unreachable:
            notice = "Couldn't reach the desk. Try again."
        case .unauthorized:
            notice = "The key was rejected. Go back to the list and retry."
        }
    }
}

/// 保管済みだけを読む口。`SessionsListing`(既定の一覧)と分けるのは、
/// 既定の実装が scope を黙って無視する形を作らない為(注入し忘れが型で落ちる)。
protocol ArchivedListing {
    func fetchArchived(baseURL: URL, apiKey: String) async -> Result<SessionsResponse, SessionsFetchError>
}

extension SessionsClient: ArchivedListing {
    func fetchArchived(baseURL: URL, apiKey: String) async -> Result<SessionsResponse, SessionsFetchError> {
        await fetch(baseURL: baseURL, apiKey: apiKey, scope: "archived")
    }
}
