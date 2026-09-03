# Codex review — 状態帯の `38.7k ctx`(対照表 #14-16 の残り、74815cb)— 2026-09-03

- 走らせ方: `codex exec --sandbox read-only --skip-git-repo-check`(gpt-5.6-sol / xhigh)。3 回目で完走
  (1・2 回目は chatgpt backend の 404 で落ちた。回線は netwhy 全層健全)。生の log = `codex-ctx-review.raw.log`
  (4332 行、rc=0。loop の receipt は其の sha)。
- 判定: **要修正**。3 項の和は「直近 API 要求の総入力 token」としては正しいが、`/context` の「現在値」ではない。

## 所見(要約。場所は 74815cb 時点の関数名)

| # | 重さ | 何処 | 何が起きるか | 最小の直し |
|---|---|---|---|---|
| 1 | P1 | `contextTokensOf` / 電話の `line` | 最終応答の output・其の後の tool result・hook は含まれない(1 turn 遅れ)。tool loop 中は途中の値。**compaction 直後は次の API 呼び出しまで pre-compact の巨大な usage を拾う**。転写の `compact_boundary` レコードは `compactMetadata.postTokens` を持つのに無視 | 名前を「last input」に改めるか、compaction 境界の `postTokens` を採る |
| 2 | P1 | `digestOf` の早期 return(`scan-budget` / `too-many-records`)| 末尾は読めているのに `sessionOf` の前に return する = **重い会話ほど session facts が出ない**。さらに `incomplete()` の既定 `session` に `contextTokens` 鍵が無い(wire-key の検体は手製なので隠れた) | 早期 return の前に facts を取り `incomplete(..., session)` へ渡す。既定に `contextTokens: null` |
| 3 | P2 | `contextTokensOf` / 後方走査 | role を見ない(後発の任意レコードの usage が勝つ)/ 負数を捨てて残りを足す(部分和)/ 全ゼロ usage を有効な 0 として走査を止める(実転写に全ゼロ行と同一 message id の重複行が在る)/ `1e308` や `MAX_SAFE_INTEGER` で Infinity・精度落ち | assistant のみ。3 項とも非負の safe integer を必須、和も safe・正・妥当上限内のみ採用。全ゼロは無効として走査継続 |
| 4 | P2 | `SessionDigest.Session.compact` / Decodable | `-1` を「-1 ctx」と描く。`Int.max` は `n + 50` で trap。Int 範囲外の JSON 数は **digest 全体の decode を落とす** | lossy に decode して非負・上限で検証、丸めは商と余りで |

検査が守れていない点(Codex の言): 「compact で減る」検査は普通の assistant 2 行で `compact_boundary` を通していない / 欠損項目の部分和を正解として固定 / `NaN` は JSONL に存在できない / wire-key の検体が手製で `incomplete()` の鍵欠けを隠す / Swift 検査に負数・`Int.max`・型不正が無い。

Clean(Codex の言): 3 項和そのもの、`99,950 → 100k` の丸め、parallel tool-use を累計しない点、subagent の転写が別 file で主会話へ混ざらない点。

## 私の読み

- 2 は実バグ(鍵の欠けは電話の decode を壊さないが、重い会話で帯が消える)。先に直す。
- 3・4 は fail-open の類。実転写に全ゼロ行が在る以上、走査停止は実害。
- 1 は「何を名乗るか」。`compact_boundary` の `postTokens` を採って compaction 直後の嘘を消し、
  意味は「直近の要求の入力の大きさ(1 turn 遅れ)」と註に書く。`ctx` の綴りを変えるかは Tom の裁定
  (表示語の好み)。
