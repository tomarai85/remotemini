# Codex 査読 — 配備のずれを定期に見る枝(2026-08-31)

対象: `rc-backend/tools/parity-observer.sh`(新設)/ `rc-backend/tools/tunnel-observer.sh`(呼び出し)。
SHIP-GATE: `production_adjacent`(task `parity-drift-is-noticed-without-a-deploy`)。

## 何を作ったか

`observer-parity-check.sh` と `fleet-plist-parity-check.sh` は repo が要るので **Jervis からしか
回せず**、今は配備の前後にしか走らない —— 配備した後にずれても次の配備まで誰も気付かない
(CF-7 の再発路)。

★**新しい見張りは建てなかった**。既存の `com.tomtim.rc-tunnel-observer`(10 分毎、283 走行、
last exit 0)に枝を足した。あれは既に「**自分の回線が落ちている時は黙る**」判断を持っている ——
Jervis は持ち歩く機体で、実測 6 時間の窓で 186 FAIL / 178 OK(ほぼ半分の時間 落ちていた)。
判断を2箇所で持つと、片方だけ直る日が来る。

## 指摘と対応

| # | 指摘 | 採否 | 実装 |
|---|---|---|---|
| 1 | 「測れない時は黙る」は**測定の鮮度を別に持つ時だけ**正しい。さもないと机への多日の不達が不可視になる。**照合(ok/drift)と観測可能性(fresh/stale)を独立した状態に**し、閾値を越えたら重複なしで1回鳴らせ | **採用** | 記録を5欄にし「最後に**測れた** epoch」を別に持つ。`PO_STALE_S`(既定 3 日)を越えたら「**ずれた訳ではなく見えていない**」として1回鳴らす。対照 P10 / P11 |
| 3 | 「日に1回」は時計を**いつ進めるか**で意味が変わる。試みるたび進めるなら、測れない1回が其の日を食う。独立 50% の可用性・1日1回なら**期待間隔は約2日** | **採用(実害だった)** | `unmeasured` の回は試みた時刻を**据え置く** → 次の 10 分の tick で再挑戦。対照 P9 |
| 2 | 相乗りは2つの故障域を1つの job に結ぶ。本体の変更・停止で照合も消える / 90 秒 x2 が本体の周期を最大3分ずらす / trap・一時 file・終了コードの干渉 / 将来の保守者が無関係に見える枝を消す | **部分採用** | 上限を 90 → **45 秒**へ(最悪 3 分 → 1.5 分)。★別 job にしない判断は維持: CF-22 で「既存の上に2本目を建てる」提案を実測で取り下げており、**回線判断を2箇所に持つ方が高くつく**。★但し指摘の残りは真なので註記に残した(本体が止まれば照合も止まる)。**撤回条件**: 本体の周期ずれが実測で問題になった時、または照合の失敗が本体の up/down 判定に影響した時 |
| 3b | 記録すべき物: 最後に試みた / 検査ごとの最後の結果 / 最後に完全に測れた / 測れなかった理由 / 連続の長さ / 飛ばした理由別の回数 | **部分採用** | 「試みた」「測れた」「状態」「状態になった時刻」「通知済み」の5つを持つ。★検査ごとの結果と理由別の回数は**未着手として記録** —— 今の判定には要らないが、周期を後から検証したくなった時に要る |

## 自分で見つけて直した欠陥

- **配線が到達しなかった**: 呼び出しを本体の `if [ "$st" = up ]; then … exit 0; fi` の**後**に
  置いていた。通常は up なので事実上一度も走らない。対照 P7 が行の前後関係で縛る。
- **`command -v log` が macOS の `/usr/bin/log` を拾った**。呼び手が関数を持たない時に
  記録が全部 Apple の log 道具へ飛んだ(実測: `log help <command>` が出力に出た)。
  `declare -f log` で**関数が在るか**を訊く形へ。
- **対照 M3 が空虚だった**(変異を植えただけで赤を測っていない)。間隔の判定を外す変異へ替えた。

## 証拠

- 対照 17/17(P1-P11 + 変異 3 + 残骸)。★中核は P1(回線が落ちていれば測らない)/
  P4(測れないをずれとして鳴らさない)/ P9(測れない回で時計を進めない)/ P10(鮮度は別に鳴る)
- 実物を1回まわして本物の照合が走り、記録 `… ok 0 … …` を実測(両方の照合が friday に対して緑)
- 宿主 `com.tomtim.rc-tunnel-observer` は 283 走行 / last exit 0

---

## 生の走行

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
session id: 01a05652-2c4f-7cf2-9b58-8de7972a2baa
--------
user
DO NOT read any files or run any commands — answer purely from this prompt; everything you need is inline. Be concise and direct.
Adversarial review of one observer branch. Under 300 words, no praise.

CONTEXT. Two parity checks (deployed-observer vs repo; LaunchAgent plists vs repo) need the git repo, so they only run from the owner's LAPTOP, and today they only run around a deploy. Drift after a deploy goes unnoticed until the next deploy.

I did NOT build a new watcher. An existing laptop-side LaunchAgent already runs every 10 minutes (283 runs, exit 0) and already has a 'stay silent when my own link is down' branch — the laptop is carried around and tethered, and a measured 6-hour window showed 186 link failures vs 178 successes, so roughly half the time it is offline. I added a branch to that existing observer instead.

