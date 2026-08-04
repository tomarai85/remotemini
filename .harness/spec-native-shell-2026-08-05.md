# spec — Native SwiftUI 電話シェル(`ios/` = `RemoteMini`)v1

作成: 2026-08-05。上流 = `DESIGN.md` §2.13(D1 訂正 = native 確定 / 2026-08-05 追記の S/C 判断分割)/
§2.36(long-poll 確定)/ §3(D1-D5)/ §6(脅威モデル)、`REQUIREMENTS.md` 全文、`rc-backend/src/*.mjs` 実装。
team-lead から届いた S/C 分割の binding ruling を本文に折り込み、17関数全部の実体を読んで再検証した
(§0-4)。本 spec の所有者はこのファイルのみ。他ファイルは一切変更しない。

先行して同名パスに別版(113行、team-lead が Planner subagent を経由させず直接書いた版)が置かれて
いたが、その後 team-lead から届いた binding ruling メッセージが「sprint 形を変える」「spec に折り
込め」と明示していたため、本版が正としてこれを置き換える。差分の要点は §0-1(先行版の Sprint 3 は
`/stream` を叩く設計だったが、それは死んでいる経路 — §0-1 で根拠を示す)。

## Design Decisions

has_design_decisions: **true**

DESIGN.md と team-lead ruling が既に確定させた事項(D1 native / long-poll / worker route / D4
permission-notify-only / S-C 判断分割とその v1 適用範囲)は「決定」として扱い、以下では**再掲しない**。
ここに載せるのは、上流のどの文書を読んでも一意に決まらず、かつ本 spec の他の節が選択に依存する3点。

| # | 論点 | 選択肢 A | 選択肢 B | 推奨 |
|---|---|---|---|---|
| D-A | v1 の CHOICE 画面対応 | 一切対応しない(バッジのみ。割り込みだけ効く) | `POST …/choice` を v1 に含める(サーバ・PWA とも実装済み) | **A**。理由 §1-a。この選択が §0-4 の Sprint 0.5 スコープ(`choiceView`/`choiceResult` を配線するか)を直接決める |
| D-B | 端末側の一覧・履歴の永続化 | セッション内メモリのみ | ディスクへ書く | **A**。理由 §4-2 |
| D-C | 一覧画面のライブ性 | `GET /api/sessions` の定期取得のみ | 各行にも poll を張る | **A**。理由 §3-4 |

いずれも後から変更可能だが、Sprint 分割と実装量に直結するため着手前に確定させる。

---

## 0. 前提の是正 + team-lead ruling の反映

### 0-1. ライブ配信は SSE ではなく long-poll(実装を読んで確認、2026-08-04 に切替済み)

先行版・当初の依頼文とも `GET /api/sessions/<id>/stream`(SSE)を主線としていたが、実装を読むと
電話向けの配信は**既に長待ち受けへ置き換わっている**:

- `app.html:418-419` — `fetch(/api/sessions/${id}/poll?cursor=…&wait=…)` を使う。`/stream` /
  `EventSource` への参照は無い(`app.html:171,403` に「`/stream` は電話では死んでいる」旨の注記あり)。
- `server.mjs:1257-1420`(`action === "poll"`)が実装。`/stream` 自体は残っているが、呼び手は
  `/debug` テストページと `tools/live-http-check.mjs` のみ — 本番の呼び出し元は無い。
- 理由(`DESIGN.md` §2.36 逐語): 「iPhone Safari が本文を溜め込むか」は Tom の実機でしか測れず測定
  不能 → 検出器を作らず**完了した HTTP 応答は中継も browser も溜め込めない**という構造の方を採った。

Swift 側は `URLSession.bytes(for:).lines` のような行単位ストリーム読みを実装**しない**。1回完結の
JSON 応答を返す離散リクエストの反復に置き換える(§3)。

### 0-2. PWA 参照実装のパスは `rc-backend/src/app.html`

`rc-backend/app.html` ではなく `rc-backend/src/app.html`(808行)。`find` で確認済み。

### 0-3. `ios/` に既に骨格が存在する — Sprint 0 は完了済み

| 実測 | 内容 |
|---|---|
| `ios/project.yml` | `xcodegen` 定義。bundle ID `com.tomarai.remotemini`、iOS 17.0 |
| `ios/tools/build.sh` | `xcodegen generate` → 署名なし `xcodebuild` → wildcard provisioning profile
  (application-identifier が `.*` で終わる物を動的検索、失効チェック付き)で再署名 →
  `codesign --verify --deep --strict` → `xcrun devicectl device install app`(接続端末を動的検索、
  tunnel flake 対策でリトライ3回)。`--sim`(simulator build+test)/ `--no-install`(署名のみ)/
  既定(実機 install)の3モード |
