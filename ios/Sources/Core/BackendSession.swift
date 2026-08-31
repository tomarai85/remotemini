import Foundation

/// Shared HTTP plumbing for every rc-backend request (spec §3-1, §3-7/N5).
///
/// Redirects are refused outright rather than "followed with the header
/// reattached": `URLSession` strips `Authorization` on a cross-origin redirect by
/// design, and re-attaching it by hand would mean this client decides on its own to
/// send the bearer key to wherever a `Location` header points. A 3xx from this
/// backend is never something the client should chase automatically -- it is either
/// a misconfiguration or something worth surfacing as an unexpected response (spec:
/// "3xx が来たら想定外の応答に分類").
///
/// ## Why clients take this type and not a bare `URLSession`
///
/// This initializer takes a *configuration*, never a delegate: it installs
/// `RedirectRefusingDelegate` itself. So possessing a `BackendSession` IS the proof
/// that N5 holds for every request made through it -- the compiler enforces what a
/// default argument only suggested.
///
/// The shape being replaced (2026-08-05, Sprint 1 evaluator Finding 1) was
/// `init(session: URLSession = BackendSession.shared.session)` on each client. That
/// made redirect refusal a *default*, not a constraint: any call site could pass a
/// plain `URLSession` and silently lose N5. The Sprint 1 tests were themselves that
/// call site -- `MockURLProtocol.makeSession()` returned a delegate-less session, so
/// `HealthzClientTests`/`SessionsAuthProbeTests` never exercised redirect refusal
/// even once, while `RedirectRefusalTests` proved only that *this* type wires the
/// delegate. Both halves were green and the gap between them was invisible.
final class BackendSession {
    static let shared = BackendSession()

    /// Spec §3-1: the server holds long-poll requests up to `POLL_MAX_WAIT_MS`
    /// (20s, `POLL_MAX_WAIT_MS` in `server.mjs`). The client timeout must exceed that
    /// or a normal "nothing happened" 200 reads as a network error.
    ///
    /// `pollTimeout` derives from this constant rather than restating 30 by hand, so
    /// those two cannot drift apart -- that non-drift property is the reason the
    /// original shape used ONE timeout for every request, and splitting the timeouts
    /// below keeps it rather than trading it away.
    ///
    /// The 20 itself is a different matter, and this comment used to overclaim it
    /// (corrected 2026-08-08, S8-23): it is a **hand-written copy** of a value that
    /// lives in another language in another tree, and until that date nothing
    /// compared the copy to the original. It is now compared, by
    /// `rc-backend/test/timeout-agreement.test.mjs` -- so raising the server's
    /// ceiling without raising this one fails the suite instead of shipping a phone
    /// that abandons every long poll early and reports a normal 200 as a network
    /// failure.
    static let serverPollMaxWait: TimeInterval = 20
    static let pollTimeout: TimeInterval = serverPollMaxWait + 10

    /// Everything the user is *staring at a blank screen* for (REQUIREMENTS §5-6,
    /// measured 2026-08-06).
    ///
    /// Why this is not `pollTimeout`: until this split, one 30s value covered every
    /// request, so a network that accepts a connection and then never answers -- a
    /// hotel/airport captive portal, or a tailnet peer asleep, i.e. precisely the
    /// 移動中 case this app exists for -- left the Conversation and List screens
    /// showing a bare `ProgressView` for a full 30 seconds before offering 再試行.
    /// That is RC 却下理由 1 (「connecting」で作業が止まる) reproduced in this app.
    ///
    /// 8s is sized off measured payloads, not guessed: `/api/sessions` is the largest
    /// read at ~30 KB (41 conversations) and `/history?limit=50` runs 14 B - 2.6 KB,
    /// with server-side work of 1-5 ms and 38-65 ms respectively. A round trip over
    /// the tailnet measured 10.6 ms on a warm connection and 45-52 ms on a new one.
    /// 8s is therefore ~2 orders of magnitude of headroom on a working link, and only
    /// a link that is silent -- not merely slow -- reaches it.
    ///
    /// Reads only. Re-issuing a read is free, which is what makes a shorter give-up
    /// window strictly better here.
    ///
    /// ★2026-08-26 に 8 -> 20 へ上げた。**上の見積もりは新規接続の TLS を含んでいなかった。**
    ///   実測(simulator、本番の机): アプリの**初回**の TLS ハンドシェイクが 6030ms
    ///   かかり、8 秒の枠に間に合わず `-1001 timed out`。2回目以降は 74ms で通る。
    ///   症状は「**アプリを初めて開いた時だけ『机に届きません』になり、Retry で直る**」
    ///   —— Tom が一番最初に触る瞬間に一番失敗する形で、画を見るまで誰も気付かなかった。
    ///   (curl が 0.14 秒で返るのは接続を使い回すから。同じ URL でも測っている物が違う。)
    ///
    ///   ★上げた分の代償を正直に書く: 本当に黙った線で諦めるまでが 8 秒 -> 20 秒に延びる。
    ///   読み直しは無料なので、**遅い時に諦める**より**初回に失敗する**方が高くつく、
    ///   という判断でこちらを採った。
    static let interactiveTimeout: TimeInterval = 20

