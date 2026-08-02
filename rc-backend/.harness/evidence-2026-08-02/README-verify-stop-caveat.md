# この dir の verify-stop-*.json をどう読むか(2026-08-02)

`~/.claude/tools/verify-production-stop.sh` は **F3(client-a の自動送信)向けに書かれた道具**で、
7 つの check のうち 2 つが `~/client-a` 決め打ち。`com.edith.rc-phone-window` に当てると:

| check | 出た値 | 意味 |
|---|---|---|
| launchd_unloaded | true | ★本物。`launchctl list` に label が居ない事を測っている |
| plist_state | absent/present | ★本物。plist の実在を測っている |
| process_absent | true | ▲弱い。`ps aux` を **label** で grep するので、bash script は元々映らない。「居ない」ではなく「この方法では見えない」。実体で数えているのは `verify-phone-window.sh` の `script_procs` の方 |
| queue_empty | no_queue_file | ✗ **測っていない**。`find ~/client-a ... queue` の結果。この案件に queue は無い |
| last_outbound_time | no_log | ✗ **測っていない**。`find ~/client-a -name '*.log'` の結果 |
| last_outbound_stable | true | ✗ 上が no_log なので自動的に true。**緑ではなく無関係** |
| vercel_deletion_excluded | true | ✗ 無関係(Vercel を使っていない) |

**この artifact が支えている主張は1つだけ: 「launchd から降りていて plist も無い」。**
「送信が止まった」「ログが静か」は**この案件については何も言っていない**。
動いている側(鎖③④が本当に在るか)は `tools/verify-phone-window.sh` で測る。

なぜ書き残すか: 今週ずっと潰してきた失敗の型が「正しい観測を、それが支えていない結論に貼る」
だから。緑の JSON が dir に転がっていると、後で読んだ人(私を含む)が7項目全部を証拠として読む。