| `ios/Sources/RemoteMiniApp.swift` / `RootView.swift` | `@main` App + 版番号表示のみの土台。
  `RootView.swift` 本文に「画面の中身は本 spec の確定後に入る」と明記 |
| `ios/Tests/BuildInfoTests.swift` | XCTest が実際に走り、壊すと落ちる事の検査1本。負の対照の方針が
  コメントに明記(各 Sprint で実装) |
| entitlements | wildcard profile の4つ(`application-identifier`/`team-identifier`/
  `get-task-allow`/`keychain-access-groups`)がそのまま通る = **Keychain に鍵を置く設計に
  Portal 作業が要らない** |

→ Sprint 計画はこの骨格の上に積む。「プロジェクトを作る」は Sprint に含めない。

### 0-4. S/C 判断分割 — team-lead ruling を17関数全部の実体で再検証(結果: 分類の修正ゼロ)

**背景**: `view.mjs`(639行、17 exported、`test/view.test.mjs` 約74件 + `test/app-html.test.mjs`
約44件)は判断関数の唯一の実装で、`app.html:179` がそれを `import` することで「実装は1本」を構造的に
保証している。Swift は `import` できないため、素朴に全17本を移植すると同じ判断が2言語に住む —
`app.html` 自体に散る `★判断は view.mjs。ここに条件を書かない` という徹底と正面から矛盾する。

**ruling**: 入力の性質で2群に割る。S群 = サーバが作った payload だけの純関数 → **サーバが
`view.mjs` を呼び、結果を応答へ追加フィールドとして足す**(`view.mjs` は実装1本のまま、`app.html`
は無改修)。C群 = client の時計・取得時刻・client 保持状態に依存 → **Swift へ再実装**。

**再検証(今回、全関数のシグネチャと本体を読んで確認)**:

| 関数 | シグネチャ(実体で確認) | 時計/client状態への依存 | 判定 |
|---|---|---|---|
| `routeLabel(live)` | payload のみ | 無し | S(確認、修正なし) |
| `subtitleOf(row)` | payload のみ | 無し | S |
| `whoOf(role)` | payload のみ | 無し | S |
| `scanLine(scan)` | payload のみ | 無し | S |
| `gapNotice(why)` | payload のみ | 無し | S(ただし §4-3 参照 — suppress 条件が poll では発火しない) |
| `readablePoll(d)` | payload のみ | 無し | S |
| `choiceView(state)` | payload のみ(`conv.state`) | 無し | S |
| `sendResult(status, body)` | payload のみ | 無し | S |
| `interruptResult(status, body)` | payload のみ | 無し | S |
| `choiceResult(status, body)` | payload のみ | 無し | S |
| `clearQueueResult(status, body)` | payload のみ | 無し | S |
| `mergeHistory(history, live)` | client が持つ2配列 | 無し(が client-held state) | C(確認) |
| `relTime(iso, nowMs)` | **`nowMs` 引数あり** | 有り | C |
| `freshness(fetchedAtMs, nowMs)` | **`nowMs` 引数あり** | 有り | C |
| `nextAttempt(attempt, openedAt, nowMs)` | **`nowMs` 引数あり** | 有り | C |
| `nextHistoryLimit(current)` | `current` = client が保持する表示件数 | client-held state | C |
| `queueView(d, fetchedAtMs, nowMs)` | **`nowMs`/`fetchedAtMs` 引数あり**、内部で `freshness` を呼ぶ | 有り | C |
| `backoffMs(attempt)`(`frames.mjs`) | payload/client 状態いずれでもなく attempt 回数のみ | 無し(client の再試行回数という client-held state) | C |

**結論: team-lead の分類に修正すべき点はゼロ**。11(S)+6(C)の内訳もそのまま成立する。

**v1 適用範囲の絞り込み(ruling の「v1 の応答経路に既に乗っている物だけ additive に含めよ」指示への回答)**:

D-A(§Design Decisions)= v1 は CHOICE 画面に「バッジのみ」で応答し、`POST …/choice` を呼ばない。
これにより:

| 関数 | v1 の応答経路に乗るか | Sprint 0.5 で配線するか |
|---|---|---|
| `routeLabel` / `subtitleOf` / `whoOf` / `scanLine` / `gapNotice` / `readablePoll` / `sendResult` / `interruptResult` | 乗る(一覧・履歴・poll・送信・割り込みの4機能が直接使う) | **する(8本)** |
| `choiceView` | `state.screen==="CHOICE"` 自体は既存の生フィールドとして v1 の poll/status/list 応答に元々乗っているが、v1 は options/buttons を描かない(バッジのみ、固定文言) | **しない**。v1 は生の `screen==="CHOICE"` を見て固定バッジを出す。CHOICE 対応(D-A = B へ変わった時)の前提作業として v2 候補(§7)に計上 |
| `choiceResult` | `POST …/choice` は v1 が呼ばない | **しない** |
| `clearQueueResult` | `DELETE …/queue` は v1 が呼ばない(送信待ちキューの表示・取消は4機能に無い) | **しない** |
| `queueView`(C群) | 同上、v1 は queue 状態を表示しない | **Swift へ移植しない** |

