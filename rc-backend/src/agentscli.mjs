// `claude agents --json` を読む層(2026-09-04)。
//
// ── なぜ在るか ──────────────────────────────────────────────────────────────
// 机はセッションの生死を **tmux の画面から再構成**している(`registry.mjs` の窓台帳 +
// `inject.mjs` の `classifyScreen`)。だが CLI 自身が同じ事を **口座全体で read-only に公開**して
// いる事が 2026-09-04 に判った(`research/subagent-stop-feasibility-2026-09-04.md` §1、此の機械で実測):
//
//   claude agents --json  → 有効なセッションの配列。実測した鍵の和集合 =
//                           cwd / id / kind / name / pid / sessionId / startedAt / state / status
//                           対話中の物は `pid` と `status`(idle|busy)、背景の物は短い `id` と `state`。
//   claude stop <id>      → 背景セッションを止める(会話は残る)
//
// 木を grep しても此の口を読む物は 1 つも無かった。此の module は其の**読む側だけ**を足す。
// 止める側・画面の置き換えは別の判断で、此処ではしない。
//
// ★**「訊けなかった」と「0 件だった」を別の値にする。** 此の repo は同じ形を何度も踏んでいる
//   (`digest-notify.sh` の「会話が 0 件」と「一覧が取れない」の分離、`listing.mjs` の
//   `metadataIncomplete`)。CLI が無い / 落ちた / JSON でない物を返した時に「動いている物は無い」と
//   答えると、**静かな故障が正常の顔で出る**。だから返り値は必ず `ok` を持ち、
//   読めなかった時は `sessions: []` ではなく `ok: false` + `reason` を返す。
//
// ★process は**呼び手が注入する**。検査で本物の `claude` を起こさない為で、
//   `roots.mjs` が fs を注入しているのと同じ理由(検査が機械の状態に依存しない)。

/** 一覧の 1 件。**知らない鍵は落とす**(机が知らない物を電話へ運ばない)。 */
function normalise(row) {
  if (!row || typeof row !== "object" || Array.isArray(row)) return null;
  const str = (v) => (typeof v === "string" && v.length > 0 ? v : null);
  const num = (v) => (Number.isInteger(v) && v > 0 ? v : null);
  const kind = str(row.kind);
  // `sessionId` が唯一、机の窓台帳(`~/.rc-backend/panes/<session_id>.json`)と突き合わせられる鍵。
  // 之が無い行は此の module の用途では使えないので落とす。短い `id` は `claude stop` 用で別物。
  const sessionId = str(row.sessionId);
  if (!sessionId) return null;
  return {
    sessionId,
    id: str(row.id),                 // 背景セッションだけが持つ短い id(`claude stop <id>` が取る)
    kind: kind === "interactive" || kind === "background" ? kind : "unknown",
    name: str(row.name),
    cwd: str(row.cwd),
    pid: num(row.pid),
    // 対話中は `status`(idle|busy)、背景は `state`。**片方に畳まない** ——
    // 2 つの語彙は別の物を指していて、混ぜると「busy な背景セッション」の様な在り得ない値が作れる。
    status: str(row.status),
    state: str(row.state),
    startedAt: str(row.startedAt),
  };
}

/**
 * `claude agents --json` の標準出力を読む。**純関数**。
 *
 * 返り値は必ず `{ ok, sessions, reason }`。
 *   ok:false / reason:"not-json"    … 出力が JSON として読めない
 *   ok:false / reason:"not-array"   … JSON だが配列でない(将来 CLI が形を変えた時)
 *   ok:true  / sessions:[]          … **本当に 0 件**。此れだけが「動いている物は無い」を意味する
 * 行単位の壊れ(鍵が足りない等)は其の行だけ落とし、`dropped` に数を残す ——
 * 1 行の欠けで一覧ごと落とすと、1 つのセッションの不調が全部の観測を消す。
 */
export function parseAgents(text) {
  if (typeof text !== "string" || text.trim() === "") {
    return { ok: false, sessions: [], dropped: 0, reason: "empty" };
  }
  let raw;
  try {
    raw = JSON.parse(text);
  } catch {
    return { ok: false, sessions: [], dropped: 0, reason: "not-json" };
  }
  if (!Array.isArray(raw)) {
    return { ok: false, sessions: [], dropped: 0, reason: "not-array" };
  }
  const sessions = [];
  let dropped = 0;
  for (const row of raw) {
    const n = normalise(row);
    if (n) sessions.push(n);
    else dropped += 1;
  }
  return { ok: true, sessions, dropped, reason: null };
}

/** 既定の呼び出し。`run` を注入しない呼び手だけが此処を通る。 */
const DEFAULT_ARGS = ["agents", "--json"];

/**
 * CLI を叩いて読む。`run(cmd, args)` は `{ status, stdout }` を返す物を注入する。
 *
 * ★終了コードが 0 でない時は**中身を読まない**。壊れた出力を寛容に読むと、
 *   「CLI が失敗した」が「0 件」に化ける道が開く —— 此の module が避けたい唯一の事。
 */
export function readAgents({ run, cmd = "claude", args = DEFAULT_ARGS } = {}) {
  if (typeof run !== "function") {
    return { ok: false, sessions: [], dropped: 0, reason: "no-runner" };
  }
  let res;
  try {
    res = run(cmd, args);
  } catch {
    return { ok: false, sessions: [], dropped: 0, reason: "spawn-failed" };
  }
  if (!res || typeof res !== "object") {
    return { ok: false, sessions: [], dropped: 0, reason: "no-result" };
  }
  if (res.status !== 0) {
    return { ok: false, sessions: [], dropped: 0, reason: "exit-" + String(res.status) };
  }
  return parseAgents(typeof res.stdout === "string" ? res.stdout : "");
}

/**
 * 机の窓台帳(`panes/<session_id>.json` の id の並び)と CLI の一覧を突き合わせる。
 *
 * ★**読めなかった時は何も言わない**(`ok:false` を素通しする)。「CLI が答えない = 台帳が古い」と
 *   読むと、CLI を入れ替えた日に全部の会話が死んだ事にされる。突き合わせは
 *   **両方が読めた時にだけ**意味を持つ。
 *
 * `onlyInRegistry` = 台帳に在るが CLI が知らない(= 終わった会話が台帳に残っている疑い)
 * `onlyInCli`      = CLI が知っているが台帳に無い(= 電話から作った物でない会話)
 */
export function crossCheck(registryIds, agents) {
  if (!agents || agents.ok !== true) {
    return { ok: false, reason: (agents && agents.reason) || "unreadable",
             onlyInRegistry: [], onlyInCli: [], both: [] };
  }
  const reg = new Set((Array.isArray(registryIds) ? registryIds : []).filter((x) => typeof x === "string" && x));
  const cli = new Set(agents.sessions.map((s) => s.sessionId));
  const both = [...reg].filter((x) => cli.has(x)).sort();
  return {
    ok: true,
    reason: null,
    both,
    onlyInRegistry: [...reg].filter((x) => !cli.has(x)).sort(),
    onlyInCli: [...cli].filter((x) => !reg.has(x)).sort(),
  };
}
