# 止められた subagent は 5 つ目の状態 `stopped`(2026-09-07、round 11、Codex interrupt-overlay #9)

## 1. 何が問題だったか
round 10 は机が止めた agent を `finished` + reason `stopped-by-desk` で返した。`finished` は成功の完了と読まれうる(counts.finished に混ざる、
電話は state で分ける)。止められた事は別の終端状態。研究の判定(`subagent-stop-cause-binding-verdict.md`)で、Claude Code 自身が親転写に
`<status>killed</status>`「stopped by user」を書く事が分かったので、其れも同じ状態の源にする。

## 2. 処置
- `SUBAGENT_STATES` に `stopped`(表示 "Stopped")。`counts.stopped`(空の形にも鍵が在る)。一覧の note に "N stopped"。
- 源 (a) 親転写の `killed` 通知(`completionsIn` が id → 通知の時刻を集める)= reason `stopped-by-user`。机の再起動でも消えず、
  Mac の鍵盤からの停止も拾う。★止められた agent は**再開できる**(通知の note)ので、通知の後(猶予 5 s を超えて)に転写が動いていれば
  再開した = killed を捨てて mtime で読む。通知の時刻が読めない時は通知を信じる。
- 源 (b) 机の観測(`DeskStopMemory`)= reason `stopped-by-desk`(round 10 の形、state だけ `stopped` へ)。
- 順位(Codex の後の最終形): 親転写の最後の終端が completed > 転写が読めない → unknown > 机の観測(親に依らない)> 親が読めない → unknown > killed(時刻で再開を見抜く)> 走査の予算 > mtime。`failed`(背景シェルの失敗の形)は読まない。
- 電話: `SubagentCounts.stopped: Int?`(古い机の応答も読める)。display は其のまま描くので画面の変更なし。
- 台帳: `wire-key-agreement` の counts の specimen に `stopped`。既存の counts の期待値 4 箇所に `stopped: 0`。

検査: `test/subagent-stopped-state.test.mjs`(13)+ `subagent-desk-stop-memory`(11、finished → stopped に更新)+ 台帳。

## 3. Codex(`codex-stopped-state.out`、DON'T SHIP、7 所見)と処置

| # | 所見 | 処置 |
|---|---|---|
| 1 | 集合の順位は歴史を失う(completed → 再開 → killed が finished になる)。最後の終端が勝つべき | **畳んだ**: `completionsIn` は終端を id → {status, ts} で持ち(ファイルの並び = 古い順で上書き)、`done` / `killed` は其処から導く。検査(両方向) |
| 2 | 再開が壊れる(killed の後に走り続ける agent が stopped のまま) | 既に畳んであった: 通知の時刻より後(猶予超)に転写が動けば killed を捨てて mtime。検査あり |
| 3 | 帰属が偽(机の停止も killed を書くので stopped-by-user に隠れる) | **畳んだ**: 机の観測を killed より先に見る → reason は `stopped-by-desk`。検査あり |
| 4 | 末尾しか読まないので古い killed は stalled に化ける | 走査の窓より古い agent は既存の `scan-budget` で `unknown`(stalled ではない)。記録 |
| 5 | 古い電話の閉じた state enum が `stopped` の行を復号できない | 電話の `SubagentRow.state` は `String`(閉じていない、`SubagentModels.swift`)。counts は optional。記録 |
| 6 | 4 欄を足す client は数え落とす | 電話は counts を足していない(view / view model に counts の参照無し)。記録 |
| 7 | 親が読めないだけで観測した停止が unknown になる | **畳んだ**: 机の観測(転写が黙っている)は親に依らず `stopped-by-desk`。観測が無ければ従来どおり unknown。検査あり |

検査 85 緑(stopped-state 16 / desk-stop-memory 11 / subagents 16 / 台帳 / note / liveness)。e2e fail 0。iOS: 対照 3/3(model を含めてコンパイル)。

## 4. 本番での確認(friday `0ac6775`、`live-stopped-state-run1.log`)= 0

使い捨ての会話で subagent 1 本を起こし、親が静かになってから `POST /subagents/<id>/stop`(200 observed)。

| 欄 | 値 |
|---|---|
| 直後の一覧 | `state:"stopped"`, `reason:"stopped-by-desk"`, `display.state:"Stopped"`, `counts.stopped: 1`(finished 0) |
| note | "1 subagent, 0 working, 1 stopped. Background shells and teammates are not listed here." |
| 10 秒後 | 同じ(揺れない) |
| 畳んだ後の親転写 | `<status>killed</status>` が 2 件(同じ task-id が 2 回 notify する = 通知の note のとおり) |

round 10 の「止めた直後 15 分 Working」は本番で消えた。reason は机の観測が先(`stopped-by-desk`)、机の記憶が無い停止(Mac の鍵盤)は
親転写の killed で `stopped-by-user` になる(単体で検査、本番では机の x しか撃てないので未観測)。
