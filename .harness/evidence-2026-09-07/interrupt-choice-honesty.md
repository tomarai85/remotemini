# 割り込みは選択画面に触らない(2026-09-07、round 11)

## 1. 何が危なかったか
`#interruptExclusive` は round 10 で overlay(panel / detail / 空パネル)を見る様になったが、**選択画面(CHOICE)は見ずに Escape を
打っていた**。選択画面での Escape はメニューへの答え(許可の確認なら「断る」= 道具の取り消し)であって割り込みではない。
電話は許可の確認に答えない(対照表 #17 の裁定)し、良性のメニューに答える口は指紋つきの `choice` 経路だけ(#18)。
Reviewer(r11、APPROVE)が cited 行を全部照合: `overlayKindIn` は CHOICE を知らず、`#interruptExclusive` は `.activity` しか読まず
無条件に Escape を送る。§2.18-11「割り込みは常に受理」は鍵の層の話で、此処とは矛盾しない。

## 2. 処置
- inject.mjs: 撮った画面が `CHOICE` なら**何も押さず** `stopped:null, reason:"choice-open", waited:0`(overlay の判定より先)。
- view.mjs: "A menu or permission prompt is open on the desk, so nothing was pressed. Answer it from the choice buttons (menus) or on the Mac (permissions)."
- server.mjs: 不変(`interrupted` は verified の時だけ true)。
検査 `test/interrupt-choice-honesty.test.mjs`(6: 実画面 3 枚が CHOICE / 許可の確認で send-keys 0 / メニューでも / 対照 = 生成中は Escape → verified /
電話の文 / server の封筒)。既存 230 緑、mutation の的 246/246、honesty 対照 15/15。

## 3. 研究題(同 round): 停止の原因は転写で区別できる
`subagent-stop-cause-binding-verdict.md` = **distinguishable**。親の転写の `<task-notification>` が `killed`(「stopped by user」)/
`completed` / `failed` を書く(本番 friday の attic 転写 2 本で実測)。発見: `scanParent` は `completed` しか `done` に入れないので、
止めた agent は mtime で running のまま(round 10 の `DeskStopMemory` は其の穴の橋)。次の題 = `killed` / `failed` を done に読む。

## 4. Codex(`codex-interrupt-choice.out`、DON'T SHIP、6 所見)と処置

| # | 所見 | 処置 |
|---|---|---|
| 1 | 許可の確認で押さないのは正しい(#17 が停止の意図より上。鍵の層の「常に受理」は要求の受理であって打鍵ではない) | 一致 |
| 2 | 文は「何故押さないか」を言え(消すと答えになる) | **畳んだ**: "…so Stop pressed nothing: dismissing it from here would answer it. Resolve it on the Mac, or use the choice buttons for a menu." |
| 3 | 番号つきの本文を CHOICE と誤認して、本物の生成が電話から止められなくなる | `menuAt` は入力欄より上(履歴)を読まず、番号行だけでは足りない(選択の印 `❯` を持つ 2 行以上の塊、または既知の文言)。送信の経路が同じ判定で modal を断っており、其処と同じ残余。記録 |
| 4 | 指紋つきの `choice` の判定器を使え | 判定器は既に構造(印・塊・入力欄の不在)で、指紋(MATCHERS)は「良性か」を決める側。割り込みは「触らない」だけなので構造の判定で足りる。記録 |
| 5 | 未知の menu 形は Escape に落ちて #17 を破る | 残余(判定器が知らない形は送信の経路でも通る)。「入力欄が無い未知の画面を全部断る」は生成中(spinner で入力欄が隠れる形)の割り込みを殺すので採らない。記録 |
| 6 | overlay の判定を CHOICE より先に | **畳んだ**: `overlayKindIn` を先に見る。検査 +1(panel の画面は overlay-closed で choice-open にならない) |

検査 198 緑(choice 7 / overlay 9 / inject / view)。

## 5. 本番での確認(friday `17f92fd`、`live-interrupt-choice-run2.log`)= 0

使い捨ての会話(idle)に `/model` を送ってモデルの選択メニュー(良性の CHOICE)を開き、`POST /interrupt`。

| 欄 | 値 |
|---|---|
| 開く前 | `/status` = CHOICE、pane に "Select model … ❯ 2. Sonnet ✔ … Esc to cancel" |
| 応答 | `interrupted:false`, `stopped:null`, `reason:"choice-open"`, waitedMs 0 |
| 電話の文 | "A menu or permission prompt is open on the desk, so Stop pressed nothing: dismissing it from here would answer it. Resolve it on the Mac, or use the choice buttons for a menu." |
| 後 | `/status` = CHOICE のまま、pane にメニューが**開いたまま**(Escape は打たれていない) |

run1(`live-interrupt-choice-run1.log`)は机は同じ応答で、台本の文言照合が Codex #2 の前の文のままだった為の赤(台本を直して run2)。
許可の確認(permission prompt)の形は本番の使い捨て会話が auto mode で出さないので、実画面 fixture の単体検査が担う。
