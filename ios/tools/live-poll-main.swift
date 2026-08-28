import Foundation

// 実機で `PollClient` を1回だけ走らせる為の入口。**製品には入らない**
// (`ios/tools/` に置いてあり、アプリの target からは参照されない)。
// `ios/tools/live-poll-check.sh` が `Sources/Core/{PollClient,PollCursor,ReadablePoll,
// BackendSession,...}.swift` と一緒に swiftc へ渡して建てる。
//
// なぜ要るか(2026-08-27): 電話の主要3経路のうち、読み(`SessionsClient`/`HistoryClient`)と
// 書き(`SendClient`)と割り込み(`InterruptClient`)は本物のサーバへ当てた事が在るのに、
// **受け取り(`PollClient`)だけ一度も無い**。Tom が Claude の答えを見るのは此の経路で、
// 単体では `MockURLProtocol` としか繋がっていない。
//
// ★入力は stdin の3行(URL / 会話 id / 鍵)。argv には置かない —— argv は `ps` に出る。
//   環境変数にも置かない —— `ps -E` と子プロセスに漏れる。鍵は読んだ後どこにも印字しない。
//   ★この file には既定のホストを書かない(書くと製品外の写しが「本番はここ」を語り出す)。
//
// 出す物: 分岐の名前と**数**だけ。会話の中身は1文字も出さない
// (poll が運ぶのは Tom と Claude のやり取りその物なので、記録に残す物ではない)。
// 終了コード: 0 = 読める応答が届いた / 1 = 契約違反・401・404 など / 2 = 入力が足りない

@main
enum LivePoll {
    /// ★stdin は一度しか読めない。読んだ物を持っておく —— 初版は `readLines` を
    ///   2 度呼ぶ形で書きかけ、2 度目が必ず空になる(同じ罠を此処で止める)。
    static var stdinLines: [String] = {
        guard let all = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) else { return [] }
        return all.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }()

    static func readAllLines() -> [String] { stdinLines }

    static func readLines(_ n: Int) -> [String]? {
        let lines = stdinLines
        guard lines.count >= n else { return nil }
        return Array(lines.prefix(n))
    }

    static func main() async {
        guard let input = readLines(3), let baseURL = URL(string: input[0]) else {
            FileHandle.standardError.write(Data("入力は stdin の3行(URL / 会話 id / 鍵)、任意で4行目に撃つ cursor\n".utf8))
            exit(2)
        }
        let sessionID = input[1]
        let apiKey = input[2]

        // ★4行目(任意)= **こちらから撃つ cursor**。2026-08-28 に足した。
        //   無ければ従来通り空 = 「今在る物を全部くれ」。
        //   在れば **1回だけ**撃って、返って来た物の分岐と gap の理由を出して終わる ——
        //   壊れた cursor を渡した時の振る舞いを測る為の口で、2回目の往復は測らない。
        let all = readAllLines()
        let injected: String? = all.count >= 4 && !all[3].isEmpty ? all[3] : nil
        if let raw = injected {
            let one = await PollClient().poll(baseURL: baseURL, apiKey: apiKey,
                                              sessionID: sessionID,
                                              cursor: PollCursor(raw: raw), waitMs: 2000)
            switch one {
            case .success(let r):
                // ★gap の**理由だけ**を出す。会話の中身は1文字も出さない。
                //   理由は閉じた語彙(`GapWhy`)なので、出しても自由文が漏れない。
                let gaps = r.items.compactMap { item -> String? in
                    if case .gap(let g) = item { return "\(g.why)" }
                    return nil
                }
                print("injected=success items=\(r.items.count) gaps=\(gaps.joined(separator: ","))")
                exit(0)
            default:
                print("injected=\(one)")
                exit(1)
            }
        }

        // ★空の cursor から始める = 「今在る物を全部くれ」。待ちは短くする ——
        //   此の殻が測るのは「読める応答が届くか」であって、長ポーリングの粘りではない
        //   (粘りは `BackendSession` の予算の検査が別に押さえている)。
        let outcome = await PollClient().poll(baseURL: baseURL, apiKey: apiKey,
                                              sessionID: sessionID,
                                              cursor: PollCursor(raw: ""), waitMs: 2000)
        switch outcome {
        case .success(let r):
            // ★2026-08-27、Codex 指摘で足した2回目。1回だけの poll は「200 が JSON の形で
            //   返る」しか言っておらず、**状態を持つ受け取り経路**(cursor の進み)を
            //   一度も触らない。サーバが返した cursor をそのまま撃ち返して、
            //   **サーバが自分の出した cursor を受け取る**事まで見る。
            //   これが破れる時の症状は「一度は読めるが二度目から進まない」= 電話が
            //   最初の1画面で固まる形で、初回 poll だけの検査では緑のまま通る。
            let second = await PollClient().poll(baseURL: baseURL, apiKey: apiKey,
                                                 sessionID: sessionID,
                                                 cursor: r.cursor, waitMs: 2000)
            // ★数と分岐だけ出す。`items` の中身は会話その物なので1文字も出さない。
            switch second {
            case .success(let r2):
                print("outcome=success items=\(r.items.count) second=success items2=\(r2.items.count)")
                exit(0)
            default:
                print("outcome=success items=\(r.items.count) second=\(second)")
                exit(1)
            }
        case .unreadable:
            // 200 は返ったが、電話の二段読み(`ReadablePoll.check` → 型付き decode)が
            // 「見せてよい形ではない」と言った。**これは赤**であって網の問題ではない。
            print("outcome=unreadable")
            exit(1)
        case .unauthorized:
            print("outcome=unauthorized(401)")
            exit(1)
        case .sessionNotFound:
            print("outcome=sessionNotFound(404)")
            exit(1)
        case .unreachable:
            print("outcome=unreachable")
            exit(1)
        case .cancelled:
            print("outcome=cancelled")
            exit(1)
        }
    }
}
