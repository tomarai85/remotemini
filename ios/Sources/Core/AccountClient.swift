import Foundation

/// 一覧の1行。`fleet-account` の `.order` に載っている口座1つ。
///
/// ★**選べない行も来る**(消して来ない)。トークンが欠けている / 名前が引数として
/// 使えない、という行は `selectable == false` + `blocked` に日本語の理由を持って届く。
/// 行ごと消す設計にすると「そんな口座は無い」に見えて、本当の理由が画面から消える
/// (`rc-backend/src/wire.mjs` の `accountRow`、DESIGN §2.88 と同じ判断)。
struct AccountRow: Equatable, Identifiable {
    let name: String
    /// edith 側にトークンの実体が在るか。無ければ切り替えても Claude が動かない。
    let hasToken: Bool
    /// いま現用の印(`->`)が付いている行か。
    let active: Bool
    let selectable: Bool
    /// 選べない理由。選べる時は `nil`。
    ///
    /// ★文面を電話側で組み立てない。理由コード(`no-token` 等)から日本語を作る所を
    /// 両側に持つと、語彙が2箇所に分かれて必ず片方だけ腐る —— 2026-08-08 の監査 S8-22 が
    /// 実際に踏んだ形(電話が `reason` の英語トークンをそのまま帯に描いていた)。
    let blocked: String?

    /// 使用量(cswap の観測)。`nil` = **測れていない**(空いているでも尽きているでもない)。
    var usage: AccountUsage? = nil

    var id: String { name }
}

/// 口座1つの使用量(2026-08-29、Tom「CodexBar のような感じで残りの使用量が無い」)。
/// 机の `cswap list --json` が出す観測で、CodexBar のメニューと同じ真実。
///
/// ★pct は**使用率**。画面は 100 - pct を「left」として描く(数値の算術は語彙ではない)。
/// ★`weeklyResetsIn` は机側の道具が作った文字列("20h 50m")をそのまま描く —
///   期限の文言を電話で組み立て直すと語彙が2箇所に分かれる(`blocked` と同じ判断)。
struct AccountUsage: Equatable {
    let sessionUsedPct: Double?
    let weeklyUsedPct: Double?
    let weeklyResetsIn: String?
    /// この消費の速さのまま行くと、リセットまで持つか。
    let willLastToReset: Bool?
}

/// `fleet-account` が名乗る、机の側の口座の状態(REQUIREMENTS §9-3)。
///
/// ★2026-08-14 に**文字列1本から構造へ変えた**。以前は `let account: String` の1鍵で、
/// 中身は台本の人向け出力6行がそのまま入っていた —— 電話に出せるのは矢印1本
/// (「次のアカウントへ」)だけで、名指しで選ぶ材料が線に一度も乗っていなかった。
/// Tom の「CodexBar と違って矢印のフォームでしかない」は、その機械的な正体。
struct AccountState: Equatable {
    /// 現用の口座名。`fleet-account` の symlink が張られていなければ `nil`。
    ///
    /// ★`nil` と `""` を混ぜない。`nil` = 机が「現用は無い」と**答えた**、であって
    /// 「まだ訊いていない」ではない(後者は `AccountViewModel.Phase.idle`)。
    let current: String?
    let accounts: [AccountRow]
    /// 一覧を読み切れたか。`false` = **切替を出してはいけない**。
    ///
    /// ★`ok == false` と `accounts.isEmpty` は別物。混ぜると、edith 側の台本の出力形式が
    /// 変わった日に電話が「候補が1つも無い」というもっともらしい嘘を描く。
    let ok: Bool
    /// 読めなかった時の理由(日本語、机が作る)。読めた時は `nil`。
    let statusMessage: String?
    /// 読めてはいるが引っ掛かる点(日本語、机が作る)。無ければ空。
    let anomalyMessages: [String]
    /// `ok == false` の時だけ机が載せる、台本の生出力(先頭 2000 字)。
    /// 診断の材料であって、常用の表示ではない。
    let raw: String?
    /// `raw` が 2000 字で**切られている**か。切れているのに黙って出すと、末尾に
    /// 在る筈の失敗行が「そもそも出力されなかった」と読める —— 診断の材料としては
    /// 其れが一番害が大きい嘘なので、切った事実を画面へ持ち上げる為に読む。
    let rawTruncated: Bool
}

