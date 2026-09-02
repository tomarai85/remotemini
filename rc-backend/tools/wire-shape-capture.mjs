// no-operator: 本番へ GET を撃つので tailnet と鍵が要り、門からは回せない。撃つのは 2 通り ——
//   /loop の verifier(タスク live-desk-response-shapes… の検査)と、電話の Decodable か
//   机の封筒を触った人が形を取り直したい時。隣の `wire-shape.mjs` と同じ立場。
// 電話が叩く経路の**実際の応答の形**を、走っているサーバから採って、
// Swift の復号器が**必須として要求する鍵**と突き合わせる。
//
// ── なぜ此れが要るか(2026-09-01、実害から)────────────────────────────────
// 転写の探索が **出荷前から 100% 壊れていた**。机は探索の応答で項目を生のまま返し、
// 素の履歴が通る `.map(withWho)` を通していなかったので `display` が無く、電話の
// `HistoryEntry.display` は非 optional だから復号ごと落ちる。実機で探索すると必ず
// 「読めない形」になっていた。
//
// ★捕まえた者が木の中に1人も居なかった理由が此の道具の存在理由:
//   fixture も、検体 body も、e2e の期待値も、**全部 `display` を入れて手で組んである**。
//   iOS 834 件 + backend 1004 件 + e2e 297 件が全部 緑でも、
//   「机が本当に何を吐くか」は 1 件も測っていなかった。**検体は自分が知っている形しか名乗らない。**
//   欠陥は「実機へ GET を 1 回 撃った」偶然でしか見つからなかった。同じ穴が
//   残りの経路に今この瞬間 生きている可能性がある。之を偶然でなくする。
//
// ── 扉(規約 5)────────────────────────────────────────────────────────────
// **実サーバへ HTTP を撃つ扉だけを使う。** 関数を import して呼ぶ扉は使わない ——
// 今日の欠陥はハンドラの中の1行(`history: r.history`)で、関数の扉からは見えなかった。
//   live  = 本番の机(friday)。**GET のみ。**会話を作らない・送らない・状態を変えない。
//   local = 此の場で起こす本物の `src/server.mjs`(砂場の projects dir)。書込み経路は此方。
// 叩けなかった経路は **推測で埋めない**。`--check` の出力に「叩けなかった」として名前を出す。
//
// ── 側B(電話)の読み方 ─────────────────────────────────────────────────
// `wire-key-agreement.test.mjs` と同じ非対称: サーバは**実行して出た鍵**、電話は**原文を読む**。
// 但し此処が見るのは鍵名の一致ではなく **必須性** —— 復号を落とす鍵はどれか。
//   明示的な `init(from:)` が在る型: `try container.decode(` で読む鍵 = 必須。
//     `decodeIfPresent` は任意(欠けても既定値へ落ちる)。
//   無い型: 格納プロパティのうち **Optional でない**物 = 必須(合成 init の挙動)。
import { spawn } from "node:child_process";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, readdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const REPO = join(ROOT, "..");
const SWIFT = join(REPO, "ios", "Sources");
const LIVE_BASE = process.env.RC_SHAPE_LIVE_BASE || "https://desk.tailnet.example:9443";

// ── 側B: Swift の必須鍵を原文から採る ─────────────────────────────────────
function swiftFiles(dir) {
  const out = [];
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, e.name);
    if (e.isDirectory()) out.push(...swiftFiles(p));
    else if (e.name.endsWith(".swift")) out.push(p);
  }
  return out;
}
const SWIFT_SRC = swiftFiles(SWIFT).map((f) => [f, readFileSync(f, "utf8")]);

/** 宣言から中括弧の深さで本体を切り出す(`src` の中の1つ目)。 */
function blockOf(src, name) {
  const re = new RegExp(`(?:struct|final class|class|extension)\\s+${name}\\b[^{]*\\{`);
  const m = re.exec(src);
  if (!m) return null;
  let i = m.index + m[0].length, depth = 1;
  while (i < src.length && depth > 0) {
    if (src[i] === "{") depth++;
    else if (src[i] === "}") depth--;
    i++;
  }
  return src.slice(m.index, i);
}

/**
 * 型の本体を採る。**修飾名 `A.B` は A の中で B を探す。**
 *
 * ★2026-09-01 に此処で実際に嘘を出した: 最初の版は `name.split(".").pop()` で
 *   短い名前だけを見ていたので、`HealthzClient.Wire` が **`AccountClient.Wire`** の本体に
 *   当たり、口座の鍵(`accounts` / `hasToken` …)を「生存信号が吐いていない」と報告した。
 *   `wire-key-agreement.test.mjs` が 2026-08-15 に同じ穴(同名の入れ子が2つ)で
 *   「片方しか測らないのに緑」になった記録を残しており、其れの再演。
 */
