# 対照表 #8 の後半 —— 限界 1・2 の本番実測(2026-09-07)

裁定(`shell-row-default-decision.md`)を本番の机で見る。会話は使い捨て(`rc-e2e-<n>`)だけ。実会話には触らない。
机 = friday、Claude Code 2.1.263(rc-claude 経由 80x24 ではなく 120x40 の tmux)。

## 1. shell 形(限界 1: シェル行が在るパネルでは断る)

### run1(計器 v2、対照なし)= 0

`live-subagent-stop-shell-run1.log`。机 = `055a084`。

| 欄 | 値 | 意味 |
|---|---|---|
| one_running | 1 | `count slowly` が 1 本 running(21 s) |
| shell_seen | 1 | `sleep 240` が机の ps に在る |
| stop_http / reason | 409 / shells-present | 裁定どおり断った |
| sent / keys | 0 / `["-l /tasks","Enter","Escape"]` | パネルを開いて閉じただけ。x も矢印も無い |
| agent_running | 1 | 転写 181318 → 197927 → 201487 |
| shell_alive | 1 | 断った後もシェルは生きている |
| torn_down | 1 | 使い捨てを畳んだ |

### Codex の 6 指摘(`codex-shellrow-live.out`、DON'T SHIP)と処置

| # | 指摘 | 処置 |
|---|---|---|
| 1 | 「断った」≠「打っていない」。x が別の所に落ちても緑になる | 机の鍵列(driver が打った順の記録)を読み、`/tasks`・Enter・Escape 以外が 1 つでも在れば `pressed_none=0` |
| 2 | `pgrep 'sleep 240'` は此の会話の物と限らない | `sleep 240.<6 桁 nonce>`(sleep に正当な引数、ps の引数列に残る)。pgrep は `[2]40\.<nonce>` |
| 3 | TUI が其のシェルの行を出していた事を見ていない | driver が `shells-present` の断りに **見えたシェル行の本文** を `after.shells` で載せる。計器は其処に nonce を探す(`shell_row_seen`) |
| 4 | 転写の伸びは脆い(書き遅れで偽の赤) | 偽の**赤**の方向なので据え置き。`sleep 12` は 12 秒ごとに 1 record、区間は 15 s × 2 |
| 5 | 409 が別の理由で恒真になりうる | #3 で閉じる(nonce 入りの行が机の断りに在る = 此のシェル由来) |
| 6 | 対照が無い: シェルを消して撃ち直し、止まる事を見よ | 同じ会話で pid 名指しに殺し、10 s ごと最長 90 s 撃ち直す。緑 = `retry_http=200 retry_stopped=observed target_frozen=1` |

残る限界(明記): `pressed_none` は机が自分で書いた鍵列に依る。独立の証拠は間接(agent の転写が伸び続け、シェルが生きた)だけ。
tmux 側に独立の鍵の記録は無い。

### run2(計器 v3、対照あり)= 赤 —— 断りの半分は全欄緑、対照が driver の穴を見つけた

`live-subagent-stop-shell-run2.log`。机 = `fd3775b`。

| 欄 | 値 |
|---|---|
| shell_seen / one_running | 1 / 1(nonce 847595) |
| stop_http / reason / sent | 409 / shells-present / 0 |
| pressed_none | 1(鍵列 = `-l /tasks`, `Enter`, `Escape`) |
| shell_row_seen | 1(`after.shells` = `["sleep 240.847595 (running)"]` —— TUI のシェル行は `sleep 240.847595 (running)` の形) |
| agent_running / shell_alive | 1 / 1 |
| **retry_http / retry_reason** | **409 / panel-did-not-open**(after = `{screen:"DETAIL", overlay:"DETAIL"}`、鍵列 `-l /tasks`, `Enter`) |
| target_frozen | 0(x は押されていない) |

### 穴の正体(再現 3/3、`repro-shell-kill-screens.log`)