→ Sprint 0.5 の追加実装は **8関数**、Swift 側の C群移植は **5関数+backoffMs**
(`mergeHistory`/`relTime`/`freshness`/`nextAttempt`/`nextHistoryLimit`、`queueView` は対象外)。

**未実装の確認(2026-08-05 時点)**: `server.mjs` に `view.mjs` の server-side `import` は無い
(`grep -n "from \"./view" server.mjs` = 0件)。`git status --short` は `ios/` 以外に変更なし。
→ Sprint 0.5 は Sprint 1(一覧)より前に置く独立した先行作業(§6)。

**不変条件(team-lead 指示、必ず spec に明記)**: **2つの器(`app.html` と native)が食い違いうるのは
C群の実装差だけ**。S群はサーバの1実装から出た値をそのまま描くので、native と PWA が同じ状況で
違う判断を見せる事は構造的に起きない。C群だけが2つの独立実装(JS/Swift)を持つ = drift の起点は
そこだけと知って良い。

**追加のサーバ制約(ruling 由来、既存箇所への影響)**:

1. **追加のみ。** 既存フィールドの意味を変えない・消さない。
2. **`display` 名前空間に入れる。** 生データに紛れる兄弟キーとして散らさない(例:
   `sessions[i].display.subtitle`、poll 応答の `items[].display`)。
3. **`app.html` は無改修。** 既存の `test/app-html.test.mjs`(約44件)が緑のままである事が検査。
   web は今まで通り `/view.mjs` を import して自分で計算する = 実装は1本のまま。
4. **各追加フィールドに、`view.mjs` の対応呼び出しの戻り値と一致する事を確認する検査を1本ずつ
   (8本)。** 期待値はサーバが実際に渡した引数を材料にしない — 検査自身が独立に組んだ入力に対する
   `view.mjs` の戻り値を期待値にする。掴みたいのは「関数を呼んだか」ではなく「正しい引数を渡したか」。
5. `readablePoll` は S群だが、**サーバ側で自分の送信の健全性を検める目的には使わない**(送り手は
   自分の送信を検められない)。electronic な用途は「クライアントが受信直後に真偽を見る」のみ。

---

## 1. スコープ確定

固定 v1(owner 発話、拡げない): **一覧 / 履歴+ライブの流れ / 打ち込む / 割り込む**。

### 1-a. 明示除外とその根拠

| 除外 | 根拠 | 本 spec での扱い |
|---|---|---|
| push 通知 | wildcard provisioning profile は push entitlement を運べない(team-lead 指示) | v2 候補(§7)。REQUIREMENTS §5-4「入力待ちで電話に通知」と衝突する — 後述 |
| アカウント表示・切替 | team-lead 明示除外 | v2 候補(§7)。REQUIREMENTS §4-5/§5-8 は Tom 逐語を根拠に必須と書いており緊張がある — 後述 |
| 電話からの許可プロンプト承認 | D4 確定済み | v1・v2 とも対象外(恒久的な決定) |

D-A(CHOICE 画面全般)は D4 の「許可プロンプト」除外とは別物: D4 が禁じるのは `choice-hard-stop`
(信頼/権限確認)のみで、一般的な選択メニュー(`POST …/choice`)はサーバ・PWA 側とも既に実装済み
(2026-08-03/04 出荷)。v1 に含めない理由: (1) team-lead が固定した4機能に無い、(2) 除外しても
「何もできなくなる」訳ではない — CHOICE 画面でも interrupt(Escape)は効く(§2-3)、(3) 7日で4機能を
実機到達させる制約下、5つ目の画面状態(選択肢のレンダリングと指紋照合)を増やすのは Sprint を圧迫する。
サーバ側は既にあるため、v2 着手時の追加コストは Swift 側の1画面 + Sprint 0.5 への `choiceView`/
`choiceResult` の追加のみ(§0-4 の表)。

### 1-b. 4機能 → 画面への割付

| 機能 | 画面 |
|---|---|
| 一覧 | List |
| 履歴+ライブの流れ | Conversation(初期表示 = history、以後は poll で追記) |
| 打ち込む | Conversation の composer |
| 割り込む | Conversation の interrupt ボタン |

このほか、鍵を保持していない起動時のための Key-entry 画面が要る(旧 PWA の3画面構成を踏襲)。

---

## 2. 画面ごとの挙動

### 2-1. Key-entry

