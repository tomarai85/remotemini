import Foundation

protocol HistoryFetching {
    /// 転写の末尾を読む。**探索の口ではない。**
    ///
    /// ★2026-09-01 に `query:` 引数を**外した**。2026-08-31 に此処へ足した時の判断
    ///   (「口は 1 本、引数で分ける」)は client を 2 型に割らない事については今も
    ///   正しいが、引数で分ける形は**戻り値の型まで同じにしてしまう**。探索の応答は
    ///   `truncated` の意味が違い(`TranscriptSearchResponse` の doc)、
    ///   `HistoryResponse` で受けた瞬間にそれが `loadEarlierState` へ流れ込む。
    ///   引数を残すと、今日 誰も呼んでいないだけで**その配線は生きたまま**なので、
    ///   経路ごと畳んだ。分けたのは client ではなく戻り値で、request の組み立ては
    ///   下の `HistoryClient` の中で 1 本を共有している。
    func fetch(baseURL: URL, apiKey: String, sessionID: String, limit: Int) async -> Result<HistoryResponse, SessionsFetchError>

    /// 転写の中を探す(`?q=`)。返るのは**探索専用の型**。
    ///
    /// `limit` は「返す一致の数」であって走査量ではない —— 机は一致が `limit` 件
    /// 集まった所で後方読みを止めるので、`limit` は速さと網羅の両方に効く。
    func search(baseURL: URL, apiKey: String, sessionID: String, limit: Int, query: String) async -> Result<TranscriptSearchResponse, SessionsFetchError>

    /// 錨を中心にした窓を読む(対照表 #3 の後追い、2026-09-04)。
    ///
    /// 末尾からの `limit` 件ではなく、**転写の中の 1 点の周り**を返す。探索の当たりが机の上限
    /// (500)より奥に在る時、末尾の窓を伸ばして届かせる道は「電話が転写を丸ごと抱える」に
    /// なるので採らない —— 窓の位置を変える。戻り値が別の型なのは `search` と同じ理由で、
    /// `truncated` の意味が違う(此の窓には両端が在り、`olderAvailable`/`newerAvailable` で言う)。
    func around(baseURL: URL, apiKey: String, sessionID: String, anchor: String, limit: Int) async -> Result<HistoryAroundResponse, SessionsFetchError>
}

/// `GET /api/sessions/<id>/history?limit=N` -- same shape as `SessionsClient`
/// (Sprint 3 brief §1-a): protocol + struct, `BackendSession` (never a bare
/// `URLSession` -- `rc-backend/test/session-guard.test.mjs` scans `ios/Sources/` and
/// fails the commit gate on any other file that spells `URLSession`), N6 (status code
/// checked before the body is trusted), and the exact same `SessionsFetchError`
/// 4-case taxonomy reused rather than inventing a Conversation-specific one (brief
/// §3-c: two error vocabularies would mean picking one every sprint from here on).
struct HistoryClient: HistoryFetching {
    private let session: BackendSession

    init(session: BackendSession = .shared) {
        self.session = session
    }

    func fetch(baseURL: URL, apiKey: String, sessionID: String, limit: Int) async -> Result<HistoryResponse, SessionsFetchError> {
        await get(
            HistoryResponse.self,
            baseURL: baseURL, apiKey: apiKey, sessionID: sessionID,
            items: [URLQueryItem(name: "limit", value: String(limit))]
        )
    }

