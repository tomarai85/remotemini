# Codex 査読 — 私の走行と Tom の電話を数え分ける(2026-08-30)

対象: `rc-backend/src/reqlog.mjs`(`clientClass`)/ `ios/tools/build.sh`(`role_for_mode` と
`--print-role`)/ `ios/project.yml`(`RCRole`)/ `ios/Sources/Core/SessionsClient.swift` /
`ios/tools/adhoc-ota.sh`(成果物の門)。
SHIP-GATE: `production_adjacent`(task `harness-traffic-is-not-counted-as-toms-phone`)。

## 何を直したか

H-3 訂正(同日)で実測: 述べ 593 件の `client=app` のうち **60 件が私の対照、36 件だけが Tom**。
私は**版番号で人を判じて**いた(私の殻は `CFBundleVersion=1`、彼は 96)。
其の規則は**配る度に壊れる** —— 彼は普段 HEAD より古い版に留まるから。
版は人ではない。

直し: `build.sh` が `RCRole` を Info.plist へ焼き、アプリが `X-RC-Role` で名乗り、
机は `control` に**完全一致した時だけ**役を採る(それ以外は UA の判定へ落ちる)。
★役を焼くのは **simulator 向けの mode だけ**(Tom は simulator を持っていない)。
署名する mode(= 配布される束)には決して焼かない。判定は1つの関数に在り、
`--print-role <mode>` で**焼かずに**問い合わせられる。

## 指摘と対応

| # | 指摘 | 採否 | 実装 |
|---|---|---|---|
| 1a | mode を鍵にすると、署名した実機ビルド・Ad Hoc・将来の mode を取り零す | **受け入れ(意図)** | 取り零した物は `app` = 過大計上に倒れる。過少計上は「彼が使ったのに使っていない事になる」= 今 直している嘘そのものなので、非対称に倒すのが正しい。★但し其れは **`app` を上限として読む**事が前提で、其れを #3 の対応で原文に書いた |
| 1b | `--print-role` は**方針**を測っており、**成果物**を測っていない。古い plist や別経路はそこを通り抜ける | **採用(実装)** | `adhoc-ota.sh` が配る直前に**焼かれた `Info.plist` の `RCRole`** を読み、空か差し込み損ねの literal 以外なら**配らずに止める**。対照 B7(門を外すと赤) |
| 2 | 自己申告のヘッダは telemetry であって identity ではない。認可・監査・確定的な帰属に使うな | **同意・現状で満たしている** | 行き先は log の1欄と台帳の集計だけ。認可にも経路制御にも触れない。詐称して得をするのは**自分の計器を汚す事だけ** |
| 3 | 曖昧さは**移動しただけ**。`control` = たぶん私 / `app` = 本人 **または** 印を付け損ねた私 / **不在は強い陰性証拠だが存在は行為を証明しない** | **採用・原文に明記** | `reqlog.mjs` の `clientClass` 註記に書いた。★**CF-17 は不在の向きに依存している**(配布口に `app` が1件も無い = 誰も来ていない)ので主張は生き残る。★誰が押したかを言うには認証された口座か設置 ID か行為ごとの事象 ID が要る —— 今は無い。対照 B8 が此の一行の存在を縛る(消すと赤) |

## 証拠

- 対照 6/6(B1-B8)+ 変異 5 本、各狙った対照だけ赤
  - M1 どの mode にも `control` を焼く → **B1 と B3** が赤(署名経路の一線)
  - M2 空でない役を何でも採る → B4-B6 赤
  - M3 役の判定を UA の後ろへ動かす → B4-B6 赤
  - M4 上限の註記を消す → B8 赤
  - M5 成果物の門を外す → B7 赤
- `--print-role` の実測: `sim`/`simapp` = `control` / `sign`・`install`・`num`・`rev`・空 = 空
- 単体 `reqlog.test.mjs` 33/33

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
session id: 01a0551b-572f-7ef0-8a12-d50fa10ba872
--------
user
DO NOT read any files or run any commands — answer purely from this prompt; everything you need is inline. Be concise and direct.
Adversarial review of an instrument fix. Under 250 words, no praise.