- 起動時、Keychain に鍵が無ければ最初に表示。鍵とベース URL(tailnet 上の HTTPS)を入力。
- 保存前に必ず `GET /healthz` で疎通確認(認証不要、`{ok, pid, uptime, version}` を返す)→ 200 なら
  URL は正しい。次に同じ URL へ `GET /api/sessions` を1回叩き、200 なら鍵も正しいとして Keychain へ
  保存し List へ遷移。401 なら「鍵が違います」、`healthz` 自体が失敗するなら「サーバに届きません」と
  **原因を分けて**表示する(§5-1)。
- 保存先: iOS Keychain、`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`。iCloud Keychain 同期は
  **しない**(DESIGN §6 の電話紛失主脅威に対し、鍵を複数端末に広げない)。ログに鍵を絶対に出さない。

### 2-2. List

- 表示行 = `GET /api/sessions` の `sessions[]`。1行の構成要素: `title`(無ければ `id` 先頭8桁)/
  `display.subtitle`(= `subtitleOf`、S群・サーバ計算値)/ `relTime(updatedAt, now)`(C群、Swift実装)/
  `display.routeLabel`(= `routeLabel`、S群)由来のバッジ・短文。
- 一覧下部に `display.scanLine`(S群、= `scanLine`)を出す — 「何本のうち何本を読んだか」。
- 更新契機: 初回表示 / pull-to-refresh / Conversation から戻った直後 / フォアグラウンド復帰時。
  **行ごとの poll は張らない**(D-C = A、§3-4)。
- 一覧の各行の `live` は取得時点のスナップショットである事を `freshness`(C群、Swift実装)で明示 —
  「N秒前の値」を薄く出し、60秒を超えたら強調(`view.mjs` の閾値をそのまま踏襲)。
- タップで Conversation へ遷移。

### 2-3. Conversation

- 初期表示: `GET …/history?limit=50` → `history[]`(各要素 `{role, text}`)を吹き出しで描く。
  `role` の表示名は `display.who`(= `whoOf`、S群)。
- 直後に poll ループを開始(§3)。history と live の継ぎ目は `mergeHistory`(C群、Swift実装)で剥がす。
- 画面上部のバッジ(`screen`/`activity` の生値 + `display.routeLabel`):
  - `SENDABLE` + `activity:"observed"` → 「動いています」
  - `SENDABLE` + `activity:"unknown"` → 何も出さない(**沈黙を「待機」と読ませない** —
    `activity` は表示専用、送信可否の判定には使わない)
  - `CHOICE` → 固定文言「選択メニューが出ています。v1 では電話から選べません。机で確認するか、
    割り込みで中断してください」(§0-4 の通り `choiceView` は v1 で配線しない、生の `screen` 値だけで
    判定する)。composer は無効化。interrupt は有効のまま
  - `UNKNOWN` → 「画面の状態を読めていません」。composer は無効化、interrupt は有効のまま
- `truncated:true` の時、「以前を読む」ボタン。押すと `nextHistoryLimit`(C群)で再取得し、
  `mergeHistory` と同じ手順で結合。
- composer: `screen === "SENDABLE"` の時のみ活性。`POST …/messages`。応答は `display.sendResult`
  (S群)をそのまま描画 — 独自の文言判定は持たない。`keepText` が真の間は入力欄の本文を消さない。
- interrupt ボタン: `route !== "blocked"` の間のみ活性。応答は `display.interruptResult`(S群)を
  そのまま描画。`interrupted` の真偽だけで丸めず、`stopped` の4値(`verified`/`already-done`/
  `unverified`/`null`)をテキストへ反映する。

---

## 3. ネットワーク層

### 3-1. transport(§0-1 の訂正を反映)

- 全リクエスト共通: `Authorization: Bearer <key>` ヘッダ、`Content-Type: application/json`(POST時)。
- List/History/Messages/Interrupt: 単発の `URLSession.data(for:)`。
- Live 更新: `GET …/poll?cursor=<opaque>&wait=<ms>` を**単一の poll ループが**繰り返す(discrete
  request の反復であって、常時接続のストリームではない)。`wait` はサーバ上限 `POLL_MAX_WAIT_MS =
  20_000`(`server.mjs:622`)に合わせ 20000 を送る。クライアント側 `URLRequest.timeoutInterval` は
  **必ずこれより大きく**(推奨30秒)。サーバの保留上限より先にクライアントがタイムアウトすると、
  正常な「何も起きなかった」応答を通信エラーと誤認する。

### 3-2. cursor の扱い(不透明値、`tail.mjs` が正本)

- 形式: tmux `t.<epoch>.<seq>.<screenRev>` / worker `w.<generation>.<seq>.0`
  (`tail.mjs:78-80 formatPollCursor`)。Swift 側は**中身を解釈しない** — 受け取った文字列を次の
  リクエストへそのまま返すだけ。
- 初回(会話を開いた直後、または N4 再同期直後)は cursor を空文字列で送る = `pollDecision` の
  `fresh` 扱い(`tail.mjs:96`)。