背景シェルが終わると(殺すと)パネルの task は subagent 1 本だけになり、`/tasks` は**一覧を描かずに其の詳細へ直行する**
(footer "← to go back · Esc/Enter/Space to close · x to stop · f to foreground")。以前の driver は其処で `panel-did-not-open` と断り、
**開けた詳細を残していた** —— 実測では其の後の interrupt(Escape)が親の生成に届いた。task が 0 本なら「Background / No tasks
currently running」の空パネル(節が無い)。

処置 = 直行した詳細を `planDirectDetail` で照合して同じ pressX へ、空パネルは `no-such-row`(overlay は閉じてから)。実画面 2 枚を fixture に。

### run3(driver `d079666`)= 赤 —— 別の穴: 親の手番の終わり際に `/tasks` を打った

`live-subagent-stop-shell-run3.log`。最初の stop が `panel-did-not-open`、鍵列は `-l /tasks` の 1 打だけ、after = `{screen:"UNKNOWN"}`、
入力欄は空。親の転写(attic)では 09:27:19 に親の返事、09:27:23 に hooks の記録、stop は 09:27:24 —— 親の手番の終わり際
(spinner "Wrangling… running stop hooks")に打っていた。生成中の入力欄に打った文字は TUI が queue として扱う。

| 何が | 処置 |
|---|---|
| driver | 入力欄が SENDABLE でも `activity: observed`(spinner が見えている)なら打たない = `not-sendable`(why `in-flight`)。実画面 `friday-running-spinner.txt` で検査 |
| 計器 | single / shell では**親が静かになるまで待つ**(親の転写の mtime が 10 s 動かない、最長 90 s)。期待外れの応答では pane を撮って log に残す |

### run4(driver `d079666`、計器は静かな親を待つ版)= 0

`live-subagent-stop-shell-run4.log`。

| 欄 | 値 |
|---|---|
| one_running / parent quiet | 1 / 10 s(37 s) |
| shell_seen / shell_row_seen | 1 / 1(`after.shells` = `["sleep 240.278776 (running)"]`) |
| stop_http / reason / sent / pressed_none | 409 / shells-present / 0 / 1(鍵列 `-l /tasks`, `Enter`, `Escape`) |
| agent_running / shell_alive | 1 / 1 |
| retry(シェルを殺して撃ち直し) | **200 observed**。鍵列 `-l /tasks`, `Enter`, `-l x`, `-l /tasks`, `Enter`, `Escape` = 一覧を飛ばした詳細で x → overlay ごと閉じた → 開き直して空パネルで数えた(`stopObserved: reopened`) |
| target_frozen | 1(204874 → 204874 → 204874) |

読み: 裁定(シェル行が在れば断る)は本番で本物 —— 断りの根拠に此のシェルの行が載り、何も打たず、両方生きている。断りの助言
「シェルが終わってから撃ち直せ」も本物 —— シェルが消えれば同じ口が止める。★直行した詳細で x を押すと overlay は**閉じる**
(一覧に戻らない。一覧の道では行が消えて一覧に戻る = 2026-09-06 の実測)。driver は開き直して数えるので観測は閉じている。

## 2. single 形(限界 2 の隣: 最後の 1 本を止めると空パネル)= run1 で 0

`live-subagent-stop-single-run1.log`。机 = `d079666`。走っている subagent が 1 本だけの会話で其れを止める。

| 欄 | 値 |
|---|---|
| one_running / parent quiet | 1 / 12 s(27 s) |
| stop_http / stopped | 200 / observed(29 s) |
| 鍵列 | `-l /tasks`, `Enter`, `-l x`, `-l /tasks`, `Enter`, `Escape` = 一覧を飛ばした詳細で照合して x → overlay ごと閉じた → 開き直して空パネル(節無し)で数えた(`observed_via=reopened`)→ Escape 1 回で閉じた |
| target_frozen | 1(183403 → 183403 → 183403) |
| screen_after | SENDABLE、overlay 無し(パネルを残さない) |

読み: 「最後の agent を止めた後の空パネル」は実機で **`/tasks` が一覧を飛ばして詳細に直行する形**として現れ、x の後は overlay が閉じる。
空パネル(No tasks currently running)は開き直した時に見え、driver は其れを「減少」と読む。2026-09-06 の未測定は閉じた。

