import Foundation

/// 電話が撮った画像を机へ渡した結果。
///
/// ★`sent` と `injected` を**分ける**。この repo が繰り返し守っている線と同じで、
///   「送れた」と「相手の入力欄に載った」は別の事実。机の tmux が居ない時、画像は
///   ちゃんと置かれているのにパスは差し込まれない —— それを「送れました」に丸めると、
///   Tom は入力欄を見て「消えた」と思う。
enum AttachOutcome: Equatable {
    /// 置けた。`injected` が false なら理由が付く(机に窓が無い等)。
    case stored(id: String, bytes: Int, converted: Bool, injected: Bool, reason: String?)
    /// 机が受け取りを断った。理由はサーバの語彙をそのまま運ぶ。
    case rejected(reason: String)
    case unauthorized
    case sessionNotFound
    case tooLarge
    case unreachable
    case cancelled
    case contractViolation(status: Int)
}

protocol Attaching {
    func attach(baseURL: URL, apiKey: String, sessionID: String, image: Data) async -> AttachOutcome
}

/// `POST /api/sessions/<id>/attach`、本文は**画像の生バイトそのもの**。
///
/// ★multipart にしない。単一利用者・単一ファイルなので境界文字列を組む理由が無く、
///   組めば「境界の解析」という新しい壊れ方を1つ増やすだけになる。
///
/// ★`Content-Type` は付けるが、**サーバはそれを読まない**(先頭バイトで実形式を判定する)。
///   付けるのは中継や log の為で、これを信頼の材料にしていないのは意図的。
///   ここを「サーバが見てくれる」と読んで検証を省くと、判定の唯一の門が消える。
struct AttachClient: Attaching {
    private let session: BackendSession

    init(session: BackendSession = .shared) {
        self.session = session
    }

    func attach(baseURL: URL, apiKey: String, sessionID: String, image: Data) async -> AttachOutcome {
        let url = baseURL.appendingPathComponent("api/sessions/\(sessionID)/attach")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // 画像は本文が大きく、机側で変換も走る。書き込みの既定より長く待つ。
        request.timeoutInterval = max(BackendSession.writeTimeout, 60)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = image

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            return .cancelled
        } catch let urlError as URLError where urlError.code == .cancelled {
            return .cancelled
        } catch {
            return .unreachable
        }

        guard let http = response as? HTTPURLResponse else { return .unreachable }
        if http.statusCode == 401 { return .unauthorized }
        if http.statusCode == 413 { return .tooLarge }

        let envelope = try? JSONDecoder().decode(Envelope.self, from: data)
        let reject = try? JSONDecoder().decode(RejectEnvelope.self, from: data)

        if http.statusCode == 404 {
            guard reject?.code == RecoveryCode.sessionNotFound else {
                return .contractViolation(status: 404)
            }
            return .sessionNotFound
        }
        if http.statusCode == 400 {
            // ★理由をそのまま運ぶ。言い換えると、撮り直せば直る物と直らない物が
            //   電話側で混ざる(too-many-pixels は撮り直しで直るが unknown-format は直らない)。
            return .rejected(reason: reject?.reason ?? "unknown")
        }
        guard http.statusCode == 200, let id = envelope?.attachmentId else {
            return .contractViolation(status: http.statusCode)
        }
        return .stored(id: id,
                       bytes: envelope?.bytes ?? 0,
                       converted: envelope?.converted ?? false,
                       injected: envelope?.injected ?? false,
                       reason: envelope?.injectReason)
    }

    /// 200 の形。`wire.mjs` の `attachBody` と1対1で突き合わせている。
    ///
    /// ★**絶対パスの欄を持たない。** サーバも返さない設計で、電話が置き場を知る必要が無い。
    ///   欄を作ると、いつか誰かが埋めて、置き場が API に固まる。
    /// ★断りの形(`reason` / `code`)を**この型に混ぜない**。2026-08-26 に一度混ぜて、
    ///   鍵名の突き合わせが「電話にしか無い鍵が2つ」として掴んだ。1つの型で2つの応答を
    ///   受けると、どちらの形が来たのかを型が説明しなくなる。
    private struct Envelope: Decodable {
        let attachmentId: String?
        let bytes: Int?
        let format: String?
        let converted: Bool?
        let injected: Bool?
        let injectReason: String?
    }

    /// 400 / 404 の形。こちらは `attachBody` ではなく、各ルートの断りが直に組む。
    private struct RejectEnvelope: Decodable {
        let reason: String?
        let code: String?
    }
}

/// 結果を人の1文にする。**「送れました」で丸めない。**
enum AttachWording {
    static func text(for outcome: AttachOutcome) -> String {
        switch outcome {
        case let .stored(_, bytes, converted, injected, reason):
            let kb = max(1, bytes / 1024)
            let conv = converted ? " (converted to JPEG)" : ""
            if injected {
                return "Photo sent — \(kb) KB\(conv). The path is in the composer; press send when ready."
            }
            // ★置けたが載っていない。ここを「送れました」にすると入力欄を見た人が混乱する。
            return "Photo saved on the desk — \(kb) KB\(conv) — but the path could not be typed (\(reason ?? "no pane"))."
        case let .rejected(reason):
            switch reason {
            case "unknown-format":  return "That file is not a PNG, JPEG or HEIC image."
            case "too-many-pixels": return "That image is too large in pixels. Try a screenshot instead."
            case "too-large":       return "That image is too big to send."
            case "empty-body":      return "Nothing was attached."
            default:                return "The desk refused the image (\(reason))."
            }
        case .tooLarge:     return "That image is too big to send."
        case .unauthorized: return "The desk rejected the key."
        case .sessionNotFound: return "That conversation is gone."
        case .unreachable:  return "Could not reach the desk."
        case .cancelled:    return "Cancelled."
        case let .contractViolation(status): return "The desk answered in a shape this app does not know (\(status))."
        }
    }
}