- 経路が変わった場合、サーバは `gap` を返す。Swift 側は cursor を空にリセットし、`/history` を
  撮り直してから poll を再開する(§3-5)。

### 3-3. 1回の poll 応答の処理(N6: 先にステータスを見る)

1. `HTTPURLResponse.statusCode` を最初に見る。200 以外は本文をデコードする前にエラー分岐へ(§5)。
2. 200 なら JSON デコード。デコード自体が失敗したら、最後の既知状態を保持したまま次の poll へ進む
   (画面を白くしない)。
3. デコードが通っても、`items` の中身は `display.readablePoll`(S群、サーバ計算のブール値)を見て
   判定する。`false` の時は**適用せず**画面を最後の正常値のまま維持し、次の poll を続ける。
4. `items` を `kind` ごとに処理。`kind:"message"` は経路で形が違う: tmux = `entries`(整形済み配列)、
   worker = `event`(生の NDJSON 1行)。型を分けて扱う(enum ケースを分ける等)。
5. `screen` フィールドは `null` でなければ最新値として置き換え(順序付き履歴配列には混ぜない)。
6. `more:true` の場合、`wait:0` で即座に再 poll してバックログを排出しきってから通常の
   `wait:20000` 保留 poll に戻る(`POLL_MAX_ITEMS = 64`、`server.mjs:623`)。
7. `queued` は v1 では未使用(§0-4、queue 表示は v1 スコープ外)。将来 v2 で使う時のため、
   `null`(観測不能)と `0`(実数)を混同しない事だけここに記録しておく。

### 3-4. connection ownership(N3)/ D-C の反映

- poll ループの所有者は**表示中の Conversation 画面につき1つ**の actor。List 画面はいかなる poll も
  張らない(D-C = A)。理由: `POLL_MAX_HELD = 4`(`server.mjs:624`、会話1本あたりの同時保留上限)は
  「1画面が1本を張る」前提。移動中の細い回線で一覧の行数ぶん同時に long-poll を開くのは Tom の
  「地下鉄で電波が瞬く」実測前提と相性が悪い。
- Conversation 画面が閉じられると、poll ループの `URLSessionTask` を明示的に `cancel()` する。

### 3-5. N4(バックグラウンド復帰)

`scenePhase` が `.background` → `.active` に遷移した時: (1) 今開いている Conversation があれば、
poll を再開する前に `GET …/history` を撮り直す(fresh fetch)。(2) cursor を空文字列にリセットし、
取り直した history を土台に画面を再構築してから poll を再開する。理由: バックグラウンド中は iOS が
接続を切る。`POLL_LEASE_MS = 30_000`(`server.mjs:625`)や worker 側の generation 変化を跨いでいる
可能性が高く、古い cursor で再開を試みても `gap` を返されるのが関の山。

### 3-6. N2(切断は正常)+ backoff(C群)

- poll リクエスト自体が失敗(タイムアウト・接続不可・5xx)した時のみ backoff の対象。`wait` を使い
  切って「何も起きなかった」で 200 が返るのは失敗ではない。
- backoff は `frames.mjs:102 backoffMs(attempt)` を1:1移植: `attempt <= 0` なら 0、それ以外は
  `min(15_000, 1000 * 2^(attempt-1))`。
- 試行回数は `view.mjs:305 nextAttempt(attempt, openedAt, now)` を移植: 直前の接続が5秒
  (`HEALTHY_MS`)より長く開いていれば1にリセット、そうでなければ `attempt + 1`。
- 3回連続失敗するまでは目立つエラー表示を出さない(§3-9 参照、閾値は初期値・調整可)。4回目以降は
  §5-4 の「backend unreachable」表示に切り替える。

### 3-7. N5(redirect は Authorization を落とす)

`URLSessionTaskDelegate.urlSession(_:task:willPerformHTTPRedirection:newRequest:completionHandler:)`
で `completionHandler(nil)` を返し、redirect を追わない。3xx が来たら §5 の「想定外の応答」に分類。

### 3-8. 認証エラー

どのリクエストでも 401 が返ったら、poll ループを含む進行中の通信をすべて止め、Key-entry へ強制遷移。
Keychain の値は自動では消さない(一時的障害と鍵ローテーションを区別できないため)。

### 3-9. テスト方針

`ios/Sources/Core/`(SwiftUI・UIKit を import しない — `view.mjs`/`tail.mjs` と同じ規律の踏襲)に
ドメインロジックを閉じ込め、`ios/Tests/` の XCTest から検査する。各グループに負の対照を1本:

