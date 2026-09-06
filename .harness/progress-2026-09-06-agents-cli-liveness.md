<!-- session: 2026-09-06 09:29 -->

# Progress — `GET /api/sessions` が 2 本目の生存信号を運ぶ(2026-09-06)

## 追記(主セッション、Evaluator = Codex 代替)— 取り込んだ 7 点

Claude の Evaluator は口座の session limit で落ちたので、Codex を 2 回当てた(1 回目は本番の実機まで見に
行って時間切れ、2 回目は inline)。両方の所見を worktree で直し、検査を各 1 本足した(20 → 26 本):

1. **配備した瞬間に死ぬ経路**(1 回目、friday で再現): `/opt/homebrew/bin/claude` は 5 月の npm 版で
   `agents --json` を `unknown option` で終える。`agentsChildEnv` が homebrew を先に置いていたので、
   本番では永久に `exit-1`。→ native install(`~/.local/bin`)を先に、`CLAUDE_BIN` の既定も其れを名指し。
2. `onError` が投げると `read()` の「投げない」契約が破れる → `report()` で包む。
3. 時刻 0 の成功を「成功が無い」と読む(`at: 0` を無しの印に使っていた。`lastAttemptAt` と同じ形)→ `null`。
4. `cliSeenFor` が行ごとに `Array.includes` = 行 × 台帳の積 → `cliSeenIndex` の Set を応答ごとに 1 回。
5. `agentsCliBody({ok:true})` が空の配列で「0 本を確認」と言う(形の壊れた成功が正常の顔)→ `malformed` で読めない側へ。
6. `Number(x) || 既定` が `-1` を通し、TTL が負だと要求のたびに子が立つ → `positiveMs`。
7. HOME の無い env で `~/.local/bin` が消え homebrew が先頭に来る → `os.homedir()` で補う。

検査: `server-agents-liveness-cross-check.test.mjs` 26/26、wire 台帳 17/17、全 suite は主線で再走。

Mode 2 (Quick) / Generator。Spec = `.harness/spec-2026-09-06-agents-cli-liveness.md`(本流の写しを読んだ。
この worktree の `.harness/` には未複製)。Loop task = `server-liveness-cross-checked-live-against-claude-agents-json`。

Codex 委譲の評価: **該当なし**(理由 = 新規実装が 3 ファイル・約 200 行で Layer A の
「100 行超の新規実装」に触れるが、中身は**既存の判定器への配線**と失敗語彙の設計であり、
繰り返しパターンでも定型生成でもない。台帳(`wire-key-agreement` / `preflight-ledgers.sh`)の
どこを満たすかの判断が実装と不可分で、切り出すと私が結果を全部読み直す事になる)。

---

## Milestone 1: `claude agents --json` を一覧の応答に配線する

- Status: **Done**
- Files Changed:
  - `rc-backend/src/agentscache.mjs` — **新規**。器 + 読み手 + 写像。
    `makeAgentsCache({exec, now, cmd, args, ttlMs, staleMs, timeoutMs, env, onError})`(非同期・
    単発化・注入可能)、`agentsSnapshot(state, registryIds, nowMs, staleMs)`(純関数、封筒の観測部)、
    `cliSeenFor(agentsCli, id)`(行の 3 値)、`readOutcome({err, stdout})`(終わった子 1 回の読み分け)、
    `agentsChildEnv(base)`(PATH に `/opt/homebrew/bin` と `$HOME/.local/bin` を足す)。
    既定 = TTL 10 秒 / stale 60 秒 / timeout 4 秒。
  - `rc-backend/src/wire.mjs` — `agentsCliView(agentsCli)`(1 文)と `agentsCliBody(agentsCli)`
    (鍵を欠かさない封筒)を追加し、`sessionsBody` の引数に `agentsCli` を足して
    `agentsCli:` 鍵を 1 つ生やした。**既存の鍵は 1 つも動かしていない**。
  - `rc-backend/src/server.mjs` — `RC_CLAUDE_BIN`(既定 `claude`)を起動時に 1 回解決、
    module 直下に器を 1 つ作り、`/api/sessions` のハンドラで `agentsCache.read([...registered])` を
    呼んで封筒へ渡し、各行の `live` に `cliSeen` を足した。**待たない**(`await` を書いていない)。
  - `rc-backend/test/wire-key-agreement.test.mjs` — 台帳の登録(下記)。
  - `rc-backend/test/server-agents-liveness-cross-check.test.mjs` — **新規**、20 本。
