# Sprint 5 ブリーフ — composer(打ち込む)(2026-08-05 発行)

対象 = 仕様 `spec-native-shell-2026-08-05.md` の Sprint 5 行:
「composer(送信): `POST …/messages`、`display`(系統B)描画、CHOICE/UNKNOWN時の無効化」。

**割り込み(interrupt)は Sprint 6。** この Sprint では作らない。仕様の sprint 表で
別行になっている(Sprint 6 = interrupt + N5 redirect + 到達不能バナー)。
v1 の owner 発話「1. 一覧 2. 履歴 + ライブの流れ 3. 打ち込む 4. 割り込む」のうち、
この Sprint が閉じるのは **3 だけ**。

---

## §0. 契約の実測(2026-08-05、`src/server.mjs` / `src/view.mjs` を逐語で読んだ)

### §0-a. この観測の性格 —— **線の上ではなく source を読んだ**

Sprint 4 のブリーフ §0 は edith 本番へ実際に投げて**線の上の形**を採った。
今回の §0 は **source の読み**である。両者は強さが違う:

| | Sprint 4 §0 | この §0 |
|---|---|---|
| 出所 | 本番の応答 JSON | `server.mjs` / `view.mjs` の分岐 |
| 保証する物 | 「本当にこう返ってきた」 | 「コードはこう返す事になっている」 |
| 落とし穴 | 観測した枝しか分からない | **走らせていないので、到達不能な枝を実在と読む余地が残る** |

★この差を消す作業は §0-d に残してある。**このブリーフだけで実装を始めてよいが、
DoD の実機行はその観測が済むまで閉じない。**

### §0-b. `POST /api/sessions/<id>/messages` の契約(実装から)

要求本文: `{ "text": "<本文>" }` のみ。`text` は文字列でなければ空扱い、`trim()` される。

| 応答 | 条件 | 本文の主な欄 | `display` |
|---|---|---|---|
| 400 | JSON として読めない | `error: "bad body: …"` | 有 |
| 400 | `text` が空 / 文字列でない | `error: "text required"` | 有 |
| 409 | 発言も開いていたペインも無い | `error`(日本語)、`route:"blocked"`, `reason:"pane-gone"` | 有 |
| 409 | 宛先を確定できない | `error`(日本語)、`route:"blocked"` ほか | 有 |
| 409 | ペインへ送れなかった | `error` = `SEND_REFUSAL[reason]`、`route:"tmux"`, `screen`, `reason` | 有 |
| 202 | tmux へ送った | `accepted:true`, `route:"tmux"`, `pane`, `source`, `delivered:"verified"|"unverified"`, `unverified` の時だけ `note` | 有 |
| 202 | ワーカー経路 | `route:"worker"` ほか | 有 |
| 401 | 鍵が通らない | `error:"unauthorized"`, **`code:"AUTH_REQUIRED"`** | **無** |
| 404 | `/api/` 配下だが道が無い | `error:"not found"`, **`code:"NO_SUCH_ROUTE"`** | **無** |
| 404 | その会話が居ない | `error:"unknown session"`, **`code:"SESSION_NOT_FOUND"`** | **無** |

`code` 欄は 2026-08-05 に入れた(下の §0-c ②)。**電話が繋ぐ鍵は `error` の文言ではなく
`code` の側**。文言はサーバ側の都合で直りうるが、`code` は契約である。

### §0-c. 仕様の散文と実装のずれ(**7件**。ここが今回の本体)

#### ① 仕様 DoD の「`sendResult` の 401 分岐」は、電話からは**到達できない**

仕様の Sprint 5 行は単体検査に
「202+verified / 202+unverified / 202+worker / 409 / 400 / **401** / 5xx / 本文なし」
のテーブル駆動を要求している。だが `server.mjs` の 401 は **1箇所だけ**で、
動作の処理へ入る**手前**にある。`display` は動作の枝が宣言した整形器を通った応答にしか
付かない。よって:

> **電話は 401 で `display` を受け取らない。**