| 対象 | 検査の主眼 | 負の対照 |
|---|---|---|
| `PollCursor` | 中身を解釈しない事(bit-for-bit 往復) | パースして再構築するコードに戻すと、未知形式の cursor で壊れる回帰を固定 |
| `backoffMs`/`nextAttempt` | 上限15秒張り付き、5秒未満切断は reset しない | 上限の `min` を外すと発散する検査を先に red で確認 |
| poll 応答の分岐 | `readablePoll==false` の時に**適用しない**事 | 「適用しない」分岐を消すと壊れた応答が画面を上書きする回帰を固定 |
| N5 redirect 拒否 | スタブサーバの 302 に Authorization 付きで追随しない事 | delegate 実装を消すと自動追随してしまう回帰を1本で掴む |

---

## 4. 状態モデル

### 4-1. 会話単位のモデル

```
ConversationState {
  history: [Entry]              // 初期表示。role/text
  live: [LiveItem]               // poll で届いた kind:"message" の蓄積
  screen: ScreenState?           // 最新値のみ。順序付き配列には入れない
  activity: "observed"|"unknown"?
  cursor: String                 // 不透明、次の poll にそのまま渡す
  truncated: Bool                // 「以前を読む」を出すか
  lastGapNotice: String?         // 直近の gap 表示(§4-3)
}
```

`history` と `live` を `mergeHistory`(C群)で結合した結果を描画用の1本の配列として都度再計算する
(会話が長大でも表示中の1会話に限られ、`/history` 自体が既に末尾N件へ有界化されているため)。

### 4-2. 永続化(D-B = A、メモリのみ)

- 一覧行・会話履歴とも**ディスクへ書かない**。アプリ終了/再起動で消え、次回起動時は必ずネットワーク
  から再取得する。
- 理由: (1) DESIGN §6 は phone-loss を主脅威に置く。会話内容を端末に平文で複製すると、Keychain の
  鍵1点だけでなく会話内容そのものも紛失時の露出面に加わる。(2) §3-5(N4)がバックグラウンド復帰時に
  fresh fetch を要求する設計なので、ディスク永続化しても「アプリを開いた瞬間に前の絵を出せる」以上の
  得は無い。(3) REQUIREMENTS §5-6(「Loading で待たされない」)はネットワーク待ちで固まらない事を
  求めているのであって、ディスクキャッシュを要求していない。
- 例外: List 画面のみ、同一アプリセッション内でのメモリキャッシュ(stale-while-revalidate)を持つ。
  ディスクには書かない。

### 4-3. gap の扱い — `gapNotice` の抑制条件は poll では発火しない(明記)

`view.mjs:320 gapNotice(why)` は `why === "tail-attached"` を無害な初回接続として抑制するが、これは
**SSE 時代の `resumeDecision`**(`tail.mjs:52`)専用の値。poll 側の `pollDecision`(`tail.mjs:94`)が
返しうる `why` は `cursor-too-long`/`cursor-malformed`/`route-changed`/`epoch-mismatch`/
`ring-overflow` の5種のみで**`tail-attached` は含まれない**(初回 poll は `gap` でなく `fresh` を
返す、`tail.mjs:96`)。→ poll の世界では gap 項目は**常に本物の切れ目**。Swift 側の `gapNotice`
移植は抑制ロジックを持たない単純版(`why` があれば必ず表示)とする。関数自体は S群(payload のみの
純関数)なのでサーバ側で計算して良いが、抑制条件が構造的に無意味である事はコードコメントに残す。

### 4-4. `display.sendResult`/`display.interruptResult` は描画するだけ

Sprint 0.5 完了後、これらはサーバ計算済みフィールドとして届く。Conversation ViewModel は届いた
`kind`(`ok`/`warn`/`refused`/`error`)で色とアイコンを出し分けるだけで、文言・成否判定ロジックを
一切持たない。

---

## 5. エラー・空状態(画面別)

### 5-1. Key-entry

| 状況 | 表示 |
|---|---|
| `healthz` 到達不能 | 「サーバに届きません。URL を確認してください」 |
| `healthz` は通るが `/api/sessions` が401 | 「鍵が違います」 |
| 両方200 | 保存して List へ |

### 5-2. List

| 状況 | 判定材料 | 表示 |
|---|---|---|
| 真に0件 | `sessions:[]` かつ `paneFault:null` | 「会話がありません」+ `display.scanLine` |
| `paneFault` あり | `paneFault.reason` | 一覧の上に専用バナー |
| fetch 自体が失敗 | HTTP層 | 「backend unreachable」— 最後に取得できた一覧(メモリキャッシュ)を
  グレーアウトして残し、赤バナー+手動再試行。**空一覧に差し替えない** |
| 401 | HTTP層 | Key-entry へ強制遷移 |

### 5-3. Conversation

