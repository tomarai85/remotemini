# Sprint 1 (`display`) の敵対的検査 — 2026-08-05

対象 = `spec-native-shell-2026-08-05.md` Sprint 1「サーバが語を持つ」。
`view.mjs` の S 群10本をサーバ側で呼び、応答の `display` に足した継ぎ目。

## 何を測ったか

回帰suiteが緑である事は**新しい欠陥が無い証拠にはならない**ので、実装を1箇所ずつ壊して
検査が赤くなるかを測った。壊し方は全部「間違えやすい方の引数を渡す」形 —— spec 訂正3の
「掴みたいのは関数を呼んだかではなく**正しい引数を渡したか**」に合わせてある。

手順: `src/server.mjs` を scratchpad に退避 -> `perl -0pi -e` で1変異 -> `node test/e2e-local.mjs`
-> 退避から復元 -> `diff -q` で復元を確認。15変異、各1回。

| # | 変異 | 結果 |
|---|---|---|
| M1 | 一覧 `routeLabel(live)` -> `routeLabel(s)` | 赤 |
| M2 | 履歴 `whoOf(entry.role)` -> `whoOf(entry)` | 赤 |
| M3 | poll gap `gapNotice(why)` -> `gapNotice({why})` | 赤 |
| M4 | poll `choiceView(f.screen.body)` -> `choiceView(f)` | 赤 |
| M5 | poll choice の変化判定を外す | 赤(但し下の注) |
| M6 | `speaks(res, clearQueueResult)` -> `interruptResult` | 赤 |
| M7 | `speaks(res, choiceResult)` -> `interruptResult` | 赤 |
| M8 | `speaks(res, interruptResult)` -> `sendResult` | 赤 |
| M9 | `SSE_SPEAKS.screen` の `choice` を消す | 赤 |
| M10 | poll choice を「画面が在れば毎回載せる」形へ | 赤(保持則の検査が単独で捕捉) |
| M11 | 一覧 `subtitleOf(s)` -> `subtitleOf(live)` | 赤 |
| M12 | 一覧 `scanLine(scanBody)` -> `scanLine({})` | 赤 |
| M13 | `SSE_SPEAKS.message` の `who` を消す | 赤 |
| M14 | `SSE_SPEAKS.gap` の `notice` を消す | **★緑のまま生き残った** |
| M15 | SSE gap `gapNotice(d.why)` -> `gapNotice(d)` | 赤(M14 を塞いだ後) |

## ★M14 = この回の唯一の実収穫

初版の 13-D は **poll の gap しか撃っていなかった**。`sendEvent` の gap の呼び口は4箇所
あるので、`SSE_SPEAKS.gap` を丸ごと消しても検査は全部緑のまま通った —— 電話側は
`display.notice` が `undefined` になる。

塞ぎ方: 古い `last-event-id` を付けて張り直すと SSE が必ず gap を1本返すので、それで撃つ
(`test/e2e-local.mjs` の「★SSE の gap にも `display.notice` が載る」)。塞いだ後に M14 を
撃ち直して赤、さらに引数違いの M15 も赤。

M5 の注: 変化判定を単純に外すと `f.screen` が `null` の会話で TypeError になり、**別の検査**
(「poll は完了した JSON を返す」)が先に赤くなる。それでは保持則そのものを測った事に
ならないので、crash しない形(M10)で撃ち直して、保持則の検査が単独で捕捉する事を確認した。

## 恒真でない事の担保

各項目に**対照**を付けてある(`argCheck`)。本命が一致しても、間違った引数でも同じ値に
なる fixture では `★対照が同値(この fixture では何も測れていない)` で赤くなる。
実際1件発火した: `DELETE …/queue` を 409 (`queue-not-ours`) で撃つと `clearQueueResult` と
`interruptResult` が両方 `{kind:"refused", text:b.error}` に潰れて、口を取り違えても
気付けない。**直したのは対照ではなく撃つ場所** —— 200 の口(`SID_SLOW` の空の行列)へ変えた。

## 副産物: 時間依存を1件除去

1回だけ、`SID_CHOICE` が `unregistered` に落ちて選択の面の検査が赤くなった(同じ回に 12-h の
行列も崩れた)。原因は登録簿の心拍窓 `HEARTBEAT_TTL_MS = 15_000` に対し、13-D 初版が
`8 × 1500ms` 待つ節を**登録に依る検査より前**に置いていた事(余裕3秒)。以後3回は緑だが、
緑が続いた事は余裕の証明ではないので、待つ節を block の最後へ回し、待ちも `4 × 800ms` に
落とした。並べ替え後 2回 + 変異検査中の十数回、この形の赤は再発していない。

なお 12-h の行列の崩れ(`queued=1`、期待 2)は **13-D より実行順が前**なので 13-D 起因では
ない。committed 版で2回走らせて再現せず、原因未特定のまま。**直したとは言わない。**

### 追記 2026-08-05 — 上の「原因未特定」は解けた(commit `69fd70d`)

真因は 12-h 自身の**暗黙の壁時計依存**。「走っている番は 1200ms 走り続ける」を前提に、
その窓の中へ3往復の HTTP と node の間合いを入れていた。窓を跨ぐと worker の
`entry.queue.shift()` が1本引き出すので `queued` が 2 -> 1 -> 0 と減る。

再現は定数を弄る前に機構で撃った: `RC_E2E_SLOW_MS=50` で 12-h **だけ**が赤(`queued=0`)。
直したのは定数ではなく形 —— turn が終わる時刻を検査が持つ(`releaseSlowTurn(n)` の合図が
来るまで偽ワーカーは答えない)。対照の対 = 合図あり+50ms は 267/0 緑、合図なし+50ms は
263/4 赤(`RC_E2E_NO_SLOW_GATE=1` が対照専用の栓)。**緑が続いた事は証拠にしていない。**

## 証拠

- `node test/e2e-local.mjs` -> `E2E: pass=267 fail=0`(並べ替え + SSE gap 追加の後)
- `npm test` -> `# pass 647 # fail 0`(`test/app-html.test.mjs` を含む = `app.html` 無改修)
- `bash rc-backend/tools/check-mutation-targets.sh` -> `的の照合: 241件 / 当たらない 0件`。
  変更前を `git stash` して同じ数(241)を実測 = **的は減っていない**
- `bash rc-backend/tools/check-no-pii.sh` -> exit 1。`src/server.mjs` を退避しても exit 1 =
  **この変更が足した PII は無い**(既存の tailnet IP 由来、remote 未設定なので未 push)