★除外の根拠を「整形器の宣言より手前に在るから」と書かない事(Codex 2026-08-05)。
それは実装上の偶然であり、コードを並べ替えたら消える理由である。契約としての根拠は
**「操作の結果ではなく、操作へ入る手前で決まったプロトコル / 資源解決の結果だから」**。

`view.mjs` の4つの mapper が持つ 401 の腕(`鍵が通りませんでした。`)は
**死んだコードではない** —— `src/app.html` が `view.mjs` を import して
生の status を渡して呼んでいるので、**web UI 専用**として生きている。消さない事。

→ Swift 側の扱い: 401 は `display` の話ではなく **経路の話**。既存の
`SessionsFetchError.unauthorized` → Key-entry 強制遷移(仕様 §5-3 の最終行)を
そのまま使う。**新しい型も新しい文言も作らない。**

#### ② ★404 は3箇所・意味は2種類。**status だけで分岐している今の電話は誤表示する**

契約を書き出す為に `json(res, 4xx, …)` を数えて見つけた、**この Sprint 最大の発見**。

| 出所 | `code` | 意味 | Sprint 3 の電話がしていた事 |
|---|---|---|---|
| `/api/` 以外の道 | `NO_SUCH_ROUTE` | 別のサーバへ来た | 一覧へ戻る(電話は此処へ来ない) |
| `/api/` だが道が無い | `NO_SUCH_ROUTE` | **client の path が間違っている** | 一覧へ戻る ← **誤り** |
| 会話が居ない | `SESSION_NOT_FOUND` | セッション id が不明 | 一覧へ戻る(正しい) |

電話は `case 404: return .notFound` で status だけを見ていたので、2番目 ——
**自分が組み立てた path が間違っている場合** —— も「この会話はもう在りません、
一覧に戻る」と表示していた。利用者は消えていないセッションを探しに行かされる。

★これが文言の粗さで済まない理由。request の path は同じ日の変異監査で
「`api/sessions` → `api/session` に変えても 214 件が緑」と実測された、この repo で
**一番守りの薄い所**である。そこへ「消えたのはセッションの方だ」という説明を被せると、
**一番出やすいバグを、一番それらしい嘘で隠す**組み合わせになる。

**サーバ側は対処済み**(2026-08-05、`test/recovery-codes.test.mjs` 付き):
語彙 `AUTH_REQUIRED` / `SESSION_NOT_FOUND` / `NO_SUCH_ROUTE` を作り、呼び口の直書きを
そこへ寄せた。検査は「呼び口で意味を発明していないか」「語彙が全部 `code` を持つか」
「404 の意味が複数在るのに1つへ潰していないか」を木から導出する。

→ **この Sprint の仕事**: 電話側を追随させる。
- `.notFound` は **`code == "SESSION_NOT_FOUND"` の時だけ**。
- それ以外の 404 は `.notFound` に**合流させない** —— ③ の応答契約違反へ。
- `HistoryClient` / `SessionsClient` の両方(どちらも status だけで分岐している)。

#### ③ `display` が無い応答は 401/404 の2つだけ —— **それ以外は「応答契約違反」**

`speaks()` は「後から枝が増えても勝手に `display` が付く」形で書かれている。
だが**手前で返る枝**(認証・経路解決)には自動では付かない。将来そこに枝が増えると、
電話は**無言**になる。

→ 実装規約(Codex 2026-08-05 の助言をそのまま採る):

> client は操作結果の表示内容を HTTP status や応答データから独自に導出してはならず、
> `display` をそのまま描く。ただし **401** と **404 + `SESSION_NOT_FOUND`** については、
> 表示判断ではなく**復旧・遷移の制御**として、それぞれ認証画面・一覧画面へ遷移してよい。
> **これらを除く応答で `display` が欠落した場合は「応答契約違反」として扱う。**

応答契約違反の扱い = **固定の障害表示**(電話が文言を創作しない)+ ログに残す。
「欄が無い = 何も表示しない」に倒さない —— それが起きた時に誰も気付けない。

#### ④ 400 の本文は**内部の英語**をそのまま画面に出す