| 状況 | composer | interrupt | 表示 |
|---|---|---|---|
| `history:[]`(新規会話) | `screen`次第 | `route`次第 | 「まだ発言がありません」 |
| `TRANSCRIPT_UNREADABLE`(500) | 無効 | 無効 | 「履歴を読めませんでした」+ 再試行 |
| `route:"blocked"` | 無効 | 無効(サーバも同じ理由で409) | サーバの `message` をそのまま表示。
  理由コードを生で出さない、独自文言に丸めない |
| `screen==="CHOICE"` | 無効(固定文言、§2-3) | **有効**(`interrupt` ハンドラは `screen` を
  条件にしない、`server.mjs:1132-1167`) | 固定文言 |
| `screen==="UNKNOWN"` | 無効 | 有効(理由は同上) | 「画面の状態を読めていません」 |
| poll が `readablePoll==false` | 変更しない | 変更しない | 変更しない(画面を白くしない) |
| poll が3回連続失敗 | 直前の状態を維持 | 直前の状態を維持 | 「backend unreachable」赤バナー |
| 401(表示中に発生) | — | — | Key-entry へ強制遷移 |

### 5-4. 共通: 「backend unreachable」の定義

接続不可・タイムアウト・5xx が**連続3回**発生した状態(§3-6 と統一)。List/Conversation 共通の
コンポーネントとして文言・見た目を1箇所にまとめる。復帰(1回でも成功)したら即座に消す。手動で
「消す」操作は用意しない。

---

## 6. スプリント計画(7日で4機能を実機到達)

前提: Sprint 0(プロジェクト骨格・署名・実機 install 経路)は §0-3 のとおり**完了済み**。以下は
2026-08-05 を Day 0 として Day 1 から数える。各 Sprint の Definition of Done は「(a) `ios/Tests`
の該当検査が green」+「(b) 客観的検証コマンドの出力」の両方。

検証コマンドの原則(開発 Mac で GUI ウィンドウは開かない):

- Simulator: `xcrun simctl boot "iPhone-dogfood"`(headless)→ 実行 →
  `xcrun simctl io "iPhone-dogfood" screenshot <out>.png`
- 実機: `ios/tools/build.sh`(署名+install)→
  `xcrun devicectl device process launch --console --terminate-existing --device <id> com.tomarai.remotemini`
  でコンソールログを標準出力へ流し、期待する診断ログ行の有無を `grep` で確認
- 単体検査: `./ios/tools/build.sh --sim`(内部で `xcodebuild test`)

