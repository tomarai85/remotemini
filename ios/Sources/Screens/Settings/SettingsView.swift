import SwiftUI

/// 設定画面(REQUIREMENTS §9-3 / §9-4)。
///
/// ★**なぜ2枚目の画面なのか**(Tom 2026-08-13、§9-4):
///   「Mikan の時みたく全て1つの画面で収めようとしなくてもいい。複数の画面やらなんやらを
///   作った方がいい」。一覧の画面は既に、行 / 鮮度 / 走査行 / 版 / 口座 を1枚で背負って
///   いた。口座の候補を4本並べる余地はもう無く、無理に置けば版の名乗りが押し出される
///   (監査 X2-7 が一度直した向きの欠け方)。**足す前に部屋を分ける**のが正しい。
///
/// ★この画面が持つのは「今どうなっているか」と「どこへ切り替えるか」だけ。
///   会話の操作は一切置かない —— 設定画面が何でも屋になると、また同じ所へ戻る。
struct SettingsView: View {
    @ObservedObject var accountViewModel: AccountViewModel
    /// 表示専用。机の在り処を人が確かめられる様にする為だけに持つ(鍵は**出さない**)。
    let baseURL: URL
    /// 計器(走査行・鮮度)の出所。nil = 一覧以外から開いた設定(節ごと出さない)。
    /// ★2026-08-16(spec-audit A4 / §9-4「計器は別画面」): 一覧の面に常時出ていた
    ///   走査行・鮮度・版の3行は此処へ移った。一覧に残るのは**古い時だけ**出る鮮度の警告1本。
    var listViewModel: ListViewModel? = nil
    /// 保管の面の束(§9-1)。nil = 出さない(fixture の面に本物の口を残さない規約の徹底)。
    var archiveDeps: ArchiveDeps? = nil

    struct ArchiveDeps {
        let apiKey: String
        let lister: ArchivedListing
        let archiver: SessionArchiving
    }

    var body: some View {
        List {
            accountSection
            archiveSection
            connectionSection
            if let list = listViewModel {
                instrumentsSection(list)
            }
        }
        .navigationTitle("設定")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("settings.root")
        // 一覧の画面から押して来た直後でも、背面から戻った直後でも読み直す。
        // 口座は**他所からも変わる**(机で `fleet-account` を直に叩く等)ので、
        // この画面が開いている間に古い名前を名乗り続けるのは電話が嘘をつく形。
        .task { await accountViewModel.load() }
    }

    // MARK: - 口座