`sendResult` の 400 腕は `{ kind:"error", text: b.error || "送れない形でした。", keepText:true }`。
`b.error` の実体は `"text required"` / `` "bad body: …" `` = 英語の内部語。

→ **そのまま描画する。** 独自文言に丸めない(仕様 §5-3 の `route:"blocked"` 行と同じ原則:
「サーバの文面をそのまま表示。理由コードを生で出さない、独自文言に丸めない」)。
文面を直すならサーバ側の仕事であり、**この Sprint の作業ではない**。Swift 側で
「`text required` を見たら日本語に差し替える」を書いたら差し戻し —— 判定の出所が2つになる。

#### ⑤ composer の活性条件は3層。**優先順位を間違えやすい**

| 状況 | composer | 出所 |
|---|---|---|
| `screen === "SENDABLE"` | 活性 | 仕様 §4-4 |
| `screen === "CHOICE"` | 無効(固定文言) | 仕様 §5-3 |
| `screen === "UNKNOWN"` | 無効 | 仕様 §5-3 |
| poll が読めない / 200 のデコード失敗 | **活性のまま** | 仕様 §5-3 の C群 行 |
| poll が3回連続失敗 | 直前の状態を維持 | 仕様 §5-3 |

★「読めない = 送らせない」に倒さない。根拠は仕様が明記している通り、送信可否は
**サーバが送信の瞬間に**判定する(`inject.mjs` が `CHOICE`/`UNKNOWN` で `sent:false`、
送信直前のモーダル検知で中止)。client の古い `screen` に依存していないので、
composer を開けたままでも fail-closed はサーバ側で成立する。

#### ⑥ `kind` を Swift の enum で厳密に decode しない

`kind` は今 `ok` / `warn` / `refused` / `error` の4つ。これを `enum: String, Decodable` に
直結すると、**サーバが5つ目を足した日に decode が投げ、`text` ごと落ちる** ——
読める文面が手元に来ているのに「読めませんでした」と出す形になる。

→ `kind` は `String` で受け、見た目へ写す時に既定(= `warn` 相当)へ倒す。
`text` は `kind` が何であっても表示する。**文面を落とす方向へ倒さない。**

#### ⑦ ★**`MockURLProtocol` は request の body を一切記録していない**(この Sprint の最大の地雷)

いま在る記録欄は3つだけ: `requestedURLs` / `requestedMethods` / `lastRequestHeaders`。
**body の欄が無い。** Sprint 5 は初めて **body を持つ request** を出す Sprint なので、
このままだと「本文を落とす / 別の欄名で送る / 空文字を送る」変異が**1つも赤くならない**。

同時に2つの罠がある:

1. **`URLProtocol` は `httpBody` を見ても `nil` になる。** `URLSession` は本文を
   `httpBodyStream` へ移す。素直に `request.httpBody` を記録する欄を足すと、
   **常に `nil` を記録し、検査は常に緑**になる —— この repo が繰り返し踏んでいる
   「緑の顔をした未測定」そのもの。記録欄を足すなら `httpBodyStream` から読み切る事。
   足した直後に**負の対照**(本文を変える変異を植えて赤になるか)を必ず1回通す。
2. **記録欄を1つ足すと、既存4本の client の検査が一斉に赤くなる。**
   `rc-backend/test/request-shape.test.mjs` は「全 client が `MockURLProtocol` の
   **全記録欄**を読んでいる事」を要求する規約で、対象も次元も木から導出している。
   → 既存4本(Healthz / History / Poll / Sessions)にも body の検査を足す
   (GET なら「body が付いていない事」を見るのが正しい検査であり、免除ではない)。
   `EXEMPT` に逃がすのは、**なぜその次元を見なくてよいかを書ける時だけ**。

★この2番は**作業量の見積もりに直結する**ので先に読む事。

### §0-d. 測っていない事(= この観測の分母)→ **3行とも 2026-08-05 に edith で観測して閉じた**

