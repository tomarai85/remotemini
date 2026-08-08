import Foundation

/// 打ちかけの本文を、**セッションごとに**画面より長く生かしておく口。
///
/// ★この型が在る理由は「アプリを落としても残る」ではない。`draft` は
/// `ConversationViewModel` の平のプロパティで、その ViewModel は
/// `ListView.makeConversationViewModel(for:)` が `NavigationLink` の行き先クロージャの
/// 中で **開くたびに新しく作る** —— つまり会話から一覧へ戻って開き直すだけで、OS も網も
/// 机も関係なく打ちかけが消える。打ちかけの寿命が「画面」に縛られていて
/// 「セッション」に縛られていない事が本体で、ディスクはその一番外側にすぎない。
///
/// 資格情報はここに置かない(鍵は Keychain のみ)。ここに入るのは Tom が打った本文
/// だけで、それでも**打った物がディスクに残る**のは新しい種類の残留物なので、
/// 実装側には古さで捨てる規則を必ず持たせる(`UserDefaultsDraftStore`)。
protocol DraftStoring: AnyObject {
    /// 復元できる打ちかけ。無い / 古すぎる時は `nil`。
    ///
    /// **読む側が捨てる**契約にしてある。書く時に古い物を掃くと、しばらく使わなかった
    /// アプリでは掃除が一度も走らない。
    func load(sessionID: String) -> String?

    /// 打ちかけを覚える。空文字は「忘れる」。
    ///
    /// ★実装は「同じ本文なら何もしない」事。復元した本文がそのまま書き戻される経路が
    /// 有り(`draft` の `didSet`)、そこで時刻が若返ると**古さで捨てる規則が永久に
    /// 発火しなくなる** —— 開き直すだけで不死身になる。
    func save(_ text: String, sessionID: String)
}

/// 覚えない実装。検査の既定値であり、**本番では使わない**。
///
/// 既定値をこちら側にしてあるのは、既定を本物にすると検査が黙って実機の
/// `UserDefaults` を触るから(検査どうしが互いの打ちかけを見る)。本番の2箇所
/// (`RootView` / `ListView`)は本物を明示的に渡す。
final class InMemoryDraftStore: DraftStoring {
    private var drafts: [String: String] = [:]

    init() {}

    func load(sessionID: String) -> String? {
        drafts[sessionID]
    }

    func save(_ text: String, sessionID: String) {
        if text.isEmpty {
            drafts.removeValue(forKey: sessionID)
        } else {
            drafts[sessionID] = text
        }
    }
}

/// `UserDefaults` に JSON で1本だけ持つ実装。
///
/// 鍵はセッションごとに分けず、**全部を1つの辞書**にしてある。捨てる処理が
/// 「辞書を舐めて古い物を落とす」で完結し、掃き残しが構造的に発生しない為
/// (鍵を撒くと、消えたセッションの鍵を見付ける手段が別に要る)。
final class UserDefaultsDraftStore: DraftStoring {
    /// 覚えている中身。`updatedAt` は**本文が変わった時刻**であって、開いた時刻でも
    /// 書き込んだ時刻でもない(`save` が同じ本文を素通しする理由)。
    private struct StoredDraft: Codable, Equatable {
        var text: String
        var updatedAt: Date
    }

    private let defaults: UserDefaults
    private let now: () -> Date
    private let maxAge: TimeInterval

    /// 7日。移動1回より十分長く、渡米の1区間より短い。
    ///
    /// ★この設計の一番弱い所を先に書いておく: 判定は端末の時計に依存していて、外し方が
    /// 対称でない。時計が**戻る**方に狂うと打ちかけは生き残る(無害)。**進む**方に
    /// 7日以上狂うと、生きている打ちかけが消える —— 取り返しがつかない。
    /// 時差の移動は絶対時刻を動かさないので該当せず、網に繋がった iPhone で7日以上
    /// 進む事は実質起きないと踏んでいる。これが崩れたら(= Tom が「打ちかけが勝手に
    /// 消えた」と言ったら)、消すのを止めて「復元しないだけ」に倒し、上限件数で
    /// 積もりを抑える形へ変える。
    static let defaultMaxAge: TimeInterval = 7 * 24 * 60 * 60

    static let storageKey = "conversation.drafts.v1"

    init(
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        maxAge: TimeInterval = UserDefaultsDraftStore.defaultMaxAge
    ) {
        self.defaults = defaults
        self.now = now
        self.maxAge = maxAge
    }

    func load(sessionID: String) -> String? {
        var all = readAll()
        let cutoff = now().addingTimeInterval(-maxAge)

        // ★捨てるのは**古さだけ**。「セッション一覧に無いから消す」は採らない ——
        // 一覧に出るのは remote-mini を on にしたセッションだけ(D5)なので、机側で
        // 一時的に off にしただけで**生きている打ちかけが消える**。電話が部分的な
        // 視界から「もう無い」と断じる形は DESIGN §2.52 で潰したのと同じ型。
        let survivors = all.filter { $0.value.updatedAt >= cutoff }
        if survivors.count != all.count {
            all = survivors
            writeAll(all)
        }

        guard let stored = all[sessionID], !stored.text.isEmpty else { return nil }
        return stored.text
    }

    func save(_ text: String, sessionID: String) {
        var all = readAll()

        if text.isEmpty {
            guard all.removeValue(forKey: sessionID) != nil else { return }
            writeAll(all)
            return
        }

        // 同じ本文なら何もしない。ここを素通しにしないと、復元 → `didSet` → 書き戻し
        // で `updatedAt` が若返り、古さで捨てる規則が発火しなくなる。
        guard all[sessionID]?.text != text else { return }

        all[sessionID] = StoredDraft(text: text, updatedAt: now())
        writeAll(all)
    }

    /// 毎回読み直す。**覚えておかない**のが要点で、この型のインスタンスが2つ在る時
    /// (会話画面ごとに作れば実際そうなる)、各々が自分の写しを持つと後から書いた方が
    /// 相手のセッションの打ちかけを丸ごと消す —— 「共有インスタンスにする」という
    /// 呼ぶ側の約束に正しさを預ける形になるので採らない。打鍵ごとに小さな JSON を
    /// 1回読むだけで、`UserDefaults` の実書き込みは OS 側でまとめられる。
    private func readAll() -> [String: StoredDraft] {
        guard let data = defaults.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([String: StoredDraft].self, from: data)
        else { return [:] }
        return decoded
    }

    private func writeAll(_ all: [String: StoredDraft]) {
        // 壊れた/書けない時は黙って忘れる。打ちかけを覚えられない事は画面の機能を
        // 一つも壊さないので、ここで throw して起動を止める価値が無い。
        guard let data = try? JSONEncoder().encode(all) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
