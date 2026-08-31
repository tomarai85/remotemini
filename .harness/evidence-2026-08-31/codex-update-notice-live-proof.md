# Codex 査読 — 更新の帯を本物の机に対して実測する道具(2026-08-31)

SHIP-GATE: `production_adjacent`(task `update-notice-live-proof`)。

## 何を作ったか

`rc-backend/tools/update-notice-live-proof.sh`。帯の経路
(`ota-published.mjs` → `wire.updateNotice` → `sessionsBody.display.update`)は
今まで **fixture に対してしか緑を取っていなかった** —— fixture は「配っている版」も
「電話が名乗った版」も台本が渡すので、机が**本物の manifest**を読めているかも、
**本物の header** を読めているかも測っていない。

同じ日に其の穴の実物を踏んでいる: 要求ログの `build=` は 08-31 まで UA が運ぶ
**売り物の版**(`CFBundleShortVersionString`)を書いており build 番号ではなかったが、
fixture 側の検査は全部緑だった —— 台本が正しい番号を渡すから。

実測(初回): `old-build=114 notice=yes / current-build=115 notice=no / no-header notice=no`、rc=0。

## 指摘と対応

| # | 指摘 | 採否 | 実装 |
|---|---|---|---|
| 3-5 | 帯の**在る無し**しか見ておらず、**其の帯である事**を見ていない。別の理由で出た帯を「更新の帯」と読む | **採用** | 文面が**両方の番号**(手元 P-1 / 配布 P)を名乗る事を要求。実測の文面 = 「机は新しい版を配っています(手元 114 → 配布 115)。栞から入れ直してください。」 |
| 3-1/3-2 | 机が manifest を読まず**固定値や別 channel の残骸**を返していても、値が偶然一致すれば 0 になる | **採用** | `display.updateBuild`(机が自分で導いた数)が、私が ssh で読んだ manifest の数と一致する事を要求。ずれれば「別の物を読んでいる」で赤 |
| 2 | `P-1` は**番号の境界**であって実在の古い client ではない。本物の古い版は header を送らない / 別の形で送る事が在る | **部分採用** | 「header を送らない client」を第3の測定として足した(今の仕様では帯は**出ない**のが正しい —— 08-31 に UA 経路を消した為)。仕様なら検査に書く。★「実在の古い版で試せ」は電話が要るので**限界として明記**した |
| 1 | 0 は**机側の境界の挙動**しか証明しない。電話が header を送るか / 応答を描くか / 叩いて実際に入るかは未証明 | **採用(そのまま記録)** | 道具自身が走行の最後に其の範囲を印字する様にした。私が「電話が更新された」と言えない事を、道具が毎回 言う |

## 陰性対照(この検査が空虚でない事)

| 撃ち方 | 結果 |
|---|---|
| 出鱈目な秘密 | rc=2(測定不成立) |
| 届かない机 | rc=2 |
| 違う鍵 | rc=2 ★**最初は rc=1 だった** —— 401 の本文に `display` が無いのを「帯が出ない」と読み、**間違った犯人**(更新の経路が死んでいる)を名指していた。HTTP 200 と `display` の存在を要求する形へ直した |
| 変異 M1: `updateBuild` の照合相手をずらす | rc=1(赤に倒れる) |
| 変異 M2: 文面の照合相手をずらす | rc=1(赤に倒れる) |

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
session id: 01a056bf-58e9-7b82-a4e0-124aee7cac45
--------
user
DO NOT read any files or run any commands — answer purely from this prompt; everything you need is inline. Be concise and direct.
Answer from this prompt only. No files, no commands. Under 200 words, adversarial, no praise.

A personal iPhone app shows an 'update available' banner. Server reads the published build from an OTA manifest on disk (P), reads the phone's build from an X-App-Build header, and returns a banner string in display.update of GET /api/sessions. This chain was only ever tested against fixtures that hand the code both numbers, so nothing proved it could read the real manifest or the real header. That blind spot already bit: the request log's build field was recording the User-Agent's marketing version (0.1) instead of the build number, and every fixture test stayed green.

New live proof: read P from the desk over ssh, then two authenticated GETs to the live server differing in exactly one header (X-App-Build: P-1, then P). Require banner present for P-1, absent for P. Exit 0 / 1 wrong / 2 unmeasurable. Measured: old=114 yes, current=115 no, exit 0. Fail-closed: bad secret, unreachable desk, wrong key all give 2.

Three questions:
1. What can still be broken on the actual phone while this returns 0?
2. Is P-1 a sound stand-in for a real older client?
3. What breakage of this chain would this script report as 0 instead of 1?
2026-08-31T07:36:16.589160Z ERROR rmcp::transport::worker: worker quit with fatal: Transport channel closed, when Auth(AuthorizationRequired)
2026-08-31T07:36:16.597058Z ERROR rmcp::transport::worker: worker quit with fatal: Transport channel closed, when Auth(AuthorizationRequired)
2026-08-31T07:36:16.996998Z ERROR rmcp::transport::worker: worker quit with fatal: Transport channel closed, when Auth(AuthorizationRequired)
codex
1. The phone path remains unproved. It may omit/mangle `X-App-Build`, hit another environment, receive cached data, fail authentication, reject the response schema, ignore `display.update`, suppress the banner, or fail when the banner is tapped. The log may also remain wrong even if comparison works.

2. No. `P-1` tests only the numeric boundary, assuming sequential builds and comparison based solely on build number. A real older client may send no header, a malformed/string value, use another API/schema/auth flow, belong to another OTA channel, or lack banner-rendering code. Test at least one actually installed older build.

3. It can falsely return 0 when outputs match expectations for the wrong reason:

- The server ignores the manifest and uses a cached/hard-coded value equal to `P`.
- `P` is read from the wrong app/channel but coincidentally matches.
- An unrelated condition produces a banner only for `P-1`.
- A proxy/cache synthesizes responses based on the header.
- The script checks only presence, not the exact update banner.
- The production phone path is broken while synthetic requests work.

So exit 0 proves a narrow server-side boundary behavior, not the end-to-end phone chain.
tokens used
12,721
1. The phone path remains unproved. It may omit/mangle `X-App-Build`, hit another environment, receive cached data, fail authentication, reject the response schema, ignore `display.update`, suppress the banner, or fail when the banner is tapped. The log may also remain wrong even if comparison works.

2. No. `P-1` tests only the numeric boundary, assuming sequential builds and comparison based solely on build number. A real older client may send no header, a malformed/string value, use another API/schema/auth flow, belong to another OTA channel, or lack banner-rendering code. Test at least one actually installed older build.

3. It can falsely return 0 when outputs match expectations for the wrong reason:

- The server ignores the manifest and uses a cached/hard-coded value equal to `P`.
- `P` is read from the wrong app/channel but coincidentally matches.
- An unrelated condition produces a banner only for `P-1`.
- A proxy/cache synthesizes responses based on the header.
- The script checks only presence, not the exact update banner.
- The production phone path is broken while synthetic requests work.

So exit 0 proves a narrow server-side boundary behavior, not the end-to-end phone chain.
```
