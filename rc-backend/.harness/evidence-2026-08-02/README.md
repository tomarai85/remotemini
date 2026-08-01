# 証拠 — edith への常設(launchd)投入 2026-08-02

safety-core.md HARD GATE 1(production-effect 案件は verifier の JSON artifact 必須)の分。
**この dir の JSON は生の観測値。以下はその読み方であって、観測値の言い換えではない。**

対象: `com.edith.rc-backend`(LaunchAgent, gui/501)/ 機械 = edith(10.0.0.0, Node 25.9.0)

---

## 1. `verify-stop-com.edith.rc-backend-*.json` — 共通の停止判定器

`~/.claude/tools/verify-production-stop.sh` の出力。**HARD GATE が名指ししている物**なので回した。

読み方: `stopped: "false"` は**期待通り**。今回は「止めた」案件ではなく「常設を入れた」案件で、
止まっていない事が目的の状態。`launchd_unloaded: false` / `plist_state: active` の2つが、
「入っていて動いている」を外から確定している。

### ★この artifact に1つ**誤った値**が入っている(隠さずに書く)

| field | 出た値 | 実際 |
|---|---|---|
| `process_absent` | `"true"` | **false**。pid 63469 が走っている(`verify-rc-backend-*.json` の同時刻の観測) |

原因: あの道具の check 3 は `ps aux | grep -F '<label>'`、つまり **launchd の label が
プロセスの argv に現れる事**を前提にしている。この service の argv は
`/opt/homebrew/bin/node src/server.mjs` で、label(`com.edith.rc-backend`)は一文字も出ない。
= **label が実行パスに含まれない service では、走っていても「プロセス不在」と出る**。

これは共通の安全器の弱点であって、この案件だけの話ではない(client-a 系は label に
`f3` 等が入っていて偶然当たっているだけの可能性がある)。**直すのは別レーンの仕事**なので
ここでは直していない = `~/.claude/tools/` は client-a 本番ゲートが使う Tier 0 の道具で、
主語が変わる。Tom への報告事項として HANDOFF §3 に出す。

代わりに、この service に対して**正しく測る道具**を同梱した ↓

## 2. `verify-rc-backend-observe-*.json` / `verify-rc-backend-prove-stop-*.json`

`rc-backend/tools/verify-rc-backend-state.sh`(この案件と一緒に書いた)。停止判定器の鏡で、
**入れた時に要る2つ**を測る:

1. **全層が「動いている」で一致するか** — launchd の job の pid ==
   8787 の listener の pid == cwd が `/Users/edith/rc-backend` の node のプロセス、その上で HTTP 401。
   ★応答コードは同一性の証拠にならない(8787 を掴んだままの古いプロセスも 401 を返す)。
2. **本当に止まるか / 戻るか** — `--prove-stop` が bootout → 全層の不在を観測 → bootstrap。
   KeepAlive=true なので SIGTERM では止まらない。真の停止は bootout だけ。

実測(03:57:12-14):

| 局面 | launchd job | job pid | 8787 の listener | 我々のプロセス | HTTP |
|---|---|---|---|---|---|
| before | あり | 63070 | 63070 | 63070 | 401 |
| **bootout 後** | **なし** | — | **なし** | **なし** | **接続不可** |
| bootstrap 後 | あり | 63469 | 63469 | 63469 | 401 |

`truly_stopped_at_bootout: true` / `restored_after_bootstrap: true`。
= **消せない物を人の機械に置いた訳ではない**事を観測で確定した。

### 負の対照(この道具が赤を出せる事の証明)

`bash tools/verify-rc-backend-state.sh --prove-stop 当たらない語` →
`aborted: true` / exit=1 / **bootout を撃たずに中止**。
プロセスプローブが盲(動いているのに0件)なら、停止後の「0件」も何も意味しないので、
**止める前に**拒む形にしてある。

## 3. この夜に**自分の検査器**で踏んだ穴2つ(同じ dir に残す)

1. **`ssh` は引数を1本に潰す**。`bash -s -- "$MODE" "node src/server.mjs"` は remote 側で
   `$2="node"` に割れ、pgrep が EDITH 自身の常駐6本(`edith-claude-http.mjs` 等)を拾って
   **「bootout 後も残留プロセスがある」という偽の赤**を出した。
   `printf %q` で包んで解決。★この罠は `verify-on-edith.sh:9-24` に既に書いてあったのに、
   隣の台本で適用し忘れた。**書いてある事と、適用してある事は別**。
   → 偽の赤を「実機の残留問題」と報告する寸前だった。`ps` を1回叩いて他人のプロセスだと分かった。
2. **`if ! ssh ...; then rc=$?` は必ず `rc=0`**(`!` で反転した後の状態が条件の状態になる)。
   検査器が拒否したのに exit 0 を返していた = 呼び出し側は「成功」と読む = 検査器の fail-open。

## 4. この証拠が**言っていない**事(広げて読まない)

