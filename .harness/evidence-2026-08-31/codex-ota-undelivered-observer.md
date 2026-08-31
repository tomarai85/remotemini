# Codex 査読 — 「出来ているのに配っていない」を定期に見る枝(2026-08-31)

SHIP-GATE: `production_adjacent`(task `ota-undelivered-watched-on-a-schedule`)。

## 何を作ったか

`rc-backend/tools/ota-undelivered-observer.sh`。`ota-freshness-check.sh` の rc を
`com.tomtim.rc-tunnel-observer`(10 分毎)から日に1回 撃ち、状態が変わった時だけ言う。
撃つ物が**配る時(adhoc-ota step 7)と人の手だけ**だったので、
「配った直後は必ず緑、其の後どれだけ離れても誰も言わない」状態だった。

猶予が状態ごとに違う: `undelivered`(rc=3)は作業中ほぼ常に真なので **2 日**、
`rollback`(rc=1)は Tom の唯一の復旧経路が壊れている状態なので**猶予なし**。

## 指摘と対応

| # | 指摘 | 採否 | 実装 |
|---|---|---|---|
| 2 | **壁時計の差は連続性の証拠ではない**。`rc=3 で開始 → 2日以上 測れない → 其の間に直って再発 → 次の観測で「3日 続いている」として即座に鳴る` —— 離れた2回の観測が1つの episode に化ける | **採用(実害)** | 前回 測れてから `OU_CONTINUITY_MAX`(既定 2×周期 = 2日)以上 空いていたら、続いた時間を**数え直す**。対照 U13(見えていなければ鳴らない)+ U13b(ずっと見えていたなら鳴る = 黙り過ぎていない)|
| 1 | 2 日の猶予は雑音対策としては妥当だが、其の間は隠れる。半分オフラインの機体では実際にはもっと長い | **意図・記録** | 隠れる代わりに**読まれる警報**を選んだ。rc=3 は開発中ほぼ常に真で、猶予無しは毎日鳴る = 本当に配り忘れた日に読まれていない。★撤回条件: 配布の間隔が実測で 2 日を大きく下回る運用になったら猶予を縮める |
| 3 | 構造的に見えない物: 観測の合間の遷移 / 見えない間に rc=3 が続いたか / 合間に始まって終わった巻き戻り / **電話の実際の版と導入の成否** / 版の数字が合っていても OTA の中身・署名・栞の経路が壊れている場合 / 「配っていない」が意図的か忘れたのか | **受容(記録)** | 電話の版は別の枝が見る(friday の `check_phone_sighting`、2026-08-31)。中身・署名・経路は `adhoc-ota.sh` の配達検査が配る時に見る。**意図か忘れたか**は機械には判らない —— 猶予はまさに其の区別を人に委ねる為の物 |

## 実測

- 対照 **19/19**(U1-U13b + 変異2 + Z)。変異: 猶予を外すと U2 が赤 / 回線の判定を外すと U1 が赤
- ★U12 = 呼び出しが宿主の早期 exit(`if [ "$st" = up ]`)**より前**に在る事を前後関係で縛る
  (2026-08-31 に parity 側で「配線されて見えるのに走らない」を実際に踏んだ)
- 実物を1回: HEAD 116 / 承認 115 → rc=3 → 記録 `undelivered`、**通知は 0**(猶予の内)
- ★対照が1度だけ 18/19 を出したが、其れは **SUT を書き換えた同じ呼び出しの中で走らせた回**。
  以後 6 回 連続で 19/19。取り逃した赤として記録に残す(再発したら此処を見る)

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
session id: 01a0574a-7536-7f80-89bd-fc78b5889f4e
--------
user
DO NOT read any files or run any commands — answer purely from this prompt; everything you need is inline. Be concise and direct.
Answer from this prompt only. No files, no commands. Under 220 words, adversarial, no praise.

A laptop-side observer (every 10 min, LaunchAgent) got one new branch: notice when a build is finished but never distributed to the phone's OTA point.

Source of truth is one script whose exit codes are: 0 published>=approved and approved==HEAD; 1 published<approved (tapping the install bookmark would ROLL THE PHONE BACK); 2 unmeasurable; 3 published==approved but approved is behind HEAD (built, never distributed).

