# Codex 査読 — 上限 vs launchd が抱えた追記者(2026-08-30)

対象: `rc-backend/tools/log-cap-live-appender-proof.sh`(新設)/ `rc-backend/tools/log-size-cap.sh`。
SHIP-GATE: `production_adjacent`(task `log-cap-proven-against-a-launchd-held-appender`)。

## ★此の台本が最初の走行で見つけた実害

CF-9 に「本番の追記者相手ではまだ測っていない」と書いてあった。作って撃ったら
**406 行が消えた**(番号 10480..10885)。

原因: 上限は退避を読んでから、**整形・`chmod`・`mv` を全部済ませてから**切っていた。
其の間も追記者は書き続けるので、其の行は**退避にも入らず、切られて消える**。
切る位置を「退避を読んだ直後」へ動かして **406 → 8-10 行**。

★**0 にはできない**。`tail` の完了と `: > "$F"` を原子的に行う手が無く、
追記者は錠を取らないので `flock` も効かない。

## 指摘と対応

| # | 指摘 | 採否 | 実装 |
|---|---|---|---|
| 1 | (A)/(B) の分割は妥当だが、**(A) の 0 は安全性の証明ではなく特定負荷の回帰試験**。複数回反復し、1回でも欠損したら失敗にせよ | **採用** | `RC_PROOF_ROUNDS`(既定 3)。**合計**で判定するので1回でも落ちれば赤。実測 2 回とも 抜け 0 |
| 2 | temp を残すだけでは不十分。**truncate 前に temp を完全に書き終えた事を検証**せよ | **採用(実害だった)** | 切る前に退避の大きさを検め、期待(`min(元の大きさ, 上限)`)を下回れば**切らない**。★変異で実演: 検めを外すと **800,001 B が 187 B** になる(対照 C13)。`tail` の終了コードは「途中まで書けた」を成功として返す経路が在るので、コードだけでは足りなかった |
| 3 | 番号では見えない破損が在る(`O_APPEND` でない writer が作る疎な穴 / 行途中の切断 / 複数 writer の混在 / cap の二重起動) | **部分採用** | **NUL バイト**と**行の途中で切れた行**を別に数え、合否に入れた(疎な穴と行途中は此れで出る)。複数 writer と二重起動は**未着手として記録** —— 今の本番は log ごとに writer 1本で、上限は `StartInterval` の単発 |
| 3b | scratch writer を実プロセスと同じ fd 保持・open flags・buffering に揃えないと主要リスクを再現できない | **部分的に満たしている** | 追記者は `>>`(= `O_APPEND`)で開き、**launchd が抱えたまま**書き続ける最中に切っている。buffering は bash の `printf` なので node の stdio とは違う —— **差分として記録** |

## ★自分で見つけた検査の欠陥(査読とは別)

`行途中` が毎回きっかり **1 本**出た。中身は**上限が自分で書き足す註記**
(`[log-size-cap] …`)で、`seq=` で始まらないのは設計どおり。
**検査が測る物と守りたい物がずれていた**形で、註記を除外して 0 になった。
毎回1本という規則性が決め手だった(壊れ方なら回ごとに揺れる)。

## 証拠

```
A[1] 抜け=0 NUL=0 行途中=0
A[2] 抜け=0 NUL=0 行途中=0
log-cap-proof: A 抜け 0 / NUL 0 / 行途中 0(2 回とも)
  B 全速での抜け = 53 行。之が窓の広さの実測
```

- 解析部の対照 10/10(D1-D6 + 変異 3 + 残骸)。★D2b が「境目ちょうどの抜け」を撃つ ——
  上限が切った瞬間に落ちるなら抜けは必ず其の位置に出る
- `log-cap-controls` 21/21(C13 新設。変異で 800,001 B → 187 B を実演)
- friday に残骸なし(dir も job も消えている事を実測)

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
session id: 01a05533-39e4-7832-a30c-53e0ea47991d
--------
user
DO NOT read any files or run any commands — answer purely from this prompt; everything you need is inline. Be concise and direct.
Adversarial review. Under 250 words, no praise.

A hourly launchd job caps log files on a Mac mini: it reads the last N bytes, writes them to <file>.tail, then truncates the original in place with ': > $F'. In-place truncation is deliberate — the writers are long-lived launchd processes holding the fd open, so renaming would leave them writing to an unlinked inode.

The existing controls only ever tested this against an appender I started myself. I built a proof that runs on the real machine: it installs a scratch LaunchAgent whose script appends numbered lines with '>>', waits for the log to grow, runs the cap WHILE the appender is still writing, then checks the sequence numbers across (tail sidecar + truncated log) for gaps.