PROBLEM (measured today). A Node backend logs a client class per request, derived from User-Agent: CFNetwork|Darwin -> 'app'. The owner's iPhone hits it, and so do MY test builds — because my builds compile the SAME product Swift, so iOS gives them an identical UA shape. Over 4 days: 593 'app' requests, of which 60 were mine and only 36 were his. I had been separating us by BUILD NUMBER (mine were CFBundleVersion=1, his 96). That rule breaks on every publish, because he normally sits on an older build than HEAD. I was using a version number as a person identifier.

FIX. The build script bakes RCRole into Info.plist; the app sends X-RC-Role when non-empty; the server returns 'control' for exactly that value (case/space insensitive), otherwise falls through to UA classification unchanged.

The role is baked ONLY for simulator build modes (--sim, --sim-app). The signing mode (--no-install), which produces the artifact that gets published to the owner's phone, gets an empty role. That decision lives in one function with a --print-role <mode> query so a control can assert 'the signed path never carries a role' WITHOUT running a multi-minute build. Mutating the function to always return 'control' turns that control red.

ATTACK:
1. Keying on build MODE rather than an explicit operator flag: what real case does that miss? A signed device build I make for local testing still counts as 'app' — over-counting him. I chose over-counting over under-counting because under-counting produces the exact lie I am fixing (the log says he never used it when he did). Right call?
2. Is a self-declared header the right instrument at all, given I am the only party with a motive to set it?
3. Does this actually let me evaluate 'did he act via the app when a real opportunity arrived', or have I just moved the ambiguity somewhere else?
2026-08-30T23:57:31.254744Z ERROR rmcp::transport::worker: worker quit with fatal: Transport channel closed, when Auth(AuthorizationRequired)
2026-08-30T23:57:31.258371Z ERROR rmcp::transport::worker: worker quit with fatal: Transport channel closed, when Auth(AuthorizationRequired)
2026-08-30T23:57:31.480849Z ERROR rmcp::transport::worker: worker quit with fatal: Transport channel closed, when Auth(AuthorizationRequired)
codex
1. Mode-based tagging misses signed physical-device builds, ad hoc/TestFlight builds, and future build modes. Choosing false positives over false negatives is defensible only if `app` is explicitly treated as an upper bound, never as “owner.” Prefer an explicit operator role required for every tester build, with production defaulting empty. Also, `--print-role` tests policy logic, not the final artifact; stale plist values or another mutation path require inspecting the produced signed plist in release validation.

2. A self-declared header is acceptable telemetry, not identity. It works for cooperative exclusion of your requests. It must never support authorization, auditing, or definitive attribution. Anyone can spoof it, and your own device builds can omit it. A secret header would not fix accidental omission.

3. You have moved, not eliminated, the ambiguity. The new meanings are:

- `control`: probably your tagged test build.
- `app`: owner, your untagged device build, or any other iOS client with that UA.
- No `app` event: useful negative evidence, assuming complete logging.
- An `app` event: not proof the owner acted.

To evaluate “did he act via the app when a real opportunity arrived,” correlate the opportunity and resulting action using an authenticated account/session, server-issued installation ID, or action-specific event ID. UA plus exclusion tagging can clean background traffic, but cannot establish the actor.
tokens used
1,907
1. Mode-based tagging misses signed physical-device builds, ad hoc/TestFlight builds, and future build modes. Choosing false positives over false negatives is defensible only if `app` is explicitly treated as an upper bound, never as “owner.” Prefer an explicit operator role required for every tester build, with production defaulting empty. Also, `--print-role` tests policy logic, not the final artifact; stale plist values or another mutation path require inspecting the produced signed plist in release validation.

2. A self-declared header is acceptable telemetry, not identity. It works for cooperative exclusion of your requests. It must never support authorization, auditing, or definitive attribution. Anyone can spoof it, and your own device builds can omit it. A secret header would not fix accidental omission.

3. You have moved, not eliminated, the ambiguity. The new meanings are:

- `control`: probably your tagged test build.
- `app`: owner, your untagged device build, or any other iOS client with that UA.
- No `app` event: useful negative evidence, assuming complete logging.
- An `app` event: not proof the owner acted.

To evaluate “did he act via the app when a real opportunity arrived,” correlate the opportunity and resulting action using an authenticated account/session, server-issued installation ID, or action-specific event ID. UA plus exclusion tagging can clean background traffic, but cannot establish the actor.
```