enum AccountError: Error, Equatable {
    case unreachable
    case cancelled
    case unauthorized
    /// The script itself failed on the backend (500 from any handler). The server
    /// puts the reason in `error`; it is carried so the phone can say *what* broke
    /// rather than "something went wrong".
    case backend(String)
    /// 机が**その名前を断った**(400)。500 と分けるのは副作用の有無が違うから ——
    /// 断りは台本を叩く**前**に返るので、口座は動いていない。500 は動いたかもしれない。
    /// 一緒くたにすると、断られただけの時にも「今どこに居るか」を測り直す羽目になる。
    case refused(String)
    case unexpectedStatus(Int)
    case malformedBody
}

protocol AccountReading {
    func current(baseURL: URL, apiKey: String) async -> Result<AccountState, AccountError>
}

protocol AccountAdvancing {
    func next(baseURL: URL, apiKey: String) async -> Result<AccountState, AccountError>
}

/// 名指しで切り替える口(REQUIREMENTS §9-3)。`AccountAdvancing` と**別の protocol**に
/// 分けてあるのは、`next` が退避路として残るから —— 一覧が読めない時(`ok == false`)は
/// 名指しが出せないので、其の場面で押せるのは矢印だけになる。
protocol AccountSelecting {
    func select(name: String, baseURL: URL, apiKey: String) async -> Result<AccountState, AccountError>
}

/// `GET /api/account` / `POST /api/account/select` / `POST /api/account/next`
/// -- REQUIREMENTS §4-5 / §5-8 / §9-3.
///
/// ★Why `next` is not retried anywhere in this file, and must not be: the server's own
/// comment on that handler records the reason -- `fleet-account --next` has a side
/// effect *before* it can time out, so a 500 does not mean "the account did not
/// advance". An automatic retry would step the account twice while reporting one
/// failure. The phone's answer to a failed switch is to re-read `current`, which this
/// client also provides, and let the person see where it actually landed.
///
/// ★Why the capabilities are separate protocols: reading is safe and can be done on
/// every appearance of the screen; the other two mutate fleet-wide state. A view model
/// that only needs to display the account should not be handed the ability to change
/// it. `AccountClient` conforms to all three; the seams are for the callers.
struct AccountClient: AccountReading, AccountAdvancing, AccountSelecting {
    /// `BackendSession`, not `URLSession` -- same constraint as every other client here.
    private let session: BackendSession

    init(session: BackendSession = .shared) {
        self.session = session
    }

    func current(baseURL: URL, apiKey: String) async -> Result<AccountState, AccountError> {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/account"))
        request.httpMethod = "GET"
        request.timeoutInterval = BackendSession.interactiveTimeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return await perform(request)
    }

    func select(name: String, baseURL: URL, apiKey: String) async -> Result<AccountState, AccountError> {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/account/select"))
        request.httpMethod = "POST"
        request.timeoutInterval = BackendSession.writeTimeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // ★名前は本文で送る(経路に載せない)。`/api/account/select/<name>` の形にすると、
        //   名前が机側の log の経路欄に残る(`LOG_PATHS`)。口座名は秘密ではないが、
        //   経路に値を埋める形は、次に「鍵も経路で」と書きたくなる形でもある。
        request.httpBody = try? JSONEncoder().encode(["name": name])
        guard request.httpBody != nil else { return .failure(.malformedBody) }
        return await perform(request)
    }

    func next(baseURL: URL, apiKey: String) async -> Result<AccountState, AccountError> {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/account/next"))
        request.httpMethod = "POST"
        // The write timeout, not the interactive one: the backend caps `fleet-account`
        // at 10s (`FLEET_ACCOUNT_TIMEOUT_MS`), so a phone-side deadline shorter than
        // that would abandon a call that is still going to change the account.
        request.timeoutInterval = BackendSession.writeTimeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return await perform(request)
    }

    private func perform(_ request: URLRequest) async -> Result<AccountState, AccountError> {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch let urlError as URLError where urlError.code == .cancelled {
            return .failure(.cancelled)
        } catch {
            return .failure(.unreachable)
        }

        // Status before body, as everywhere else in this layer.
        guard let http = response as? HTTPURLResponse else { return .failure(.unreachable) }
        switch http.statusCode {
        case 200:
            guard let state = Self.decodeAccount(data) else { return .failure(.malformedBody) }
            return .success(state)
        case 400:
            // 断りは机が日本語で書いて寄越す(`src/account.mjs` の `selectionMessage`)。
            return .failure(.refused(Self.decodeError(data) ?? "That account cannot be selected"))
        case 401:
            return .failure(.unauthorized)
        case 500:
            // The server always attaches `error` on this route's failure path. If it is
            // missing, say so rather than inventing a reason.
            return .failure(.backend(Self.decodeError(data) ?? "The server gave no reason"))
        default:
            return .failure(.unexpectedStatus(http.statusCode))
        }
    }

