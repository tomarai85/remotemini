import Foundation

/// 名前の付け外しの結果。器は意味だけを運ぶ(文言は画面が決める — `SignOutNotice` と同じ役割分担)。
enum RenameOutcome: Equatable {
    case renamed(String?)          // 保存された名前(nil = 外した)
    case rejected                  // サーバが形を拒んだ(空・60字超)
    case unreachable               // 届かない・読めない
    case unauthorized              // 401(呼び側が鍵の失効へ回す)

    static func from(status: Int, savedTitle: String?, serverError: String?) -> RenameOutcome {
        switch status {
        case 200: return .renamed(savedTitle)
        case 401: return .unauthorized
        // "title required" = 検証の拒否(rc-backend/src/server.mjs の title 道)。
        // 400 は他に BAD_JSON 相当も同じ語で来るので、区別せず「形が悪い」に畳む —
        // 電話の入力欄は 1..60 文字を自分でも見張るので、此処へ来るのは競合時だけ。
        case 400: return .rejected
        default: return .unreachable
        }
    }
}

protocol SessionRenaming {
    func rename(baseURL: URL, apiKey: String, sessionID: String, title: String?) async -> RenameOutcome
}

/// `POST /api/sessions/<id>/title` — 明示名(rename)。本家 RC のタイトル優先順の1段目
/// (research/remote-control-teardown.md §2、spec-audit A1)。`title: nil` で外す。
struct TitleClient: SessionRenaming {
    private let session: BackendSession

    init(session: BackendSession = .shared) {
        self.session = session
    }

    func rename(baseURL: URL, apiKey: String, sessionID: String, title: String?) async -> RenameOutcome {
        let url = baseURL.appendingPathComponent("api/sessions/\(sessionID)/title")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = BackendSession.writeTimeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // ★`title: nil` を「鍵ごと省略」に落とさない。外す意思は `"title": null` として
        //   線に載せる必要が在る。synthesized Codable の Optional プロパティは
        //   encodeIfPresent(= 省略)に落ちるので struct は使えない — 辞書の Optional 値は
        //   Optional 自身の Encodable が `null` を書く。
        let payload: Data
        do {
            payload = try JSONEncoder().encode(["title": title])
        } catch {
            return .unreachable
        }
        request.httpBody = payload

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            return .unreachable
        }
        guard let http = response as? HTTPURLResponse else { return .unreachable }
        struct Wire: Decodable { let title: String?; let error: String? }
        let wire = try? JSONDecoder().decode(Wire.self, from: data)
        return RenameOutcome.from(status: http.statusCode, savedTitle: wire?.title, serverError: wire?.error)
    }
}

/// 検査・fixture の面が握る口。本物の HTTP に一切触れない(fixture の面に本物の口を
/// 1つも残さない — Sprint 4/5/6/7 が4回踏んだ穴の再発防止と同じ判断)。
struct RenameFixture: SessionRenaming {
    var outcome: RenameOutcome = .renamed(nil)
    func rename(baseURL: URL, apiKey: String, sessionID: String, title: String?) async -> RenameOutcome {
        outcome
    }
}

// MARK: - 保管(§9-1)

/// 保管の付け外しの結果。
enum ArchiveOutcome: Equatable {
    case done(Bool)                // 保存された状態(true = 一覧から外れた)
    case unreachable
    case unauthorized

    static func from(status: Int, archived: Bool?) -> ArchiveOutcome {
        switch status {
        case 200: return .done(archived ?? true)
        case 401: return .unauthorized
        default: return .unreachable
        }
    }
}

protocol SessionArchiving {
    func setArchived(baseURL: URL, apiKey: String, sessionID: String, archived: Bool) async -> ArchiveOutcome
}

/// `POST /api/sessions/<id>/archive` — 一覧から外す / 戻す(§9-1)。
/// ★「消す」ではない。サーバ側に削除の機構が存在しない(titles.mjs の検査が
///   `unlink` 系の不在を見張っている)。此のクライアントも語彙に delete を持たない。
struct ArchiveClient: SessionArchiving {
    private let session: BackendSession

    init(session: BackendSession = .shared) {
        self.session = session
    }

    func setArchived(baseURL: URL, apiKey: String, sessionID: String, archived: Bool) async -> ArchiveOutcome {
        let url = baseURL.appendingPathComponent("api/sessions/\(sessionID)/archive")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = BackendSession.writeTimeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(["archived": archived])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            return .unreachable
        }
        guard let http = response as? HTTPURLResponse else { return .unreachable }
        struct Wire: Decodable { let archived: Bool?; let error: String? }
        let wire = try? JSONDecoder().decode(Wire.self, from: data)
        return ArchiveOutcome.from(status: http.statusCode, archived: wire?.archived)
    }
}

struct ArchiveFixture: SessionArchiving {
    var outcome: ArchiveOutcome = .done(true)
    func setArchived(baseURL: URL, apiKey: String, sessionID: String, archived: Bool) async -> ArchiveOutcome {
        outcome
    }
}

// MARK: - 戻しの依頼(§9-2)

/// 戻し依頼の結果。**依頼**であって実行ではない(実行は MBP 側の台本)。
enum ReturnRequestOutcome: Equatable {
    case requested(at: String, already: Bool)
    case notACheckout(String)      // サーバの日本語の理由をそのまま
    case unreachable
    case unauthorized

    static func from(status: Int, requestedAt: String?, already: Bool?, message: String?) -> ReturnRequestOutcome {
        switch status {
        case 200:
            guard let at = requestedAt else { return .unreachable }
            return .requested(at: at, already: already ?? false)
        case 409: return .notACheckout(message ?? "This session is not checked-out work.")
        case 401: return .unauthorized
        default: return .unreachable
        }
    }
}

protocol ReturnRequesting {
    func requestReturn(baseURL: URL, apiKey: String, sessionID: String) async -> ReturnRequestOutcome
}

/// `POST /api/sessions/<id>/return-request` — 「MBP へ戻す」の依頼を置く(§9-2)。
/// ★force に相当する引数は**存在しない**(Codex 条件3。渡す道が構造的に無い)。
struct ReturnRequestClient: ReturnRequesting {
    private let session: BackendSession

    init(session: BackendSession = .shared) {
        self.session = session
    }

    func requestReturn(baseURL: URL, apiKey: String, sessionID: String) async -> ReturnRequestOutcome {
        let url = baseURL.appendingPathComponent("api/sessions/\(sessionID)/return-request")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = BackendSession.writeTimeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            return .unreachable
        }
        guard let http = response as? HTTPURLResponse else { return .unreachable }
        struct Wire: Decodable { let requestedAt: String?; let already: Bool?; let error: String?; let message: String? }
        let wire = try? JSONDecoder().decode(Wire.self, from: data)
        return ReturnRequestOutcome.from(
            status: http.statusCode, requestedAt: wire?.requestedAt,
            already: wire?.already, message: wire?.message)
    }
}

struct ReturnRequestFixture: ReturnRequesting {
    var outcome: ReturnRequestOutcome = .requested(at: "2026-08-16T00:00:00.000Z", already: false)
    func requestReturn(baseURL: URL, apiKey: String, sessionID: String) async -> ReturnRequestOutcome {
        outcome
    }
}
