import Foundation

// 実机の探索 + 跳びを**製品の Swift**で測る殻(2026-09-03、対照表 #3 の live 検査)。
// stdin 3 行: URL / 会話 id / 鍵。出力は `kind=...` の 1 行 + 説明。終了コード 0 = 観測で閉じた。
//
// 測る鎖: HistoryClient.fetch(limit 1) で最新の項目の語を取る → search(其の語) → 当たりは anchor と fromEnd を持つ
//         → fetch(limit: fromEnd + 1) の窓に同じ anchor が居る(= 電話の jump が読み足す数が正しい)
//         → 陰性対照: 当たり得ない語は matched 0。
@main
enum LiveSearch {
    static func readLines(_ n: Int) -> [String]? {
        guard let all = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) else { return nil }
        let lines = all.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= n else { return nil }
        return Array(lines.prefix(n)).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func main() async {
        guard let input = readLines(3), let baseURL = URL(string: input[0]), !input[1].isEmpty, !input[2].isEmpty else {
            FileHandle.standardError.write(Data("使い方: stdin に3行(URL / 会話 id / 鍵)\n".utf8))
            exit(2)
        }
        let sid = input[1], key = input[2]
        let client = HistoryClient()

        // 1. **古い**項目から探す語を取る(末尾 40 件の一番古い物)。最新の項目だと fromEnd = 0 になり、
        //    「1 本少ない窓には居ない」の対照が空振りする。古い項目なら fromEnd が数十になり、読み足しの数が本当に測れる。
        guard case .success(let latest) = await client.fetch(baseURL: baseURL, apiKey: key, sessionID: sid, limit: 40),
              let oldest = latest.history.first(where: { $0.role != .tool }) else {
            print("kind=ng step=fetch-latest"); exit(1)
        }
        let words = oldest.text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init).filter { $0.count >= 3 }
        guard let query = words.first else { print("kind=ng step=no-word text=\(oldest.text.prefix(20))"); exit(1) }

        // 2. 探す → 当たりは anchor + fromEnd を持つ
        guard case .success(let found) = await client.search(baseURL: baseURL, apiKey: key, sessionID: sid, limit: 5, query: query) else {
            print("kind=ng step=search"); exit(1)
        }
        guard found.matched > 0, let hit = found.history.first(where: { $0.anchor != nil && $0.fromEnd != nil }),
              let anchor = hit.anchor, let fromEnd = hit.fromEnd else {
            print("kind=ng step=no-anchored-hit matched=\(found.matched)"); exit(1)
        }

        // 3. 跳びの読み足し: limit = fromEnd + 1 の窓に同じ anchor
        guard case .success(let window) = await client.fetch(baseURL: baseURL, apiKey: key, sessionID: sid, limit: fromEnd + 1) else {
            print("kind=ng step=fetch-window"); exit(1)
        }
        let inWindow = window.history.contains { $0.anchor == anchor }
        // 対照: 1 本足りない窓には居ない(fromEnd が 1 ずれていない)。fromEnd == 0 なら窓 0 は無いので飛ばす。
        var shortMiss = true
        if fromEnd > 0, case .success(let short) = await client.fetch(baseURL: baseURL, apiKey: key, sessionID: sid, limit: fromEnd) {
            shortMiss = !short.history.contains { $0.anchor == anchor }
        }

        // 4. 陰性対照
        let decoy = "zzqx\(Int(Date().timeIntervalSince1970))"
        var negMatched = -1
        if case .success(let none) = await client.search(baseURL: baseURL, apiKey: key, sessionID: sid, limit: 5, query: decoy) {
            negMatched = none.matched
        }

        let ok = inWindow && shortMiss && negMatched == 0
        print("kind=\(ok ? "ok" : "ng") matched=\(found.matched) fromEnd=\(fromEnd) inWindow=\(inWindow ? 1 : 0) shortMiss=\(shortMiss ? 1 : 0) neg=\(negMatched) query=\(query.prefix(12))")
        exit(ok ? 0 : 1)
    }
}