| 何 | なぜ未測定だったか | 観測の結果 |
|---|---|---|
| 400 / 401 / 404 の**線の上の**形(`code` 欄を含む) | `tools/wire-shape.mjs` が GET 専用で、非200 の本文を出さない**と書いてあった**(= 古い前提。`RC_METHOD`/`RC_BODY`/`RC_EXPECT_STATUS` と `code` は既に在った) | **閉**。5形を観測。401 と 404 の2つは `display` **無**、400 は `display` **有**(`keepText:true`)。電話の契約と一致 |
| 202 + `delivered:"unverified"` の実物 | 起こすには TUI を特定の状態に置く必要がある | **閉**。生成中に**定型文と同一の本文**を送ると必ず起きる(`bodyIsPlaceholder` が直接証拠を無効化する = 構造的に決まらない唯一の道)。`kind:"warn"` / `keepText:true` / `display.text` は `note` より**長い**(二重送信の警告を持つ) |
| ワーカー経路(`route:"worker"`)の送信 | tmux 経路しか踏んでいない | **閉**。ペインを畳んでから送ると 202 `{accepted,route:"worker",seq}`。**`delivered` も `pane` も無い**。`display` は `kind:"ok"` / `keepText:false`。割り込み後、子プロセスの一致数 0 |

観測の全文と再現手順: `rc-backend/.harness/evidence-2026-08-05/live-http-0d-rows-20260805.md`
(走行そのもの: `tools/live-http-check.mjs` を edith で 25 OK / 0 NG / 実測メモ 8 件、exit 0)

★1行目は今日の `code` 追加で**重みが増した**。電話が新しく `code` に依存するので、
「source にはそう書いてある」だけで実装を閉じない —— この規則どおり、**source ではなく線の上で**閉じた。

★閉じた事で電話側に効く発見が2つ(どちらも source を読むだけでは出なかった):
1. `unverified` の `display.text` は `note` の**続きを持つ**。電話が `note` を出す実装だったら
   「送り直すと二重に入ることがあります」が落ちていた。→ `display.text` を verbatim で出す形が正しい。
2. ワーカーの 202 には `delivered` が無い。生の欄から画面を作る実装だったら此処で落ちる。
   → `SendClient.Envelope` が `display` と `code` しか宣言していない形が正しい(§1-b の禁止と同じ向き)。

---

## §1. スコープ

### §1-a. 作る物

| # | 物 | 置き場所 |
|---|---|---|
| 1 | `SendClient` — `POST …/messages`、本文 `{text}` | `ios/Sources/Core/` |
| 2 | 系統B `display` の型(`kind`/`text`/`keepText`)と decode | `ios/Sources/Core/` |
| 3 | `ConversationViewModel` の送信状態(送信中 / 結果 / 入力欄を消すか残すか) | 既存 file |
| 4 | `ConversationView` の composer(入力欄 + 送信ボタン + 結果の帯) | 既存 file |
| 5 | `MockURLProtocol` の body 記録欄 + 既存4 client の検査の追随(§0-c ⑦) | `ios/Tests/` |
| 6 | **404 の `code` 追随**: `.notFound` は `SESSION_NOT_FOUND` の時だけ(§0-c ②) | `HistoryClient` / `SessionsClient` |
| 7 | **応答契約違反の固定表示**(§0-c ③)。`.notFound` にも `.malformedBody` にも合流させない | `ios/Sources/` |

### §1-b. 作らない物(手を出したら差し戻し)

- **interrupt(割り込み)** = Sprint 6。
- `POST …/choice` を呼ぶ画面 = 仕様の D-A で **A(作らない)** に裁定済み。
- `POST …/queue`(キュー UI) = 仕様 §7 の v2 候補。
- `view.mjs` の判定の Swift 移植。**`display` を描くだけ。** 独自の文言判定を持たない。
- 400 の英語文言の日本語化(§0-c ④)。
- **サーバ側の変更**。`code` 欄は着地済みなので、この Sprint で `server.mjs` を触る
  必要は無い。触りたくなったら、それは契約の穴を見つけた合図なので先に報告する事。