- Tests Added(`rc-backend/test/server-agents-liveness-cross-check.test.mjs`、20 本):
  - 器: 1 本目は `pending` で子を 1 本だけ起こす / 飛んでいる間は前の答えを出し子は増えない /
    TTL を跨ぐと測り直しが始まる / **決して答えない読みが在っても即答する**(`read` が
    Promise を返したら赤 = 一覧の速さが CLI に依存し始めた合図) / 時間切れ / 成功の後の失敗 /
    `stale` と古さの数字 / 子を注入しない器 / 同期で投げる子 / **1 本目は時計の原点に依らず立つ**。
  - 写像: 台帳 {A,B} × CLI {A,C} → `both=[A]` / `onlyInRegistry=[B]` / `onlyInCli=[C]`、
    行は A=true / B=false / 未登録=null、`live` への追加のみ。
  - 封筒: 鍵を 1 つも欠かさない(`undefined` / `null` / `{}` / 文字列 / 正常 / 失敗の 6 入力)/
    `ok:false` の配列は必ず空 / 文面は数を語り、読めない時は理由の語を出して数を語らない。
  - 陰性対照 2 本(写像の側 = `ok:false` で配列を読む版と答えが違う / 器の側 = 「0 件」と
    「訊けなかった」が別の値・別の文面)。
- Self-Assessment:
  - Functional completeness: **5/5**(spec の Behaviour 1〜5 と Tests の 6 項を全部実装・実測)
  - Operational stability: **4/5**(下の「実測していない事」を引いた分)
  - No regressions: **5/5**(全 1304 本が緑のまま。差分は追加のみ)
- Setup Instructions:
  - How to run: `cd rc-backend && npm test`
  - How to test (この機能だけ): `cd rc-backend && node --test test/server-agents-liveness-cross-check.test.mjs`
  - 台帳: `cd rc-backend && node --test test/wire-key-agreement.test.mjs test/wire-vocabulary-agreement.test.mjs`
    / `bash test/wire-shape-controls.sh` / `bash rc-backend/tools/preflight-ledgers.sh`(木の根から)
  - 依存の追加: **無し**(`node:child_process` の `execFile` は既に server が使っている)
  - 新しい環境変数(全部 任意): `RC_CLAUDE_BIN` / `RC_AGENTS_TTL_MS` / `RC_AGENTS_STALE_MS` /
    `RC_AGENTS_TIMEOUT_MS`

---

## 検査の数(前 / 後)

| いつ | `npm test` |
|---|---|
| 着手前 | tests **1304** / pass 1304 / fail 0 |
| 着手後 | tests **1324** / pass 1324 / fail 0 |

差 = +20(新しい file の 20 本ちょうど。既存の本数は 1 本も減っていない)。

その他の走行:
- `node --test test/wire-key-agreement.test.mjs test/wire-vocabulary-agreement.test.mjs` → tests 17 / pass 17 / fail 0 / skipped 0
- `bash test/wire-shape-controls.sh` → PASS 20 / FAIL 0

---

## 台帳が止めた所と、満たし方

1. **`test/wire-key-agreement.test.mjs` ②(原文の鍵位置 = 実行で出た鍵)** — `sessionsBody` の
   引数を分解する書き方なので `MODULE_OF` に**目印(関数の宣言行そのもの)**が焼いてある。
   引数を 1 つ増やした瞬間に目印が本文を指さなくなる(= 鍵が 0 件になり ② が赤)。
   → 目印を新しい宣言行へ張り替えた。**緩めていない**(目印を消して既定へ戻す道は取っていない)。
2. **同 ④(鍵名の一致)** — `SessionsResponse` は `phone-subset` で、サーバにしか無い鍵は
   `serverOnly` に**過不足なく**宣言する規則。`agentsCli` が増えたので宣言に足した。
   足すだけでなく**理由を書く**手が要る規則なので、「電話がまだ 1 鍵も読まない = 読まないと
   決めたのではなく机側だけ先に出した」事と、電話が読み始めたら降ろす事を注釈に残した
   (`usageAgeSeconds` が実際に辿った道)。
3. **同 ①(builder は鍵を 1 つ以上出す)/ 入力の広さ** — `CASES.sessionsBody` の 2 枝に
   `agentsCli` を渡した。**読めた枝と読めなかった枝の両方**を通す(片枝だと「読めなかった時も
   鍵が欠けない」という封筒の約束を一度も実行しないまま緑になる)。検体は手で書かず
   `agentsSnapshot` を実際に走らせた出力にした。
4. **同「例外表は空のまま」** — `CASES` に在ってどの組でも使われない builder は赤。
   だから `agentsCliView` / `agentsCliBody` は `CASES` に**登録していない**(電話側に対応する
   `Decodable` が無く、組める相手が居ない)。`sessionsBody` の中から呼ばれる形で、
   出た鍵は `sessionsBody` の実行に含まれる。
5. **`test/wire-vocabulary-agreement.test.mjs`** — `src/**` の**全部大文字の文字列リテラル**は
   片側にしか無ければ赤。新しく書いたのは `"SIGKILL"` と `"ETIMEDOUT"` の 2 つだけで、
   どちらも既に `SERVER_ONLY` に理由付きで載っている(新規登録は不要)。
   理由の語(`pending` / `stale` / `timeout` / `spawn-failed` / `no-runner` / `exit-N`)は
   全部小文字なので走査に掛からない。**許可表を 1 行も緩めていない。**