    /// Sends and interrupts keep the long timeout, deliberately.
    ///
    /// `POST /api/sessions/<id>/messages` carries **no idempotency key** (checked
    /// 2026-08-06: `server.mjs` has no dedup/nonce on that path -- it resolves a pane
    /// and calls `injector.send`). So a client that gives up while the request is
    /// still in flight cannot know whether the text was injected, and a retry types
    /// it into Claude's composer twice. Shortening this would widen exactly that
    /// window. The blank-screen complaint this split fixes is a *read* problem
    /// anyway: a send happens on an already-loaded screen that has the reachability
    /// banner, not behind a spinner.
    ///
    /// ★2026-08-26: **その冪等鍵を入れた**(`src/idem.mjs` + 電話が `sendId` を送る)。
    /// 上の「retry types it into Claude's composer twice」は、この日まで**実際に起きていた**
    /// —— 本番で同じ本文を2回投げたら実画面に2回入るのを測って確かめ、そこから塞いだ。
    /// 鍵が入った今、この長い上限を短くする道は開いている。ただし短くする理由が
    /// 今は無い(送信は一覧が出た後の操作で、待たされても画面は空にならない)ので据え置く。
    static let writeTimeout: TimeInterval = pollTimeout

    let session: URLSession

    /// 此の instance が名乗る build。既定は束から読んだ物。
    /// ★差せる様にしてあるのは検査の為(束の `CFBundleVersion` は検査の走行では
    ///   別の値になるので、差せないと「押しているか」を測れない)。
    ///   本番の経路は既定のまま通るので、差し口が在る事で挙動は変わらない。
    let appBuild: String?

    /// 此の instance が名乗る役(検査用の殻なら `control`)。差せるのは検査の為。
    let appRole: String?

    init(configuration: URLSessionConfiguration = .default,
         appBuild: String? = BackendSession.appBuild,
         appRole: String? = BackendSession.appRole) {
        self.appBuild = appBuild
        self.appRole = appRole
        // The session-wide default stays the LONGEST of the three. A client that
        // forgets to set a per-request value therefore behaves exactly as this tree
        // did before the split -- the failure mode of forgetting is "no improvement,"
        // never "a working request now times out."
        //
        // That fallback is measured, not assumed (2026-08-06, plain Swift against an
        // unroutable address): a request that sets nothing still *reads* 60.0 from
        // `URLRequest.timeoutInterval`, but under a session whose configuration says
        // 3s it fails at 3.02s with `URLError` -1001 -- so the configuration governs
        // when the request stays silent, and the request governs when it speaks
        // (5s -> 5.03s, 2s -> 2.01s under the same 30s configuration).
        //
        // The consequence for tests: `MockURLProtocol.requestedTimeouts` records the
        // request's DECLARED value (60 for a bare request), not the effective one.
        // `RequestTimeoutTests` says so in its own header rather than implying the
        // suite proves enforcement -- enforcement is what the measurement above is for.
        configuration.timeoutIntervalForRequest = Self.pollTimeout
        self.session = URLSession(configuration: configuration, delegate: RedirectRefusingDelegate(), delegateQueue: nil)
    }

