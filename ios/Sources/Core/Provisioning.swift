import CryptoKit
import Foundation

/// 焼く時に**機械から**渡された既定の接続先。初回起動で人に打たせない為の供給経路
/// (2026-08-11)。
///
/// ★何を直しに来たか。此処が空だった間、`AppState` に資格情報を**書く**経路は
/// `KeyEntryView` の `onSaved` ただ一つで、新規インストール直後の Keychain は空だから、
/// 初回起動は必ず「Base URL と API Key を打て」という欄から始まっていた。
/// `REQUIREMENTS.md` の合格条件は「開くとセッション一覧が出る」で、人が打つとは
/// どこにも書いていない。**規則(機械名を追跡ファイルに残さない)は守られ、製品が
/// 設計から外れていた** —— 禁止だけを置いて、塞いだ供給経路を引き直さなかった為。
///
/// ★値は此の repo の何処にも書かない。`ios/tools/build.sh` が焼く時に
///   鍵 = 机側の `~/.rc-backend/api.key`(`ios/tools/live-send-check.sh` と
///        `rc-backend/tools/verify-phone-window.sh` が既に読んでいる**同じ正本**)
///   URL = 机自身が名乗る tailnet の名前(`tailscale status --json` の `Self.DNSName`)
/// を取り、`xcodegen generate` の**後**に `Info.plist` へ刻む。刻むのは plistlib で、
/// 鍵は**標準入力**から渡す —— `PlistBuddy` は値を argv で受けるので `ps` に出る。使えない。
/// `ios/Info.plist` は生成物で `ios/.gitignore` 済 = 追跡ファイルには一文字も増えない。
/// 写しを2つ目に作らない(新しい設定ファイルを置かない)のは、この木の他の場所と同じ約束。
///
/// ★代償を隠さない: 鍵が **app の束の中**に平文で入る。Keychain だけの時より露出は
/// 悪い。取るのは、届く先が tailnet の内側にしか無く、回転が「机で鍵を差し替えて
/// 焼き直す」1手で済むから。打たせる形に戻すのは刻印を外すだけ = 可逆。
enum Provisioning {
    /// `ios/tools/build.sh` が刻む鍵の名前。`BuildInfo.revKey` と同じ流儀で、
    /// OS が意味を持つ枠(`CFBundle*`)には相乗りさせない。
    static let baseURLKey = "RCBaseURL"
    static let apiKeyKey = "RCAPIKey"

    /// 焼いた物が持っている既定値。持っていなければ `nil`(= 打つ画面へ落ちる)。
    static var bundled: Credentials? {
        seed(baseURL: Bundle.main.object(forInfoDictionaryKey: baseURLKey) as? String,
             apiKey: Bundle.main.object(forInfoDictionaryKey: apiKeyKey) as? String)
    }

    /// Info.plist の生値2つ → 資格情報。view body から出した純関数と同じ理由で
    /// `Bundle` から切り離してある(此処が検査から触れないと、刻印の欠けを
    /// **焼いて電話に入れた後**にしか見付けられない)。
    ///
    /// ★落とす3つは全部「もっともらしい値」で届く形:
    ///   - `${RC_BASE_URL}` … xcodegen は未定義の変数を**そのまま文字列として書く**
    ///     (`BuildInfo.displayRev` の doc に実測が在る)。此処で潰さないと、
    ///     電話が `${...}` という宛先へ繋ぎに行って「サーバに届かない」と名乗る。
    ///   - 空文字 … 刻印の途中で失敗した形。空の鍵で 401 を貰うと、
    ///     「鍵が拒まれた」と「鍵が入っていない」が画面上で区別できなくなる。
    ///   - `https` でない URL … 机側は `tailscale serve` の 443 でしか受けていない。
    ///     平文の宛先を既定にすると、`ITSAppUsesNonExemptEncryption` の判断と
    ///     ATS の例外を置いていない前提の両方が黙って崩れる。
    /// **半端に埋まった種を蒔かない** = 埋まっていないなら打つ画面へ落ちるのが正しい。
    static func seed(baseURL rawURL: String?, apiKey rawKey: String?) -> Credentials? {
        guard let url = clean(rawURL), let key = clean(rawKey) else { return nil }
        guard let parsed = URL(string: url), parsed.scheme == "https", parsed.host != nil else { return nil }
        return Credentials(baseURL: parsed, apiKey: key)
    }

    private static func clean(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if trimmed.contains("${") { return nil }
        return trimmed
    }
}