## 3. 一覧が見えない物を名乗る(限界 2)

`GET /subagents` の `display.note` が毎回 "Background shells and teammates are not listed here." を名乗る(読めない 2 枝は除く)。
電話は文を其のまま描く(`subagents.note`)ので電話側の変更なし。検査 = `test/subagents-note.test.mjs`(7、否定対照つき)。

## 4. 副産物(此の題の外、記録だけ)

- 机の `POST /interrupt` は overlay(詳細)が開いている時も Escape を打つ。今回は overlay を閉じた上で「stopped: verified」を返した
  (親の生成が同時に終わった可能性と、Escape が生成を切った可能性を分けていない)。overlay が開いている時の interrupt の意味は未整理。
  ★r9 の Planner が此れを「interrupt が subagent を止めたと偽った」と読んで題にし、Reviewer が REJECT_FALSE(系譜の主張が偽 +
  原因を言い過ぎ)。**正しい残余**(Reviewer の note): `#interruptExclusive` は pane の busy/quiet の印しか見ず「subagent」の概念が無く、
  固定の文 "Stopped (generation confirmed stopped)." は**どの生成**が止まったかを言わない。overlay が走行中の subagent を見せている
  時に其の文は誤解を招く。次の題にするなら: overlay が見えている時の interrupt は「overlay を閉じた」と名乗り、生成の判定を言わない。
- 使い捨て会話は Tom の hooks(stop hooks 0/2)を走らせる。計器の時間に数秒足す。
- ★候補(r9 の CRITIC lens「電話の利用者は何を見るか」): 止めた直後、電話の一覧の行は最長 **15 分**「Working」のまま
  (`rc-backend/src/subagents.mjs` の `SUBAGENT_STALE_MS = 15 min`、転写の mtime だけで生死を読む)。電話は `stoppedHere` で
  Stop ボタンを隠し、帯が「Stopped」と言う(`SubagentsViewModel.tapStop` の注記「止めた直後は行がまだ running に見える」)。
  机は x を押してパネルで行が減ったのを**見ている**のだから、其の観測を一覧に反映できる: session ごとの「机が止めた agent」を
  覚え、転写が終了を言うまで `state: finished`(reason `stopped-by-desk`)で返す。信号 = 帯と行が 15 分間 矛盾する。

## 5. Codex(直行した詳細の道、`codex-direct-detail.out`、DON'T SHIP)と処置

| # | 指摘 | 処置 |
|---|---|---|
| 1 | 内容の一致は同一性ではない。同じ説明・prompt・道具列の隣が入れ替わっていれば x は其方に効く。不変の id が要る | TUI の行にも詳細にも id は無い(9/6 実測)。一覧の道と同じ残余として受け入れ。prompt が隣と同じなら `promptDistinct` が外れて `twin-without-prompt`(ambiguous)で断る。残るのは「目標を組んだ後に同じ prompt の新しい隣が起きた」場合だけ |
| 2 | `before = 1` は「1 本なら直行」の逆を仮定している | 逆が偽でも向きは安全側: 一覧に同名の running が残れば減少と読めず `unverified`(x は押した後)。空パネルは全部が消えた = 目標も消えた |
| 3 | 開き直しの `/tasks` は手番が再開すると model への文になりうる | **畳んだ**: 開き直す前も spinner の veto(`activity: observed` なら打たず `unverified`)。検査 +1。残余 = echo と Enter の間の再開(送信の経路と同じ受け入れ) |
| 4 | spinner が無い = 静か、ではない | 机に権威ある手番の信号は無い(tmux の画面しか無い)。計器側は親の転写の mtime で二重に見る。記録 |
| 5 | 減少は原因に束ねられていない(自然終了が成功に見える) | 利用者に見える結果(もう走っていない)は同じ。「止めた」の言葉が僅かに強い。転写の終了記録で区別できるかは未調査 → 候補 |