Branch behaviour: runs at most once per 24h; returns immediately writing nothing if the laptop's own link is down or unknown (that laptop is offline roughly half the time, measured); state file holds attempt/state/announced/since/last-measured. rc=3 notifies ONLY after the state has persisted 2 days, once. rc=1 notifies immediately, once, no grace. rc=2 never notifies as a drift, does not advance the attempt clock, and after 3 days raises a separate 'I cannot see this' alert. Recovery announced only if the problem was announced.

Why the grace differs: rc=3 is true almost continuously during development, so a no-grace alarm would fire daily and stop being read. rc=1 means the owner's only recovery path is broken.

Controls 17/17 including two mutations (remove grace -> the silence test goes red; remove the link check -> the silence test goes red) and a check that the call sits before the host observer's early exit.

Attack:
1. Is a 2-day grace on rc=3 right, or does it hide the case that matters?
2. What state transition sequence produces a wrong or missing notification?
3. What is this branch structurally unable to notice?
2026-08-31T10:08:13.457045Z ERROR rmcp::transport::worker: worker quit with fatal: Transport channel closed, when Auth(AuthorizationRequired)
2026-08-31T10:08:13.466852Z ERROR rmcp::transport::worker: worker quit with fatal: Transport channel closed, when Auth(AuthorizationRequired)
2026-08-31T10:08:13.743901Z ERROR rmcp::transport::worker: worker quit with fatal: Transport channel closed, when Auth(AuthorizationRequired)
codex
1. The 2-day grace is defensible for noise control, but it hides the case for at least 48 hours—often longer because the laptop is offline half the time. More importantly, wall-clock age does not prove continuous persistence; it proves only two separated observations.

2. Wrong notification sequence:

`rc=3 → state starts → laptop offline/rc=2 for >2 days → issue recovers unseen → rc=3 recurs → alert`

If offline/unknown and rc=2 preserve `since`, two separate incidents become one “persistent” incident, causing an immediate false-aged alert.

Missing notification sequence:

`rc=3 → recovery or rc=1 occurs entirely between successful measurements → next measurement rc=0`

Neither incident is observed. Likewise, a permanently offline laptop produces no drift notification; only the separate visibility alert may eventually appear, assuming that timer advances independently.

To avoid conflation, any non-confirming measurement should mark continuity as unknown. A later rc=3 should restart or explicitly classify the episode as “duration unverified.”

3. Structurally, this branch cannot notice:

- Transient states between polls.
- Whether rc=3 persisted while offline or unmeasurable.
- A rollback window that begins and ends between measurements.
- The phone’s actual installed version or whether installation succeeded.
- Broken OTA content, signing, bookmark routing, or reachability when version counters still agree.
- Whether “approved behind HEAD” was intentional rather than forgotten distribution.
tokens used
12,843
1. The 2-day grace is defensible for noise control, but it hides the case for at least 48 hours—often longer because the laptop is offline half the time. More importantly, wall-clock age does not prove continuous persistence; it proves only two separated observations.

2. Wrong notification sequence:

`rc=3 → state starts → laptop offline/rc=2 for >2 days → issue recovers unseen → rc=3 recurs → alert`

If offline/unknown and rc=2 preserve `since`, two separate incidents become one “persistent” incident, causing an immediate false-aged alert.

Missing notification sequence:

`rc=3 → recovery or rc=1 occurs entirely between successful measurements → next measurement rc=0`

Neither incident is observed. Likewise, a permanently offline laptop produces no drift notification; only the separate visibility alert may eventually appear, assuming that timer advances independently.

To avoid conflation, any non-confirming measurement should mark continuity as unknown. A later rc=3 should restart or explicitly classify the episode as “duration unverified.”

3. Structurally, this branch cannot notice:

- Transient states between polls.
- Whether rc=3 persisted while offline or unmeasurable.
- A rollback window that begins and ends between measurements.
- The phone’s actual installed version or whether installation succeeded.
- Broken OTA content, signing, bookmark routing, or reachability when version counters still agree.
- Whether “approved behind HEAD” was intentional rather than forgotten distribution.
```