FIRST RUN FOUND A REAL DEFECT: 406 consecutive numbers missing. Cause: everything between reading the tail and truncating — formatting the sidecar, chmod, an mv — happened before the truncate, and the appender kept writing into that window. Those lines were in neither the sidecar nor the surviving file. I moved the truncate to immediately after the tail read; the loss dropped to 8-10 lines. It cannot reach zero: read-tail and truncate cannot be made atomic, and the appender takes no lock.

So the proof now asserts TWO things: (A) at a production-like write rate (one line per 20ms — still orders of magnitude faster than the real 11 KB/hour) the gap must be ZERO, pass/fail; (B) at max write rate it reports the gap size as a measured bound, NOT pass/fail, because gating on a machine-speed-dependent number makes the check change colour with the weather.

ATTACK:
1. Is (A)/(B) the right split, or am I hiding a real defect behind 'production rate'?
2. Moving the truncate earlier means a later failure (sidecar write) happens AFTER the file is already emptied. I keep the temp snapshot on that path and print its location instead of deleting it. Sufficient?
3. What else does an in-place truncate against a live launchd writer break that sequence numbers cannot see?
2026-08-31T00:23:36.489512Z ERROR rmcp::transport::worker: worker quit with fatal: Transport channel closed, when Auth(AuthorizationRequired)
2026-08-31T00:23:36.912159Z ERROR rmcp::transport::worker: worker quit with fatal: Transport channel closed, when Auth(AuthorizationRequired)
2026-08-31T00:23:37.198235Z ERROR rmcp::transport::worker: worker quit with fatal: Transport channel closed, when Auth(AuthorizationRequired)
codex
1. (A)/(B)の分割はテスト設計として妥当ですが、既知のデータ損失競合は残っています。(A)のゼロは安全性の証明ではなく、特定負荷での回帰試験です。平均11 KB/時ではなく、実運用の最大バースト、行サイズ、複数writer、実際のopen方式で試すべきです。複数回反復し、1回でも欠損したら失敗にしてください。(B)は性能依存の観測値として扱うのが正しいです。

2. temp保持だけでは不十分です。truncate前にtempを完全に書き終え、closeし、可能なら`fsync`し、サイズまたはハッシュを検証する必要があります。さらに、後続失敗を監視対象として非ゼロ終了し、tempを自動削除対象外へ置き、復旧手順を明示してください。それでも「snapshot取得後、truncate前」の追記は失われます。完全保証にはwriter側ロック、再open可能なrotation、またはロギング基盤への移行が必要です。

3. sequence番号では見えない破損があります。

- writerが`O_APPEND`でなければ、truncate後も古いfd offsetから書き、巨大な疎ファイルやNUL領域を作る
- stdioバッファ内データの遅延書込み
- 行途中・UTF-8途中での切断
- 複数writer間の行混在、順序逆転、重複
- cap処理の重複起動による相互破壊
- disk-full、I/Oエラー、kill、電源断によるsnapshot未永続化
- `tail -f/-F`など読者側のtruncate追従不良

scratch writerは、実プロセスと同じfd保持期間、open flags、buffering、複数writer構成に合わせないと主要リスクを再現できません。
tokens used
13,128
1. (A)/(B)の分割はテスト設計として妥当ですが、既知のデータ損失競合は残っています。(A)のゼロは安全性の証明ではなく、特定負荷での回帰試験です。平均11 KB/時ではなく、実運用の最大バースト、行サイズ、複数writer、実際のopen方式で試すべきです。複数回反復し、1回でも欠損したら失敗にしてください。(B)は性能依存の観測値として扱うのが正しいです。

2. temp保持だけでは不十分です。truncate前にtempを完全に書き終え、closeし、可能なら`fsync`し、サイズまたはハッシュを検証する必要があります。さらに、後続失敗を監視対象として非ゼロ終了し、tempを自動削除対象外へ置き、復旧手順を明示してください。それでも「snapshot取得後、truncate前」の追記は失われます。完全保証にはwriter側ロック、再open可能なrotation、またはロギング基盤への移行が必要です。

3. sequence番号では見えない破損があります。

- writerが`O_APPEND`でなければ、truncate後も古いfd offsetから書き、巨大な疎ファイルやNUL領域を作る
- stdioバッファ内データの遅延書込み
- 行途中・UTF-8途中での切断
- 複数writer間の行混在、順序逆転、重複
- cap処理の重複起動による相互破壊
- disk-full、I/Oエラー、kill、電源断によるsnapshot未永続化
- `tail -f/-F`など読者側のtruncate追従不良

scratch writerは、実プロセスと同じfd保持期間、open flags、buffering、複数writer構成に合わせないと主要リスクを再現できません。
```
