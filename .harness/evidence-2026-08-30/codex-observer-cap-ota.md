# Codex 査読 — 観測器の掃除/配布口の2枝(2026-08-30)

対象: `rc-backend/tools/health-observer.sh` の `check_log_cap` / `check_ota_fresh`、
`rc-backend/tools/log-cap-all.sh` の生存の印。
SHIP-GATE: `production_adjacent`(task `observer-notices-a-stopped-cap-and-a-stale-ota-point`)。

依頼文の全文 = 同 dir の `codex-observer-cap-ota-prompt.md`。

## 判定

> 結論: 方向性は正しいですが、通知状態機械には実害のある穴があります。

## 指摘と、私が採った対応

| # | Codex の指摘 | 採否 | 実装 |
|---|---|---|---|
| 1 | `undelivered` は HEAD 差でなく「配布可能になった時刻」を起点に。閾値を跨いだ瞬間に1回鳴らせば常時警告にならない | **採用** | `OTA_UNDELIVERED_GRACE`(既定 48h)。状態が続いた時間で判定。C8/C9 |
| 2 | cap の「最後の行」判定は本番監視の契約として脆い。job 側に `attempt/success/exit_code` の構造化 heartbeat を atomic rename で | **採用** | `log-cap-all.sh` に EXIT trap で mktemp+mv。観測側は最終行を一切読まなくなった。C2/C3/C4/C17 |
| 3 | rollback を 24h 放置は不適切。測定と通知再送を分離せよ | **部分採用** | 分離はせず、**壊れている間だけ測定間隔を縮める**(`BAD_EVERY` 既定 900s)。1つの機構で #3 と #4 の両方が直る。未解決が残る間も縮める |
| 4 | `unmeasurable` は回数でなく経過時間。今は最悪 48h | **採用** | `OTA_BLIND_S`(既定 1h)。`BAD_EVERY` と併せて実効 1h |
| 5a | recovery 通知が失敗しても捨てて `ok` を書く | **採用** | 配達できるまで `open` を降ろさない。C16 |
| 5b | `rollback(announced) → undelivered → ok` で復帰通知が永久に消える | **採用** | 状態と「言った問題(`open`)」を分離。C14 |
| 5c | DRY-RUN が実送信せずに `announced=1` を書く | **採用** | dry は `<file>.dry` にだけ書く。C15 |
| 5d | `floor=999999` は「通知しない」ではない | **採用** | 猶予秒に置き換えて削除 |
| 5e | `S_DONE` は `2` でも通る | **採用** | `= "1"` の厳密判定 |
| 5f | state 書き込みが atomic でない | **採用** | mktemp + mv |
| 5g | 未来の `S_TS` が測定を長期停止させ得る | **採用** | `> now` は 0 に倒す |
| 5h | 4 フィールドでは `state_since` / 保留通知 / `retry_at` を表現できない | **部分採用** | 6 フィールドに拡張(`since` と `open` を追加)。`retry_at` は `BAD_EVERY` が代替 |

## 私が Codex に**採らなかった**判断と理由

**#3 の「通知再送を測定周期から分離し 5分/30分/2時間… で再送」** は採らなかった。
再送の梯子は独立した時計・incident ID・再送状態を要求し、観測器に2つ目の状態機械を作る。
`BAD_EVERY`(壊れている間だけ細かく測る)は1つの機構で同じ効果域を覆い、
直れば自動で元の周期へ戻る。**撤回条件**: 出し先が「時々失敗し時々成功する」振る舞いを
見せた時 —— その時は測定周期と再送周期が本当に別物になるので、梯子が要る。

## 査読の後に**追加で**見つかった実害(Codex は指摘していない)