    func search(baseURL: URL, apiKey: String, sessionID: String, limit: Int, query: String) async -> Result<TranscriptSearchResponse, SessionsFetchError> {
        var items = [URLQueryItem(name: "limit", value: String(limit))]
        // ★空白だけの問いを送らない。机は空を「全件一致にしない」で受けるが、
        //   送らない方が往復 1 回ぶん安く、机の判断に頼らずに済む。
        //   ★`q` が落ちた要求は机の**素の履歴経路**へ落ち、`matched` の無い body が
        //     返る。`TranscriptSearchResponse` が `matched` を必須にしているので、
        //     其れは `.success` ではなく `.malformedBody` になる —— 空の問いが
        //     「直近 100 行が全部一致」の顔で返る道が、型の側で塞がっている。
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            items.append(URLQueryItem(name: "q", value: trimmed))
        }
        return await get(
            TranscriptSearchResponse.self,
            baseURL: baseURL, apiKey: apiKey, sessionID: sessionID,
            items: items
        )
    }

    func around(baseURL: URL, apiKey: String, sessionID: String, anchor: String, limit: Int) async -> Result<HistoryAroundResponse, SessionsFetchError> {
        // ★`q` と併せて送らない。机は両方在る要求を 400 で断る(Codex 所見 F6)ので、
        //   此処で混ぜない事が唯一の正しい呼び方 —— `search` と `around` は別の呼び出し。
        await get(
            HistoryAroundResponse.self,
            baseURL: baseURL, apiKey: apiKey, sessionID: sessionID,
            items: [
                URLQueryItem(name: "around", value: anchor),
                URLQueryItem(name: "limit", value: String(limit)),
            ]
        )
    }

    /// 3 つの口が共有する **1 本の**要求の組み立てと status の読み。
    ///
    /// ★分けたのは戻り値の型だけ、という主張の実体が此処。URL の組み立て・method・
    ///   `Bearer` header・待ち時間・status の写像を 3 箇所に書くと、片方だけが
    ///   直る日が来る(此の repo が `title` / `archive` で実演済み)。違うのは
    ///   最後の 1 行 —— どの型へ復号するか —— だけ。
    private func get<T: Decodable>(
        _ type: T.Type,
        baseURL: URL,
        apiKey: String,
        sessionID: String,
        items: [URLQueryItem]
    ) async -> Result<T, SessionsFetchError> {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("api/sessions/\(sessionID)/history"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = items
        guard let url = components?.url else {
            // Not observed in practice (session ids are opaque server-issued
            // strings), but `URLComponents` construction is technically failable --
            // fail closed rather than force-unwrap.
            return .failure(.unreachable)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = BackendSession.interactiveTimeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

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

        // N6: status is checked before the body is trusted.
        guard let http = response as? HTTPURLResponse else { return .failure(.unreachable) }
        switch http.statusCode {
        case 200:
            break
        case 401:
            return .failure(.unauthorized)
        case 404:
            // Sprint 3 brief §3-c made 404 distinct from the `default` bucket below:
            // Conversation renders it as "this conversation is gone," never as
            // "network trouble, try again."
            //
            // Sprint 5 brief §0-c ② then NARROWED it, and that narrowing is the
            // point of DoD row 6. Counting `json(res, 404, …)` in `server.mjs` turned
            // up three sites carrying two meanings: the session really is unknown
            // (`SESSION_NOT_FOUND`), or the requested path does not exist at all
            // (`NO_SUCH_ROUTE`, twice). Branching on the status alone -- which is
            // what this line did until now -- rendered the second as "この会話はもう
            // 在りません," i.e. it told the user their conversation had been deleted
            // when the truth was that this app built a URL wrong.
            //
            // That combination is worse than a merely imprecise message. The same
            // day's mutation audit measured the request path as the least-guarded
            // thing in this tree (changing `api/sessions` to `api/session` left 214
            // tests green), so this branch was covering the most likely bug in the
            // app with the most convincing possible false explanation.
            let code = try? JSONDecoder().decode(RecoveryCode.self, from: data).code
            guard code == RecoveryCode.sessionNotFound else {
                return .failure(.contractViolation(ResponseContractViolation(status: 404, code: code)))
            }
            return .failure(.notFound)
        default:
            // Covers the brief §0-a-5 500 (`TRANSCRIPT_UNREADABLE`) case too: the
            // brief does not ask for a distinct display for that status, and folding
            // it into `.unreachable` matches `SessionsClient`'s existing judgment
            // that any non-200/401/404 status is "nothing usable to show."
            return .failure(.unreachable)
        }

        guard let decoded = try? JSONDecoder().decode(T.self, from: data) else {
            return .failure(.malformedBody)
        }
        return .success(decoded)
    }
}
