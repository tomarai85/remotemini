import Foundation

enum SessionsFetchError: Error, Equatable {
    /// Connection failure/timeout, and any HTTP status other than 200/401 (5xx
    /// included). Judgment call, same shape as `SessionsAuthProbe.Outcome.unreachable`
    /// (spec gap, flagged in progress.md): the brief's §4-a counting table only names
    /// "接続不可 / タイムアウト / 5xx", it does not separately name e.g. a stray 403/404.
    /// Grouped here because none of those responses are evidence the List screen has
    /// anything usable to show, which is the property the failure counter actually
    /// tracks.
    case unreachable
    /// HTTP 401. Counted separately from `.unreachable` -- brief §4-a: a 401 does not
    /// advance the consecutive-failure counter at all, it exits straight to Key-entry.
    case unauthorized
    /// HTTP 200, but the body didn't decode as `SessionsResponse`. Treated as a
    /// failure (not a reset) by the ViewModel: brief §4-a's "200 resets the counter"
    /// rule is written with a well-formed body in mind (its own example is "200 that
    /// happens to carry a paneFault"), and reaching a 200 with an undecodable body is
    /// not the same evidence of a healthy round trip -- flagged in progress.md.
    case malformedBody
    /// The request was cancelled -- either `CancellationError` (structured-concurrency
    /// cancellation) or `URLError.cancelled` (`URLSession`'s own cancellation
    /// surfacing), which the brief explicitly says must both be treated as this same
    /// case, not folded into `.unreachable` (§4-a, §8: found via Codex, not
    /// self-discovered -- rapid pull-to-refresh cancels an in-flight fetch, and that
    /// must not look like the backend went unreachable).
    case cancelled
    /// HTTP 404. Added in Sprint 3 (brief §3-c, a same-day correction to the brief's
    /// own first draft, which had folded 404 into `.unreachable`): `src/server.mjs`'s
    /// `/history` handler, `if (!file && !registeredOnly) return json(res, 404, {
    /// error: "unknown session" })` -- a session that existed when the List row was
    /// rendered but is gone by the time Conversation opens it (or by the time a
    /// later "load earlier" tap lands). This is an EXTENSION of the shared taxonomy,
    /// not a second one (the brief's own distinction, §3-c): `SessionsClient` below
    /// still never returns it -- `/api/sessions` has no session id to 404 against --
    /// only `HistoryClient` produces this case. It lives here rather than on a
    /// Conversation-only type so both clients keep exactly one error vocabulary.
    ///
    /// Narrowed in Sprint 5 (brief §0-c ②): this now means "the server said
    /// `SESSION_NOT_FOUND`," not "the status was 404." The three 404 sites in
    /// `server.mjs` carry two different meanings, and the other one -- the phone
    /// built a URL that does not exist -- must never render as "this conversation is
    /// gone," which sends the user hunting for a session that was never deleted.
    case notFound
    /// A response the phone is not allowed to interpret on its own: no `display`, and
    /// not one of the two statuses whose meaning is fixed by the contract (401, and
    /// 404 + `SESSION_NOT_FOUND`). Sprint 5 brief §0-c ③.
    ///
    /// Kept distinct from `.malformedBody` on purpose. `.malformedBody` says "a 200
    /// arrived and its payload did not parse" -- a data problem in a response that
    /// otherwise went right. This says "the response did not obey the response
    /// contract," which is a problem with the *agreement* between the two sides, and
    /// which the phone must surface loudly rather than fold into a familiar-looking
    /// failure. Folding them would put the single most likely client bug (a wrong
    /// path) into the same bucket as an ordinary bad payload.
    case contractViolation(ResponseContractViolation)
}

protocol SessionsListing {
    func fetch(baseURL: URL, apiKey: String) async -> Result<SessionsResponse, SessionsFetchError>
}

/// `GET /api/sessions`, decoded to the full response shape (unlike
/// `SessionsAuthProbe`, which only cares about the status code and discards the
/// body -- that type stays Key-entry's, this one is the List screen's data source).
struct SessionsClient: SessionsListing {
    /// `BackendSession`, not `URLSession`: see that type for why N5 is a constraint
    /// here rather than a default argument. This client carries the bearer key, so a
    /// followed redirect would be the exact leak N5 exists to prevent.
    private let session: BackendSession

    init(session: BackendSession = .shared) {
        self.session = session
    }

    func fetch(baseURL: URL, apiKey: String) async -> Result<SessionsResponse, SessionsFetchError> {
        await fetch(baseURL: baseURL, apiKey: apiKey, scope: nil)
    }

