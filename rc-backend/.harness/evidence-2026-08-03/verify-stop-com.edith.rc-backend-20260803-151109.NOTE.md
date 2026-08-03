# この artifact の `process_absent: true` は**偽**(2026-08-03 15:11 実測)

隣の `verify-stop-com.edith.rc-backend-20260803-151109.json` を後から読む人へ。
あの JSON の 1 行だけ、事実と逆の値が入っている。**消さずに注記で残す**(artifact は
道具の出力そのものであるべきで、都合よく書き換えたら artifact ではなくなる)。

## 何が食い違ったか

| 項目 | artifact の値 | 別手順で測った値 |
|---|---|---|
| `launchd_unloaded` | `false` | 一致(job は在る) |
| `plist_state` | `active` | 一致 |
| **`process_absent`** | **`true`** | **偽。pid 52311 が生きていて :8787 を掴んでいる** |

別手順(同時刻):

```
launchd_pid=52311
52311 Mon Aug  3 02:36:01 2026  /opt/homebrew/bin/node
8787 の listener: node 52311
```

## なぜ道具が外したか

`~/.claude/tools/verify-production-stop.sh` の check 3 は

```
ps aux | grep -v grep | grep -F '$SERVICE'
```

で、**launchd の label 文字列がプロセスのコマンド行に現れる**事を前提にしている。
この service の実際のコマンド行は `/opt/homebrew/bin/node …` で、label
`com.edith.rc-backend` は**含まれない**。実測:

```
ps -p 52311 -o command= | grep -c "com.edith.rc-backend"  →  0
```

つまり「見えなかった」を「居ない」と読んだ。名前で探して見つからない事を不在の証明に
使う型 = memory の `method_measure_where_the_system_actually_reads` の計器版と同じ。

## なぜこれが**重い**向きの誤りか

この道具は「本当に止まったか」を判定する為の物で、safety-core の HARD GATE 1 が
production 案件に添付を義務付けている唯一の計器。その計器が

- 実際は**走っている** → `process_absent: true`(= 止まっている側)

と出るのは **fail-open**。F3 型の「自動送信は本当に止まったのか」に対して、
**止まっていないのに止まったと証明してしまう**方向に外れる。今回は「上がっていて
欲しい」案件なので実害は無かったが、向きとしては最悪の外し方。

## 直し方(まだ直していない)

label が当たらない時に `true` を返さない。`unknown_by_label` を返し、
`launchctl print <job>` の pid で見る経路を必須にする(= 今回私が手で踏んだ手順)。
`STOPPED=true` の条件からも `process_absent=unknown_by_label` は外す(fail-closed)。

**この session では直していない。** 理由 = `~/.claude/tools/` は全レーンが使う安全計器で、
deploy の片手間に触る物ではない。対照付きで独立に直すべきなので、REPLAN で queue に出す。