THE BRANCH.
- Runs at most once per 24h; the observer itself fires every 10 min.
- Returns immediately, writing nothing, if the laptop's own link is down OR unknown.
- Runs both checks with a 90s alarm each, output via a temp file (a direct command substitution waits on the orphaned grandchild's pipe even after the kill — measured on a sibling observer).
- States: ok / drift / unmeasured. Notifies ONLY on drift, only on a state CHANGE, and announces recovery only if the drift was announced.
- 'unmeasured' (a check exited 2, e.g. ssh could not reach the desk) is recorded but NEVER notified: not measuring is not the same as drifting, and on this machine it will happen constantly.

I found and fixed one placement bug: I first put the call AFTER the observer's 'if up then exit 0' block, so it would only ever have run when the tunnel was DOWN — effectively never.

ATTACK:
1. Is 'silent on unmeasured' right, or am I hiding the case where the desk is unreachable for days and drift is accumulating unseen?
2. Riding on an existing observer couples two unrelated failure domains into one job. What breaks that would not break if it were separate?
3. Once per 24h on a machine that is asleep or offline half the time: what does that actually give me, and what would I have to record to know?
2026-08-31T05:37:02.007151Z ERROR codex_memories_write::phase2: Phase 2 no changes
2026-08-31T05:37:02.073580Z ERROR rmcp::transport::worker: worker quit with fatal: Transport channel closed, when Auth(AuthorizationRequired)
2026-08-31T05:37:02.242607Z ERROR rmcp::transport::worker: worker quit with fatal: Transport channel closed, when Auth(AuthorizationRequired)
2026-08-31T05:37:03.018461Z ERROR rmcp::transport::worker: worker quit with fatal: Transport channel closed, when Auth(AuthorizationRequired)
codex
1. “Silent on unmeasured” is correct only if measurement freshness is tracked separately. Otherwise, multi-day desk unreachability becomes invisible. Do not label it drift; emit a deduplicated “parity unmeasured for N days” alert after a threshold, then recovery when both checks become measurable. Keep two independent states: parity (`ok/drift`) and observability (`fresh/stale`).

2. Coupling creates these additional failure modes:

- Changes, syntax errors, disablement, or unloading of the original observer also eliminate parity checking.
- Its early exits and link definition may suppress parity checks even when the desk is reachable by another route.
- Two 90-second checks can delay the original observer by three minutes. launchd generally avoids overlapping instances, so its primary monitoring cadence may slip.
- Shared traps, temporary files, stdout/stderr handling, exit codes, and state files can interfere.
- Troubleshooting and restarting one concern affects both.
- A future maintainer may remove the apparently unrelated branch while modifying the observer.

A separate LaunchAgent would isolate lifecycle, timeout, logs, schedule, and failure reporting. Reusing the existing job avoids another watcher but does not provide that isolation.

3. “Once per 24h” may mean much less than daily. The critical question is when the 24-hour timestamp advances:

- If advanced on every attempt, an `unmeasured` attempt consumes the day.
- If advanced only after both checks are measured, it retries every ten minutes when eligible, giving approximately one successful measurement per available opportunity.

With independent 50% availability and only one attempt daily, expected measurement spacing is roughly two days; 95% success takes about five eligible daily attempts. Real sleep/offline periods are correlated, so it can be worse.

Record durable timestamps for: last eligible attempt, last measured result per check, last successful complete measurement, last unmeasured reason, consecutive unmeasured duration/count, and skipped runs by reason (`asleep` cannot be observed, `link-down`, `link-unknown`, `rate-limited`). Without those, the claimed cadence cannot be verified.
tokens used
13,043
1. “Silent on unmeasured” is correct only if measurement freshness is tracked separately. Otherwise, multi-day desk unreachability becomes invisible. Do not label it drift; emit a deduplicated “parity unmeasured for N days” alert after a threshold, then recovery when both checks become measurable. Keep two independent states: parity (`ok/drift`) and observability (`fresh/stale`).

2. Coupling creates these additional failure modes:

- Changes, syntax errors, disablement, or unloading of the original observer also eliminate parity checking.
- Its early exits and link definition may suppress parity checks even when the desk is reachable by another route.
- Two 90-second checks can delay the original observer by three minutes. launchd generally avoids overlapping instances, so its primary monitoring cadence may slip.
- Shared traps, temporary files, stdout/stderr handling, exit codes, and state files can interfere.
- Troubleshooting and restarting one concern affects both.
- A future maintainer may remove the apparently unrelated branch while modifying the observer.

A separate LaunchAgent would isolate lifecycle, timeout, logs, schedule, and failure reporting. Reusing the existing job avoids another watcher but does not provide that isolation.

3. “Once per 24h” may mean much less than daily. The critical question is when the 24-hour timestamp advances:

- If advanced on every attempt, an `unmeasured` attempt consumes the day.
- If advanced only after both checks are measured, it retries every ten minutes when eligible, giving approximately one successful measurement per available opportunity.

With independent 50% availability and only one attempt daily, expected measurement spacing is roughly two days; 95% success takes about five eligible daily attempts. Real sleep/offline periods are correlated, so it can be worse.

Record durable timestamps for: last eligible attempt, last measured result per check, last successful complete measurement, last unmeasured reason, consecutive unmeasured duration/count, and skipped runs by reason (`asleep` cannot be observed, `link-down`, `link-unknown`, `rate-limited`). Without those, the claimed cadence cannot be verified.
```