- 電話(iPhone Safari)での描画・PWA・回線断からの復帰 — **一度も測っていない**(DESIGN §8-4、Tom ゲート)
- 再起動後に面が戻るか — plist の `LimitLoadToSessionType` と autoLogin から**推論している**だけ。
  edith を実際に再起動して確かめてはいない

---

## 5. 鎖③(打ち込み)を edith の実機で回した — と、そこで自分の計器に踏まれた話

`node tools/live-inject-check.mjs --cwd /Users/Shared/dev/roundtrip --cols 120 --rows 40`
(使い捨てセッション `rc-live-20260801190258`、Tom の `work` には触れない)

| ケース | 何を見ている | 字数 | 結果 | 待ち |
|---|---|---|---|---|
| A | 折り返す長文(1行) | 100 | sent delivered=verified | echo=39ms clear=39ms |
| B | 番号付きの複数行 | 50 | sent delivered=verified | echo=42ms clear=39ms |
| C | 先頭行が短い複数行 | 61 | sent delivered=verified | echo=42ms clear=42ms |
| D | 1500字級の長文 | 1507 | sent delivered=verified | echo=43ms clear=38ms |

4/4 delivered=verified・exit 0・片付け後にセッションの不在を確認。
= **打ち込みの層は edith の本物の Claude Code TUI(2.1.220)でも成立する**。

### ★その緑は「鎖が通った」ではなかった

画面の写しを開いたら、4件とも同じ物が返っていた:

```
⎿  You've hit your weekly limit · resets 12am (Asia/Tokyo)
   /usage-credits to finish what you're working on.
```

`grep -c "weekly limit"` = A:1 / B:2 / C:3 / D:1。**一度も答えが返っていない**。
この台本の検査対象は配達なので緑それ自体は嘘ではない。だが「edith で 4/4 緑」を
読んだ人(=数時間後の私)は「注入の鎖が通った」と読む。**狭い観測を、それが支えていない
結論に貼る**型 — この案件で最も繰り返している誤りで、今回はそれを**自分の計器に
埋め込んで**いた。

直した所(コード。文書に書き足すだけでは同じ事が起きる):

| 場所 | 変更 |
|---|---|
| `src/inject.mjs` | `limitNoticeIn()` / `classifyScreen().limited` を追加。**送信可否には使わない** — 上限は「送れない」ではなく「答えが返らない」で、遮断すると解けた瞬間に送れる物まで送れなくなる |
| `tools/live-inject-check.mjs` | 「相手」列 + 結論の位置に警告 + **exit 3**(配達は成立・相手が答えていない)。上限に当たっている機械では緑を出さない |
| `src/server.mjs` → `src/view.mjs` → 電話 | `limited` を状態に載せ、帯を「静か」ではなく「★利用上限(答えは返りません)」にする。外出先で「返事が遅い」と読んで待ち続ける事が実害 |
| `test/mutation-controls.py` | M74(検出を殺す)/ M75(常に真)/ M76(電話に出さない)= 3件とも**検出**を確認 |

### ★この変更が、既に在った検査を2つ黙って無力化していた

`classifyScreen` の返り値に `limited` を足した事で、M1(メニュー判定を外す)と
M7(生成中を遮断条件に戻す)の**的の文字列が一致しなくなった**。
`--dry` の「的の照合: 76件 / 当たらない 2件」で気付いて的を貼り直した(現在 0件)。
= **当たらないプローブは「無い」と報告する**の、この夜3度目。今回は検査の側で起きた。

### 分かった事(Tom の判断が要る)

- edith の Claude Code は **`mail-redacted@example.invalid` の Organization / Claude Max / Sonnet 5**
  で走っている(起動バナーの実測)。★これは**新事実ではない** — DESIGN §8-3 が 7/31 に
  `~/.claude.json` から同じ事を確定済で、上限の解除日まで書いてある。私はそれを二度目に
  発見しかけた。足せたのは「別経路での裏取り」と「上限時に実際どう見えるか」の実測だけ
  (= 送信は4/4成立し、答えは0件。残量切れは「使えない」ではなく
  **送れてしまうのに返ってこない**形で来る)。
- 上限の解除は **12am Asia/Tokyo**。それまで edith 側で会話を進める検証はできない。
- §8-3 の判断(個人アカウントへ切替えるか)は**まだ Tom 待ち**。
- ~~tmux への打ち込み(鎖③④)— **まだ作っていない**。今動くのは「見る」側だけ~~

  ★**この行は誤り。同じ日の内に自分で訂正する**(2026-08-02 04:20)。打ち込みは
  `src/inject.mjs`(483行・単体59件)と `POST /api/sessions/:id/messages` /
  `POST …/interrupt` として**在る**。8/01 に MBP の実機で4ケース通してもいる。
  正しくは「**edith では一度も回していない**」だった。書いた時に手元の `src/` を
  1回開けば分かる事を、記憶で「作っていない」と書いた。→ §5 に実測を足した。