    /// §9-1(2026-08-16): `scope: "archived"` = 保管した会話だけ。nil = 既定の一覧
    /// (保管済みはサーバ側で絞られて出ない)。設定画面の「保管した会話」が使う。
    func fetch(baseURL: URL, apiKey: String, scope: String?) async -> Result<SessionsResponse, SessionsFetchError> {
        var url = baseURL.appendingPathComponent("api/sessions")
        if let scope, var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            comps.queryItems = [URLQueryItem(name: "scope", value: scope)]
            url = comps.url ?? url
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = BackendSession.interactiveTimeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        // ★版の名乗りは `BackendSession.data(for:)` が**通り道で**打つ(2026-08-31 に移した)。
        //   此処だけに在った頃は、一覧以外の口が全部 `build=-` で記録され、
        //   机側の道具が「最後の app 行」を読んで版を取り違えた。client が増えるたびに
        //   刻印を足す形は、足し忘れた日に静かに版が消える。
        // ★検査用の殻だけが役を名乗る(2026-08-30)。空なら何も送らない = 机は UA で判ずる。
        //   ★`${` を含む値は送らない —— xcodegen は変数が未定義でも落ちず、
        //     `${RC_ROLE}` という**もっともらしい文字列**を Info.plist に書く(実測、
        //     `BuildInfo.displayRev` が同じ罠を扱っている)。
        //     ★之は**守りの重ね掛け**であって一線ではない: 机の分類器は `control` に
        //       完全一致した時だけ役を採り、其れ以外は UA の判定へ落ちる。つまり
        //       literal を送っても結果は現状(= `app`)で、害は無い。送らないのは
        //       机の log に意味の無い文字列を残さない為。
        if let role = Bundle.main.object(forInfoDictionaryKey: "RCRole") as? String,
           !role.isEmpty, !role.contains("${") {
            request.setValue(role, forHTTPHeaderField: "X-RC-Role")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch let urlError as URLError where urlError.code == .cancelled {
            return .failure(.cancelled)
        } catch {
            // ★2026-08-27: DEBUG に限り**なぜ届かなかったか**を1行出す。
            //   `.unreachable` は「網の何かが駄目」を1語に畳むので、外から見ると
            //   名前解決の失敗・接続拒否・時間切れ・証明書の不一致が**全部同じ顔**になる。
            //   実機で「Can't reach the desk」しか出ない時、それを分ける手が他に無い
            //   (URLSession の失敗は os_log 側で、`devicectl --console` は print しか拾えない)。
            //   ★値は**分類だけ**。URL も鍵も本文も出さない。
            // ★`#if DEBUG` に**しない**。実機の束は `-configuration Release` で焼くので
            //   (`tools/build.sh` の device 経路)、DEBUG 限定にすると**実機でだけ消える** ——
            //   実機でしか出ない不具合を診る為の行が、実機で存在しない。
            //   同じ理由で `RootView` の `root flow:` も条件の外に在る(先例)。
            //   出すのは**分類だけ**: URL も鍵も本文も出さない。
            let why: String
            if let u = error as? URLError {
                why = "URLError(\(u.code.rawValue) \(u.code)) host=\(u.failingURL?.host ?? "-") port=\(u.failingURL?.port.map(String.init) ?? "-")"
            } else {
                why = "\(type(of: error))"
            }
            print("sessions fetch unreachable: \(why)")
            return .failure(.unreachable)
        }

        // N6: status is checked before the body is trusted.
        guard let http = response as? HTTPURLResponse else { return .failure(.unreachable) }
        switch http.statusCode {
        case 200:
            break
        case 401:
            return .failure(.unauthorized)
        case 404:
            // Sprint 5 brief §0-c ②, this client's half. `/api/sessions` names no
            // session, so there is nothing here that could legitimately be
            // "not found" -- every 404 on this route means the phone asked for a path
            // the server does not serve. The `code` is read anyway, purely so the
            // violation carries a diagnostic; the branch does NOT depend on its
            // value, because `SESSION_NOT_FOUND` arriving on a listing request would
            // itself be a contract problem rather than a reason to show the
            // "conversation is gone" screen (which this screen does not even have).
            let code = try? JSONDecoder().decode(RecoveryCode.self, from: data).code
            return .failure(.contractViolation(ResponseContractViolation(status: 404, code: code)))
        default:
            return .failure(.unreachable)
        }

        guard let decoded = try? JSONDecoder().decode(SessionsResponse.self, from: data) else {
            return .failure(.malformedBody)
        }
        return .success(decoded)
    }
}