| Day | Sprint | やること | Definition of Done / 検証 |
|---|---|---|---|
| 1 | **0.5**(rc-backend、§0-4) | `view.mjs` の S群8本(v1 で使う分のみ、`choiceView`/`choiceResult`/`clearQueueResult` は defer)をサーバが呼び、`display` 名前空間の追加フィールドとして `/api/sessions`・`/history`・`/status`・`/poll`・`/messages`・`/interrupt` の応答へ足す。既存フィールド不変、`app.html` 無改修 | rc-backend の既存テスト(352 unit + 150 e2e)全て green のまま、`display` 各フィールドに `view.mjs` 戻り値との一致検査を8本追加(§0-4 条件4)。`test/app-html.test.mjs`(約44件)が無改修で通る事が「無改修」の証明。**担当は team-lead 判断**(私は spec 以外に触れない) |
| 1 | 1 | Core モジュール雛形: `PollCursor`、`backoffMs`/`nextAttempt`、Keychain 保存層、`/healthz` 疎通クライアント。Key-entry 画面実装 | 単体: `PollCursor` 不透明性検査・`backoffMs` 上限検査 green。実機: `devicectl device process launch --console` のログに自前の診断ログ `healthz ok:true pid:<n>` を出力させ `grep` で確認 |
| 2 | 2 | List 画面: `GET /api/sessions` クライアント、行UI、`display.subtitle`/`display.scanLine`/`freshness`/`relTime`、pull-to-refresh、§5-2 の3分岐 | 単体: `freshness` 閾値(60秒)検査 green。Simulator: fixture 応答での `paneFault` あり/なし/空一覧3状態のスクリーンショット、バナー文字列を Accessibility identifier 経由で XCUITest 確認 |
| 3 | 3 | Conversation 画面: `GET …/history` クライアント、吹き出しUI、`mergeHistory`、`truncated`+「以前を読む」 | 単体: `mergeHistory` 重複剥がし検査(正常系+「同じ発言2回で剥がしすぎる」既知限界の検査)。Simulator: fixture 応答スクリーンショット |
| 4 | 4 | poll ループ(§3全体): 単一owner の poll actor、gap処理(§4-3訂正版)、N4フォアグラウンド復帰時fresh fetch、`more:true` 即時再poll | 単体: スタブ `URLProtocol` で駆動する poll状態機械の検査群(正常/gap/screen-only/`readablePoll==false` の4分岐、最後は負の対照込み)。実機: edith上の1会話にpollを張り、バックグラウンド→フォアグラウンド遷移後に「history refetched before poll resumed」ログが1行出る事を確認 |
| 5 | 5 | composer(送信): `POST …/messages`、`display.sendResult` 描画、CHOICE/UNKNOWN時の無効化 | 単体: `sendResult` 全分岐(202+verified/202+unverified/202+worker/409/400/401/5xx/本文なし)テーブル駆動検査。実機: edithのテストセッションへ実送信、`delivered:"verified"` 観測 + `ssh edith` で対象jsonl末尾行増加を確認 |
| 6 | 6 | interrupt + ネットワーク堅牢化: `POST …/interrupt`、`display.interruptResult`描画、N5 redirect拒否の負の対照検査、backend-unreachableバナー(§5-4)全画面適用 | 単体: `interruptResult` 4分岐 + N5 検査。実機: 生成中セッションへinterrupt送信、`stopped:"verified"` 観測 |
| 7 | 6.5 | 統合仕上げ: 4機能を実回線(Wi-Fi→セルラー切替、機内モード往復、rc-backend再起動を挟む)で通し。REQUIREMENTS §5 のうちv1該当分(#1-3,#5-7,#9。#4は push不可のため対象外、#8はアカウント切替除外のため対象外)を証跡付きで確認 | チェックリスト+証跡(スクリーンショット/ログ抜粋)を `.harness/evidence-2026-08-1x/sprint6-acceptance.md` に記録(Evaluator/Generator の成果物。本spec はその期待値を定義するのみ) |

Day 7 終了時点で v1 の4機能が実機で動作。残り(渡米まで2026-08-20)は実運用の不具合修正と v2 候補
(§7)の着手判断に充てる。

---

## 7. v2 候補(v1 に含めない。理由付きで明記)

| 候補 | 出典・根拠 | v1 で含めない理由 | 着手コストの目安 |
|---|---|---|---|
| **アカウント表示・切替** | REQUIREMENTS §4-5(Tom逐語)/ §5-8 が合格条件に明記 | team-lead の v1 スコープ指示で明示除外。**REQUIREMENTS 側は必須要件として記録済みであり、静かに落とすと明記要件を無断で削る失敗になる — team-lead の再確認を推奨** | 低。`GET /api/account`/`POST /api/account/next` はサーバ実装済み(`server.mjs:961-976`)。UI側はラベル+ボタン1つ |
| **CHOICE画面への回答** | D-A(本spec)。サーバ・PWAとも実装済み(2026-08-03/04出荷) | §1-a に理由詳記 | 低〜中。`choiceView`はS群として既に分類済み(§0-4)、Sprint 0.5 へ2関数追加するだけで済む。Swift側は選択肢一覧+2ボタン+digest照合の1画面 |
| **push通知(入力待ちを電話へ通知)** | REQUIREMENTS §5-4 が合格条件に明記するが、wildcard profile はpush entitlementを運べない | 構造的制約。正規App ID+明示provisioning profile(Tom Apple IDログイン要)= 真のTomゲート | 高。entitlement取得自体がTomゲート。取得後もAPNs連携の実装が別途必要 |
| **送信待ちキュー表示・取消** | `queueView`/`clearQueueResult`(§0-4 で defer 済み)、`DELETE …/queue` はサーバ実装済み | v1の4機能に無い | 低。S群1関数(`clearQueueResult`)+C群1関数(`queueView`)を足すだけ |

push通知が取れない間の緩和策として、フォアグラウンドで開いている間だけの軽い代替(List画面で
`SENDABLE`+`activity:"unknown"` に切り替わった行へのハイライト)はv1範囲内で安価に足せるが、これは
REQUIREMENTS §5-4 が求める「ロック中/非フォアグラウンドでも気づける」を満たさないため合格条件の
充足とは呼ばない — v2候補にのみ計上する。

---

## 8. 出典表

| 主張 | 出典 |
|---|---|
| long-pollが本線、SSEは死んでいる | `DESIGN.md` §2.36、`app.html:171,403,418-419`、`server.mjs:1257-1420` |
| cursor形式・定数 | `tail.mjs:78-107`、`server.mjs:622-625` |
| S/C判断分割・再検証 | `DESIGN.md` §2.13 内2026-08-05追記、team-lead ruling メッセージ、`view.mjs`各関数(本文中に行番号記載) |
| `ios/`骨格が実機到達済み | `ios/tools/build.sh`、`ios/project.yml`、`ios/Sources/RootView.swift`のコメント |
| block理由・文言 | `blocked.mjs`全体、`server.mjs:369-423` |
| 応答フィールドの契約(messages/interrupt/poll) | `server.mjs:1038-1420` |
| アカウント切替のTom逐語 | `REQUIREMENTS.md:151-157` |
| 合格条件9件 | `REQUIREMENTS.md:161-176` |
