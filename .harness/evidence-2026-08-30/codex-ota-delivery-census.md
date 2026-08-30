# Codex 査読 — 配布口の受け渡し台帳(2026-08-30)

対象: `rc-backend/tools/ota-delivery-census.sh`(+ `com.fleet.rc-log-cap` の鎖への組み込み)。
SHIP-GATE: `production_adjacent`(task `ota-deliveries-counted-outside-the-cap`)。

## 指摘と対応

### #1 「`:ipa` だけでは『栞が叩かれたか』は判定できない」→ **採用**

> 測っているのは IPA 取得の試行であり、操作ではない。少なくとも `install-page`、
> `manifest`、`ipa` を別イベントとして集計すべき。

その通り。iOS は **install ページ → manifest.plist → ipa** の順に引くので、
「押した」証拠は manifest 側に出る。ipa まで来なかった回は
「**押したが入らなかった**」で、私の設計では其れが「押していない」と同じ顔になっていた。

対応: **副台帳**を足した(`ota-delivery-events.tsv`、`<date> <hour> <client> <事象> <結末> <件数>`)。
★**主台帳の 5 欄は変えない** —— 検査が欄位置を固定しており、形を変えれば既に積んだ履歴も
読めなくなる。足すのは別 file。朝の `app-usage-census.sh` で採ったのと同じ流儀。
対照 C9 / C10(C10 は「一度も押していない」と「押した」を分けられる事そのものを測る)。

### #2 「`&&` は誤り。census 障害をディスク枯渇へ昇格させている」→ **不採用(理由つき)**

Codex の求めた物は「cap は必ず実行し、**census 失敗は別途記録・通知する**」。
後半は**同じ日に別のタスクで作った**(CF-16): 台帳が落ちると `log-cap-all.sh` へ到達せず、
其の EXIT trap が書く**生存の印が更新されない** → 観測器が 3 時間で `stale` を鳴らす。
つまり「失敗が人に届く経路」は既に在る。

その上で `&&` を残す理由は数字: 配布口の log は **約 11 KB/時**で伸び、上限は 5MB。
台帳が止まってから上限に当たるまで**約 20 日**の余裕が在る。
「数え終わる前に元を消す」方が「20 日の猶予つきで切らずに溜める」より高くつく。
**撤回条件**: log の伸びが1桁上がった時(余裕が2日を切る)、または観測器の
`stale` が Tom に届かない事が実測された時。

### #3 「epoch/carry は tail 保持型の in-place 切り詰めでは不正確」→ **前提が誤り(私の説明が招いた)**

> 前回集計済みの tail が新ファイルにも残るため、`carry + current` は保持部分を二重計上する。

此れは**この系では起きない**。私が依頼文で "truncates in place (keeps the tail)" と
書いたのが曖昧だった。実装(`log-size-cap.sh`)は末尾を**別 file** `<file>.tail` へ写してから
`: > "$F"` で空にする —— 同じ file には戻さない(同 file の註記に
「tail を同じ file へ書き戻すのも採らない(初版はこれだった)」と明記)。
よって繰越と現在は**重ならない**。

残る指摘のうち生きている物:
- 「切り詰め後、次回確認までに再成長して前回 size 以上になると検出できない」= 真。
  但し境界は **1時間で 5MB 伸びる**事で、実測 11 KB/時。約 450 倍の余裕。
  **撤回条件**: 伸びが 5MB/時に近づいた時。
- 「inode 不変かつ同サイズへの書き換え」= 此の系に其の書き手は居ない。
- 「census 成功後・cap 実行前後のクラッシュ境界」= 台帳は cap の**前**に epoch を
  記録するので、次回は post-cut の小さい size を見て「切られた」と判ずる。順序は正しい。

## 実測(此の台帳が最初に答えた事)

```
ota-delivery-census: 6 行 / 渡し切り 18・中断 0・断り 0
  電話(client=app): ipa を受け取った 0 回 / 配布口へ来た事自体が 0 回
```

`client=app` の行が **path を問わず1本も無い**。install ページにすら来ていない。
= **栞は一度も叩かれていない**。

★此の主張が及ぶ範囲: log は 19,500 B で上限 5MB に一度も当たっておらず、
先頭がサーバの起動バナー、`runs = 7` の全走行を覆う。よって
「配布口が出来てから今まで」で正しい。それ以前は配布口自体が無い。

## 証拠

- 対照 10 本緑 / 変異 6 本(各狙った対照だけ赤)
- 出題側の検査 PASS(副台帳を足しても主台帳の 5 欄は無傷)
- friday で鎖が3段とも走り exit 0、生存の印も更新

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
session id: 01a054bd-35ea-7263-8dba-ba9714e50605
--------
user
DO NOT read any files or run any commands — answer purely from this prompt; everything you need is inline. Be concise and direct.
Review a small production tally script. Be adversarial, under 300 words, no praise.

