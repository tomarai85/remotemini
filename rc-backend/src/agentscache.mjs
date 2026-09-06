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
import { homedir } from "node:os";
import { crossCheck, readAgents } from "./agentscli.mjs";

/** 何 ms 経ったら測り直すか。既定 = 10 秒。 */
export const AGENTS_TTL_MS = 10_000;
/** 何 ms 経った成功を「古い」と呼ぶか。既定 = 60 秒。 */
export const AGENTS_STALE_MS = 60_000;
/** 子を諦める時刻。既定 = 4 秒。 */
export const AGENTS_TIMEOUT_MS = 4_000;

/** 設定値は **正の有限な ms** だけ受ける。`Number(x) || 既定` は `-1` を通し、TTL が負だと
 *  要求のたびに子が立つ(Codex 2026-09-06)。読めない・0 以下・無限は既定へ。 */
export function positiveMs(raw, dflt) {
  const n = typeof raw === "number" ? raw : Number(raw);
  return Number.isFinite(n) && n > 0 ? n : dflt;
}

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
  // ★HOME が無い env(launchd の素の env で HOME を落とした plist)でも native install を先に置く
  //   (Codex 2026-09-06: HOME 欠けで `~/.local/bin` が消え、古い homebrew 版が先頭に来ていた)。
  let home = typeof base.HOME === "string" && base.HOME ? base.HOME : null;
  if (!home) { try { home = homedir() || null; } catch { home = null; } }
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
 *   `at`     … 其の成功の時刻(ms)。**null** = 一度も成功していない(0 は時刻 0 の成功。
 *              `lastAttemptAt` と同じ理由で 0 を「無い」に使わない — Codex 2026-09-06)
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
  const at = Number.isFinite(state?.at) && state.at !== null && state.at >= 0 ? state.at : null;
  const atIso = at !== null ? new Date(at).toISOString() : null;
  const ageMs = at !== null ? Math.max(0, Math.trunc(nowMs - at)) : null;
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
export function cliSeenIndex(agentsCli) {
  if (!agentsCli || agentsCli.ok !== true) return { ok: false, both: new Set(), gone: new Set() };
  return {
    ok: true,
    both: new Set(Array.isArray(agentsCli.both) ? agentsCli.both : []),
    gone: new Set(Array.isArray(agentsCli.onlyInRegistry) ? agentsCli.onlyInRegistry : []),
  };
}

/** 一覧の行ごとに呼ぶ。`agentsCli` そのものでも `cliSeenIndex` の結果でも受ける —— 行の数だけ
 *  `Array.includes` を走らせない(Codex 2026-09-06: 行 × 台帳の積になっていた)。 */
export function cliSeenFor(agentsCliOrIndex, id) {
  if (typeof id !== "string" || id === "") return null;
  const idx = agentsCliOrIndex && agentsCliOrIndex.both instanceof Set ? agentsCliOrIndex : cliSeenIndex(agentsCliOrIndex);
  if (idx.ok !== true) return null;
  if (idx.both.has(id)) return true;
  if (idx.gone.has(id)) return false;
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
  const state = { agents: null, at: null, reason: null, inFlight: null, lastAttemptAt: null };
  // ★log の口が投げても器は投げない(Codex 2026-09-06: `onError` が投げると `read()` の契約が破れる)。
  const report = (why) => { try { onError(why); } catch { /* 診断の口の故障で観測を壊さない */ } };

  function land(out) {
    if (out.ok === true) {
      state.agents = out;
      state.at = now();
      state.reason = null;
      return;
    }
    state.reason = out.reason || "unreadable";
    report(state.reason);
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
      .catch((e) => { state.reason = "spawn-failed"; report(e && e.message); })
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
        report(e && e.message);
      }
      return agentsSnapshot(state, registryIds, now(), staleMs);
    },
    /** 検査と、起動直後の 1 本目の為の口。返り値は待てる(要求の側は待たない)。 */
    refresh,
  };
}
