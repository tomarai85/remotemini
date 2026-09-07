# 割り込みの正直さ(overlay が開いていた時)+ 机が止めた subagent の一覧(2026-09-07、round 10)

## 1. 何が起きていたか(実機 friday 09:13、`repro-shell-kill-screens.log` C → E)

| 段 | 画面 | 机の応答 |
|---|---|---|
| C | subagent の詳細 overlay が開いている(`general-purpose › count slowly`、23s) | — |
| interrupt | `POST /interrupt` → Escape 1 回 | `{"interrupted":true,"stopped":"verified","display":{"text":"Stopped (generation confirmed stopped)."}}` |
| E | overlay が閉じ、composer。同じ subagent は 29s で走り続けている | — |

`#interruptExclusive` は生成の印(spinner / `Interrupted` の行)しか見ず、overlay の存在も「どの生成」も知らなかった。Escape は overlay を
閉じただけ。round 9 の Planner は此れを「subagent を止めたと偽った」と読んで題にし、Reviewer が REJECT_FALSE(系譜の主張が偽 + 原因の
言い過ぎ)。round 10 で「机が知り得る事だけを言う」形に直して Reviewer APPROVE。

## 2. 処置

- inject.mjs: `overlayKindIn(text)` = panel / detail / panel-empty / null(最後の `▔` 区切りより下に composer が無い時だけ)。`#interruptExclusive`
  は打つ前に其れを見て、在れば Escape 1 回 → 閉じたのを見て `stopped:"overlay-closed"`(reason = 種類)/ 見えなければ
  `stopped:"unverified"`(reason `overlay-stuck`)。overlay が無ければ従来の道(不変)。
- view.mjs: `overlay-closed` → warn "Closed the agent panel on the desk; nothing was interrupted. Tap Stop again to interrupt." /
  `unverified` + `overlay-stuck` → warn "An agent panel is open on the desk and did not close; nothing was interrupted. Check the screen."
- server.mjs: 不変(`interrupted` は verified の時だけ true)。電話は `display` しか読まない(`InterruptClient` の契約)。
- `emptyPanel` の判定を driver から inject.mjs(`emptyPanelIn`)へ移動。

検査 `test/interrupt-overlay-honesty.test.mjs`(7)。既存 227 + honesty 対照 15/15 は不変。

## 3. 机が止めた subagent を一覧が直ちに返す(同 commit)

一覧は転写の mtime で生死を読むので、止めた直後も最長 15 分「Working」のまま(帯は Stopped)。`DeskStopMemory` が観測した停止
(`stopped:"observed"`)だけを覚え、`stateOf` は 転写の終了記録 > 机の観測 > mtime の順に読む。止めた後も転写が猶予 5 s を超えて
動いていれば記憶を捨てる。display "Stopped"。検査 `test/subagent-desk-stop-memory.test.mjs`(11)。

## 4. Codex(`codex-interrupt-overlay.out`、DON'T SHIP as-is、10 所見)と処置

| # | 所見 | 処置 |
|---|---|---|
| 1 | 偽陽性: 生成の本文が「区切りの下・composer 無し」に見えて overlay と誤認 → 本当の止まりを under-report | 判定は区切りだけでなく panel の文(Background + 節 + `↑/↓ to select … Esc to close` / `No tasks currently running`)を要求する。引用された panel の文は composer が見えていれば overlay にしない(既存の guard)。残余として記録 |
| 2 | 偽陰性: 崩れた・古い panel は検出を逃れ、旧来の判定が「止めた」と言う | **畳んだ**: 入力欄が見えていない画面では「静かになった」を止まりの根拠にしない(`unverified` / `overlay-unknown`)。印(`Interrupted` の行)が増えた時だけ verified |
| 3 | TOCTOU: 撮った後に overlay が自分で閉じ、Escape が親に届く | **畳んだ**: overlay の道でも印を先に見る。増えれば verified を名乗る |
| 4 | 2 度目のタップは親の生成を止める(パネルが見せていた agent ではない)。文で言え | **畳んだ**: "Tap Stop again to interrupt the conversation, or stop one agent from Running." |
| 5 | overlay が消えた事と生成が interrupted に遷移しなかった事の両方を確かめよ | #2/#3 で実質畳んだ(印が増えれば verified、増えず composer が無ければ unverified) |
| 6 | B: 行の消失は UI の除去で、kill の失敗や書かない agent(sleep 中)を隠す | `/tasks` の行は TUI 自身の task 一覧で、x で消えるのは TUI が其の task を止めた時。転写の沈黙は追加の条件(消えた + 書かれない)。残余として記録 |
| 7 | B: 5 秒の猶予は遅延書き込みを解かない | 実測(single run1 / shell run4)では x 直後から 1 byte も動かなかった。猶予を超えて動けば記憶を捨てる = 嘘は時間で自己修正する。記録 |
| 8 | B: Stopped → Working の揺れ | 正直な訂正として受け入れ(揺れるのは「止まっていなかった」時だけ)。記録 |
| 9 | B: `finished` は成功の完了と読まれうる。別の終端状態 `stopped` を | state の語彙は電話・台帳と共有(4 値)。今回は `finished` + reason `stopped-by-desk` + display "Stopped" で利用者には見える。5 値目は台帳を跨ぐので次の題の候補。記録 |
| 10 | 形の推定でなく overlay の同一性、送る前の競合、`stopping` の暫定状態を | #3 と #2 で競合の両側を畳んだ。overlay の同一性(id)は TUI に無い(9/6 実測)。`stopping` は候補。記録 |

検査 +2(TOCTOU で verified / 認識できない overlay で unverified・印が増えれば verified)。全 191 緑。

## 5. 本番での確認(friday `b7ada08`、`live-interrupt-overlay-run1.log`)= 0

使い捨ての会話(idle)に `/tasks` を送って空パネルを開き(pane の撮影で "No tasks currently running" を確認)、`POST /interrupt`。

| 欄 | 値 |
|---|---|
| 応答 | `interrupted:false`, `stopped:"overlay-closed"`, `reason:"panel-empty"`, waitedMs 102 |
| 電話の文 | "Closed the agent panel on the desk; nothing was interrupted. Tap Stop again to interrupt the conversation, or stop one agent from Running." |
| 画面 | 2 秒後に SENDABLE、overlay 無し(撮影で composer を確認) |
| 対照(overlay 無しの pane に interrupt) | 従来どおり `stopped:null`, `reason:"not-in-flight"`("Nothing was running to stop") |

detail overlay が開いた形(09:13 の実物)は、driver の修正(`d079666`)以降 机が自分では残さなくなったので、本番では空パネルで確かめた。
detail / panel の形は実画面 fixture の単体検査(`interrupt-overlay-honesty.test.mjs`)が担う。