CONTEXT: an iPhone app is distributed over an unauthenticated tailnet-only OTA endpoint (Ad Hoc, no TestFlight). Its access log lives in a directory that an hourly log-cap job truncates at 5MB, so history is destroyed. I added a census that runs BEFORE the cap in the same launchd job, chained '\''app-census && ota-census && exec cap'\'', and writes counts to a directory the cap does not touch.

Log line: '\''[ota] req <ISO8601> GET /:secret/:ipa client=app peer=xff code=200 bytes=1960109'\''
client is derived from User-Agent: CFNetwork|Darwin -> app (iOS installd or Safari), curl|node|... -> tool.

Output rows: '\''<date> <hour> <client> <outcome> <count>'\'', outcome = done(200) / aborted(0, logged on '\''close'\'' not '\''finish'\'' so interrupted downloads appear) / refused(anything else).

I count ONLY GETs whose path ends '\''/:ipa'\''. Not manifest.plist, not the install page — because the output has no path column, so mixing would make '\''done 3'\'' ambiguous.

Accumulation: I keep the log'\''s (inode, size). If inode changed OR size shrank, the log was cut: fold the previous total into a carry file, then ADD the current epoch'\''s counts. Otherwise the current count IS that epoch'\''s total. (You previously showed me that max() UNDERCOUNTS across a cut on the sibling script.)

FIRST REAL RESULT: 18 ipa fetches, ALL client=tool. Zero client=app requests of ANY path, across the log'\''s whole life. The owner has never tapped the install bookmark.

ATTACK:
1. Does counting only :ipa actually answer '\''was the bookmark tapped'\''? manifest.plist is fetched first and a manifest-without-ipa means tapped-but-refused. Am I measuring the wrong event?
2. The && chain means a census failure blocks the cap, so logs grow unbounded. Right trade or wrong?
3. Anything wrong with the epoch/carry accumulation as described, given the cap TRUNCATES in place (keeps the tail) rather than renaming?
2026-08-30T22:14:42.447956Z ERROR rmcp::transport::worker: worker quit with fatal: Transport channel closed, when Auth(AuthorizationRequired)
2026-08-30T22:14:42.447955Z ERROR rmcp::transport::worker: worker quit with fatal: Transport channel closed, when Auth(AuthorizationRequired)
2026-08-30T22:14:42.741897Z ERROR rmcp::transport::worker: worker quit with fatal: Transport channel closed, when Auth(AuthorizationRequired)
codex
1. **`:ipa` だけでは「ブックマークが押されたか」は判定できない。** 測っているのはIPA取得の試行であり、操作ではない。少なくとも `install-page`、`manifest`、`ipa` を別イベントとして集計すべき。出力に path/event 列を追加する。「全ログ期間で app の全パスが0」は未操作の状況証拠だが、過去の切り捨て以前までは証明しない。

2. **`&&` は誤り。** census障害をログ肥大・ディスク枯渇へ昇格させている。capは必ず実行し、census失敗は別途記録・通知するべき。集計欠損よりディスク障害の方が影響範囲が大きい。

3. **そのepoch/carry方式は、tail保持型のin-place切り詰めでは不正確。**

   - 前回集計済みのtailが新ファイルにも残るため、`carry + current` は保持部分を二重計上する。
   - 切り詰め後、次回確認までに再成長して前回size以上になると、size縮小を検出できない。
   - inode不変かつ同サイズへの書き換えも検出できない。
   - census成功後・cap実行前後のクラッシュ境界も曖昧。

必要なのは、capとの明示的な引き継ぎだ。cap前に累積値と境界を確定し、cap後は保持tailを除いた新規行だけ加算する。最も堅いのはログ行への一意ID、またはcapが保持境界を記録する方式。size/inodeだけを世代識別子として使ってはいけない。
tokens used
13,660
1. **`:ipa` だけでは「ブックマークが押されたか」は判定できない。** 測っているのはIPA取得の試行であり、操作ではない。少なくとも `install-page`、`manifest`、`ipa` を別イベントとして集計すべき。出力に path/event 列を追加する。「全ログ期間で app の全パスが0」は未操作の状況証拠だが、過去の切り捨て以前までは証明しない。

2. **`&&` は誤り。** census障害をログ肥大・ディスク枯渇へ昇格させている。capは必ず実行し、census失敗は別途記録・通知するべき。集計欠損よりディスク障害の方が影響範囲が大きい。

3. **そのepoch/carry方式は、tail保持型のin-place切り詰めでは不正確。**

   - 前回集計済みのtailが新ファイルにも残るため、`carry + current` は保持部分を二重計上する。
   - 切り詰め後、次回確認までに再成長して前回size以上になると、size縮小を検出できない。
   - inode不変かつ同サイズへの書き換えも検出できない。
   - census成功後・cap実行前後のクラッシュ境界も曖昧。

必要なのは、capとの明示的な引き継ぎだ。cap前に累積値と境界を確定し、cap後は保持tailを除いた新規行だけ加算する。最も堅いのはログ行への一意ID、またはcapが保持境界を記録する方式。size/inodeだけを世代識別子として使ってはいけない。
```
