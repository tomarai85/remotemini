# Codex adversarial review — agents-cli liveness signal (2026-09-06, Evaluator substitute; codex-quick inline)

Two runs: the first (CRITICAL mode, file access) timed out at 300 s but had already reproduced on friday that /opt/homebrew/bin/claude is an old npm build rejecting 'agents --json' while ~/.local/bin/claude succeeds; the second (inline) returned the six findings below. All seven are folded into the change (see .harness/progress-2026-09-06-agents-cli-liveness.md 追記).

```
[codex-quick started pid=72408 10:02:48 timeout=170s — background callers: wait on the pid, do not read the output early]
Reading additional input from stdin...
OpenAI Codex v0.144.3
--------
workdir: /Users/tomtim/Infra/mobile-work/.claude/worktrees/agent-a7f17b04b93e9df69/rc-backend
model: gpt-5.6-sol
provider: openai
approval: never
sandbox: read-only
reasoning effort: xhigh
reasoning summaries: none
session id: 01a0773e-530a-7403-808f-b3cef999e1ef
--------
user
DO NOT read any files or run any commands — answer purely from this prompt; everything you need is inline. Be concise and direct.
Adversarial review, under 600 words, no file access (all inline). Findings with function name + concrete failing input; no rewrites. A Node desk adds an async, cached, single-flight reader of 'claude agents --json' to GET /api/sessions. Contract: the request NEVER awaits the CLI; ok:false is the ONLY meaning of unreadable and arrays are [] then; per-row cliSeen is null when unreadable/stale/unregistered; stale = ok:false with reason stale; at/ageMs carried on failure when a prior read succeeded; timeouts/spawn failures never throw into the handler. Hunt: fail-open paths, promise rejections escaping, unbounded growth, duplicate spawns, epoch-0 ambiguities, PATH/binary resolution under launchd (the desk runs under launchd with minimal PATH on a Mac mini where /opt/homebrew/bin/claude is an OLD npm build lacking 'agents --json' and ~/.local/bin/claude is current — the code now prefers ~/.local/bin), and whether cliSeenFor is O(1) per row.

=== src/agentscache.mjs ===
// `claude agents --json` を**一覧の応答に間に合う形で**持つ層(2026-09-06)。
//
// ── なぜ `src/agentscli.mjs` と別の file か ─────────────────────────────────
// あちらは純関数だけ(出力を読む / 台帳と突き合わせる)で、**process を呼び手が注入する**。
// 呼び手が居なかったので木の中で誰も import していなかった。此の file が其の呼び手で、
// 足すのは 3 つだけ:
//   ① 子を起こす経路(非同期・時間切れ付き)
//   ② 結果を持つ器(古さと、最後に失敗した理由)
//   ③ 一覧の 1 行に落とす写像(`cliSeen`)
// 判定と形は向こうに置いたまま —— 既に検査が在る道を通す為で、
// 此処で `JSON.parse` を書き直すと、同じ判断が 2 箇所に増える。
//
// ── なぜ `src/server.mjs` の中ではないのか ──────────────────────────────────
// server.mjs は **import した瞬間に listen する**ので、単体検査から一度も呼べない。
// 器と写像を其処に書くと、此の機能の中で一番間違えやすい所(読めなかった時に
// 何を返すか)が測れない場所に座る。だから呼べる場所へ出す ——
// `src/wire.mjs` を封筒の為に切り出したのと同じ理由。
//
// ── 此の層が守る 1 つの線 ───────────────────────────────────────────────
// ★**「訊けなかった」を「動いている物は無い」に化かさない。** `agentscli.mjs` が
//   parse の面で守っている線を、**時間の面**へ延ばすのが此の file の仕事:
//     ・まだ一度も読めていない  → `pending`(0 件ではない)
//     ・最後の読みが失敗した    → 其の理由(`timeout` / `spawn-failed` / `exit-N` …)
//     ・読めたが古い            → `stale`
//   どれも `ok:false` で、突き合わせの配列は空。**`ok:false` だけが
//   「配列を読むな」を意味する** —— 空の配列を「机にしか無い会話が 0 本」と
//   読めてしまうと、CLI を入れ替えた日に全部の会話が「生きている」の顔で出る。
//
// ★一覧の応答は**此の読みを待たない**。待つ造りにすると、`claude` が固まった日に
//   一覧そのものが返らなくなる —— 電話から机へ手が届かない事が此の系で一番高く付く。
//   だから要求は**キャッシュが持っている物を即答**し、古ければ裏で測り直す
//   (`usageForWire` が `cswap list --json` に対して採っているのと同じ形)。
import { crossCheck, readAgents } from "./agentscli.mjs";

/** 何 ms 経ったら測り直すか。既定 = 10 秒。 */
export const AGENTS_TTL_MS = 10_000;
/** 何 ms 経った成功を「古い」と呼ぶか。既定 = 60 秒。 */
export const AGENTS_STALE_MS = 60_000;
/** 子を諦める時刻。既定 = 4 秒。 */
export const AGENTS_TIMEOUT_MS = 4_000;

/** 既定の引数。`agentscli.mjs` の既定と同じ物を、注入できる形で持つ。 */
export const AGENTS_ARGS = ["agents", "--json"];

/**
 * 子に被せる env。**PATH だけ**を足す。
 *
 * ★足す理由は実測された故障の形に限る: launchd から起きたサーバの PATH は最小で、
 *   `claude` は `/opt/homebrew/bin` か `$HOME/.local/bin` に居る。PATH を渡さないと
 *   `spawn-failed` が机の常態になり、此の信号は永久に `ok:false` のまま座る。
 * ★locale は**被せない**。`tmuxChildEnv` が `LC_ALL` を上書きするのは、tmux の
 *   `-F` の区切りが locale で潰れるという**実測された**故障が在るから。此処の子は
 *   JSON を吐くだけで、同じ故障は一度も観測していない —— 観測していない機序に
 *   対策を書くと、次に読む人が「locale で壊れた事が在る」と読む。
 */
export function agentsChildEnv(base = process.env) {
  const home = typeof base.HOME === "string" && base.HOME ? base.HOME : null;
  // ★native install(`~/.local/bin`)を **先**に置く(2026-09-06、Codex が本番で再現): friday の
  //   `/opt/homebrew/bin/claude` は 5 月の npm 版で `agents --json` を `unknown option` で終える。
  //   homebrew を先に引くと、配備した瞬間に此の信号は `exit-1` で死に、封筒は永久に `ok:false` になる。
  //   `~/.local/bin/claude` は自動更新される本体(2.1.263)で、同じ命令が通る。
  const want = [home ? `${home}/.local/bin` : null, "/opt/homebrew/bin"].filter(Boolean);
  const have = typeof base.PATH === "string" && base.PATH ? base.PATH.split(":") : [];
  const seen = new Set();
  const path = [...want, ...have].filter((p) => p && !seen.has(p) && seen.add(p)).join(":");
  return { ...base, PATH: path };
}

/**
 * 終わった子 1 回ぶんを `agentscli.mjs` の返り値の形へ落とす。**純関数**。
 *
 * ★中身の解釈は `readAgents` に通す(注入した `run` が `{status, stdout}` を返すだけ)。
 *   parse の枝を此処で書き直すと、既に検査が在る道の**2 本目の写し**が生まれる。
 * ★時間切れは `readAgents` の語彙に無いので此処で名乗る。exit code に潰さないのは、
 *   「答えなかった」と「答えたが失敗だった」で次に採る手が違うから
 *   (前者は机が重い / 後者は CLI が壊れた)。
 * ★spawn の失敗(`ENOENT` 等)は `err.code` が**文字列**、通常の失敗は**整数**の
 *   終了コード。此の 2 つを取り違えると、`claude` が居ない机で `exit-ENOENT` という
 *   在り得ない語が線に出る。
 */
export function readOutcome({ err = null, stdout = "" } = {}) {
  if (!err) return readAgents({ run: () => ({ status: 0, stdout: typeof stdout === "string" ? stdout : "" }) });
  if (err.killed === true || err.signal === "SIGKILL" || err.code === "ETIMEDOUT") {
    return { ok: false, sessions: [], dropped: 0, reason: "timeout" };
  }
  if (Number.isInteger(err.code)) {
    return readAgents({ run: () => ({ status: err.code, stdout: "" }) });
  }
  return { ok: false, sessions: [], dropped: 0, reason: "spawn-failed" };
}

/** 読めなかった時の封筒の観測部。**配列は必ず空**、鍵は 1 つも欠かさない。 */
function unread(reason, atIso, ageMs) {
  return { ok: false, reason, at: atIso, ageMs, both: [], onlyInRegistry: [], onlyInCli: [], dropped: 0 };
}

/**
 * 器の中身 + 台帳の id から、`GET /api/sessions` に載せる観測部を組む。**純関数**。
 *
 * `state` = `{ agents, at, reason }`。
 *   `agents` … 最後に**成功**した `readAgents` の返り値(まだ無ければ null)
 *   `at`     … 其の成功の時刻(ms)。0 = 一度も成功していない
 *   `reason` … 最後に**完了**した読みが失敗した理由。成功で null に戻る
 *
 * ★失敗は成功より**強い**。成功の後に 1 回失敗したら、古い成功ではなく失敗を名乗る ——
 *   「3 秒前は読めていた」より「今訊いたら答えなかった」の方が新しい観測で、
 *   前者を出すと故障が「少し古い正常」の顔をする。
 * ★`at` / `ageMs` は**成功が在れば必ず載せる**(`stale` や失敗の時も)。
 *   古さを隠すと、`stale` という語だけが出て「どれくらい古いのか」に誰も答えられない。
 * ★`ok:true` に成れるのは「成功が在り」「失敗していず」「古くない」時だけ。
 */
export function agentsSnapshot(state, registryIds, nowMs, staleMs = AGENTS_STALE_MS) {
  const at = Number.isFinite(state?.at) && state.at > 0 ? state.at : 0;
  const atIso = at > 0 ? new Date(at).toISOString() : null;
  const ageMs = at > 0 ? Math.max(0, Math.trunc(nowMs - at)) : null;
  const failed = typeof state?.reason === "string" && state.reason ? state.reason : null;
  if (failed) return unread(failed, atIso, ageMs);
  const agents = state?.agents ?? null;
  // まだ一度も読めていない = 最初の要求(裏で 1 本走り出した所)。0 件ではない。
  if (!agents) return unread("pending", atIso, ageMs);
  if (ageMs !== null && ageMs > staleMs) return unread("stale", atIso, ageMs);
  const x = crossCheck(registryIds, agents);
  // `crossCheck` は読めない入力を素通しする。此処へ来る時点で `ok:true` の筈だが、
  // 通らなかったら**其の理由をそのまま**名乗る(握り潰して ok:true にしない)。
  if (x.ok !== true) return unread(x.reason || "unreadable", atIso, ageMs);
  return {
    ok: true,
    reason: null,
    at: atIso,
    ageMs,
    both: x.both,
    onlyInRegistry: x.onlyInRegistry,
    onlyInCli: x.onlyInCli,
    dropped: Number.isInteger(agents.dropped) ? agents.dropped : 0,
  };
}

/**
 * 一覧の 1 行に落とす。`true` = CLI も知っている / `false` = 台帳に在るのに CLI は知らない /
 * `null` = **言えない**(読めなかった・古い・そもそも登録が無い行)。
 *
 * ★`ok:false` の時に配列を読んではいけない —— 空の配列は「0 件だった」ではなく
 *   「訊けなかった」の入れ物なので、読めば登録済みの行が全部 `false`(= 終わった会話)に
 *   見える。此の 1 行の分岐が、此の機能で一番静かに壊れる場所。
 * ★登録の無い行(ペインを持たない会話)は `false` ではなく `null`。台帳に居ない物を
 *   「CLI が知らない」と言っても、突き合わせた事実が 1 つも無い。
 */
export function cliSeenFor(agentsCli, id) {
  if (!agentsCli || agentsCli.ok !== true) return null;
  if (typeof id !== "string" || id === "") return null;
  if (Array.isArray(agentsCli.both) && agentsCli.both.includes(id)) return true;
  if (Array.isArray(agentsCli.onlyInRegistry) && agentsCli.onlyInRegistry.includes(id)) return false;
  return null;
}

/**
 * 器 + 読み手。**`read()` は決して await しない / 決して投げない**。
 *
 * @param exec      `(cmd, args, opts) => Promise<{stdout}>`。既定は無い —— 注入しないと
 *                  `no-runner` を返し続ける(検査が本物の `claude` を起こさない為)。
 * @param now       時計。検査が進める。
 * @param onError   失敗を机の log へ出す口。既定は黙る(検査を汚さない)。
 *
 * ★測り直しの間隔は**試行の時刻**から数える(成功の時刻からではない)。成功からだと、
 *   恒久的に失敗している間は `at` が古いままなので**要求のたびに**子が立つ ——
 *   `usageForWire` が同じ形で踏んだ所(単発化は同時実行を 1 本にするだけで、
 *   連続実行を止めない)。
 */
export function makeAgentsCache({
  exec = null,
  now = Date.now,
  cmd = "claude",
  args = AGENTS_ARGS,
  ttlMs = AGENTS_TTL_MS,
  staleMs = AGENTS_STALE_MS,
  timeoutMs = AGENTS_TIMEOUT_MS,
  env = undefined,
  maxBuffer = 4 * 1024 * 1024,
  onError = () => {},
} = {}) {
  // ★`lastAttemptAt` の「まだ一度も」は **null** で持つ(0 ではない)。0 にすると
  //   「一度も試していない」と「時刻 0 に試した」が同じ値になり、時計の原点が小さい
  //   場面(注入した時計・単調時計へ替えた日)で **1 本目が永久に立たない**。
  //   書いた其の日に検査が捕まえた形なので、実在する壊れ方として残す。
  const state = { agents: null, at: 0, reason: null, inFlight: null, lastAttemptAt: null };

  function land(out) {
    if (out.ok === true) {
      state.agents = out;
      state.at = now();
      state.reason = null;
      return;
    }
    state.reason = out.reason || "unreadable";
    onError(state.reason);
  }

  function refresh() {
    if (state.inFlight) return state.inFlight;
    if (typeof exec !== "function") {
      state.reason = "no-runner";
      return null;
    }
    state.lastAttemptAt = now();
    let started;
    try {
      started = exec(cmd, args, { encoding: "utf8", timeout: timeoutMs, killSignal: "SIGKILL", maxBuffer, ...(env ? { env } : {}) });
    } catch (e) {
      // 同期で投げる `exec`(注入した偽物 / spawn の即時失敗)も、非同期の失敗と同じ語へ。
      land(readOutcome({ err: e }));
      return null;
    }
    if (!started || typeof started.then !== "function") {
      state.reason = "no-runner";
      return null;
    }
    state.inFlight = Promise.resolve(started)
      .then((res) => land(readOutcome({ stdout: res?.stdout })), (err) => land(readOutcome({ err })))
      // ★`land` 自身が投げても器を壊さない。壊れると `inFlight` が残り、
      //   以後 1 本も測り直されないまま古い値が出続ける(最悪の壊れ方)。
      .catch((e) => { state.reason = "spawn-failed"; onError(e && e.message); })
      .finally(() => { state.inFlight = null; });
    return state.inFlight;
  }

  return {
    /**
     * 今の観測を返す。裏で古ければ測り直しを**始めるだけ**で、待たない。
     * `registryIds` = 机の窓台帳に居る session id の並び。
     */
    read(registryIds) {
      try {
        if (!state.inFlight && (state.lastAttemptAt === null || now() - state.lastAttemptAt >= ttlMs)) refresh();
      } catch (e) {
        state.reason = "spawn-failed";
        onError(e && e.message);
      }
      return agentsSnapshot(state, registryIds, now(), staleMs);
    },
    /** 検査と、起動直後の 1 本目の為の口。返り値は待てる(要求の側は待たない)。 */
    refresh,
  };
}

=== server.mjs hunks ===
+// 2 本目の生存信号(2026-09-06)。CLI 自身が名乗るセッション一覧を、tmux の画面の**隣**に置く。
+import { AGENTS_STALE_MS, AGENTS_TIMEOUT_MS, AGENTS_TTL_MS, agentsChildEnv, cliSeenFor, makeAgentsCache } from "./agentscache.mjs";
+// ★2 本目の生存信号が叩く CLI(2026-09-06)。起動時に 1 回だけ決める —— `TMUX_BIN` /
+//   `CLAUDE_LAUNCHER` と同じ作法で、要求ごとに環境を読み直す道を作らない。
+//   既定が素の `claude` なのは、机ごとに置き場が違う(homebrew / `.local/bin`)為で、
+//   解決は `agentsChildEnv` が組む PATH に任せる。
+const CLAUDE_BIN = process.env.RC_CLAUDE_BIN || "claude";
+// ── 2 本目の生存信号(2026-09-06)────────────────────────────────────────────
+// 机はセッションの生死を tmux の画面から再構成している。CLI 自身も同じ事を口座全体で
+// read-only に公開しているので、**並べて**持つ。置き換えない —— 2 つは別々に壊れる
+// (tmux は locale や socket で、CLI は版の入れ替えで)から、片方が黙った時に
+// もう片方が残る事に価値が在る。
+//
+// ★一覧の応答は此の読みを**待たない**。`usageForWire` と同じ形(返してから測り直す)で、
+//   `claude` が固まった日にも一覧は同じ速さで返る。器と判定は `src/agentscache.mjs`
+//   (import しても listen しない場所)に在り、単体検査が直に呼ぶ。
+const agentsCache = makeAgentsCache({
+  exec: execFileAsync,
+  cmd: CLAUDE_BIN,
+  env: agentsChildEnv(),
+  ttlMs: Number(process.env.RC_AGENTS_TTL_MS) || AGENTS_TTL_MS,
+  staleMs: Number(process.env.RC_AGENTS_STALE_MS) || AGENTS_STALE_MS,
+  timeoutMs: Number(process.env.RC_AGENTS_TIMEOUT_MS) || AGENTS_TIMEOUT_MS,
+  // ★黙って捨てない(口座の使用量で同じ形を踏んだ)。読めない状態が続く事は、
+  //   値が無い事と同じくらい報告に値する —— 帯には 1 文しか出ないので、
+  //   机の log が唯一の診断になる。頻度は TTL で頭打ち(既定 10 秒に 1 本)。
+  onError: (why) => console.error(`[rc-backend] claude のセッション一覧を読めない(${why})`),
+});
+
+      // 2 本目の生存信号。**待たない**(古ければ裏で測り直すだけ)ので、此の 1 行で
+      // 一覧の遅さは変わらない。突き合わせる台帳側の id は上の `registered` と同じ集合 ——
+      // 別の所で作り直すと、絞り(scope / 保管)の掛かった後の並びと突き合わせる事になり、
+      // 「机が知らない」の意味が要求ごとに変わる。
+      const agentsCli = agentsCache.read([...registered]);
-        return sessionRow(s, live, machine, diffCache.get(s.cwd));
+        // ★2 本目の信号を**行の居場所の隣**に置く(2026-09-06)。表示専用 ——
+        //   此の値で送信を断ったり経路を変えたりはしない。`null` = 言えない
+        //   (読めなかった / 古い / 台帳に居ない行)で、`false` とは別の意味。
+        return sessionRow(s, { ...live, cliSeen: cliSeenFor(agentsCli, s.id) }, machine, diffCache.get(s.cwd));
+        // 文面は `wire.mjs` の `agentsCliView` が組む(「描くのは display」に揃える)。
+        // 此処は観測値を渡すだけ。
+        agentsCli,

=== wire.mjs hunks ===
-export function sessionsBody({ sessions, scan, paneFault, publishedBuild, appBuild }) {
+/**
+ * `claude agents --json` の突き合わせを**人が読む1文**にする(2026-09-06)。
+ *
+ * ★文面を此処で組む理由は `paneFaultView` / `scanLine` と同じ —— 電話に語を組み立てさせない。
+ *   `both` / `onlyInRegistry` の数から文を作る規則が机と電話の 2 箇所に在ると、
+ *   片方だけ直した日に、同じ観測が 2 つの違う事を言う。
+ *
+ * ★**読めなかった時に数を言わない。** `ok:false` の配列は「0 件だった」ではなく
+ *   「訊けなかった」の入れ物なので、其処から「0 本を確認」という文を作ると、
+ *   静かな故障が正常の顔で帯に出る(`src/agentscache.mjs` が守っている線と同じ物)。
+ *   代わりに**理由の語を文に入れる** —— 診断はこの1文しか読まれない事が多い。
+ */
+export function agentsCliView(agentsCli) {
+  if (!agentsCli || agentsCli.ok !== true) {
+    const why = (agentsCli && typeof agentsCli.reason === "string" && agentsCli.reason) || "unreadable";
+    return {
+      note: `Claude's own session list could not be read (${why}), so this list can't say which desk sessions Claude still knows.`,
+    };
+  }
+  const confirmed = Array.isArray(agentsCli.both) ? agentsCli.both.length : 0;
+  const gone = Array.isArray(agentsCli.onlyInRegistry) ? agentsCli.onlyInRegistry.length : 0;
+  return {
+    note: `Claude's own session list confirms ${confirmed} of ${confirmed + gone} registered sessions; ${gone} it no longer knows.`,
+  };
+}
+
+/**
+ * 封筒に載せる `agentsCli` の1枚。**鍵は 1 つも欠かさない**。
+ *
+ * ★引数が無い / 形が違う時は「読めていない」へ倒す。呼び側が渡し忘れた時に
+ *   鍵ごと消えると、電話は「古いサーバ」と「読めなかった机」を見分けられない ——
+ *   `diffBody` の `reason` を成功時も `null` で必ず載せるのと同じ判断。
+ * ★`ok:false` なら配列は**空に固定**する。呼び側が何を入れて来ても此処で落とす =
+ *   「`ok:false` だけが『配列を読むな』を意味する」という約束を、封筒の側でも守る。
+ */
+export function agentsCliBody(agentsCli) {
+  const ok = agentsCli?.ok === true;
+  const list = (v) => (ok && Array.isArray(v) ? [...v] : []);
+  const obs = {
+    ok,
+    reason: ok ? null : ((typeof agentsCli?.reason === "string" && agentsCli.reason) || "pending"),
+    at: typeof agentsCli?.at === "string" ? agentsCli.at : null,
+    ageMs: Number.isInteger(agentsCli?.ageMs) ? agentsCli.ageMs : null,
+    both: list(agentsCli?.both),
+    onlyInRegistry: list(agentsCli?.onlyInRegistry),
+    onlyInCli: list(agentsCli?.onlyInCli),
+    dropped: Number.isInteger(agentsCli?.dropped) ? agentsCli.dropped : 0,
+  };
+  return { ...obs, display: agentsCliView(obs) };
+}
+
+export function sessionsBody({ sessions, scan, paneFault, publishedBuild, appBuild, agentsCli }) {
+    // ★2 本目の生存信号(2026-09-06)。1 本目(tmux のペインの画面)と**並べて**載せる。
+    //   置き換えではない —— 机の観測と CLI の観測は別々に壊れるので、片方が黙った時に
+    //   もう片方が残る事に価値が在る。此処では表示専用で、送信も経路も此の値では変えない。
+    agentsCli: agentsCliBody(agentsCli),

End with a verdict line: PASS or FAIL naming blocking findings.
2026-09-06T15:02:49.064772Z ERROR rmcp::transport::worker: worker quit with fatal: Transport channel closed, when Auth(AuthorizationRequired)
2026-09-06T15:02:49.074893Z ERROR rmcp::transport::worker: worker quit with fatal: Transport channel closed, when Auth(AuthorizationRequired)
2026-09-06T15:02:49.537111Z ERROR rmcp::transport::worker: worker quit with fatal: Transport channel closed, when Auth(AuthorizationRequired)
codex
1. **`makeAgentsCache.read` can throw despite its contract.** Input: `exec: () => { throw Object.assign(new Error(), {code:"ENOENT"}) }`, `onError: () => { throw new Error("logger failed") }`. `refresh()` calls `land()`, whose `onError` throws; `read()` catches it but calls the same throwing `onError` again, escaping into `/api/sessions`. With `exec: () => Promise.reject(...)`, the `.catch()` callback can likewise throw and create an unhandled rejection.

2. **`agentsSnapshot` confuses a successful epoch-0 read with “no timestamp.”** Input: `state={agents:{ok:true,sessions:[],dropped:0},at:0,reason:null}`, `nowMs=60001`, `staleMs=60000`. It emits `ok:true`, `at:null`, `ageMs:null` instead of `ok:false, reason:"stale"`. `lastAttemptAt` fixed the epoch-0 ambiguity, but `state.at` still uses `0` as a sentinel.

3. **`cliSeenFor` is not O(1) per row.** Input: 100,000 IDs in `both`, 100,000 in `onlyInRegistry`, and 100,000 session rows whose IDs occur late or nowhere. Two `Array.includes()` scans per row make response construction O(rows × registered IDs), approaching quadratic behavior.

4. **`agentsCliBody` has a fail-open malformed-success path.** Input: `agentsCliBody({ok:true})` or `{ok:true,both:"invalid"}`. It returns `ok:true`, empty arrays, and a display claiming “confirms 0 of 0,” although the observation is unreadable. This contradicts its own stated malformed-input behavior and makes `ok:false` cease to be the reliable unreadability marker.

5. **Negative configuration permits request-rate process spawning.** Input: `RC_AGENTS_TTL_MS=-1`. `Number(...) || default` accepts `-1`, so every sequential request after settlement starts another CLI process. Single-flight prevents simultaneous duplicates, but does not bound spawn frequency.

6. **The preferred binary depends on `HOME` existing under launchd.** Input: `agentsChildEnv({PATH:"/usr/bin:/bin"})`. The resulting PATH omits `~/.local/bin` and places the known-old `/opt/homebrew/bin/claude` first, producing `exit-1`. Thus the stated production binary preference is not guaranteed under a minimal launchd environment.

**FAIL — blocking findings: handler/rejection escape, epoch-0 stale bypass, non-O(1) row lookup, and malformed-success fail-open.**
tokens used
21,838
1. **`makeAgentsCache.read` can throw despite its contract.** Input: `exec: () => { throw Object.assign(new Error(), {code:"ENOENT"}) }`, `onError: () => { throw new Error("logger failed") }`. `refresh()` calls `land()`, whose `onError` throws; `read()` catches it but calls the same throwing `onError` again, escaping into `/api/sessions`. With `exec: () => Promise.reject(...)`, the `.catch()` callback can likewise throw and create an unhandled rejection.

2. **`agentsSnapshot` confuses a successful epoch-0 read with “no timestamp.”** Input: `state={agents:{ok:true,sessions:[],dropped:0},at:0,reason:null}`, `nowMs=60001`, `staleMs=60000`. It emits `ok:true`, `at:null`, `ageMs:null` instead of `ok:false, reason:"stale"`. `lastAttemptAt` fixed the epoch-0 ambiguity, but `state.at` still uses `0` as a sentinel.

3. **`cliSeenFor` is not O(1) per row.** Input: 100,000 IDs in `both`, 100,000 in `onlyInRegistry`, and 100,000 session rows whose IDs occur late or nowhere. Two `Array.includes()` scans per row make response construction O(rows × registered IDs), approaching quadratic behavior.

4. **`agentsCliBody` has a fail-open malformed-success path.** Input: `agentsCliBody({ok:true})` or `{ok:true,both:"invalid"}`. It returns `ok:true`, empty arrays, and a display claiming “confirms 0 of 0,” although the observation is unreadable. This contradicts its own stated malformed-input behavior and makes `ok:false` cease to be the reliable unreadability marker.

5. **Negative configuration permits request-rate process spawning.** Input: `RC_AGENTS_TTL_MS=-1`. `Number(...) || default` accepts `-1`, so every sequential request after settlement starts another CLI process. Single-flight prevents simultaneous duplicates, but does not bound spawn frequency.

6. **The preferred binary depends on `HOME` existing under launchd.** Input: `agentsChildEnv({PATH:"/usr/bin:/bin"})`. The resulting PATH omits `~/.local/bin` and places the known-old `/opt/homebrew/bin/claude` first, producing `exit-1`. Thus the stated production binary preference is not guaranteed under a minimal launchd environment.

**FAIL — blocking findings: handler/rejection escape, epoch-0 stale bypass, non-O(1) row lookup, and malformed-success fail-open.**
```