6. **`test/app-update-notice-controls.sh`** — 既存の対照が `sessionsBody` を `agentsCli` **無し**で
   呼ぶ。だから `agentsCliBody` は引数が無い時に投げず「読めていない」へ倒す
   (`ok:false` / `reason:"pending"`)。対照は無改修で緑のまま。

---

## 陰性対照を実測した(「壊せば赤くなる」)

写しの木(`src/` + この検査 1 本だけを scratchpad へ複製)で変異を 1 件ずつ当てた。
**live の木は一度も書き換えていない**(複製の前後で `diff` が空である事を確認済み)。

| 当てた変異 | 倒れた検査 |
|---|---|
| `cliSeenFor` から `ok` の見張りを外す(= spec が名指しした変異) | 11 番「陰性対照(写像)」**だけ** |
| `agentsSnapshot` が失敗時にも配列を返す | 4・5・7・9・12 の 5 本 |
| `agentsCliBody` が `ok:false` でも配列を通す | 18 番「封筒は `ok:false` の配列を必ず空にする」**だけ** |
| `sessionsBody` から `agentsCli` を消す(機能の巻き戻し) | 20 番「封筒に載る」**だけ** |

= 4 件とも狙った検査が倒れ、巻き添えの形も判っている。「常に緑を返す検査」ではない。

---

## 途中で見つけた欠陥(検査が捕まえた、私が気付いていなかった 1 件)

「最後に測り直しを試みた時刻」を **0** で初期化していた。`now() - 0 >= ttlMs` は、
時計の原点が TTL(10 秒)より小さい場面 —— 注入した時計、あるいは将来 単調時計へ替えた日 ——
で**偽**になり、**1 本目の読みが永久に立たない**。帯は `pending` のまま固まるが、
本番の `Date.now()` は巨大なので**実機だけが緑**という、一番見つけにくい形だった。
`null`(= まだ一度も)と 0(= 時刻 0 に試した)を分けて直し、其の形を狙う検査を 1 本足した。

---

## 判断が spec の字面と分かれた所(2 件、どちらも意図的)

1. **`stale` は `ok:true` ではなく `ok:false`。** spec の封筒の註は
   「`ok:false` だけが『配列を読むな』を意味する」と書いており、`stale` を `ok:true` のまま
   行の側だけ `null` にすると、同じ「読むな」が 2 つの綴りで表される。fail-closed 側へ寄せた。
2. **`at` / `ageMs` は失敗時・`stale` 時にも載せる**(成功が 1 度でも在れば)。
   spec の註は「`ageMs` は ok の時」だが、`at` の定義は「最後に**成功**した時刻」なので、
   古い成功が在る限り齢は言える。隠すと `stale` という語だけが出て「どれくらい古いのか」に
   誰も答えられなくなる —— 古さを見せる為に足した信号が、古さを隠す形になる。
   一度も成功していない時は両方 `null`(此処は spec のまま)。

---

## 実測していない事(= 残っている的)

- **本物の `claude agents --json` を叩いていない。** 検査は全部 `exec` を注入していて、
  この worktree からは本番の机(friday)に触らない約束。よって
  「実際の CLI の出力が `parseAgents` を通る」事は 2026-09-04 の実測
  (`test/agents-cli-reader.test.mjs` の検体はその日の実出力の写し)に依っており、
  **今日 撃ち直してはいない**。配備の時に机の上で 1 回撃つのが正しい順。
- **電話は 1 鍵も読まない。** spec の通り表示専用・机側だけ。`display.note` は線に載っているが、
  描く者がまだ居ない(`serverOnly` に宣言済み)。
- **`RC_CLAUDE_BIN` の実在検証をしていない。** `CSWAP_BIN` は起動時に実在を確かめるが、
  こちらは spec の「`TMUX_BIN` / `CLAUDE_LAUNCHER` と同じ作法」に揃えた(あの 2 つも
  実在を確かめない)。居なければ `spawn-failed` が線に出て log にも 1 行出るので、
  静かには壊れない。**揃える判断であって、確かめられない訳ではない** —— 起動時の
  1 回の確認を足すのは安く、次の機会に足す価値が在る。
- **失敗が続く時の指数 backoff を入れていない。** 測り直しは TTL(既定 10 秒)で頭打ちなので、
  恒久障害でも 10 秒に 1 本。口座の使用量が 30 秒 → 最大 30 分の backoff を持つのと違う。
  一覧の要求頻度(電話が前面に来る度)では 10 秒上限で足りると判断したが、
  **測って決めた値ではない**ので、机の log が `claude のセッション一覧を読めない` で
  埋まる様なら backoff を足す。
- **commit していない**(lane の指示どおり)。差分は worktree に置いたまま。

---

## Evaluation History

- Attempt 1: 未評価(Evaluator へ渡す前)
