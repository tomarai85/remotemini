# 配備の記録 — c4a5a60 を edith の常設へ (2026-08-05)

対象: `com.edith.rc-backend`(edith 常設・tailnet 内)
道具: `tools/deploy-to-edith.sh`(仮置き → 単体 → e2e → 複製 → 入れ替え → 同一性の観測)
機械が出した artifact: `verify-rc-backend-observe-20260805-171129.json`(この記録の隣)

この記録は**人が読む為の物**で、判定の正本ではない。判定は上の JSON と、
`deploy-to-edith.sh` 自身の終了コードが持つ。

---

## 1. 何が起きたか(3回走らせて、2回は門で止まった)

| 回 | 結果 | 止まった段 | 中身 |
|---|---|---|---|
| 1 | 赤 | 3(単体・仮置きで) | `doc-linerefs.test.mjs` が3本赤。**検査自身の誤り**(下記 §2) |
| 2 | 赤 | 3(単体・仮置きで) | 1本赤。①の直しに付けた**見張りの方**が誤り(下記 §3) |
| 3 | 緑 | — | 入れ替えまで完走(下記 §4) |

★1回目・2回目とも **本番の木に触る前**で止まっている。仮置き(`/Users/edith/rc-staging`)で
単体が落ちた段なので、`rc-backend` は旧版(434e292)のまま走り続けていた。
門が設計通りに効いた、という観測でもある。

## 2. 1回目の赤 — 「上に repo が在るか」は「上に在るのがこの repo か」ではない

`doc-linerefs.test.mjs` は、写しの中では原理的に測れない(対象の `.md` は親側に在る)ので
`skip = 測っていない` へ倒す造りになっている。その判定が
`git rev-parse --is-inside-work-tree` —— **「上が git の作業木か」**だけを見ていた。

edith の仮置きは `/Users/edith/rc-staging` で、その親 `/Users/edith` には
**別件の `.git`** が在る(艦隊の衛生 pass が 2026-08-03 に作った物。索引 12 件・`.md` 0 本)。
だから問いは yes になり、検査は**無関係な索引**を測って「追跡 .md が 0 本」で赤くなった。

直し: 問いを「その索引が**この file を今の path で**追跡しているか」へ替えた
(`git ls-files --error-unmatch -- <self>`)。写しでは必ず偽、親がたまたま別 repo でも真にならない。

★edith 側で先に**観測してから**直した(推測で直していない):
`rc-staging/test/doc-linerefs.test.mjs` は当該索引に **追跡されていない**。

## 3. 2回目の赤 — 見張りの印が、兄弟の本番の木に吸われていた

①の直しと同時に「本物の repo に居るのに飛ばしていたら赤にする」見張りを足した。
その印を**基準値の path 全部**から取っていたのが誤り。
`rc-backend/.harness/evidence-2026-08-02/README.md` は `/Users/edith` の下で**実在する**
—— 配備先には本番の木が `rc-backend` という名前で居るのだから当然で、親 repo の印にならない。

実測した内訳: 親直下の候補 4 件は全部 absent、当たったのは `rc-backend/…` の 2 件だけ。

直し: 印にするのは**親 repo の直下**(path に `/` を含まない)の書類だけ。
下位 path は配備先で兄弟の木に吸われる。印が 1 件も無くなったら黙らず**その場で赤**。

## 4. 3回目 — 完走(log からそのまま)

```
=== 6. 複製を取ってから、仮置きを本番の木へ入れ替える ===
配備中の印を立てた: /Users/edith/.rc-backend/deploy-in-progress
複製: /Users/edith/rc-releases/20260805-170600-e74c50e
入れ替えた: /Users/edith/rc-staging → /Users/edith/rc-backend

=== 7. 刻印が送った版と一致するか(= rsync が黙って何もしていない、を捕まえる) ===
本番に刻まれた版: c4a5a60

=== 8. 常設(launchd)が在るなら、走っている物を新しい木に入れ替える ===
常設あり(pid=11419) → kickstart -k で入れ替える(bootout はしない = 定義は触らない)
PID: 11419 → 47859(入れ替わった)
8787 の listener = 47859(launchd の job と一致)
応答: 401(401 が正 = 鍵を求めている)
/healthz: version=c4a5a60 pid=47859
```

