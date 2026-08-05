# DoD 9行目 —— 電話の送信路を本物の rc-backend へ当てた(2026-08-05)

走らせた物: `ios/tools/live-send-check.sh`。
送る側 = Jervis(`swiftc` で建てた殻。中身は**製品の Swift そのもの**)、
建てる側 = edith(本番の rc-backend、`tailscale serve` 経由の tailnet https)。

この file には**会話 id もアカウントのメールも写さない**。

---

## 何を「実機」と呼んだか

モックを外した所が3つある。3つ揃って初めて「電話のコードが本物に当たった」と言える:

| 外した物 | 前 | 今回 |
|---|---|---|
| HTTP の相手 | `MockURLProtocol` | 本物の rc-backend(tailnet https) |
| 送る主体 | テストが組み立てた body | 製品の `SendClient.send(...)` |
| 画面の言葉 | 固定の期待値 | サーバが返した `display` をそのまま印字 |

殻(`ios/tools/live-send-main.swift`)は `Sources/Core/` の
`SendClient.swift` / `ResultDisplay.swift` / `BackendSession.swift` を**アプリと同じ file のまま**
一緒に建てている。写しではない。

## 観測(3走目、最終)

```
=== 1. 電話側の殻を建てる(製品の Swift をそのまま使う) ===
ok: 150000 bytes
=== 2. edith に使い捨ての本物 TUI を建てる ===
建てる場所: /private/tmp(信頼済み)
起動 ok(1038ms) セッション=rc-e2e-<数字>
登録 ok(0ms)
=== 3. 送る前の転写の行数 ===
before = 0 行
=== 4. 電話のコードで送る ===
outcome=display kind=ok tone=ok keepText=false
text=送った
終了コード = 0
=== 5. 送った本文が転写に着いたか ===
行数 = 8(送る前 0) / 本文の一致 = 1 件
陰性対照(送っていない本文)= 0 件
=== 判定 ===
  ok  : 電話のコードが display を受け取った
  ok  : kind=ok
  ok  : keepText=false(= サーバは verified と言っている)
  ok  : 送った本文が転写に 1 件 居る(行数は 0 → 8)
  ok  : 陰性対照 0 件(数える口は生きている)
→ DoD 9行目: 観測で閉じた
```

`kind=ok` + `keepText=false` が、電話から見た `delivered:"verified"` の顔である事は
`src/view.mjs` の対応表による(生の `delivered` 文字列は §0-d の走行で既に観測済)。

## ★1走目で踏みかけた型 —— 「増えた」を「着いた」と読む

1走目の判定は **`after > before`(0 → 7 行)** で ok を出していた。これは測定になっていない:

- 使い捨ての会話は**転写が無い所から始まる**(`before = 0` は「0 行の file」ではなく「file が無い」)。
- 起動そのものが数行書く。だから「増えた」は**私の本文が着いた事を意味しない**。

直した形: 一意な本文(`rc-live-send probe <時刻>`)を**転写の中で数える**
(`disposable-session.mjs contains`、返るのは件数だけ)。
更に、送っていない本文が **0 件**で返る事を同じ口で確かめる(陰性対照)。
これが無いと「数える口が壊れていて常に1件以上」を検出できない。

## 同じ走行で潰した観測ノイズ

- `tmux has-session` の `can't find session: …` が、**成功した走行の真ん中に2回**出ていた。
  これは「そんなセッションは無い」= 答えであって異常ではないのに、log の中では失敗の顔をする。
  `tmuxOk` の stderr を捨てた。
- 起動 1034ms / 登録 0ms は速すぎて疑ったが、`classifyScreen` は空画面もシェルの促しも
  `UNKNOWN` を返す(実測)。`SENDABLE` は本物の入力欄でしか出ない = 偽陽性ではない。

## ★rsync が「転送した」と言って**手元に**書いていた(この案件で最も危ない発見)

macOS の `/usr/bin/rsync` は openrsync。**相対の遠隔パス**を渡すと:

```
rsync -av tools/disposable-session.mjs edith@<host>:rc-backend/tools/
  → "sent 10775 bytes … total size is 10632"(成功の顔、終了コード 0)
  → 遠隔には無い。手元に `rc-backend/mail-redacted@example.invalid-backend/tools/` が生えていた
```

絶対パス(`:/Users/edith/rc-backend/tools/…`)なら正しく着く。

- 捕まえたのは `no-linerefs.test.mjs` の「走査の範囲が木の直下と一致している」。
  木に黙って dir が増えた事を検査していたので、**私が気付く前に赤くなった**。
- 一般化: **`sent … bytes` は「相手に着いた」の証拠ではない**。この案件で毎回 sha256 を
  両側で突き合わせているのはこの為で、今回それが唯一の検出手段だった
  (突き合わせ無しなら「synced」と書いて次へ進んでいた)。
- 迷子の dir は中身が手元の原本と sha256 一致 = 外から来た物ではない事を確かめた上で撤去、不在を確認。

## 後始末(edith に恒久物を残さない)

1走目・2走目は `~/.claude/projects/` に**転写を2本置き去りにしていた**。線を私自身が破っていた。

- 置き去りの2本: 本文の印(`rc-live-send probe`)で**完全一致だけ**を選んで撤去、0 本を確認。
- 再発を止めたのは道具側: `disposable-session.mjs down … --purge-transcript`。
  **既定では消さない** —— 転んだ走行の転写は人が次に読む唯一の物なので、
  `live-send-check.sh` は**判定が緑だった時だけ**この旗を渡す。
- 走行後の edith: 印つき転写 0 本 / `rc-e2e` の tmux 0 本 / `heads/` 0 本。

`panes/` に「直近2時間に触られたが死んだペイン」が **3 本**在るが、
`tmux` 欄に `rc-e2e` の印が **0 本** = **私の物ではない**。所有者が分からない物は消さない(そのまま置いた)。

## この走行で足した物

- `rc-backend/tools/disposable-session.mjs`(新規): `up` / `lines` / `contains` / `down`。
  名前は `rc-e2e-<数字6桁以上>` の形しか建てず、その形しか畳まない(Tom の実セッションに触る道が無い)。
  信頼は**読むだけ**で、与える道はこの file の何処にも無い。
- `ios/tools/live-send-main.swift`(既出) と `ios/tools/live-send-check.sh`(新規)。
  鍵は stdin にしか流さない(argv は `ps` に出る / 環境変数は子に漏れる)。印字もしない。

## 手元の検査

`npm test` = **681/681 緑**(道具を足した後に再走行)。