/// `AppState` が種を貰う口。**protocol にしてあるのは検査の為ではなく、
/// UI 検査が本物の刻印を握らない為**(`NoStoredCredentials` と同じ理由)。
/// 焼いた機械に本物の鍵が刻まれている日に fixture が `Bundle` を読むと、
/// 鍵入力画面を撮りに来た検査が**機械の状態次第で一覧を撮る**事になる。
protocol ProvisioningSource {
    var seed: Credentials? { get }
}

/// 本番の口。焼いた束から読む。
struct BundleProvisioning: ProvisioningSource {
    var seed: Credentials? { Provisioning.bundled }
}

/// 種を一つも持たない口。刻印の無い焼き方(simulator / 対照)と同じ姿。
struct NoProvisioning: ProvisioningSource {
    var seed: Credentials? { nil }
}

// MARK: - 蒔いた記録

/// **同じ種を二度蒔かない**為の記録。持つのは種の指紋1本だけ。
///
/// ★何故この器が要るか(2026-08-11、Codex の指摘で設計を差し替えた)。
/// 最初は「断り(`SignOutNotice`)が残っていない時だけ蒔く」にしていた。断りは 401 で
/// 書かれるから、拒まれた鍵を蒔き直す輪は塞げる —— **その一つの筋道だけは**。
/// 断りは画面に出す為の物で、認証の状態ではない。両者を結ぶと次が全部壊れる:
///   - 断りを読んだ後(接続成功で消える設計)に、拒まれた同じ鍵がまた蒔かれる
///   - **鍵を回して焼き直した新しい種**まで、古い断りが止める ← 渡米中の唯一の復旧路
///   - アプリを入れ直すと断りだけ消えるので、状態の意味が入れ直しで変わる
/// 記録するのは「何を蒔いたか」であって「何を表示したか」ではない。
///
/// ★指紋にする理由は、比べたいのが**同一性**だから。「一度蒔いた」という旗1本だと、
/// 机で鍵を回して焼き直した電話が二度と種を受け取れない —— 渡米先で鍵を回したら
/// 打ち込む以外に道が無くなる。指紋なら、値が変われば別の種として蒔ける。
///
/// ★入れ直しで消えるのは正しい。入れ直し = 新規インストールで、そこは最初の1回と
/// 同じ扱いでよい(同じ拒否鍵が刻まれていれば、また 401 と断りが出るだけ。錠は掛からない)。
protocol SeedLedgerStoring: AnyObject {
    /// 最後に蒔いた種の指紋。まだ一度も蒔いていなければ `nil`。
    var plantedSeedDigest: String? { get set }
}

enum SeedDigest {
    /// 種の指紋。**鍵そのものは書かない**。
    ///
    /// ★16桁に切るのは、要るのが同一性の判定だけで、それ以上の桁が
    /// `UserDefaults`(= 束の中の平文 plist)に残る意味が無いから。切っても
    /// 「同じ種か」は判る。なお同じ束には**鍵の平文自体**が刻まれているので、
    /// この指紋が新しく増やす露出は無い(増やしているのは刻印の方で、
    /// それは `Provisioning` の doc で明示的に払った代償)。
    static func of(_ credentials: Credentials) -> String {
        let material = Data("\(credentials.baseURL.absoluteString)\n\(credentials.apiKey)".utf8)
        return SHA256.hash(data: material).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

/// 覚えない実装。検査の既定値。`InMemorySignOutNoticeStore` と同じ理由で、
/// 既定を本物にすると検査が開発機の `UserDefaults` を触り合う。
final class InMemorySeedLedger: SeedLedgerStoring {
    var plantedSeedDigest: String?

    init(plantedSeedDigest: String? = nil) {
        self.plantedSeedDigest = plantedSeedDigest
    }
}

/// `UserDefaults` に1本だけ持つ実装。`UserDefaultsSignOutNoticeStore` と同じ置き場・
/// 同じ流儀(古さで捨てる規則は置かない —— 「何を蒔いたか」は時間で偽にならない)。
final class UserDefaultsSeedLedger: SeedLedgerStoring {
    static let storageKey = "provisioning.planted-seed.v1"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var plantedSeedDigest: String? {
        get { defaults.string(forKey: Self.storageKey) }
        set {
            guard let newValue else {
                defaults.removeObject(forKey: Self.storageKey)
                return
            }
            defaults.set(newValue, forKey: Self.storageKey)
        }
    }
}
