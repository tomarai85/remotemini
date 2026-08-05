import Foundation

// 実機で `SendClient` を1回だけ走らせる為の入口。**製品には入らない**(`ios/tools/` に置いてあり、
// アプリの target からは参照されない)。`ios/tools/live-send-check.sh` が
// `Sources/Core/{SendClient,ResultDisplay,BackendSession}.swift` と一緒に swiftc へ渡して建てる。
//
// なぜ要るか: 電話の送信路(`SendClient`)は**単体でしか動いた事が無い**。相手は
// `MockURLProtocol` で、本物の rc-backend に一度も繋がっていない。Sprint 5 の DoD 9行目は
// 其処を「実機で」と書いている。SwiftUI のアプリを立ち上げずに同じ**製品コード**を
// 本物のサーバへ当てる為の、最小の殻がこれ。
//
// ★入力は stdin の3行(URL / 会話 id / 鍵)。argv には**置かない** —— argv は `ps` に出る。
//   環境変数にも置かない —— `ps -E` と子プロセスに漏れる。鍵は読み込んだ後どこにも印字しない。
//   ★この file には既定のホストを書かない(書くと製品外の写しが「本番はここ」を語り出す)。
//
// 出す物: 分岐の名前と `display` の中身だけ。鍵は勿論、送った本文も出さない
// (本文は人の打った物 = 記録に残す物ではない)。
// 終了コード: 0 = `display` が届いた / 1 = 契約違反・401・404 など / 2 = 入力が足りない・届かない

// ★`main.swift` という名前にはしない(top-level code が書ける代わりに、`ios/tools/` の
//   中に「main」を名乗る file が生まれる)。`@main` + `static func main() async` なら
//   非同期をそのまま書けるので、待ち合わせの為の semaphore も要らない。
@main
enum LiveSend {
    static func readLines(_ n: Int) -> [String]? {
        guard let all = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) else { return nil }
        let lines = all.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= n else { return nil }
        return Array(lines.prefix(n)).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func main() async {
        guard let input = readLines(4),
              let baseURL = URL(string: input[0]),
              !input[1].isEmpty, !input[2].isEmpty, !input[3].isEmpty
        else {
            FileHandle.standardError.write(Data("使い方: stdin に4行(URL / 会話 id / 鍵 / 本文)\n".utf8))
            exit(2)
        }
        let sessionID = input[1]
        let apiKey = input[2]
        let text = input[3]

        let outcome = await SendClient().send(baseURL: baseURL, apiKey: apiKey, sessionID: sessionID, text: text)
        switch outcome {
        case .display(let d):
            // `keepText` の**不在**と `false` を潰さない(電話は不在を「残す」と読む)。
            let keep = d.keepText.map { String($0) } ?? "(欄なし)"
            print("outcome=display kind=\(d.kind) tone=\(d.tone) keepText=\(keep)")
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
            print("outcome=unreachable(応答が届いていない。送れたかどうかは不明)")
            exit(2)
        case .cancelled:
            print("outcome=cancelled")
            exit(2)
        }
    }
}