function typeBody(name) {
  const parts = name.split(".");
  for (const [, src] of SWIFT_SRC) {
    let body = blockOf(src, parts[0]);
    if (!body) continue;
    let ok = true;
    for (const seg of parts.slice(1)) {
      body = blockOf(body, seg);
      if (!body) { ok = false; break; }
    }
    if (ok && body) return body;
  }
  return null;
}

/**
 * 入れ子の型宣言を丸ごと落とす。
 *
 * ★之が無いと、親の必須鍵に**子のプロパティが混ざる**。実測(同日): `HistoryEntry` が
 *   `who` を要求していると報告した —— `who` は入れ子の `EntryDisplay` の物で、
 *   `HistoryEntry` 自身の線の鍵は `role` / `text` / `display` の3つ。
 *   `DigestEnvelope` が `user`/`assistant`/`tool`(= `Counts` の中身)を要求する、も同じ形。
 */
function stripNested(body) {
  const head = body.indexOf("{");
  let out = body.slice(0, head + 1);
  const inner = body.slice(head + 1);
  let i = 0;
  const re = /(?:struct|final class|class|enum|extension)\s+\w+[^{;]*\{/g;
  let m;
  while ((m = re.exec(inner)) !== null) {
    out += inner.slice(i, m.index);
    let j = m.index + m[0].length, depth = 1;
    while (j < inner.length && depth > 0) {
      if (inner[j] === "{") depth++;
      else if (inner[j] === "}") depth--;
      j++;
    }
    i = j; re.lastIndex = j;
  }
  return out + inner.slice(i);
}

/** 註と文字列を落とす(註の中の `decode(` を鍵と読まない為)。 */
function strip(s) {
  return s.replace(/\/\*[\s\S]*?\*\//g, "").replace(/\/\/[^\n]*/g, "").replace(/"(?:[^"\\]|\\.)*"/g, '""');
}

export function requiredKeys(typeName) {
  const raw = typeBody(typeName);
  if (!raw) return null;
  const full = strip(raw);
  // `CodingKeys` は入れ子の enum なので、落とす**前**に採る。
  const ckBlock = /enum\s+CodingKeys[^{]*\{([\s\S]*?)\n\s*\}/.exec(full);
  // ★`;` を改行へ均す。`struct Wire: Decodable { let ok: Bool; let pid: Int; … }` の様な
  //   **1行宣言**を、改行を要求する下の走査が 1 件も拾えなかった(2026-09-01 実測:
  //   `HealthzClient.Wire` の必須鍵が 0 件と出た)。**必須鍵が空の型は照合が恒真になる**ので、
  //   空を「一致」と読まず疑ったのが此の欠陥を出した。
  const body = stripNested(full).replace(/;/g, "\n");
  const req = new Set();
  if (/init\s*\(\s*from\s+decoder/.test(body)) {
    for (const m of body.matchAll(/\.decode\s*\([^)]*forKey:\s*\.(\w+)/g)) req.add(m[1]);
  } else {
    // 境界に `{` も入れる。`{ let ok: Bool; …` の**最初の1個**は前に改行が無いので、
    // 改行だけを境界にすると 1 件だけ静かに落ちる(2026-09-01 実測: `ok` が消えた)。
    for (const m of body.matchAll(/(?:^|[\n{])\s*(?:let|var)\s+(\w+)\s*:\s*([^\n;=]+)/g)) {
      const t = m[2].trim();
      // ★計算プロパティを除く。`var isCheckout: Bool { machine?.kind == "checkout" }` は
      //   復号に一切参加しないのに、型の後ろに `{` が来る形を格納プロパティとして数えていた
      //   (2026-09-01 実測: `SessionRow` が `displayTitle` / `isCheckout` を必須と報告し、
      //   本番の行が吐いていないので「欠陥」に見えた。**机は正しく、計器が嘘をついていた**)。
      if (t.includes("{")) continue;
      if (!t.endsWith("?") && !/^Optional</.test(t)) req.add(m[1]);
    }
  }
  if (ckBlock) {
    for (const m of ckBlock[1].matchAll(/case\s+(\w+)\s*=\s*"([^"]+)"/g)) {
      if (req.delete(m[1])) req.add(m[2]);
    }
  }
  return [...req];
}

/** 応答から鍵の集合を採る(配列は最初の要素を代表にする)。 */
function emittedKeys(v) {
  if (v === null || typeof v !== "object") return [];
  if (Array.isArray(v)) return v.length ? emittedKeys(v[0]) : [];
  return Object.keys(v);
}
function at(v, path) {
  if (!path) return v;
  for (const seg of path.split(".")) {
    if (v === null || v === undefined) return undefined;
    v = Array.isArray(v) ? v[0] : v;
    if (v === null || v === undefined) return undefined;
    v = v[seg];
  }
  return Array.isArray(v) ? v[0] : v;
}

// ── 側A: 走っているサーバを叩く ───────────────────────────────────────────
async function hit(base, key, path, { method = "GET", body = null } = {}) {
  const headers = { authorization: `Bearer ${key}` };
  const init = { method, headers };
  if (body !== null) { headers["content-type"] = "application/json"; init.body = JSON.stringify(body); }
  const ctl = new AbortController();
  const t = setTimeout(() => ctl.abort(), 25000);
  try {
    const r = await fetch(base + path, { ...init, signal: ctl.signal });
    const text = await r.text();
    let json = null; try { json = JSON.parse(text); } catch {}
    return { status: r.status, json, text: text.slice(0, 400) };
  } catch (e) {
    return { status: 0, json: null, error: String(e).slice(0, 160) };
  } finally { clearTimeout(t); }
}

function liveKey() {
  for (let i = 0; i < 3; i++) {
    try {
      return execFileSync("ssh", ["-o", "ConnectTimeout=20", "athenas", "cat ~/.rc-backend/api.key"],
        { encoding: "utf8", timeout: 45000 }).trim();
    } catch { /* DERP relay の一過性。3 回まで。 */ }
  }
  return null;
}

// ── local: 本物の server.mjs を砂場で起こす ───────────────────────────────
function bootLocal() {
  const sb = mkdtempSync(join(tmpdir(), "rc-shape-"));
  const proj = join(sb, "projects", "-rc-shape");
  mkdirSync(proj, { recursive: true });
  mkdirSync(join(sb, "keys"), { recursive: true });
  const work = join(sb, "work"); mkdirSync(work, { recursive: true });
  const sid = "11111111-2222-3333-4444-555555555555";
  writeFileSync(join(proj, `${sid}.jsonl`), [
    JSON.stringify({ entrypoint: "cli", cwd: work, type: "user", message: { role: "user", content: "最初の質問" } }),
    JSON.stringify({ type: "assistant", message: { role: "assistant", content: [{ type: "text", text: "最初の答え" }, { type: "tool_use", name: "Bash", input: {} }] } }),
    JSON.stringify({ type: "ai-title", aiTitle: "形の捕捉" }),
  ].join("\n"));
  writeFileSync(join(sb, "trust.json"), JSON.stringify({ projects: { [work]: { hasTrustDialogAccepted: true } } }));
  const sv = spawn(process.execPath, [join(ROOT, "src", "server.mjs")], {
    env: { ...process.env, RC_PROJECTS_DIR: join(sb, "projects"), RC_KEY_DIR: join(sb, "keys"),
           RC_PHONE_TRUST_FILE: join(sb, "trust.json"), RC_PORT: "0" },
    stdio: ["ignore", "pipe", "pipe"],
  });
  let log = "";
  sv.stdout.on("data", (d) => { log += d; });
  sv.stderr.on("data", (d) => { log += d; });
  return { sv, sb, sid, port: async () => {
    for (let i = 0; i < 80; i++) {
      const m = /listening on http:\/\/[^:\s]+:(\d+)/.exec(log);
      if (m) return Number(m[1]);
      await new Promise((r) => setTimeout(r, 150));
    }
    return null;
  }, key: () => {
    const f = join(sb, "keys", "api.key");
    return existsSync(f) ? readFileSync(f, "utf8").trim() : null;
  }, log: () => log };
}

// ── 経路表。`at` = 応答のどの位置が其の Swift 型に当たるか ────────────────
const ROUTES = [
  // live で採れる物(GET のみ)
  { id: "healthz",            src: "live",  method: "GET", path: "/healthz",                          type: "HealthzClient.Wire",       at: "" },
  { id: "sessions",           src: "live",  method: "GET", path: "/api/sessions",                     type: "SessionsResponse",         at: "" },
  { id: "sessions.row",       src: "live",  method: "GET", path: "/api/sessions",                     type: "SessionRow",               at: "sessions" },
  { id: "history",            src: "live",  method: "GET", path: "/api/sessions/{sid}/history?limit=3", type: "HistoryResponse",        at: "" },
  { id: "history.entry",      src: "live",  method: "GET", path: "/api/sessions/{sid}/history?limit=3", type: "HistoryEntry",           at: "history" },
  { id: "history.search",     src: "live",  method: "GET", path: "/api/sessions/{sid}/history?limit=3&q=%E3%81%AE", type: "TranscriptSearchResponse", at: "" },
  { id: "history.search.entry", src: "live", method: "GET", path: "/api/sessions/{sid}/history?limit=3&q=%E3%81%AE", type: "HistoryEntry",          at: "history" },
  { id: "poll",               src: "live",  method: "GET", path: "/api/sessions/{sid}/poll?wait=0",   type: "PollResponse",             at: "" },
  { id: "account",            src: "live",  method: "GET", path: "/api/account",                      type: "AccountClient.Wire",       at: "" },
  { id: "digest",             src: "live",  method: "GET", path: "/api/sessions/{sid}/digest",        type: "DigestEnvelope",           at: "" },
  // local(本物のサーバを此処で起こす)。書込みは本番へ撃たない。
  { id: "local.healthz",      src: "local", method: "GET", path: "/healthz",                          type: "HealthzClient.Wire",       at: "" },
  { id: "local.sessions",     src: "local", method: "GET", path: "/api/sessions",                     type: "SessionsResponse",         at: "" },
  { id: "local.history",      src: "local", method: "GET", path: "/api/sessions/{sid}/history?limit=3", type: "HistoryResponse",        at: "" },
  { id: "local.history.entry",src: "local", method: "GET", path: "/api/sessions/{sid}/history?limit=3", type: "HistoryEntry",           at: "history" },
  { id: "local.search",       src: "local", method: "GET", path: "/api/sessions/{sid}/history?limit=3&q=%E6%9C%80%E5%88%9D", type: "TranscriptSearchResponse", at: "" },
  { id: "local.search.entry", src: "local", method: "GET", path: "/api/sessions/{sid}/history?limit=3&q=%E6%9C%80%E5%88%9D", type: "HistoryEntry", at: "history" },
  { id: "local.poll",         src: "local", method: "GET", path: "/api/sessions/{sid}/poll?wait=0",   type: "PollResponse",             at: "" },
  { id: "local.digest",       src: "local", method: "GET", path: "/api/sessions/{sid}/digest",        type: "DigestEnvelope",           at: "" },
];

export async function capture() {
  const rows = [], skipped = [];
  const lk = liveKey();
  if (!lk) skipped.push(["live", "*", "ssh で本番の鍵が採れない(3 回とも失敗)"]);

  let liveSid = null;
  if (lk) {
    const s = await hit(LIVE_BASE, lk, "/api/sessions");
    liveSid = s.json?.sessions?.[0]?.id ?? null;
    if (!liveSid) skipped.push(["live", "session", `本番に会話が 1 本も無い(status=${s.status})`]);
  }

  const L = bootLocal();
  const lport = await L.port();
  const lkey = L.key();
  if (!lport || !lkey) skipped.push(["local", "*", `ローカルのサーバが上がらない: ${L.log().slice(0, 160)}`]);

  for (const r of ROUTES) {
    let base, key, sid;
    if (r.src === "live") { base = LIVE_BASE; key = lk; sid = liveSid; }
    else { base = `http://127.0.0.1:${lport}`; key = lkey; sid = L.sid; }
    if (!key || (!sid && r.path.includes("{sid}")) || (r.src === "local" && !lport)) {
      skipped.push([r.src, r.id, "前提が揃わず叩けなかった"]);
      continue;
    }
    // ★本番へは GET しか撃たない。表に書いてあっても此処で最後に弾く。
    if (r.src === "live" && r.method !== "GET") { skipped.push([r.src, r.id, "本番は GET のみ = 撃たない"]); continue; }
    const res = await hit(base, key, r.path.replace("{sid}", sid), { method: r.method });
    if (res.status !== 200 || res.json === null) {
      skipped.push([r.src, r.id, `status=${res.status}${res.error ? " " + res.error : ""}`]);
      continue;
    }
    const node = at(res.json, r.at);
    if (node === undefined || node === null) { skipped.push([r.src, r.id, `応答に ${r.at || "直下"} が無い`]); continue; }
    const emitted = emittedKeys(node);
    const required = requiredKeys(r.type);
    if (required === null) { skipped.push([r.src, r.id, `Swift に ${r.type} が居ない`]); continue; }
    const missing = required.filter((k) => !emitted.includes(k));
    rows.push({ id: r.id, src: r.src, method: r.method, status: res.status, type: r.type,
                required, emitted, missing });
  }
  L.sv.kill("SIGTERM");
  return { rows, skipped };
}
