# Sprint 6 ブリーフ — 割り込み + ネットワーク堅牢化(2026-08-05 発行)

対象 = 仕様 `spec-native-shell-2026-08-05.md` の Sprint 6 行:
「interrupt + ネットワーク堅牢化: `POST …/interrupt`、`display`(系統B)描画、
N5 redirect 拒否の負の対照検査、backend-unreachable バナー(§5-4)全画面適用」。

v1 の owner 発話「1. 一覧 2. 履歴 + ライブの流れ 3. 打ち込む 4. **割り込む**」の
**4 が閉じる**。Sprint 5 で 3 が閉じたので、これで v1 の 4 機能が揃う。

---

## §0. 契約の実測(2026-08-05、`src/server.mjs` / `src/view.mjs` / `src/inject.mjs` を逐語で読んだ)

Sprint 5 の §0 と同じ性格 —— **source の読み**であって線の上の観測ではない。
実機行(§5 の DoD 最終行)はこの読みだけでは閉じない。

### §0-a. `POST /api/sessions/<id>/interrupt` の契約(実装から)

要求本文は**読まれない**(ハンドラは `resolvePane()` しか見ない)。

| 応答 | 条件 | 本文の主な欄 |
|---|---|---|
| 409 | 宛先を確定できない(`UNDECIDABLE`) | `error`(日本語)、`route:"blocked"` ほか |
| 200(tmux) | ペインへ Escape を送った | `interrupted`, **`stopped`**, `reason`, `waitedMs`, `route:"tmux"`, `pane` |
| 200(worker) | 机で開かれていない会話 | `interrupted`, `route:"worker"` —— **`stopped` を載せない** |
| 401 / 404 / 5xx | 送信と同じ | 送信と同じ |

`stopped` の値域は 4 つ(`inject.mjs` の `#interruptExclusive`):

| `stopped` | 意味 | `interrupted` |
|---|---|---|
| `"verified"` | 止まったのを見た(印が増えた / 進行の印が消えて戻らない) | `true` |
| `"already-done"` | 押した時には自力で終わっていた = **止めていない** | `false` |
| `"unverified"` | 動いていたが期限内に止まりを観測できない = **まだ止まっていない** | `false` |
| `null` | 押す前から生成の印が無かった | `false` |

### §0-b. ★`interrupted` は「押した事」ではなく「止まった事」

`interrupted: out.stopped === "verified"` の 1 行がそれ。
2026-08-03 以前は Escape を送れたら必ず `true` で、**止まっていないのに
「止めました」と出ていた**。電話はこの区別を**再発明しない** —— `display` を出すのは
サーバ(`speaks(res, interruptResult)`)で、電話は `display.text` を逐語で描く。

### §0-c. `interruptResult` の分岐(`view.mjs`、電話が描く文言の出所)

| 入力 | `kind` | `text` |
|---|---|---|
| 200 / 本文が読めない | `warn` | 「止めたかどうか確認できませんでした。…」 |
| 200 / `stopped:"verified"` | `ok` | 「止めました(生成が止まったのを確認)。」 |
| 200 / `stopped:"already-done"` | `ok` | 「押した時には終わっていました(…)。」 |
| 200 / `stopped:"unverified"` | `warn` | 「Escape は押しましたが、まだ止まっていません。…」 |
| 200 / `stopped:null` | `warn` | 「止める対象が見当たりませんでした(Escape は押しました)。」 |
| 200 / `stopped` の欄が**無い**(worker) | `ok`/`warn` | `interrupted` の真偽で2択 |
| 409 | `refused` | `b.error` |
| 401 | `error` | 「鍵が通りませんでした。」 |
| 5xx / それ以外 | `error` | HTTP 番号入りの固定文 |

★**worker 経路の見分けは `stopped` の欄の有無**(`hasOwnProperty`)であって値ではない。
`stopped:null`(tmux)と `stopped` 欄なし(worker)は**別の文言**になる。
これはサーバ側の分岐なので電話は触らないが、検査の駆動本文を書く時に取り違えると
「4 分岐を見た」と言いながら 3 分岐しか見ない事になる。

### §0-d. `keepText` は無い

`interruptResult` が返すのは `{kind, text}` だけ。送信と違って入力欄には触らない。
送信で作った `ResultDisplay` / `SendBanner` の型はそのまま再利用できる。

