# 失敗した subagent は 6 つ目の状態 `failed`(2026-09-07、round 12)

## 1. 何が問題だったか
`completionsIn` は `<status>failed</status>` を読まず、失敗した agent は mtime で running / stalled / unknown に見えた(作業中と見分けが
付かない)。round 11 の研究では「failed は背景シェルの形」と書いたが、Planner(r12)が Jervis の転写を全部 grep すると failed 470 件のうち
**42 件が agent の失敗**(此の session 自身の転写にも 1 件: `Agent "Implement the transcript search UI" failed: Agent terminated early due
to an API error … (ENOTFOUND)`)。

## 2. 処置
- `SUBAGENT_STATES` に `failed`(表示 "Failed")、`counts.failed`、note に "N failed"。電話は `SubagentCounts.failed: Int?`。
- `completionsIn`: `<status>failed</status>` で summary が `Agent "…" failed` の形の物だけ終端 `failed`(背景シェル `Background command …
  failed` / Monitor `Monitor "…" script failed` は読まない)。最後の終端が勝つ(completed ↔ failed の両方向を検査)。
- `stateOf`: killed の次に failed(`agent-failed`)。再開の守りは killed と同じ(通知の後 + 5 s を超えて転写が動けば mtime)。
- 台帳と既存の期待値に `failed: 0`。

検査 `test/subagent-failed-state.test.mjs`(8、否定対照 = シェル / Monitor の形は読まない)。既存 + 台帳 緑。

## 3. Codex(`codex-failed-state.out`、DON'T SHIP、9 所見)と処置

| # | 所見 | 処置 |
|---|---|---|
| 1-3 | summary の文で選ぶのは脆い(文言の変更・偽装)。task-id を既知の agent id に束ねよ | **畳んだ**: 文は読まない。一覧の行は `agent-<id>.jsonl` が在る id だけなので、シェル / Monitor の failed は行にならない(id で束ねる)。否定対照を「別 id の failed は行にも数にも出ない」に |
| 4-5 | 5 s の mtime 猶予は再開に弱い。時刻の推定でなく世代の同一性か生きている証拠で | **畳んだ(半分)**: 親転写の**終端の後の起動の記録**を再開の証拠として終端を捨てる(ファイルの並び = 時刻順)。mtime の猶予は「動いている証拠が在れば終端を捨てる」向きだけなので残す。残余 = 再開が親に記録を書かない版が在れば、最初の書き込みまで failed に見える |
| 6 | 走行中の偽 failed(再開直後・buffered write・mtime の粗さ・id の再利用・summary の偽装) | 偽装は #1-3 で消えた。再開は #4-5。mtime の粗さは 1 秒(macOS)。記録 |
| 7 | failed は独立の終端状態、構造化した reason を | 一致(`failed` / reason `agent-failed`) |
| 8 | counts.failed は既定 0 で必ず載せる、電話は optional | 其の形(空の形にも鍵、Swift `Int?`) |
| 9 | 最後の終端が勝つのを順位より先に | 其の形(`terminal` は id ごとに上書き、順位は最後の終端にだけ掛かる。両方向の検査) |

検査 60 緑(failed-state 9 / stopped-state / desk-stop-memory / subagents / 台帳)。e2e 0、iOS 対照 3/3(model を含めてコンパイル)。
