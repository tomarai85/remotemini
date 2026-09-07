# 止めた / 失敗した subagent を再開すると、親転写に起動の記録が書かれるか(2026-09-07、round 13 の研究題)

VERDICT: no-launch-record

## 問い
`completionsIn`(rc-backend/src/subagents.mjs)は「終端(killed / failed)の後に起動の記録(`toolUseResult.status:"async_launched"`)が在れば
再開した」と読む(round 11 で killed に、round 12 で failed に)。Claude Code 2.1.263 は再開の時に其の記録を本当に書くのか。

## 実測(本番 friday、使い捨て会話 `8a507764…`、`live-resume-record-run1.log`)

| 段 | 何をした | 親転写の記録 |
|---|---|---|
| 1 | subagent `count slowly`(id `ab20e2286b5dffc76`)を起こし、机の口で止めた(200 observed) | `<status>killed</status>` × 2、親は「stopped before finishing (status: killed)」と返答 |
| 2 | 親に「Agent tool の resume で其の id を再開せよ」と送った | 親: 「No such parameter exists on the Agent tool — resuming a spawned agent is done via SendMessage with `to` set to its id」 |
| 3 | 親が `SendMessage {to: "ab20e2286b5dffc76", …}` を撃った | tool_result: `{"success": false, "message": "Agent \"ab20e2286b5dffc76\" was stopped by the user and was not resumed. Treat its work as cancelled; only start a new agent for it if the user explicitly asks."}` |
| 4 | 一覧 | `state: stopped`, `reason: stopped-by-desk`(記憶)。agent 転写の最後の記録 = `"[Request interrupted by user for tool use]"`(user 型、停止の時刻) |

## 結論
- **killed(利用者 / 机が止めた)agent は 2.1.263 では再開できない**: Agent tool に resume の引数は無く、`SendMessage` は「stopped by the user
  and was not resumed」で断る。よって再開の起動の記録は**書かれない**(書かれる以前に再開が起きない)。`completionsIn` の「終端の後の起動」
  の枝は killed には**到達しない**(害は無い。到達しない枝として注記する)。
- **failed agent の再開は未測定**(此の実験は killed だけ。通知の note「send it another message and resume it」は failed には効くかもしれない)。
  次に測るなら: API 障害で failed になった agent を作るのは難しいので、`SendMessage` を failed の id に撃って `success` と親転写を見る。
- ★副産物(Codex direct-detail #5 の残余に効く): agent の転写自身が停止の瞬間に `"[Request interrupted by user for tool use]"` を書く。
  「机の x で止めた」を agent 側の記録で確かめる道が在る(自然完了とは区別できる)。今は使っていない。

## 反証条件
別の版で `SendMessage` が killed の agent を再開できる、または Agent tool に resume が生えたら、此の判定は其の版について撤回する。