### §0-e. ★★出荷前に潰す衝突 —— 割り込みは CHOICE 画面にも Escape を打つ

**これが今回一番効く発見で、実装より先に裁定が要る。**

- `server.mjs` の interrupt ハンドラは `screen` を**条件にしない**。決められるペインなら
  `injector.interrupt(pane)` を呼ぶ。
- `inject.mjs` の `#interruptExclusive` は `tmux send-keys -t <pane> Escape` を
  **無条件で**撃つ。hard-stop / 許可確認の判定は**通らない**(`choice.mjs` の
  `classifyChoice` はこの経路に居ない)。
- 許可・信頼の確認画面は番号付き選択肢を持つので `classifyScreen` では
  **`state:"CHOICE"`** になる(`menuAt` 経由)。

つまり **CHOICE 画面で有効な割り込みボタン = 電話から許可確認へ Escape を打つ口**である。
それは `DESIGN.md` §2.29-f と `src/choice.mjs` 冒頭が「**採っていない・Tom の裁定待ち**」と
名指しで保留している、まさにその能力:

> 「良性と同定できない画面へ `Escape` だけは送る(= 明示的な拒否)」は**採っていない**。
> Escape の向きは取り消しなので裁定の字面には触れないが、D4 は hard-stop を
> 「電話へ通知のみ・承認ボタン無し」と書いており、**画面に操作を出す事自体**を断っている。

仕様 §5-3 の表は `screen==="CHOICE"` の行で割り込みを **有効**と書いている。
だがその根拠欄は「`interrupt` ハンドラは `screen` を条件にしない」= **サーバの挙動の記述**で、
D4 にも §2.29-f にも触れていない。**裁定した跡ではなく、受け継いだ跡**である。
(仕様は DESIGN より新しいので普通なら仕様が勝つ。ここで勝たせないのは、
この行が問いを**見た上で**答えた形跡が無いから。)

さらに Sprint 5 で既に出荷済みの文言がこれを前提にしている:

```
composerDisabledReason(.choice) = "v1 では電話から選べません。机で確認するか、割り込みで中断してください"
```

—— 割り込みを CHOICE で無効にすると、**この文が嘘になる**。両方を同じスイッチで動かす。

**この Sprint の既定は禁止側**(`interruptEnabled` は `.choice` で `false`)。理由:
Codex(2026-08-03)の裁定が「拒否操作を許したいなら、D4 を『承認は禁止、明示的な拒否は可』と
**持ち主が**再定義する必要がある。開発側の解釈だけで広げるべきではない」で、
私の推奨(Yes)はあくまで推奨だから。

★**Tom が Yes と言ったら変わるのは 2 箇所だけ**にしておく:
`ConversationViewModel.interruptEnabled` の `.choice` の枝と、
`composerDisabledReason(.choice)` の文言。片方だけ動かせない形にする(§3 の対照で縛る)。

---

## §1. この Sprint で作らない物

- CHOICE 画面への**回答**(`POST …/choice`)。仕様 D-A で v1 スコープ外。
- 送信待ちキューの表示・取消(`DELETE …/queue`)。v1 の 4 機能に無い。
- `src/` は触らない。今回は電話側だけ。

## §2. 作る物

### §2-a. `InterruptClient`(`ios/Sources/Core/`)

`POST /api/sessions/<id>/interrupt`、body 無し。`BackendSession` を取る(N5)。
返す型は `SendOutcome` を**再利用しない** —— 送信と失敗語彙が違う所が 1 つある:
割り込みには「入力欄をどうするか」が無い。だが `unauthorized` / `sessionNotFound` /
`contractViolation` / `unreachable` / `cancelled` / `display` の 6 つは同じなので、
**`SendOutcome` をそのまま使う**方が site ごとの「この case は起こりうるか」を増やさない。
—— 判断: 再利用する。`SendClient` の doc に書いた「本当に同じ失敗様式か」の基準で、
今回は同じ(404 の 2 意味も 401 の経路性もそのまま当てはまる)。

### §2-b. `ConversationViewModel` の割り込み

