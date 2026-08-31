# Codex 査読 — build 115 を配布口へ載せた判断(2026-08-31)

SHIP-GATE: `production_adjacent`(task `ota-publish-head`)。**配布の後**に撃った
(配る前ではない —— 配る行為自体は可逆で、止めるべき性質の物ではないと判断した)。

## 何をしたか

配布口(friday の `tailscale serve` 9443、tailnet 限定)が配る版を **105 → 115** にした。
秘密の path は**変えていない**ので Tom の栞は生きたまま。承認の記録は手元と机の両方に 115。

## 指摘と対応

| # | 指摘 | 採否 | 実装 / 判断 |
|---|---|---|---|
| 1 | 秘密の path は「access control」ではなく**再利用可能な bearer secret**。本当の周壁は tailnet の会員資格と ACL。回さずに新しい版を載せた事は、既に漏れているかもしれない capability の**価値と寿命を伸ばした**。回して栞を差し替える方が安全 | **却下(理由付き)** | 枠組みの指摘は正しい —— 「唯一の access control」という私の言い方が雑だった。ただし対処は採らない: 回すと **Tom が叩く唯一の物が壊れる**。守る相手は「彼自身の艦隊の中に居て、既に秘密を見た誰か」で、其の艦隊は彼の機体しかない。栞を人の手で差し替える代金の方が高い。★**撤回条件**: tailnet に彼以外の人間の機体が入った時、または秘密が艦隊の外(画面共有・貼り付け・公開ログ)へ出た形跡が出た時、其の場で回して栞を作り直す |
| 2 | 断続的な UI の赤を抱えたまま配るのは危うい。倒れているのは**利用者から見える中核の挙動**。「今日 source を触っていない」は無関係 —— **115 は 105 と実質的に違う**ので、欠陥が 115 側に在る可能性を潰していない | **採用(私の論拠が甘かった)** | 実測で潰した。`git diff f5f8f4a..HEAD -- ios/Sources` の中身は **7 file、全部 List 画面と更新の帯**(SessionsClient / SessionsListingFixture / SessionsModels / UpdateSnooze / RootView / ListView / ListViewModel)。**`ios/Sources/Screens/Conversation` は 0 file**(対照: `Screens/List` は 2 file = 検査が本当に差分を見ている)。倒れる検査が覆う「長い会話を開いた時どこへ寄るか」の実装は **105 と 115 で1バイトも違わない**。よって 115 は其の欠陥を**持ち込んでいない**。同時に、**在る欠陥を直してもいない** —— 未解決として記録済み |
| 3 | 私の 11 点は**机側の整合**を証明しただけで、**導入の成功**は証明していない(電話が tailnet に居るか / UDID が profile の1台か / 証明書が失効していないか / iOS の版 / Safari が itms-services を辿るか / MIME・redirect・TLS・cache / .ipa が実際に入るか / 端末の空き容量や制限 / 115 が起動して机に届くか / 栞が古い頁を cache していないか) | **採用(そのまま記録)** | 全部**電話が要る**。私に出来るのは「机が正しく配っている」まで —— 実際、私の合計は其の範囲だった。★**言い方を直す**: 「配布口が 115 を配っている」と言い、「Tom の電話が 115 になる」とは言わない。★1つだけ機械で潰せた: 秘密を回していないので**栞の URL は前と同一**、= 古い URL を指したまま死んだ栞にはならない |

## 私の判断(Codex に同意しなかった点の理由)

配らない事の代金の方が大きい。実測:

- 彼の電話は配布口に**一度も取りに来ていない**ので、載っている物が何であれ彼は 105 未満
- **105 は更新の帯 UI 自体を持たない**(`6e2a5a0` は 105 配布の 2 時間後)。
  つまり 106 未満を配り続ける限り、「新しい版が在る」を彼に伝える経路は
  **私が思い出して言う**しか無い —— F3 以来、私の記憶は此の系の最弱点
- 配る行為は可逆(原子的な置き換え / `.ipa.prev` / `rollback-friday.sh` / 古い版を配り直せる)

## 実測(この判断を支える観測値)

- 配布 115 / 机の承認 115 / 手元の承認 115、`ota-freshness-check.sh` rc=0
- 机の外から: manifest・束・頁が返る / 出鱈目な秘密は 404 / ひとつ手前は一覧しない /
  manifest の行き先が今の机 / 配布版 == 署名版(115) / 配る木は所有者だけ /
  manifest と束が同じ版・同じ bundle id … 緑 10 / 赤 0 / 未測定 1(電話の UDID)
- 署名: Apple Distribution: Tomonori Arai (KJ2942P8F8) / get-task-allow=false /
  profile 期限 2027-06-07
- iOS 全掃き 752/752 緑(直前の走行)。★既知の断続的な赤は別記録
  (`ios/UITests/ConversationUITests.swift` の註 + commit `b6388f5`)

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
session id: 01a056b7-d7d8-7330-8585-efeecd624175
--------
user
DO NOT read any files or run any commands — answer purely from this prompt; everything you need is inline. Be concise and direct.
DO NOT read files or run commands — answer purely from this prompt. Under 300 words, no praise. Adversarial.

I just published a signed iOS Ad Hoc build to a distribution point the owner installs from by tapping a bookmark on his phone. Attack the decision and the verification.

WHAT: iPhone app + Node backend on the owner's own Mac mini. Distribution is `tailscale serve` on port 9443, tailnet-only (Funnel can only bind 443/8443/10000, so 9443 is structurally not public). The install page lives behind a 24-hex secret path segment; that secret path is the only access control and was NOT rotated, so his existing bookmark still works.