---

## §2. 送信1回の順序(これ以外を採らない)

1. `screen` が `SENDABLE` でなければボタンは押せない(§0-c ⑤)。
2. 押下 → 入力欄を**まだ消さない**。送信中の表示にする。
3. `POST …/messages` に `{text}`。
4. 応答で分岐:
   - **401** → 資格情報を捨てて Key-entry へ(既存の経路。`display` を見ない)。
   - **404 かつ `code == "SESSION_NOT_FOUND"`** → `.notFound` 相へ(既存の経路)。
   - **404 でそれ以外の `code`** → 応答契約違反(§0-c ③)。**一覧へ戻さない。**
   - **それ以外** → `display` を読む。**無ければ応答契約違反として表に出す**。
5. `display.keepText` が真なら入力欄の本文を**残す**。偽/不在なら消す。
   → 送り直せる事が「残す」の意味。実測すると **`keepText:false` は `kind:"ok"` の1枝だけ**で、
   `warn` / `refused` / `error` は全部 `true`。つまり「消えるのは送れた時だけ」。
   ★`kind` から `keepText` を推測して実装しない —— **欄を読む**。
   1枝しか偽が無い形は「`kind === "ok"` なら消す」と書いても今日は緑になるが、
   サーバが枝を増やした日に黙ってずれる。
6. 帯に `display.text` を `kind` に応じた見た目で出す。**文面は加工しない。**
   ★特に「本文は残してあります。送り直すと二重に入ることがあります。」は
   **`display.text` に既に含まれている**。電話側で足すと二重に出る。

★4 と 5 の順序を入れ替えない。本文を先に消すと、断られた時に打ち直しになる。

---

## §3. 検査(`ios/Tests/`)

### §3-a. 必須の負の対照(**これが無い検査は受け取らない**)

- `display` を**握り潰していない**事: `display` の無い 200 応答を1本流し、
  画面が無言にならず応答契約違反として出る事を見る(§0-c ③)。
- **404 の2つの `code` を見分けている**事: `SESSION_NOT_FOUND` で一覧へ戻り、
  `NO_SUCH_ROUTE` で**戻らない**事を両方見る。片側だけだと Sprint 3 の実装
  (status だけで分岐)がそのまま緑で通る —— **この対照が今回の本命**。
- body の記録欄が**効いている**事: 本文を変える変異を1つ植えて、検査が赤くなる事を
  一度実際に見る(§0-c ⑦-1)。緑を数えても記録欄の生死は分からない。
- `keepText` が**見分けている**事: 真の応答と偽の応答で入力欄の残り方が変わる事。
  片側だけ見ると「常に残す」実装が緑で通る。

### §3-b. テーブル駆動(仕様 DoD の要求)

`sendResult` が返す `display` の全分岐を、**サーバが実際に返す本文の形**で駆動する:
202+verified / 202+unverified / 202+worker / 409 / 400 / 5xx / 本文なし。
**401 はこの表に入れない**(§0-c ①)—— 401 は `display` の分岐ではなく経路の分岐なので、
`SendClient` の status → 結果の表の側で見る。

### §3-c. 走らせる物

`tools/build.sh --sim`(headless)。GUI は開かない。

---

## §4. 引き継いだ制約(破ると commit の門で止まる、または後で高く付く)

- **書類の行番号引用を増やさない。** `.md` の `file.swift:NN` 形式はラチェットで
  止まる(`tools/doc-linerefs-gate.sh`)。記号名・節番号で書く事。
- **既定のサーバ名を Swift の source / placeholder / fixture / 注釈に置かない。**
- **API 鍵は Keychain だけ。** ログにも fixture にも診断行にも出さない。
- Release ビルドに fixture 経路を残さない(`ui-fixture-absence-control.sh` が見ている)。
- 変異走行が回るのは **`rc-backend/` だけを写した部分木**。電話側の木を読む検査は
  木が無い時に**赤ではなく「測っていない」**へ倒す事(本日 commit A でこれを踏んだ)。
