# subagent の停止は「原因」に束ねられるか —— 転写の記録で判る(2026-09-07、round 11 の研究題)

VERDICT: distinguishable

## 問い
机が x を押してパネルの行が減ったのを見た(`stopped:"observed"`)時、其れが**机の停止**なのか、同じ瞬間の**自然な完了**なのかを、
転写から区別できるか(Codex 2026-09-07 direct-detail #5、interrupt-overlay #6)。

## 証拠(本番 friday の使い捨て会話の親転写、attic に退避した物を読んだ)

| 会話 | 事象 | 親転写の記録 |
|---|---|---|
| `2f132bb6…`(single run1) | 机が x で止めた subagent `a593f1f1061be1dc8` | `<task-notification>` … `<status>killed</status>` `<summary>Agent "count slowly" was stopped by user</summary>` |
| `c9cae356…`(shell run4) | 机が x で止めた subagent `a7e1c21864d6efea8` | 同上 `<status>killed</status>` / "was stopped by user" |
| `c9cae356…` | 外から殺した背景シェル `bo357kwj2` | `<status>failed</status>` `<summary>Background command … failed with exit code 144</summary>` |
| 9/4-9/6 の実測(`subagents.mjs` 頭注) | 自然に終わった subagent | `<status>completed</status>`(async)/ `toolUseResult.status:"completed"`(sync) |

つまり Claude Code 2.1.263 は**親の転写に停止の原因を書く**: 利用者(= 机の x)が止めた agent は `killed` + "stopped by user"、自然完了は
`completed`、失敗は `failed`。同じ task-id が複数回 notify しうる(note にそう書いてある: 再開できる)。

## 今の机の読み方の穴(発見)
`scanParent`(rc-backend/src/subagents.mjs)は `<status>completed</status>` だけを `done` に入れる。`killed` は done にならず、
止めた agent は **mtime で running のまま**(15 分後に stalled)。round 10 の `DeskStopMemory` は其の穴を机の記憶で塞いだが、
転写自身が `killed` と言っているのだから、其方を読む方が強い(机の再起動でも消えない・原因に束ねられる)。

## 結論
- 区別できる: 親転写の `<task-notification>` の `<status>` が `killed`(利用者が止めた)/ `completed`(自然完了)/ `failed`。
- 次の一手(実装は別の題): `scanParent` が `killed` / `failed` を `done` に入れ、reason を `stopped-by-user` / `failed` として返す。
  `DeskStopMemory` は「通知がまだ書かれていない数秒」の橋渡しとして残す(通知が来れば転写が勝つ = 既存の順位どおり)。
- 未確認: sync の Agent 呼び出し(`toolUseResult`)で止めた時の `status` の値(今回の実測は全部 async)。実測してから読む。

## 反証条件
別の版の Claude Code が停止を `completed` と書く、または通知を書かない事が観測されたら、此の判定は其の版について撤回する。