    /// ★`parseStatus` と `anomalies`(機械語)は**わざと読まない**。線には診断用に載って
    /// いるが、電話が描くのは `display` に畳まれた日本語だけ。読んでしまうと、いつか
    /// 「英語のまま画面に出す」道が生えるので、型から取り除いてある。
    private static func decodeAccount(_ data: Data) -> AccountState? {
        struct Wire: Decodable {
            let current: String?
            let accounts: [Row]
            let ok: Bool
            let display: Display
            let raw: String?
            /// 机は `ok == false` の枝でしか此の鍵を載せない(`accountRaw` が組で吐く)。
            /// 読めた時に鍵ごと無いのは正常なので、欠けを `false` に落とす。
            let rawTruncated: Bool?

            struct Row: Decodable {
                let name: String
                let hasToken: Bool
                let active: Bool
                let selectable: Bool
                let display: RowDisplay
                /// 使用量。机がまだ測れていない間は `null` で来る(鍵は常に在る)。
                let usage: Usage?

                struct RowDisplay: Decodable {
                    let blocked: String?
                }

                struct Usage: Decodable {
                    let usageStatus: String?
                    let sessionUsedPct: Double?
                    let weeklyUsedPct: Double?
                    let weeklyResetsIn: String?
                    let willLastToReset: Bool?
                }
            }

            struct Display: Decodable {
                let status: String?
                let anomalies: [String]
            }
        }
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data) else { return nil }
        let trimmed = wire.current?.trimmingCharacters(in: .whitespacesAndNewlines)
        return AccountState(
            // 空文字は口座名ではない。机は未設定を `null` で寄越すが、空文字が来た時に
            // 空白のラベルを描くより「現用は無い」に寄せる方が、嘘が小さい。
            current: (trimmed?.isEmpty ?? true) ? nil : trimmed,
            accounts: wire.accounts.map {
                AccountRow(
                    name: $0.name,
                    hasToken: $0.hasToken,
                    active: $0.active,
                    selectable: $0.selectable,
                    blocked: $0.display.blocked,
                    usage: $0.usage.map {
                        AccountUsage(
                            sessionUsedPct: $0.sessionUsedPct,
                            weeklyUsedPct: $0.weeklyUsedPct,
                            weeklyResetsIn: $0.weeklyResetsIn,
                            willLastToReset: $0.willLastToReset
                        )
                    }
                )
            },
            ok: wire.ok,
            statusMessage: wire.display.status,
            anomalyMessages: wire.display.anomalies,
            raw: wire.raw,
            rawTruncated: wire.rawTruncated ?? false
        )
    }

    /// ★型の名前が `Wire` ではなく `Envelope` なのは**名前が衝突していたから**
    ///   (2026-08-15 に実測)。此処も `Wire` だった間、`decodeAccount` の中の
    ///   `struct Wire` と此の `struct Wire` は、鍵名を突き合わせる検査
    ///   (`rc-backend/test/wire-key-agreement.test.mjs`)から見て**同じ1つの型**
    ///   `AccountClient.Wire` に見えていた。あの検査は file を brace で切って型を
    ///   集め、修飾名を鍵に Map へ入れる —— 同じ名前は後勝ちで上書きされる。
    ///   つまり「口座の応答の鍵名を測っている」つもりが、実際に残っていたのは
    ///   `{ error }` の1鍵だけ、という**静かに痩せた測定**になっていた。
    ///   誤り応答の封筒を `Envelope` と呼ぶのは `SendClient` / `InterruptClient` /
    ///   `ChoiceClient` と同じ綴りで、此処だけの造語ではない。
    private static func decodeError(_ data: Data) -> String? {
        struct Envelope: Decodable { let error: String }
        guard let wire = try? JSONDecoder().decode(Envelope.self, from: data) else { return nil }
        let trimmed = wire.error.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