既存の対照 `health-observer-controls.sh` 5 本が赤くなった。原因は
「既定で開発機の実パス(`$HOME/.rc-backend/rc-log-cap.heartbeat`)を読みに行く」設計で、
**掃除を回していない機体で必ず誤報する**。掃除も配布口も「明示した機体でだけ測る」
(空 = 測らない、鍵の `KEY_PEER` と同じ形)に変更。C18/C19/C22。
据え付け直後の誤報は `CAP_MISSING_GRACE`(既定 2h)で潰した。

## 証拠

- 対照 22 本緑 / 既存の観測器 122 本緑 / 単体 991 本緑 / 触れた対照 7/7 緑
- 変異 5 本、各1本だけ赤 — `open` を状態に括り付ける→C14、dry を本番に書く→C15、
  復帰の配達結果を見ない→C16、試み時刻を成功時刻として読む→C2、未配達を鳴らさない→C9
- 本番 friday: `rc-log-cap: 状態が unknown → ok` 1行・通知0。
  無い印/古い印を見せて実物が掴む事も確認(本番の記録には触れずに `--dry-run` で)
- commit `c7b086b` / `aae5d1e`

---

## 2巡目 — 直した実装を当て直した生の走行(2026-08-30)

★1巡目(この上の表)の走行記録は `tail` で頭を切って保存し損ねた。
此処は**直した後の検証**で、ヘッダごと残してある。

```
Reading additional input from stdin...
OpenAI Codex v0.144.3
--------
workdir: /Users/tomtim/Infra/mobile-work
model: gpt-5.6-sol
provider: openai
approval: never
sandbox: read-only
reasoning effort: xhigh
reasoning summaries: none
session id: 01a054ae-333e-70c1-ab73-bf14d0017cb0
--------
user
DO NOT read any files or run any commands — answer purely from this prompt; everything you need is inline. Be concise and direct.
You found 4 defects in a health-observer notification state machine this morning. I rewrote it. Verify the fixes; be adversarial, no praise. Answer in under 250 words.

Your findings -> my fixes:
1. 'undelivered' keyed off HEAD diff -> now keyed off elapsed time in state (grace 48h), using a 'since' epoch field.
2. cap health read by parsing another script's last log line -> that script now writes '<attempt_epoch> <last_success_epoch> <exit_code>' via mktemp+rename in an EXIT trap; observer reads only that.
3. rollback notify retry was bound to a 24h measurement interval. I did NOT split measurement from notification. Instead the measurement interval itself drops to 900s whenever the stored state != ok OR an announced problem is still unresolved ('open'==1). When it recovers, the normal interval returns.
4. 'unmeasurable' counted runs -> now elapsed time (1h), which combined with #3 is reachable.
5. recovery-notify failure was discarded -> 'open' is cleared only when the notifier exits 0. 'open' is a separate field from the per-state 'announced', so rollback->undelivered->ok still announces recovery. Dry-run writes to a separate .dry state file. Strict 0|1 parsing, atomic state write via mktemp+rename, future-timestamp guard.

Record is: '<last_measure_epoch> <state> <announced> <consecutive_runs> <open> <since>'.

Question: is fix #3 (adaptive measurement interval instead of a separate notify-retry ladder) sufficient, or name a concrete case where it fails. And name anything still broken in the record above.
2026-08-30T21:58:19.535542Z ERROR rmcp::transport::worker: worker quit with fatal: Transport channel closed, when Auth(AuthorizationRequired)
2026-08-30T21:58:19.560911Z ERROR rmcp::transport::worker: worker quit with fatal: Transport channel closed, when Auth(AuthorizationRequired)
2026-08-30T21:58:21.525984Z ERROR rmcp::transport::worker: worker quit with fatal: Transport channel closed, when Auth(AuthorizationRequired)
codex
Fix #3 is only conditionally sufficient: every 900-second iteration must complete and execute notification logic even when measurement fails. Concrete failure: the health probe hangs indefinitely, or an unmeasurable/error path returns before notification handling. An unresolved recovery notification then receives no retry despite `open=1`. Add a probe timeout and guarantee notification processing in every loop; otherwise use an independent retry timer.

Still broken or underspecified:

- The record cannot make notification delivery crash-safe. If the notifier succeeds and the observer crashes before persisting `open=0` or `announced=1`, it sends a duplicate next run. Writing first instead risks losing the notification. Use notifier idempotency keys or a persisted outbox/event ID.
- `announced` is only “per-state” if it is reset on every actual state transition, atomically with `state` and `since`.
- Validate the entire record, not only `0|1`: exact field count, allowed state enum, integer/range checks, and invariants such as `since <= last_measure_epoch <= now`.
- Define `last_measure_epoch`: attempt time and successful-measurement time are different. Conflating them can distort scheduling and unmeasurable timing.
- Epoch-based elapsed time remains vulnerable to backward clock adjustments; a future-only guard does not cover that.
- `consecutive_runs` is now redundant unless another rule still uses it.
tokens used
13,378
Fix #3 is only conditionally sufficient: every 900-second iteration must complete and execute notification logic even when measurement fails. Concrete failure: the health probe hangs indefinitely, or an unmeasurable/error path returns before notification handling. An unresolved recovery notification then receives no retry despite `open=1`. Add a probe timeout and guarantee notification processing in every loop; otherwise use an independent retry timer.

Still broken or underspecified:

- The record cannot make notification delivery crash-safe. If the notifier succeeds and the observer crashes before persisting `open=0` or `announced=1`, it sends a duplicate next run. Writing first instead risks losing the notification. Use notifier idempotency keys or a persisted outbox/event ID.
- `announced` is only “per-state” if it is reset on every actual state transition, atomically with `state` and `since`.
- Validate the entire record, not only `0|1`: exact field count, allowed state enum, integer/range checks, and invariants such as `since <= last_measure_epoch <= now`.
- Define `last_measure_epoch`: attempt time and successful-measurement time are different. Conflating them can distort scheduling and unmeasurable timing.
- Epoch-based elapsed time remains vulnerable to backward clock adjustments; a future-only guard does not cover that.
- `consecutive_runs` is now redundant unless another rule still uses it.
```

