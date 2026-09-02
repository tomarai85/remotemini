import Foundation

protocol PathCompleting {
    /// 会話の作業場所の下から、`query` に**前方一致**する path を貰う。
    ///
    /// `query` が空 = cwd の直下だけ(机の仕様。全走査はしない)。
    /// `limit` は返る候補の上限で、机は其れを自分の枠(200)に収める。
    func complete(
        baseURL: URL, apiKey: String, sessionID: String, query: String, limit: Int
    ) async -> Result<PathCompletionResponse, SessionsFetchError>
}

/// `GET /api/sessions/<id>/paths?q=…&limit=N` — `@` の補完(2026-09-02)。
///
/// 形は `HistoryClient` / `NewSessionClient` を踏襲する: protocol + struct、
/// `BackendSession`(素の `URLSession` は `rc-backend/test/session-guard.test.mjs` が
/// `ios/Sources/` を走査して commit の門で落とす)、status を読んでから body を信じる、
/// 誤りの語彙は `SessionsFetchError` を使い回す(2つ目の語彙を作らない)。
///
/// ★**読む口**なので `interactiveTimeout`。机は fs を舐めるが、舐める量には
///   上限が入っている(`src/paths.mjs` の時間・件数・深さ)ので、書き込みの様に
///   長く待つ理由が無い。待ち過ぎると、打鍵に付いて来ない候補列が画面に残る。
struct PathCompletionClient: PathCompleting {
    private let session: BackendSession

    init(session: BackendSession = .shared) {
        self.session = session
    }

    func complete(
        baseURL: URL, apiKey: String, sessionID: String, query: String, limit: Int
    ) async -> Result<PathCompletionResponse, SessionsFetchError> {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("api/sessions/\(sessionID)/paths"),
            resolvingAgainstBaseURL: false
        )
        // ★空の問いでも `q=` を**送る**。`HistoryClient.search` が空を送らないのと逆で、
        //   理由も逆: あちらは `q` が落ちると机の**別の経路**(素の履歴)へ行くので
        //   送ってはいけない。此処は `q` が空でも同じ経路で、机は「直下だけ」を返す ——
        //   `@` を打った直後に一段目が出るのが此の機能の入口なので、落とす訳にいかない。
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        guard let url = components?.url else { return .failure(.unreachable) }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = BackendSession.interactiveTimeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            // ★打鍵ごとに前の要求を捨てるので、**取り消しは常態**。
            //   「届かない」に丸めると、速く打っただけで「机に繋がらない」と描く事になる。
            return .failure(.cancelled)
        } catch let urlError as URLError where urlError.code == .cancelled {
            return .failure(.cancelled)
        } catch {
            return .failure(.unreachable)
        }

        // status を読んでから body を信じる。
        guard let http = response as? HTTPURLResponse else { return .failure(.unreachable) }
        switch http.statusCode {
        case 200:
            break
        case 401:
            return .failure(.unauthorized)
        case 404:
            // ★`HistoryClient` と**同じ narrowing**。404 は2つの意味を運ぶ ——
            //   会話が本当に無い(`SESSION_NOT_FOUND`)か、電話が URL を組み違えたか
            //   (`NO_SUCH_ROUTE`)。後者を「この会話はもう在りません」と描くのが、
            //   一番もっともらしい嘘になる形。
            let code = try? JSONDecoder().decode(RecoveryCode.self, from: data).code
            guard code == RecoveryCode.sessionNotFound else {
                return .failure(.contractViolation(ResponseContractViolation(status: 404, code: code)))
            }
            return .failure(.notFound)
        default:
            return .failure(.unreachable)
        }

        guard let decoded = try? JSONDecoder().decode(PathCompletionResponse.self, from: data) else {
            return .failure(.malformedBody)
        }
        return .success(decoded)
    }
}

/// 渡し忘れた時の受け皿。**本当の HTTP を飛ばさない。**
///
/// ★`NoDigest` と同じ判断で、`ConversationClients` の既定は之にする。
///   読む口なので、渡し忘れの症状は「候補列が出ない」だけ —— 本物を既定にすると、
///   UI 検査の面が黙って本番の机へ繋ぎに行く(あの file が塞いだ当の穴)。
struct NoPathCompletion: PathCompleting {
    func complete(
        baseURL: URL, apiKey: String, sessionID: String, query: String, limit: Int
    ) async -> Result<PathCompletionResponse, SessionsFetchError> { .failure(.unreachable) }
}
