# Codex 査読 — build 116 を配った判断(2026-08-31)

SHIP-GATE: `production_adjacent`(task `distribution-point-serves-the-dense-build-signal`)。

## 何をしたか

配布口を **115 → 116**。116 の利用者から見える唯一の差は、版の名乗りが
**全部の要求に載る**(元は一覧取得だけ)。之は実測した欠陥を塞ぐ物:
机側の道具が「最後の app 行」を読み、其れが名乗らない口だったので
**「電話は版を名乗っていない」と報告**した —— 電話は 115 を名乗っていたのに。

副次的に、Tom が今 動かしている 115 は**帯の UI を持つ最初の版**なので、
116 を配った事で「新しい版が在る」の帯が**初めて実際に出せる状態**になった。

## 指摘と対応

| # | 指摘 | 採否 | 実装 / 判断 |
|---|---|---|---|
| 1 | 初回導入の1時間後に次を配るのは**信頼を使う**。彼は「入れたばかりの物がもう古い」と読みうる。しかも 116 の利益は主に計測側で、走っている 115 を遡って直しはしない | **採用(報告の仕方を変える)** | 技術的には可逆で押し付けでもないが、**言い方が大事**なので Tom への報告で「急ぎではない」「利益は主に計測」と明示する。★配る事自体は取り消さない: 帯は出るだけで、叩くかは彼が決める |
| 2 | 帯が煩わしくなる条件: 115 が一覧取得を一度もしない / 消しても再出現 / 「新しい版」が計測だけの変更を大げさに言う / 導入が失敗する | **一部 実測・一部 記録** | 115 は**一覧取得でだけ**名乗るので、其の要求こそが帯の乗る応答(実測: 08:20:53Z の `/api/sessions` が build=115)。再出現の抑制は `UpdateSnooze`(115 に入っている)。★「計測だけの変更を大げさに言う」は真 —— 文面は版番号しか言わないので誇張はしないが、**中身の説明は帯に無い** |
| 3 | 配った後の検査が**証明していない**事: 実機の 115 が帯を表示した / 116 が本当に全部の口で押す(2要求しか見ていない)/ 叩いて入って起動する / 更新でデータ・認証・設定が残る / cache・オフライン・再起動・背面 | **受容(記録)** | 全部**電話が要る**。116 の「全部の口」は `BackendSession.data(for:)` に1箇所化した構造(対照 S1-S3)+ 単体検査で担保しており、**実機での観測ではない**。言い方を分ける: 「机は 116 を配っている」「彼の 115 に帯が出る筈」までが私の言える範囲 |
| 2-最後 | 秘密の path は revoke できない bearer credential | **既知・撤回条件つき** | 08-31 の `codex-ota-publish-115.md` に同じ指摘と裁定(回すと栞が壊れる / tailnet に彼以外の人間の機体が入ったら回す)|

## 実測

- 配布 116 / 承認 116(手元・机の両方)/ `ota-freshness` rc=0
- 机の外から 緑 10 / 赤 0 / 未測定 1(電話の UDID)
- **帯の生証明**: `old-build=115 notice=yes / current-build=116 notice=no / no-header notice=no`
  = 机は 115 を名乗る client に帯を出し、116 には出さない
- 「出来ているのに配っていない」の見張りが `undelivered` → **`ok`** へ戻った
- iOS 756/756(756 を取った commit から `ios/` は 0 file 変更)

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
session id: 01a0575a-3e3b-7d40-9d18-b0c63e701bb7
--------
user
DO NOT read any files or run any commands — answer purely from this prompt; everything you need is inline. Be concise and direct.
Answer from this prompt only. No files, no commands. Under 200 words, adversarial, no praise.

Personal iPhone app, backend on the owner's own Mac mini, install page on a tailnet-only URL behind a secret path that is never rotated (his bookmark must keep working).

An hour ago he installed build 115 — the first build he has ever taken from that install page. 115 is also the first build containing the in-app 'a new version is available' banner.

I have now published build 116. Its only user-visible difference: every request stamps the app's build number in a header, instead of only the session-list request. That closed a measured defect — a desk-side tool read the last app log line, which was an endpoint that did not stamp, and concluded 'the phone has not announced a version' while the phone had announced 115.

Consequence I intend: his running 115 will now show the banner naming 116. He taps when he wants; I never push.

Measured after publishing: served build 116, approval records agree on both machines, 10 delivery checks green from off the desk's LAN, freshness rc=0, and a live two-request probe shows the desk offers the banner to a client announcing 115 and not to one announcing 116.

Attack:
1. Is publishing a second build within an hour of his first install a mistake?
2. What could make the banner wrong or annoying rather than useful?
3. What did the post-publish checks NOT establish?
2026-08-31T10:25:27.897537Z ERROR rmcp::transport::worker: worker quit with fatal: Transport channel closed, when Auth(AuthorizationRequired)
2026-08-31T10:25:27.935630Z ERROR rmcp::transport::worker: worker quit with fatal: Transport channel closed, when Auth(AuthorizationRequired)
2026-08-31T10:25:28.325798Z ERROR rmcp::transport::worker: worker quit with fatal: Transport channel closed, when Auth(AuthorizationRequired)
codex
1. Not inherently. Optional pull-based publishing is defensible. But publishing within an hour of his first install spends trust: he may interpret the first install as immediately obsolete. The fix benefits telemetry mainly after 116; it does not retroactively make running 115 stamp every request.

2. The banner can be wrong or annoying if:

- 115 never performs the session-list request that announces its build.
- The banner decision relies on stale logs, caches, sessions, or mismatched client identity.
- It repeatedly appears after dismissal, during use, or before 116 is actually installable.
- “New version” overstates a telemetry-only change.
- Upgrade fails, loses state, or requires confusing trust/install steps.
- The permanent secret path leaks. Tailnet restriction helps, but the URL remains a non-revocable bearer credential.

3. The checks did not establish that:

- His physical iPhone running 115 displayed the banner.
- 115’s real request sequence triggers the version comparison.
- Build 116 stamps every endpoint, not merely the two probed requests.
- Tapping the banner successfully installs and launches 116.
- Upgrade preserves data, authentication, and settings.
- Dismissal/reappearance behavior is acceptable.
- Cache, offline, relaunch, backgrounding, and concurrent-session cases work.
- The artifact is correctly signed, uncompromised, and rollback-capable.
tokens used
4,361
1. Not inherently. Optional pull-based publishing is defensible. But publishing within an hour of his first install spends trust: he may interpret the first install as immediately obsolete. The fix benefits telemetry mainly after 116; it does not retroactively make running 115 stamp every request.

2. The banner can be wrong or annoying if:

- 115 never performs the session-list request that announces its build.
- The banner decision relies on stale logs, caches, sessions, or mismatched client identity.
- It repeatedly appears after dismissal, during use, or before 116 is actually installable.
- “New version” overstates a telemetry-only change.
- Upgrade fails, loses state, or requires confusing trust/install steps.
- The permanent secret path leaks. Tailnet restriction helps, but the URL remains a non-revocable bearer credential.

3. The checks did not establish that:

- His physical iPhone running 115 displayed the banner.
- 115’s real request sequence triggers the version comparison.
- Build 116 stamps every endpoint, not merely the two probed requests.
- Tapping the banner successfully installs and launches 116.
- Upgrade preserves data, authentication, and settings.
- Dismissal/reappearance behavior is acceptable.
- Cache, offline, relaunch, backgrounding, and concurrent-session cases work.
- The artifact is correctly signed, uncompromised, and rollback-capable.
```