    /// 自分の build 番号。**一度だけ**読む(要求ごとに Info.plist を引かない)。
    ///
    /// ★`nil` を返す条件を狭く保つ: 数字だけの値以外は名乗らない。`xcodegen` は変数が
    ///   未定義でも落ちず `${...}` という**もっともらしい文字列**を Info.plist に書くので、
    ///   素通しにすると其れが机の log に載る(`BuildInfo.displayRev` が同じ罠を扱っている)。
    ///   名乗れない時は**何も送らない** —— 机側は header の不在を「版が判らない」と読む。
    static let appBuild: String? = normalizedBuild(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)

    /// 自分の役。**一度だけ**読む。既定は束の `RCRole`。
    /// ★`project.yml` の既定は 2026-08-31 に `control` へ倒した —— `build.sh` を通らない
    ///   焼き手(自分で `xcodegen generate` を撃つ対照が 12 本)が役を名乗らないと、
    ///   机の台帳で **Tom の要求と混ざる**。配る束だけが `build.sh` の刻印で空になる。
    static let appRole: String? = normalizedRole(Bundle.main.object(forInfoDictionaryKey: "RCRole") as? String)

    /// 生値 → 名乗ってよい役。`${…}` を弾くのは、`xcodegen` が未定義の変数を
    /// **もっともらしい文字列**として書く為(`BuildInfo.displayRev` が同じ罠を扱う)。
    static func normalizedRole(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty, !v.contains("${") else { return nil }
        return v
    }

    /// 生値 → 名乗ってよい値。**規則だけを純関数に出す**ので、束を立てずに測れる。
    static func normalizedBuild(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty, v.count <= 9, v.allSatisfy({ $0.isNumber }) else { return nil }
        return v
    }

    /// The one call clients make. Kept here rather than having each client reach for
    /// `.session` so that "which session did this request actually go through" has a
    /// single answer, greppable in one place.
    ///
    /// ★版の名乗りは**此処で1回だけ**打つ(2026-08-31)。元は `SessionsClient` の
    ///   一覧取得だけが `X-App-Build` を付けており、他の口は全部 `build=-` で記録された。
    ///   其の疎らさは机側で実害になった: 同じミリ秒に `/api/sessions`(build=115)と
    ///   `/api/account`(build=-)が並び、「最後の app 行」を読む道具が後者を掴んで
    ///   **「電話は版を名乗っていない」と報告した** —— 電話は 115 だったのに。
    ///   16 箇所の `Authorization` は全部この1本を通るので、**通り道で押す**方が
    ///   「client を1つ足した日に版が消える」形を構造的に潰せる。
    /// ★既に入っている値は上書きしない —— 検査が意図して差した値を消さない為。
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        var stamped = request
        if stamped.value(forHTTPHeaderField: "X-App-Build") == nil, let build = appBuild {
            stamped.setValue(build, forHTTPHeaderField: "X-App-Build")
        }
        // ★役も**同じ場所で**押す(2026-08-31)。版と全く同じ疎らさを持っていた ——
        //   元は `SessionsClient` の一覧取得 1 箇所だけで、`/api/account` 等は役を
        //   名乗らないので机は `client=app` と記録した。電話の版を見る枝は
        //   `client=app` の行を数えるので、**押していない口が1つ在れば誤報が再発する**。
        //   実測: 誤報 2 通の行は `/api/sessions` と `/api/account` の両方に出ていた。
        if stamped.value(forHTTPHeaderField: "X-RC-Role") == nil, let role = appRole {
            stamped.setValue(role, forHTTPHeaderField: "X-RC-Role")
        }
        return try await session.data(for: stamped)
    }
}

/// Internal (not `private`) so `RedirectRefusalTests` can exercise this delegate's
/// method directly via `@testable import` -- testing the redirect refusal itself
/// does not require standing up real (or mocked) networking, only calling the
/// delegate method with a synthetic response and observing the completion handler.
final class RedirectRefusingDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil) // N5: do not follow. The 3xx response itself becomes the task's result.
    }
}
