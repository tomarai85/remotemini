import Foundation

/// 401 で鍵を落とした時、**次に開く鍵入力画面へ「なぜ此処に居るか」を渡す**器。
///
/// ★これが在る理由(監査 X2-6、2026-08-08、DESIGN §2.65)。一覧でも会話でも 401 は
/// `RootView` の `onUnauthorized` に集まり、`AppState.clearCredentials()` が Keychain と
/// memory を両方消して鍵入力画面へ戻す。戻った先の画面には**理由が1文字も出ず、URL 欄も
/// 空**だった。机の前なら「ああ鍵を入れ替えたな」で済む。この欠陥が効くのは机が遠い時だけ
/// —— つまり**渡米して初めて鳴る**種類で、鳴った時に一番情報が要る。
///
/// ★なぜ memory の持ち回しでは足りないか。iOS は背面のアプリを日常的に殺す。
/// 「断りを読む → 鍵を探しに別のアプリへ行く → 戻る」の途中で殺されると、理由も URL も
/// 消える。**最も助けが要る筋道でだけ助けが消える**形になるので、ディスクに落とす。
///
/// ★入って良い物と、入れられない物。ここに入るのは**理由**と**URL**だけで、鍵は入らない。
/// 鍵の唯一の永続先は Keychain(`KeychainCredentialStore`)で、この型は `apiKey` を
/// 受け取る口すら持たない —— 「入れない約束」ではなく**入れられない形**にしてある。
/// 約束の側で守ると、後から field を1つ足した人が破れる。
struct SignOutNotice: Equatable, Codable {
    /// なぜ鍵入力画面に戻ったか。**文言ではなく意味**を持つ。文を決めるのは画面
    /// (`KeyEntryView.noticeText`)で、此処は「何が起きたか」だけを運ぶ。
    enum Reason: String, Codable {
        /// 一度は通った鍵が、サーバに 401 で拒まれた。
        ///
        /// ★鍵入力画面で最初から弾かれる 401(`KeyEntryViewModel` の「鍵が違います」)とは
        /// **別物**。あちらは「その鍵は通らない」、こちらは「**通っていた鍵が通らなくなった**」。
        /// 同じ 401 でも次の一手が違うので、同じ文にしてはいけない。
        case keyRejected = "key-rejected"
    }

    var reason: Reason

    /// 拒まれた時に使っていた URL。**URL は間違っていない** —— 届いた上で 401 が返った
    /// のだから、届く事自体は観測済み。だから次の画面に置き直す。電話で tailnet の URL を
    /// 打ち直すのは苦行で、しかも打ち間違えると症状が「鍵が違う」から「届かない」へ化けて、
    /// Tom は**自分が作った方の故障**を追う事になる。
    var baseURL: URL?
}

/// 断りの置き場。`nil` の保存が「消す」。
protocol SignOutNoticeStoring: AnyObject {
    func load() -> SignOutNotice?

    /// ★消すのは**接続が成功した時**であって、画面を見た時ではない。見ただけで消すと、
    /// 読んだ直後に OS に殺されて戻った電話がまた白紙になる —— この型が存在する理由
    /// そのものを取り落とす。
    func save(_ notice: SignOutNotice?)
}

/// 覚えない実装。検査の既定値であり、**本番では使わない**。
///
/// 既定をこちら側に置く理由は `InMemoryDraftStore` と同じ: 既定を本物にすると、検査が
/// 黙って開発機の `UserDefaults` を触り、検査どうしが互いの断りを見る。
final class InMemorySignOutNoticeStore: SignOutNoticeStoring {
    private var notice: SignOutNotice?

    init(notice: SignOutNotice? = nil) {
        self.notice = notice
    }

    func load() -> SignOutNotice? { notice }

    func save(_ notice: SignOutNotice?) { self.notice = notice }
}

/// `UserDefaults` に JSON で1本だけ持つ実装。
///
/// 古さで捨てる規則は**置かない**(`UserDefaultsDraftStore` とはここが違う)。断りは
/// 「鍵を入れ直すまで真であり続ける事実」で、日数で偽になる物ではない。逆に時計に依存
/// させると、時計が進む方に狂った電話で**理由だけが消えて白紙に戻る** = 直した欠陥が
/// そのまま復活する。消す条件は接続の成功ただ一つ。
final class UserDefaultsSignOutNoticeStore: SignOutNoticeStoring {
    static let storageKey = "keyentry.signout-notice.v1"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> SignOutNotice? {
        guard let data = defaults.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode(SignOutNotice.self, from: data)
        else { return nil }
        return decoded
    }

    func save(_ notice: SignOutNotice?) {
        guard let notice else {
            defaults.removeObject(forKey: Self.storageKey)
            return
        }
        // 書けない時は黙って忘れる。断りを覚えられない事は画面の機能を一つも壊さない
        // (白紙に戻るだけで、直す前と同じ)ので、此処で throw して起動を止める価値が無い。
        guard let data = try? JSONEncoder().encode(notice) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