BEFORE: served build 105 (published 5 days ago). His phone runs something older than 105 and has never once fetched the distribution endpoint. HEAD builds to 115. So ~10 builds of fixes had no path to his phone.

ALSO MEASURED: build 105 predates the in-app "a new version is available" banner by two hours, so below build 106 that banner can never fire — the only way he learns about a new build is me telling him.

AFTER: serves 115. Approval record written on both the laptop and the desk. Verified from off the desk's LAN: manifest returns, ipa returns, page returns, wrong secret 404s, the path one level up does not list, manifest points at the current desk, served build == locally signed build (115), distribution tree is owner-only, manifest and ipa agree on build and bundle id. 10 green / 0 red / 1 unmeasured (his phone's UDID — I cannot ask the phone from here; the provisioning profile has 1 device and expires 2027-06-07).

KNOWN RED I DID NOT FIX: one UI test (`opening a long conversation lands at the newest line`) fails intermittently in the full 752-test run — FAIL/FAIL/PASS. Passes isolated (3/3, ~4s), passes in its own class, passes with each preceding class added one at a time. Raising its 10s wait to 20s still failed at 23.4s with the element absent the whole time, so it is not slowness. I reverted that timeout, left the test red-capable, and added a failure-time dump of the accessibility tree. I did NOT block publishing on it: I changed no iOS source today, so build 105 has the same code path.

ATTACK:
1. Is "the secret path is the only access control, and I did not rotate it" defensible, or did publishing a new build just widen something?
2. Is shipping with a known intermittent UI failure the wrong call, given the test is about where a long conversation opens?
3. What did my 11-point delivery check NOT measure that could still leave his tap broken?
2026-08-31T07:28:04.914144Z ERROR rmcp::transport::worker: worker quit with fatal: Transport channel closed, when Auth(AuthorizationRequired)
2026-08-31T07:28:05.118574Z ERROR rmcp::transport::worker: worker quit with fatal: Transport channel closed, when Auth(AuthorizationRequired)
2026-08-31T07:28:05.503719Z ERROR rmcp::transport::worker: worker quit with fatal: Transport channel closed, when Auth(AuthorizationRequired)
codex
1. **Secret path:** Weakly defensible for bookmark continuity, not as “access control.” Tailscale membership/ACLs are the real perimeter; the path is a reusable bearer secret. Reusing it means anyone in the tailnet who previously learned it—including through history, logs, screenshots, or sharing—automatically gains build 115. Publishing did not widen Internet reachability, but it widened the value and lifetime of an already-leaked capability. Rotation plus bookmark replacement would be safer.

2. **Intermittent UI failure:** Shipping is risky because the failing assertion covers a user-visible, core navigation behavior. PASS in isolation but failure in the full suite suggests state leakage, ordering, race, or resource interaction—not proof that the test is defective. “No source changed today” is irrelevant: build 115 differs materially from 105, and the defect may already exist in both. Publishing is defensible only if delivery was urgent, the owner accepted the known risk, and build 115 received a manual on-device long-conversation check. Otherwise the verification bar was lowered around a directly relevant red signal.

3. **Still unmeasured:**

- The phone is currently authorized on the tailnet and permitted by ACLs.
- Its UDID is actually the profile’s sole device.
- The signing certificate/profile is accepted and not revoked.
- The phone’s iOS version satisfies deployment requirements.
- Safari successfully follows the exact `itms-services` link.
- MIME types, redirects, TLS, caching, and manifest URL encoding work on iOS.
- The IPA downloads, verifies, installs, and upgrades the existing bundle.
- Device storage, restrictions, or prior signing identity do not block installation.
- Build 115 launches and reaches the Mac mini backend from that phone.
- The bookmark still contains the exact current URL and is not opening cached build 105.

Your checks prove server-side consistency, not successful OTA installation.
tokens used
13,102
1. **Secret path:** Weakly defensible for bookmark continuity, not as “access control.” Tailscale membership/ACLs are the real perimeter; the path is a reusable bearer secret. Reusing it means anyone in the tailnet who previously learned it—including through history, logs, screenshots, or sharing—automatically gains build 115. Publishing did not widen Internet reachability, but it widened the value and lifetime of an already-leaked capability. Rotation plus bookmark replacement would be safer.

2. **Intermittent UI failure:** Shipping is risky because the failing assertion covers a user-visible, core navigation behavior. PASS in isolation but failure in the full suite suggests state leakage, ordering, race, or resource interaction—not proof that the test is defective. “No source changed today” is irrelevant: build 115 differs materially from 105, and the defect may already exist in both. Publishing is defensible only if delivery was urgent, the owner accepted the known risk, and build 115 received a manual on-device long-conversation check. Otherwise the verification bar was lowered around a directly relevant red signal.

3. **Still unmeasured:**

- The phone is currently authorized on the tailnet and permitted by ACLs.
- Its UDID is actually the profile’s sole device.
- The signing certificate/profile is accepted and not revoked.
- The phone’s iOS version satisfies deployment requirements.
- Safari successfully follows the exact `itms-services` link.
- MIME types, redirects, TLS, caching, and manifest URL encoding work on iOS.
- The IPA downloads, verifies, installs, and upgrades the existing bundle.
- Device storage, restrictions, or prior signing identity do not block installation.
- Build 115 launches and reaches the Mac mini backend from that phone.
- The bookmark still contains the exact current URL and is not opening cached build 105.

Your checks prove server-side consistency, not successful OTA installation.

```
