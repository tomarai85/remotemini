import Foundation

/// 「此の版は後で」を憶える。
///
/// ★なぜ要るか(2026-08-30、Codex 査読2巡目): 消せない帯は壁紙になる。
///   「入れれば消える」は反論にならない —— 問題は**入れるまでの長い期間**で、
///   CF-17 の実測ではそれが 9 ビルド分続いた。
///
/// ★憶えるのは**版番号**であって「消した」という事実ではない。事実だけを憶えると、
///   次の版が出ても黙ったままになる —— 壁紙を消す為の仕掛けが、警報そのものを消す。
///   番号で憶えれば、105 を黙らせても 106 は再び出る。**黙るのは最大1版**。
///
/// ★置き場は `UserDefaults`。金庫(Keychain)は資格情報の座標で、此処は
///   「見た事が在る」程度の話。消えても最悪もう一度出るだけで、害は無い側に倒れる。
protocol UpdateSnoozeStoring {
    func snoozedBuild() -> String?
    func snooze(build: String)
}

struct UserDefaultsUpdateSnooze: UpdateSnoozeStoring {
    /// ★座標を製品と検査で分ける。同じ鍵だと、検査を1回回すだけで
    ///   実機の「後で」が書き換わる(`KeychainCredentialStoreTests` が 2026-08-15 に
    ///   同じ形で資格情報を消した)。
    static let key = "rc.updateNotice.snoozedBuild"

    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func snoozedBuild() -> String? { defaults.string(forKey: Self.key) }
    func snooze(build: String) { defaults.set(build, forKey: Self.key) }
}

/// 検査用。プロセス内にだけ憶える。
final class InMemoryUpdateSnooze: UpdateSnoozeStoring {
    private var value: String?
    init(_ initial: String? = nil) { value = initial }
    func snoozedBuild() -> String? { value }
    func snooze(build: String) { value = build }
}

/// 帯を出すかどうかの**純関数**。時計も disk も持たないので、UI を起こさずに検べられる
/// (`ConversationView.limitedNotice` / `SettingsView.statusLine` と同じ置き方)。
enum UpdateNoticeRule {
    /// - Parameters:
    ///   - notice: 机が決めた文面(`nil` = 机が何も言っていない)
    ///   - build: 帯が指す配布側の番号(`nil` = 番号が判らない)
    ///   - snoozed: 「後で」と言われた番号
    /// - Returns: 出す文面。出さないなら `nil`。
    static func visibleNotice(notice: String?, build: String?, snoozed: String?) -> String? {
        guard let notice, !notice.isEmpty else { return nil }
        // ★番号が判らない時は**黙らせられない**。鍵が無い物を「後で」に入れると、
        //   何を黙らせたのか誰も判らなくなる。文面が在るなら出す。
        guard let build, let snoozed else { return notice }
        // ★数として比べる。文字列比較だと "99" > "105" になり、**新しい版が黙る**。
        guard let b = Int(build), let s = Int(snoozed) else { return notice }
        return s >= b ? nil : notice
    }
}