- 新しい対照 file を足したら**2行目に `# controls-for:` を書く**。宣言の無い対照は、
  その道具だけを直す commit で静かに回らない(本日 commit B で門に止められた)。

---

## §5. Definition of Done

全行の裏付けは 2026-08-05 に取った。単体の走行は `ios/tools/build.sh --sim`(headless)で
**290 件 / 失敗 0 件**、`node --test test/request-shape.test.mjs` が **5 / 5**。

| # | 行 | 判定 | 閉じた根拠(2026-08-05) |
|---|---|---|---|
| 1 | `SendClient` が `POST` / 正しい path / `Authorization` / `{text}` body を出す | 単体(4次元とも記録欄で観測) | **済**。`testRequestIsAPOSTToTheMessagesPathWithTheBearerKeyAndTheTextAsJSON` / `testTextIsSentUntrimmed`。★body 次元だけは緑では閉じない ので**変異を1つ植えて赤を見た**(`RequestBody` の鍵を `message` へ改名 → 290 中 **2 本だけ**赤、288 本は緑)= `evidence-2026-08-05/send-body-recording-control-20260805.md`。**残り3次元(method / path / header)は同種の変異を植えていない = 未測定** |
| 2 | `display` の全分岐がテーブル駆動で緑(§3-b) | 単体 | **済**。`testEveryDisplayBranchIsCarriedThroughVerbatim`(本文は `view.mjs` から逐語)+ `testInternalEnglishFrom400IsNotLocalizedByThePhone` + `testUnknownKindStillCarriesItsTextAndFallsBackToWarnTone`、対照 `testToneIsNotAlwaysWarnNegativeControl`。画面側は `testEveryDisplayToneReachesTheBannerUnchanged` |
| 3 | `display` 欠落を握り潰さず応答契約違反として出す | 単体(負の対照) | **済**。欠落の 4 形(欄が無い / 本文が空 / `display` に `text` が無い / 読めない)+ 対照 `testContractViolationCarriesTheObservedStatusNegativeControl` `testContractViolationIsNotCollapsedIntoDisplayNegativeControl` |
| 4 | `keepText` の真偽で入力欄の残り方が変わる | 単体(負の対照) | **済**。`testKeepTextFalseClearsTheDraft` / `testKeepTextTrueKeepsTheDraft` / 対照 `testClearingFollowsKeepTextNotKindNegativeControl`。★**欠落時は残す**をブリーフ §2 step5 から意図的に外しており、その旨を検査文に明記(`testKeepTextAbsentKeepsTheDraftDeliberateDeviationFromTheBrief`)—— 消し過ぎは復元不能、残し過ぎは目に見えて消せる、の非対称 |
| 5 | 401 → Key-entry / 404+`SESSION_NOT_FOUND` → `.notFound` | 単体 | **済**。client 側 `testStatus401IsUnauthorizedWithoutConsultingTheBody` / `testStatus404WithSessionNotFoundCodeIsSessionNotFound`、画面側 `testUnauthorizedRoutesOutAndKeepsWhatTheUserTyped` / `testSessionNotFoundOnSendTearsTheScreenDown` |
| 6 | **404+`NO_SUCH_ROUTE` が一覧へ戻らない**(§0-c ②) | 単体(負の対照) | **済**。`testStatus404WithNoSuchRouteCodeIsContractViolation` + **本命の対照** `testTheTwo404MeaningsAreNotCollapsedNegativeControl`(status だけで分岐する Sprint 3 の実装がこれで落ちる)。画面側 `testContractViolationOnSendIsABannerOverAnIntactScreen` / `testTheSameViolationBecomesThePhaseOnLoadButNotOnSendNegativeControl` |
| 7 | CHOICE / UNKNOWN で composer が無効、poll 不読では**活性のまま** | 単体 | **済**。`testComposerIsDisabledOnCHOICEWithTheSpecsFixedWording` / `…OnUNKNOWN…` / 対照 `testAnUnreadablePollDoesNotDisableTheComposerNegativeControl` / `testEnablementIsNotAConstantNegativeControl`。BUSY で活性のままは owner 発話(「返答待ちであれ作業中であれいつでも見て、干渉できれば」)の直系 = `testComposerStaysEnabledOnBUSY` |
| 8 | 既存4 client の検査が body 次元を読む(または理由付き `EXEMPT`) | `request-shape.test.mjs` が緑 | **済**。`# tests 5 / # pass 5 / # fail 0`。自身の陰性対照(「判定が見分けている = 常に緑を返してはいない」)を含む |
| 9 | **実機**: edith のテストセッションへ実送信し `delivered:"verified"` を観測、対象 jsonl の末尾行が増えた事を `ssh edith` で確認 | 実機 | **済(2026-08-05)**。`ios/tools/live-send-check.sh` で5項目とも ok(`evidence-2026-08-05/live-send-row9-20260805.md`)。★但し**行数の増分では閉じていない**: 使い捨ての会話は転写が無い所から始まるので `0 → 8 行` には起動が書いた行が混ざる。閉じたのは**送った本文そのものを転写の中で数えた**方(1 件、陰性対照 0 件) |
| 10 | §0-d の3行を観測して §0 を更新(または**未測定と明記**) | 観測 | **済(2026-08-05)**。3行とも edith の線の上で観測(`evidence-2026-08-05/live-http-0d-rows-20260805.md`)。未測定として残した行は無い |