単体(edith 上・仮置きで): `tests 680 / pass 674 / fail 0 / skipped 6`
e2e(edith 上・仮置きで): `pass=267 fail=0`
起動ラッパの分岐 / 陰性対照 / 印の置き場 / 外から入る印: 全部 OK
e2e の作業場の残骸: `残っている rc-e2e-*: 0`

警告の段(門ではない、3/3 緑):
- tailnet 鍵の期限 2026-12-25(残り 141 日)
- 停電から自力で戻る鎖 7/7(FileVault off / 自動ログイン / RunAtLoad / KeepAlive / autorestart / sleep 0)
- 複製の在庫 7 個・17M(自動では消さない)

★`skipped 6` の内訳も観測した。全部**理由を名乗って**飛んでいる:
4 本 = 上記 `doc-linerefs`(仮置きは版管理の外)、2 本 = 別 file の DESIGN 検査
(囲む repo が此処の `DESIGN.md` を版管理していない)。
つまり `緑 / 赤 / 測っていない` の三分が、本番の配備で実際に三つとも観測された。

## 5. 線の上の形(電話が分岐に使う4つ、実機で確認)

`tools/wire-shape.mjs` で**本番のサーバから**取った。値は出していない(形と閉じた語彙だけ)。

| 観測 | status | `code` | `display` |
|---|---|---|---|
| 実在セッションへ `POST …/messages` 本文 `{}` | 400 | 無し | **在り**(kind/text/keepText) |
| 実在しないセッションへ `POST …/messages` | 404 | `SESSION_NOT_FOUND` | 無し |
| 実在しないセッションの `GET …/history` | 404 | `SESSION_NOT_FOUND` | 無し |
| `GET /api/nope` | 404 | `NO_SUCH_ROUTE` | 無し |
| 鍵違いで `GET /api/sessions` | 401 | `AUTH_REQUIRED` | 無し |

`c2ce232` で凍らせた契約が、**動いているサーバの上で**その通りである事を確認した:
電話は「対象が消えた」(`SESSION_NOT_FOUND`)と「client が道を組み間違えた」(`NO_SUCH_ROUTE`)と
「認証」(`AUTH_REQUIRED`)を機械で見分けられる。操作の失敗は `display` を持ち `code` を持たない。

★この観測の途中で、`tools/wire-shape.mjs` の**使い方の例**が `/api/sessions/{id}/input` と
書いている事に気付いた(実際に打って 404 を踏んだ)。`/input` は対照の**偽サーバ**が持つ道で、
本番の書き込み口は `/api/sessions/{id}/messages`。
**散文と実装の名前がずれる**——この道具が存在する理由そのものを、道具自身の説明が踏んでいた。
散文の側を直した(対照側の `/input` は偽サーバの道なので正しい)。

## 6. これで**証明できていない**事

- 電話の実機からの通し。`§DoD` の 9 行目・10 行目は Tom の iPhone が要る。
- `--prove-stop`(止まる方向)は今回**回していない**。人が使う時間帯なので観測のみ。
  常設を入れた時の「止められるか」は 8/04 の artifact が持っている。
- 401/404 以外の分岐(5xx / SSE の切断)は今回の観測に含まれない。

## 7. 出所

- 完全な log: セッションの scratchpad `deploy-20260805-3.log`(1082 行)。
  中身は走らせた検査の名前が大半で、鍵・token・個人情報の類は走査して 0 件。
  この記録には判断に効く行だけを引いた。
- 錠の持ち主タグ `deploy-9dd585eb-…` は `hostname -s` の shasum 由来の8桁
  (機械名をそのまま log に出さない為。`deploy-to-edith.sh` の設計)。
