# commit の門に watchdog(2026-09-07、round 12、gate-41 の停止から)

## 1. 何が起きたか
`gate-41-hang-diagnosis.md`: `commit-suite-gate.sh` の一式(`npm test` = `node --test`、95 file、並列 = CPU 数 15)が 20 分以上 終わらず、
runner は生存・子は idle(kevent、0% CPU)・出力は止まったまま。上限が無いので commit は永遠に止まり、何が止まっているかも残らない。

## 2. 処置(`tools/commit-suite-gate.sh`)
- 一式の subshell を背景で回し、1 秒ごとに `kill -0` で見る。`SUITE_WATCHDOG_S`(既定 900 s = 実測の一式 3-5 分の 3 倍)を超えたら
  「終わらない = 測れていない」と名乗り(exit 2、緑でも赤でもない)、subshell と子孫(`pgrep -P` を再帰)の `ps`(pid ppid %cpu stat etime
  command)と出力の末尾を残し、**子孫から先に** TERM → 2 秒 → KILL で殺す(残すと次の commit の `mutation-run-live` が「木が動いている」で止まる)。
- 終わった時は従来どおり `wait` の exit code を使う。
- `package.json` の test script は触らない(`--test-timeout` は 1 検査の hang しか捕まえず、今回の runner の停滞には効かない。
  診断の #5)。

## 3. 対照(`test/commit-suite-gate-watchdog-controls.sh`、7/7)
| # | 何を | 結果 |
|---|---|---|
| ① | hang(`sleep 999.<nonce>`、watchdog 2 s) | exit 2 / 「終わらない」/ 木の dump に sleep が名指される / sleep は殺されている |
| ② | 直ぐ終わる緑 | exit 0(退行なし) |
| ③ | 1 秒掛かる緑(watchdog 10 s) | exit 0(締切の手前で終われば測れている) |
| ④ | 既定 900 s が script に在る | 読める |
既存の `commit-suite-gate-controls.sh` 18/18 も不変。

## 4. Codex(`codex-watchdog.out`、DON'T SHIP、10 所見)と処置

| # | 所見 | 処置 |
|---|---|---|
| 1 | PPID の再帰は一瞬の写し。走査中の fork / 再親付け / setsid は逃げる | setsid は再帰で見えない = 残余として記録(node の runner は setsid しない)。#2 で走査は取り直す |
| 2 | KILL は木を取り直せ(元の pid 一覧は新しい子を逃し、再利用 pid を撃つ) | **畳んだ**: TERM → 2 秒 → 木を取り直して KILL |
| 3 | `pgrep -P` は自分に当たらない。空出力は無害。exit 競合で ps/kill が落ちても致命にしない | `2>/dev/null` で既に非致命。記録 |
| 4 | `wait` は TERM/KILL 後に 143/137 を返す(正常)。`rc=$?` で取れ | 其の形。記録 |
| 5 | subshell を KILL すれば wait は吊らない。出力は file なので子が pipe を握る事は無い | 一致。記録 |
| 6 | 締切と終了の競合(最後の poll の後に終わった一式を殺す) | **畳んだ**: 締切の処理の直前に `kill -0` で生存を再確認、終わっていれば wait へ |
| 7 | `SUITE_WATCHDOG_S` の検証(壊れた値 / 0 / 巨大) | **畳んだ**: 1〜7200 の整数だけ、外れた値は既定に戻して名乗る。対照 2 本 |
| 8 | 既定は 600 s(通常の上限 5 分の 2 倍) | **畳んだ**: 600 |
| 9 | `$OUT` は毎回新規か | `mktemp` で毎回新規。記録 |
| 10 | 子が TERM の間に孫を起こす対照が無い | **畳んだ**: 孫の対照(dump に居る / 殺されている)。★最初の版は孫の `sleep 999.<nonce>g` が
  「g は単位ではない」で即死して対照が空回りしていた —— 対照の対照で気づいた(数字だけの nonce に修正) |

対照 11/11、既存 18/18。