    @ViewBuilder
    private var accountSection: some View {
        Section {
            switch accountViewModel.phase {
            case .idle, .loading:
                HStack {
                    ProgressView().controlSize(.small)
                    Text("読み込み中").foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("settings.account.loading")

            case .failed(let reason):
                VStack(alignment: .leading, spacing: 6) {
                    Text(reason)
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("settings.account.failed")
                    Button("もう一度読む") {
                        Task { await accountViewModel.load() }
                    }
                    .accessibilityIdentifier("settings.account.retry")
                }

            case .loaded(let state):
                loadedAccount(state)
            }
        } header: {
            Text("アカウント")
        } footer: {
            // ★理由は**机が書いた文**をそのまま出す。電話が言い換えを持つと、机の門が
            //   増えた日に画面の断り方だけが古いまま残る(`src/account.mjs` が正本)。
            if let failure = accountViewModel.lastFailure {
                Text(failure)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("settings.account.lastFailure")
            }
        }
    }

    @ViewBuilder
    private func loadedAccount(_ state: AccountState) -> some View {
        // 一覧が読めていない時。**候補を空で出さない** —— 空の一覧は「候補が1つも無い」
        // と読めるが、実際は「読めなかった」。机が日本語の理由を寄越すので、それを出す。
        if !state.ok {
            VStack(alignment: .leading, spacing: 6) {
                Text(state.statusMessage ?? "アカウント一覧が読めていません。")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("settings.account.unreadable")
                if let raw = state.raw, !raw.isEmpty {
                    Text(raw)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("settings.account.raw")
                    // ★切れている事を**必ず言う**。生出力は末尾に失敗行が来るので、
                    //   黙って先頭 2000 字を出すと「失敗行が無い = 台本は最後まで
                    //   走った」と読める。診断の材料としては其れが一番害の大きい嘘。
                    if state.rawTruncated {
                        Text("（出力が長い為、先頭のみ表示しています。続きは edith 側の log にあります）")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("settings.account.rawTruncated")
                    }
                }
            }
        }

        // 現用は一覧の有無に関わらず出す(一覧が読めなくても現用は読めている事が在る)。
        HStack {
            Text("現用")
            Spacer()
            Text(state.current ?? "（未設定）")
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("settings.account.current")
        }

        ForEach(state.accounts) { row in
            accountRow(row)
        }

        ForEach(Array(state.anomalyMessages.enumerated()), id: \.offset) { _, message in
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("settings.account.anomaly")
        }

        // 矢印は**退避路として残す**(§5-8)。一覧が読めない時、名指しは出せないが
        // 「次へ送る」は台本の側だけで完結するので押せる —— 唯一残る手を消さない。
        Button {
            Task { await accountViewModel.advance() }
        } label: {
            HStack {
                if accountViewModel.advancing { ProgressView().controlSize(.small) }
                Text("次のアカウントへ")
            }
        }
        .disabled(accountViewModel.isBusy)
        .accessibilityIdentifier("settings.account.next")
    }

    @ViewBuilder
    private func accountRow(_ row: AccountRow) -> some View {
        Button {
            Task { await accountViewModel.select(row.name) }
        } label: {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.name)
                        .font(.callout.monospaced())
                        .foregroundStyle(row.selectable ? .primary : .secondary)
                    // ★選べない行を**消さない**。消すと「そんな口座は無い」に見えて、
                    //   本当の理由(トークンが欠けている等)が画面から消える。
                    //   出して、押せなくして、理由を置く(DESIGN §2.88 と同じ判断)。
                    if let blocked = row.blocked {
                        Text(blocked)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if accountViewModel.switchingTo == row.name {
                    ProgressView().controlSize(.small)
                } else if row.active {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
        }
        .disabled(!row.selectable || accountViewModel.isBusy)
        // ★識別子は **Button 自身**に載せる。`children: .contain` を挟んではいけない
        //   (2026-08-15、走行の木を実際に出して判った)。挟んだ版の木はこうだった:
        //
        //     Other,  identifier: 'settings.account.row.sdgs'      <- 容器。押せない
        //       Button, identifier: 'settings.account.blocked', Disabled
        //         StaticText 'sdgs' / StaticText '…トークンが…'
        //
        //   容器は Button ではないので **Disabled の印を持たない** = 検査から見た
        //   `isEnabled` が真のまま。「押せない行が押せる」と読める状態を、画面は
        //   正しく描いているのに検査が測れない形で作っていた。
        //   更に悪いのは2行目 —— Button は label を子から畳む時に**子の識別子まで
        //   吸い上げる**ので、行の Button が `settings.account.blocked` を名乗り、
        //   現用の行は `settings.account.active` を名乗っていた。子に識別子を置くと
        //   行の身元がその子に乗っ取られる。
        //
        //   なので子の識別子は**置かない**。理由の文も現用の印も、Button の label に
        //   畳まれて出る(実測: label = 'sdgs, そのアカウントのトークンが edith に
        //   ありません。' / 現用の行は Selected の印が付く)。読む側は畳まれた文字列を
        //   読む —— 此の repo が繰り返し踏んだ「層の下は緑なのに画面に出ていない」は、
        //   **描かれた文字列**を測る事でしか塞げない。
        .accessibilityIdentifier("settings.account.row.\(row.name)")
    }

    // MARK: - 接続

    private var connectionSection: some View {
        Section("接続") {
            HStack {
                Text("机")
                Spacer()
                // ★鍵は出さない。出す物は「どこに繋いでいるか」まで。
                //   host だけにしないのは、port が既定でない事が此の系では常態だから。
                Text(Self.endpointLine(baseURL))
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("settings.endpoint")
            }
            HStack {
                Text("版")
                Spacer()
                Text(BuildInfo.line)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings.buildInfo")
            }
        }
    }

    // MARK: - 保管(§9-1 の行き先)

    /// 「一覧から外す」で消えた行の行き先。此処が無いと、外す操作が削除に見える —
    /// §9-1 の合格条件は「外れた事が画面で判る(edith 側の file は残る)」。
    @ViewBuilder
    private var archiveSection: some View {
        if let deps = archiveDeps {
            Section {
                NavigationLink {
                    ArchivedListView(baseURL: baseURL, apiKey: deps.apiKey,
                                     lister: deps.lister, archiver: deps.archiver)
                } label: {
                    Label("保管した会話", systemImage: "archivebox")
                }
                .accessibilityIdentifier("settings.archived")
            } footer: {
                Text("一覧から外した会話です。記録は机(edith)に残っていて、いつでも戻せます。")
            }
        }
    }

    // MARK: - 計器(一覧から移って来た走査行と鮮度。§9-4「計器は別画面」)

    @ViewBuilder
    private func instrumentsSection(_ list: ListViewModel) -> some View {
        Section {
            if let scan = list.phase.scanLine {
                VStack(alignment: .leading, spacing: 2) {
                    Text("走査")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    // brief §3-b の契約は据え置き: サーバの文を逐語で描く(再組成しない)
                    Text(scan)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("settings.scanLine")
                }
            }
            if list.lastFetchedAtMs > 0 {
                let f = Freshness.freshness(list.lastFetchedAtMs, nowMs: Date().timeIntervalSince1970 * 1000)
                HStack {
                    Text("鮮度")
                    Spacer()
                    Text(f.text)
                        .font(.callout)
                        .foregroundStyle(f.stale ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .accessibilityIdentifier("settings.freshness")
                }
            }
        } header: {
            Text("計器")
        } footer: {
            Text("壊れた日に読む欄です。ふだんは気にしなくて構いません。")
        }
    }

    /// `https://host:8787/` → `host:8787`。view body から出した純関数なのは
    /// `BuildInfo.displayRev` と同じ理由 —— 画面の規則なのに検査から触れなくなる。
    ///
    /// ★`baseURL` に鍵が載る形は無い(`Credentials` が別に持つ)が、`user:pass@` を
    ///   含む URL を人が打ち込む事は在り得るので、**host と port しか読まない**。
    static func endpointLine(_ url: URL) -> String {
        guard let host = url.host, !host.isEmpty else { return url.absoluteString }
        guard let port = url.port else { return host }
        return "\(host):\(port)"
    }
}