- `interruptEnabled`(§0-e の既定 = `.choice` で `false`、他は `true`)
- `interruptDisabledReason`(`.choice` の時だけ文言。`composerDisabledReason` と同じ規律)
- `isInterrupting` / `interrupt()` / `applyInterruptOutcome(_:)`
- バナーは `sendBanner` と**別の欄**にする(`interruptBanner`)。同じ欄に入れると
  送信の結果が割り込みの結果に上書きされて、どちらの返事か読めなくなる。

### §2-c. §5-4 の共通バナーを 1 箇所へ

現状: `ListViewModel` は `unreachableThreshold = 3` を持ち `.unreachable(priorSessions:)` を出す。
`ConversationViewModel` は経路で別々に振る舞う ——

| 経路 | 現状 | 問題 |
|---|---|---|
| 初回読み込み(`applyInitialLoad`) | `.failure(.unreachable)` を **1 回で** `phase = .unreachable` | 閾値が無い(§5-4 は連続3回) |
| 「前を読む」(`applyLoadEarlier`) | `.stalledRetry`(ボタンは残る) | ここは妥当 |
| **poll 中(`applyPollStep`)** | **`.unreachable` の腕は `return true` だけで、何も変えない** | ★会話の途中で backend を失った電話が、**古い画面を黙って映し続ける** |

見た目も `ListView` の private な `BannerStyle` に閉じている。

仕様 §5-4 は「**連続3回**」「List/Conversation 共通のコンポーネントとして文言・見た目を
1 箇所にまとめる」「復帰(1回でも成功)したら即座に消す」。よって:

1. 失敗の連続回数を数える計器を 1 つの型へ出す(List の閾値 3 が正)。
2. バナー View を共通コンポーネントへ出し、両画面がそれを使う。
3. **§5-5(読めない配信)と混ぜない**。仕様が「片方をもう片方で代用しない」と名指しで
   禁じている —— 代用した瞬間、200 で返る壊れた配信が「接続は健全」に見える。

### §2-d. N5 の負の対照を全 client へ

現状 302 を撃っているのは `PollClientTests` だけ(`RedirectRefusalTests` は delegate 単体)。
`SessionsClient` / `HistoryClient` / `SendClient` / `HealthzClient` / `SessionsAuthProbe` /
新しい `InterruptClient` にも 302 + `Location: https://…invalid/` を流し、
**追わない事**と**想定外の応答として分類される事**の両方を見る。

## §3. 必須の負の対照(これが無い検査は受け取らない)

- **`stopped` の 4 値が別々の文言になる事**。1 つでも同じ文言に落ちたら赤。
  特に `already-done` を `verified` と同じ「止めました」に混ぜると、**止めていないのに
  止めたと言う**(サーバが 2026-08-03 に直した誤りの再発明)。
- **`stopped` 欄なし(worker)と `stopped:null`(tmux)が別の文言になる事**。
  欄の有無で見分けている以上、`String?` に潰した瞬間に区別が消える(§0-c ★)。
- **割り込みバナーが送信バナーを潰さない事**、およびその逆。両方を続けて出して、
  2 つとも読める事を見る。
- **§5-4 が 3 回目で初めて出る事**(2 回では出ない)+ **1 回の成功で即座に消える事**。
  片側だけだと「常に出す」実装が緑で通る。
- **§5-4 と §5-5 が互いを代用しない事**: HTTP は成功しているが読めない応答を連続で流して、
  赤バナーが**出ない**事(段階表示だけが出る)。逆向きも。
- **`interruptEnabled` が定数でない事** + **`.choice` の 2 箇所が同時に動く事**
  (§0-e の片肺化防止)。

## §4. 引き継いだ制約(破ると commit の門で止まる、または後で高く付く)

- **行番号で書類を引かない**(`doc-linerefs` の門)。錨は関数名・特徴のある文字列。
- 新しい対照 file は 2 行目に `# controls-for:` を書く。
- `display` の文言を電話側で創作しない。出すのはサーバの `display.text` を逐語。
- 走らせるのは `ios/tools/build.sh --sim`(headless)。**GUI は開かない**。
- 実機の鍵は Keychain のみ。診断ログにも fixture にも書かない。

## §5. Definition of Done

