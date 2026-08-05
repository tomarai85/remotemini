import Foundation

// 実機で `InterruptClient` を1回だけ走らせる為の入口。**製品には入らない**(`ios/tools/` に置いてあり、
// アプリの target からは参照されない)。`ios/tools/live-interrupt-check.sh` が
// `Sources/Core/{InterruptClient,SendClient,ResultDisplay,BackendSession}.swift` と一緒に
// swiftc へ渡して建てる(`SendOutcome` は `SendClient.swift` に居るので一緒に要る)。
//
// なぜ要るか: Sprint 6 の割り込み路は**単体でしか動いた事が無い**。相手は `MockURLProtocol` で、
// 本物の rc-backend に一度も繋がっていない。DoD 9行目は其処を「実機で」と書いている。
//
// ★入力は stdin の3行(URL / 会話 id / 鍵)。argv には**置かない** —— argv は `ps` に出る。
//   環境変数にも置かない —— `ps -E` と子プロセスに漏れる。鍵は読み込んだ後どこにも印字しない。
//   ★この file には既定のホストを書かない(書くと製品外の写しが「本番はここ」を語り出す)。
//
// 出す物: 分岐の名前と `display` の中身だけ。`display.text` は**サーバが書いた文**なので出してよい
// (電話側で組み立てた文ではない事は `SendBanner.fromServer` が型で持っている)。
// 終了コード: 0 = `display` が届いた / 1 = 契約違反・401・404 など / 2 = 入力が足りない・届かない
@main
enum LiveInterrupt {
    static func readLines(_ n: Int) -> [String]? {
        guard let all = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) else { return nil }
        let lines = all.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= n else { return nil }
        return Array(lines.prefix(n)).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func main() async {
        guard let input = readLines(3),
              let baseURL = URL(string: input[0]),
              !input[1].isEmpty, !input[2].isEmpty
        else {
            FileHandle.standardError.write(Data("使い方: stdin に3行(URL / 会話 id / 鍵)\n".utf8))
            exit(2)
        }
        let sessionID = input[1]
        let apiKey = input[2]

        let outcome = await InterruptClient().interrupt(baseURL: baseURL, apiKey: apiKey, sessionID: sessionID)
        switch outcome {
        case .display(let d):
            // ★`keepText` は**出さない**。割り込みには入力欄の本文が懸かっていないので、
            //   此処に印字すると「割り込みも欄を触る」という読み方を作る
            //   (`InterruptClient` の見出しが、その欄を読まない事を明記している)。
            print("outcome=display kind=\(d.kind) tone=\(d.tone)")
            print("text=\(d.text)")
            exit(0)
        case .unauthorized:
            print("outcome=unauthorized(401)")
            exit(1)
        case .sessionNotFound:
            print("outcome=sessionNotFound(404+SESSION_NOT_FOUND)")
            exit(1)
        case .contractViolation(let v):
            print("outcome=contractViolation status=\(v.status) code=\(v.code ?? "(無)")")
            exit(1)
        case .unreachable:
            print("outcome=unreachable(応答が届いていない。押せたかどうかは不明)")
            exit(2)
        case .cancelled:
            print("outcome=cancelled")
            exit(2)
        }
    }
}