### 2巡目の指摘への対応

| 指摘 | 採否 | 実装 |
|---|---|---|
| #3 は「毎回 通知処理まで到達する」が前提。検査が固まれば `open=1` の再送に永久に到達しない | **採用(実害)** | `run_bounded`(perl の alarm、既定 45 秒)。★出力は一時 file 経由 —— `$( )` に直接流すと**孤児の孫がパイプを握ったまま**で、殺せているのに EOF を待つ(実測: 3 秒で切った筈が 60 秒)。C23 |
| 記録は欄数・状態名の列挙・不変条件まで検めよ | **部分採用** | 欄数が 6 でない行は丸ごと未知に倒す。C24。★変異で実演: 検めを外すと epoch を状態名として読み「rc-log-cap が直りました(1788127640 から回復)」と言い出す |
| 通知の配達と記録の間で落ちると重複する | **不採用(既知の取引)** | 此の file の既存の方針が「重複は沈黙よりまし」。冪等鍵や outbox は観測器に2つ目の状態機械を作る。**撤回条件**: Tom が重複通知を煩わしいと言った時 |
| `announced` は状態遷移で必ず 0 に戻る事が前提 | **既に満たしている** | `state != S_STATE` の枝で 0 に戻し、`state`/`since` と同じ1行に atomic に書く |
| `last_measure_epoch` が「試みた」と「測れた」を混ぜている | **不採用(意図)** | 測れなかった時も次の試みを `BAD_EVERY` だけ遅らせたい(固まった相手を叩き続けない) |
| 時計の巻き戻りには未来ガードだけでは足りない | **未対応(既知)** | shell に単調時計が無い。巻き戻ると警報が遅れる。**実害が出たら**別の刻みを持たせる |
| `consecutive_runs` は今や誰も使っていない | **残す(診断用)** | 閾値は全部時間に移したので判定には使わない。記録を人が読む時の手掛かりとして残す |