| # | 行 | 判定 |
|---|---|---|
| 1 | `InterruptClient` が `POST` / 正しい path / `Authorization` を出す | 単体(記録欄で観測) |
| 2 | サーバが書いた文が**逐語で**バナーへ届き、電話は生フィールドから文言を作れない | 単体(逐語表 + 生フィールド盲目の対照3本) |
| 3 | 401 → Key-entry / 404+`SESSION_NOT_FOUND` → `.notFound` / 404+`NO_SUCH_ROUTE` → 契約違反 | 単体(送信と同じ規律) |
| 4 | 割り込みバナーと送信バナーが独立 | 単体(負の対照) |
| 5 | §5-4 が共通コンポーネントで、両画面が連続3回・復帰で即消 | 単体(負の対照2本) |
| 6 | §5-4 と §5-5 が互いを代用しない | 単体(負の対照) |
| 7 | N5: 6 client 全部が 302 を追わず想定外として分類 | 単体 |
| 8 | `interruptEnabled` の `.choice` 既定が**禁止側**、かつ文言と同時に動く | 単体(負の対照) |
| 9 | **実機**: edith の生成中セッションへ割り込み、`stopped:"verified"` を観測 | **閉じた**(2026-08-06、`ios/tools/live-interrupt-check.sh`。生フィールドではなく `interruptResult` が `verified` の時だけ書く文で観測 —— 電話が `stopped` を読まない設計に合わせる為) |

## §6. Tom の裁定待ち(★今回は 1 件が実装に効く)

- **★D4 の読み替え**(`DESIGN.md` §2.29-f / `src/choice.mjs` 冒頭)。
  Yes = CHOICE 画面でも割り込みを出す(= 許可確認へ Escape を打てる)。
  No = 出さない(既定)。**私の推奨は Yes** —— 移動中に止まった会話を動かせる唯一の手で、
  向きは常に拒否だから。ただし Codex の裁定どおり、持ち主の再定義が要る。
  Yes になったら動くのは §0-e の 2 箇所だけ。
- 仕様 §7: 口座の切り替えを v1 から落とす件(`REQUIREMENTS.md` は必須と記録している)。
  こちらは Sprint 6 を止めない。

## §7. この brief 自身の訂正(2026-08-06、実装後に読み直して見つけた)

書いた時点の誤りを消さずに残す。次の brief を書く時、同じ形で外さない為。

**訂正1 —— DoD 行2 が、電話側では測れない物を電話側の行に置いていた。**
元の文: 「`interruptResult` の**6 分岐**(verified / already-done / unverified / null /
worker欄なし / 409)が別々の文言で描かれる」。
この 6 分岐を**文言へ変換しているのはサーバ**(`src/view.mjs`)で、既に
`rc-backend/test/view.test.mjs` が単体で押さえている。電話側で同じ表を書いても、
測るのは「私が fixture に書いた 6 本の文字列が、私の書いた表と一致する」事でしかない ——
サーバが 7 本目を足しても、文言を変えても、この検査は緑のまま。**検査が二重になったのではなく、
片方が何も測っていない**。
電話側でしか測れないのは別の性質だった: **サーバの文がそのまま届く事**と、**生フィールド
(`interrupted` / `stopped` / `route` / `pane`)から電話が文言を再発明できない事**。
`InterruptClient.Envelope` が `display` と `code` しか宣言していないのは、その為の構造。
行2 はそちらへ差し替えた(対照は `testDisplayTextWinsOverTheRawFieldsThatContradictIt` /
`testTwoWildlyDifferentRawBodiesWithTheSameDisplayProduceTheSameOutcome` /
`testAMissingDisplayIsNotBackfilledFromTheRawFieldsNegativeControl`)。

**訂正2 —— §2-c の「現状」が、一番大きい穴を書き落としていた。**
元の文は Conversation を 1 行で片付けていた(「`.failure(.unreachable)` を 1 回で
`phase = .unreachable`」)。それは**初回読み込みの経路だけ**の話で、`applyPollStep` の
`.unreachable` の腕は `return true` だけ、つまり**何も変えていなかった**。
閾値が 1 なのは「厳しすぎる」だが、poll の腕が無反応なのは「**会話の途中で backend を
失った電話が、古い画面を黙って映し続ける**」——後者の方が重い。1 経路だけ読んで
「現状」を書いたのが原因。§2-c は 3 経路の表へ直した。