---

## §6. Sprint 6 への申し送り(今は実装しない)

- interrupt の `display` は `interruptResult`。**形は送信と同一**(`{kind,text}`、
  `keepText` は使わない)。Swift の型は Sprint 5 で作った物を再利用する。
- interrupt は `screen` を条件に**しない**(仕様 §5-3: CHOICE でも UNKNOWN でも有効)。
- 401/404 の扱いは送信と同じ(§0-c ①②)。Sprint 5 で作る `code` の分岐をそのまま使う。
- N5 redirect と到達不能バナーは Sprint 6 の別項。

---

## §7. Tom の裁定待ち(この Sprint を止めはしない)

- `DESIGN.md` §2.29-f: D4 を「承認は禁止、**明示的な拒否は可**」と読み替えるか。
  Yes なら CHOICE 画面へ `Escape` だけ送れる。実装は禁止側に置いてある。
  **私の推奨は Yes**、ただし Codex は「持ち主が再定義する必要がある」と裁定しており、
  開発側の解釈だけで広げない。
- 仕様 §7: 口座の切り替えを v1 から落とす件。`REQUIREMENTS.md` は必須と記録している
  ので、**黙って落とすと要件が1つ消える**。Tom の再確認が要る。

---

## §8. このブリーフに対する外部の目(Codex sanity、2026-08-05)

問い: 「401/404 は `display` を持たないので電話が status で遷移を決める」という裁定は
妥当か。電話側の status 分岐は仕様の「独自判定を持たない」に反しないか。

答え(採用済み):

1. 裁定は妥当。status 分岐は**文言の独自判定ではなく復旧・遷移の制御**なので方針違反ではない。
2. **ただし除外の理由を書き換えろ** —— 「整形器の宣言より手前だから」(実装上の偶然)ではなく
   「操作処理より手前のプロトコル / 資源解決の結果だから」(API 契約)と定義する。→ §0-c ① に反映。
3. **それ以外で `display` が欠けたら、電話が文言を創作せず「応答契約違反」として
   固定の障害表示 + ログ・監視対象にする。** → §0-c ③ と DoD 3 に反映。
4. 「可能なら生の status でなく `code: AUTH_REQUIRED | SESSION_NOT_FOUND` を返せ。
   404 の意味が将来増えても誤遷移しない」→ **将来の話ではなかった。** 数えたら 404 は
   既に3箇所・意味2種類で、誤遷移は現に起きる形だった。同日サーバへ実装(§0-c ②)。

★4 が今日一番効いた指摘である。私は「今 404 は1箇所」という記憶で書きかけており、
数えたのは Codex の助言を**反論する為に**根拠を取りに行った時だった。
