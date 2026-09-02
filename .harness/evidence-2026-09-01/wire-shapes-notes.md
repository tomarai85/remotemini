<!-- session: 2026-09-01 21:5x -->
# 実応答の形の捕捉 — 読み方と、**この計器が守れていない範囲**

`wire-shapes.tsv` は `rc-backend/tools/wire-shape-capture.sh --check` の出力。
電話の `Decodable` が**必須として要求する鍵**と、走っているサーバが**実際に吐いた鍵**の突き合わせ。

## 何故 作ったか

2026-09-01、転写の探索が**出荷前から 100% 壊れていた**。机が探索の応答で項目を生のまま返し、
素の履歴が通る `.map(withWho)` を通していなかったので `display` が無く、電話の
`HistoryEntry.display` は非 optional だから復号ごと落ちる。
★**捕まえた者が木の中に1人も居なかった**: fixture も検体 body も e2e の期待値も、全部
`display` を入れて手で組んである。iOS 834 + backend 1004 + e2e 297 が全部 緑でも、
「机が本当に何を吐くか」は 1 件も測っていなかった。実機へ GET を 1 回 撃った偶然でしか出なかった。

## 今回の結果

- 捕捉 **17 形**(live 9 / local 8)。うち **2 件は恒真**(`DigestEnvelope` は全プロパティが
  Optional = 必須鍵ゼロなので照合が何も言わない)。**実質 15 件**。
- **MISMATCH: 0**。
- 叩けなかった経路は推測で埋めず名前を出した: `live/history.search.entry`
  (本番のその会話で問いに一致が 0 件 = 標本が空)。

## ★計器が「0 件」と言える資格 —— 感度を実測した

3 回直した後の計器の 0 件は、そのままでは信用できない。植えて赤が出る事を見た:

| 植えた変異 | 結果 |
|---|---|
| `historySearchBody` から `.map(withWho)` を外す(= **今日の実欠陥そのもの**) | **赤** `local/local.search.entry HistoryEntry … display` |
| `historySearchBody` から `matched` を落とす | **赤** `local/local.search TranscriptSearchResponse … matched` |
| `historyBody` から `history` を落とす | **赤** `local/local.history HistoryResponse … history` |
| `pollBodyTmux` から `cursor` を落とす | **緑のまま = 捕まえられない**(下記) |

## ★★守れていない範囲(此処を読まずに「全経路 検証済み」と読まない事)

1. **ローカルの砂場が届かない枝は、退行を検出できない。**
   実測: `pollBodyTmux` から `cursor` を落としても `MISMATCH: 0` のままだった。
   理由は照合の欠陥ではなく**被覆**: 砂場に tmux が無いので local の poll は
   `pollBodyWorker` の枝を返し(`display` が無い事で判る)、`pollBodyTmux` を一度も通らない。
   一方 **live の poll は `route=tmux`** なので、其の枝の**形**は観測で検証済み(必須3鍵とも出ている)。
   つまり **形は live で確認できるが、感度は local でしか示せず、その local が当該枝へ届かない。**
   塞ぐ道: 砂場へ偽 tmux を噛ませる(`test/e2e-local.mjs` が既に持っている機構)。未実施。

2. **書込み経路(POST / DELETE)を 1 本も捕捉していない。**
   本番へは GET しか撃たない規約なので、`messages` / `interrupt` / `choice` / `attach` /
   `queue` / `new` / `title` / `archive` / `return-request` / `account/select` / `account/next` の
   応答の形は**未測定**。表に行が無いのは「一致した」ではなく「見ていない」。

3. **恒真の 2 件は検証ではない。** `DigestEnvelope` は必須鍵ゼロなので、机が何を返しても通る。

4. **必須性の判定は Swift の静的解析**(`init(from:)` の `decode` / 非 Optional の格納プロパティ)。
   3 つの誤りを自分で見つけて直した — 修飾名 `A.B` を短名で解決して別の同名型に当たった /
   入れ子の子プロパティが親に混ざった / `var x: T { … }` の計算プロパティを格納と数えた。
   ★**3 つとも「机の欠陥」の顔で出た**(`HealthzClient.Wire` が口座の鍵を要求、
   `SessionRow` が `displayTitle` を要求 等)。**赤を見たら、まず計器を疑う。**
   Codex の第二の目を通そうとしたが 220s で timeout。道具自身が「PASS と扱うな」と言うので
   受領書は書いていない。まだ当たっていない Swift の書き方(property wrapper /
   デフォルト値つき / 型別名 / `init(from:)` の委譲)は**未検証**。
