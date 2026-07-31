// RC 模倣バックエンド — HTTP 面(依存ゼロ、node:http)。
//
// 起動(edith 上):
//   RC_BIND=10.0.0.0 RC_PORT=8787 node src/server.mjs
// 認証: ~/.rc-backend/api.key の bearer(無ければ起動時に生成・0600)。
// bind 既定は 127.0.0.1(fail-closed)— tailnet 公開は RC_BIND の明示で。
//
// 設計の出典: ~/Infra/mobile-work/DESIGN.md(D3/D4)+ .harness/spec.md。
// 参照パターン: edith-claude-http.mjs の bearer / EPIPE / fail-closed 起動(コピーでなく型)。
import { createServer } from "node:http";
import { readFileSync, writeFileSync, mkdirSync, readdirSync, statSync, existsSync, chmodSync } from "node:fs";
import { randomBytes, timingSafeEqual } from "node:crypto";
import { join, basename } from "node:path";
import { homedir } from "node:os";
import { spawn as nodeSpawn, execFileSync } from "node:child_process";
import { extractSessionMeta, buildListing, extractHistory } from "./sessions.mjs";
import { WorkerManager } from "./worker.mjs";

const HOME = homedir();
const PROJECTS_DIR = process.env.RC_PROJECTS_DIR || join(HOME, ".claude", "projects");
const CLAUDE_WORK = process.env.RC_CLAUDE_WORK || join(HOME, "fleet-tools", "claude-work");
const FLEET_ACCOUNT = process.env.RC_FLEET_ACCOUNT || join(HOME, "fleet-tools", "fleet-account");
const BIND = process.env.RC_BIND || "127.0.0.1";
const PORT = Number(process.env.RC_PORT || 8787);
const KEY_DIR = process.env.RC_KEY_DIR || join(HOME, ".rc-backend");
const KEY_FILE = join(KEY_DIR, "api.key");

// ---- 認証キー(無ければ生成、0600) --------------------------------------
function loadOrCreateKey() {
  mkdirSync(KEY_DIR, { recursive: true, mode: 0o700 });
  if (!existsSync(KEY_FILE)) {
    writeFileSync(KEY_FILE, randomBytes(32).toString("hex") + "\n", { mode: 0o600 });
  }
  chmodSync(KEY_FILE, 0o600);
  return readFileSync(KEY_FILE, "utf8").trim();
}
const API_KEY = loadOrCreateKey();

function authorized(req) {
  const h = req.headers["authorization"] || "";
  const m = /^Bearer\s+(.+)$/.exec(h);
  if (!m) return false;
  const got = Buffer.from(m[1]);
  const want = Buffer.from(API_KEY);
  return got.length === want.length && timingSafeEqual(got, want);
}

// ---- セッション走査(fs 層) ----------------------------------------------
function scanSessions() {
  const entries = [];
  let slugs = [];
  try {
    slugs = readdirSync(PROJECTS_DIR);
  } catch {
    return entries; // projects dir 無し = 空一覧(落とさない)
  }
  for (const slug of slugs) {
    const dir = join(PROJECTS_DIR, slug);
    let files;
    try {
      files = readdirSync(dir).filter((f) => f.endsWith(".jsonl"));
    } catch {
      continue;
    }
    for (const f of files) {
      const p = join(dir, f);
      try {
        const st = statSync(p);
        const text = readFileSync(p, "utf8");
        entries.push({
          sessionId: basename(f, ".jsonl"),
          projectSlug: slug,
          mtimeMs: st.mtimeMs,
          meta: extractSessionMeta(text),
        });
      } catch {
        continue; // 消えた/読めないファイルで一覧全体を落とさない
      }
    }
  }
  return entries;
}

function findSessionFile(sessionId) {
  // sessionId はパスに入るので厳格に(uuid 形式のみ)— path traversal を型で殺す
  if (!/^[0-9a-f-]{8,64}$/i.test(sessionId)) return null;
  let slugs;
  try {
    slugs = readdirSync(PROJECTS_DIR);
  } catch {
    return null;
  }
  for (const slug of slugs) {
    const p = join(PROJECTS_DIR, slug, `${sessionId}.jsonl`);
    if (existsSync(p)) return p;
  }
  return null;
}

// ---- TUI 保持判定(fail-closed: 判定不能 = 保持扱い = 書かない) ----------
// 「今 tmux の対話 TUI が掴んでいるセッション」への書き込みは lost-update 未検証のため 409。
// 判定: 対話 claude プロセス(-p 無し)の cwd 集合に、セッションの cwd が含まれるか。
// lsof が失敗したら null を返し、呼び出し側は保持扱いに倒す。
function tuiHeldCwds() {
  try {
    const psOut = execFileSync("ps", ["-axo", "pid=,command="], { encoding: "utf8" });
    const pids = [];
    for (const line of psOut.split("\n")) {
      const m = /^\s*(\d+)\s+(.*)$/.exec(line);
      if (!m) continue;
      const cmd = m[2];
      // 対話 TUI: コマンド名が claude(ラッパ経由でも最終形は claude)で、-p を含まない
      if (/(^|\/)claude(\s|$)/.test(cmd) && !/\s-p(\s|$)/.test(cmd) && !cmd.includes("--input-format")) {
        pids.push(m[1]);
      }
    }
    const cwds = new Set();
    for (const pid of pids) {
      try {
        const out = execFileSync("lsof", ["-a", "-p", pid, "-d", "cwd", "-Fn"], { encoding: "utf8" });
        const n = out.split("\n").find((l) => l.startsWith("n"));
        if (n) cwds.add(n.slice(1));
      } catch {
        /* そのプロセスは読めない — 他は続ける */
      }
    }
    return cwds;
  } catch {
    return null; // 判定不能
  }
}

function isTuiHeld(sessionCwd) {
  const cwds = tuiHeldCwds();
  if (cwds === null) return true; // fail-closed
  return sessionCwd ? cwds.has(sessionCwd) : false;
}

// ---- ワーカー ---------------------------------------------------------------
const manager = new WorkerManager({
  spawn: (sessionId) =>
    nodeSpawn(CLAUDE_WORK, [
      "-p",
      "--resume", sessionId,
      "--input-format", "stream-json",
      "--output-format", "stream-json",
      "--verbose",
    ], { stdio: ["pipe", "pipe", "pipe"], cwd: HOME }),
});
setInterval(() => manager.sweep(), 30_000).unref();

// SSE 購読者: sessionId -> Set<res>
const subscribers = new Map();
function pushToSubscribers(sessionId, seq, data) {
  const subs = subscribers.get(sessionId);
  if (!subs) return;
  const frame = `id: ${seq}\ndata: ${JSON.stringify(data)}\n\n`;
  for (const res of subs) {
    try {
      res.write(frame);
    } catch {
      subs.delete(res);
    }
  }
}

// ---- HTTP -------------------------------------------------------------------
function json(res, code, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(code, { "content-type": "application/json; charset=utf-8" });
  res.end(body);
}

async function readBody(req, limit = 64 * 1024) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on("data", (c) => {
      size += c.length;
      if (size > limit) {
        reject(new Error("body too large"));
        req.destroy();
        return;
      }
      chunks.push(c);
    });
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    req.on("error", reject);
  });
}

const server = createServer(async (req, res) => {
  try {
    const url = new URL(req.url, `http://${req.headers.host || "local"}`);
    const path = url.pathname;

    if (path === "/" && req.method === "GET") {
      // 最小テストページ(認証キーは手で貼る。ページ自体は秘密を含まない)
      res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
      res.end(TEST_PAGE);
      return;
    }

    if (!path.startsWith("/api/")) return json(res, 404, { error: "not found" });
    if (!authorized(req)) return json(res, 401, { error: "unauthorized" });

    if (path === "/api/sessions" && req.method === "GET") {
      const listing = buildListing(scanSessions()).map((s) => ({
        ...s,
        live: manager.status(s.id),
      }));
      return json(res, 200, { sessions: listing });
    }

    if (path === "/api/account" && req.method === "GET") {
      try {
        const out = execFileSync(FLEET_ACCOUNT, [], { encoding: "utf8" }).trim();
        return json(res, 200, { account: out });
      } catch (e) {
        return json(res, 500, { error: `fleet-account failed: ${e.message}` });
      }
    }
    if (path === "/api/account/next" && req.method === "POST") {
      try {
        const out = execFileSync(FLEET_ACCOUNT, ["--next"], { encoding: "utf8" }).trim();
        return json(res, 200, { account: out });
      } catch (e) {
        return json(res, 500, { error: `fleet-account --next failed: ${e.message}` });
      }
    }

    const m = /^\/api\/sessions\/([^/]+)\/(history|messages|stream|interrupt|status)$/.exec(path);
    if (!m) return json(res, 404, { error: "not found" });
    const [, sessionId, action] = m;
    const file = findSessionFile(sessionId);
    if (!file) return json(res, 404, { error: "unknown session" });

    if (action === "history" && req.method === "GET") {
      const limit = Math.min(Number(url.searchParams.get("limit") || 50), 500);
      const text = readFileSync(file, "utf8");
      return json(res, 200, { history: extractHistory(text, limit) });
    }

    if (action === "status" && req.method === "GET") {
      return json(res, 200, manager.status(sessionId));
    }

    if (action === "messages" && req.method === "POST") {
      const meta = extractSessionMeta(readFileSync(file, "utf8"));
      if (isTuiHeld(meta.cwd)) {
        return json(res, 409, {
          error: "session is held by an interactive TUI — read-only from phone (lost-update untested)",
        });
      }
      let body;
      try {
        body = JSON.parse(await readBody(req));
      } catch (e) {
        return json(res, 400, { error: `bad body: ${e.message}` });
      }
      const text = typeof body.text === "string" ? body.text.trim() : "";
      if (!text) return json(res, 400, { error: "text required" });
      const seq = manager.send(sessionId, text, {
        onEvent: (s, d) => pushToSubscribers(sessionId, s, d),
      });
      return json(res, 202, { accepted: true, seq });
    }

    if (action === "interrupt" && req.method === "POST") {
      const had = manager.interrupt(sessionId);
      return json(res, 200, { interrupted: had });
    }

    if (action === "stream" && req.method === "GET") {
      res.writeHead(200, {
        "content-type": "text/event-stream",
        "cache-control": "no-cache",
        connection: "keep-alive",
      });
      const last = Number(req.headers["last-event-id"] || url.searchParams.get("since") || 0);
      const missed = manager.eventsSince(sessionId, last);
      if (missed.gap) {
        res.write(`event: gap\ndata: {"rereadHistory":true}\n\n`);
      }
      for (const e of missed) {
        res.write(`id: ${e.seq}\ndata: ${JSON.stringify(e.data)}\n\n`);
      }
      let subs = subscribers.get(sessionId);
      if (!subs) {
        subs = new Set();
        subscribers.set(sessionId, subs);
      }
      subs.add(res);
      const ping = setInterval(() => {
        try {
          res.write(`: ping\n\n`);
        } catch {
          /* close handler が拾う */
        }
      }, 25_000);
      req.on("close", () => {
        clearInterval(ping);
        subs.delete(res);
      });
      return;
    }

    return json(res, 405, { error: "method not allowed" });
  } catch (e) {
    try {
      json(res, 500, { error: String(e?.message || e) });
    } catch {
      /* already sent */
    }
  }
});

// EPIPE で落ちない(edith-claude-http の実地教訓)
process.on("uncaughtException", (e) => {
  if (e && e.code === "EPIPE") return;
  console.error("[rc-backend] fatal:", e);
  process.exit(1);
});
process.on("SIGTERM", () => {
  manager.shutdown();
  server.close(() => process.exit(0));
});

const TEST_PAGE = `<!doctype html><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>rc-backend test</title>
<style>body{font-family:sans-serif;margin:8px}#log{white-space:pre-wrap;border:1px solid #ccc;padding:8px;min-height:8em}
li{margin:4px 0}input,button{font-size:16px}</style>
<h3>rc-backend 検証ページ(素)</h3>
<p>key: <input id="key" size="24" placeholder="api.key の中身"> <button onclick="load()">一覧</button>
<span id="acct"></span></p>
<ul id="list"></ul>
<p>session: <span id="sid">-</span> <button onclick="intr()">interrupt</button></p>
<div id="log"></div>
<p><input id="msg" size="30" placeholder="メッセージ"><button onclick="send()">送信</button></p>
<script>
let SID=null, ES=null;
const H=()=>({authorization:"Bearer "+document.getElementById("key").value.trim()});
async function load(){
  const r=await fetch("/api/sessions",{headers:H()});const j=await r.json();
  const ul=document.getElementById("list");ul.innerHTML="";
  for(const s of j.sessions||[]){const li=document.createElement("li");
    li.textContent=(s.live&&s.live.worker==="running"?"● ":"○ ")+s.title+" — "+s.updatedAt+" ("+s.project+")";
    li.onclick=()=>open(s.id);ul.appendChild(li);}
  const a=await fetch("/api/account",{headers:H()});document.getElementById("acct").textContent=(await a.json()).account||"";
}
async function open(id){
  SID=id;document.getElementById("sid").textContent=id.slice(0,8);
  const r=await fetch("/api/sessions/"+id+"/history?limit=30",{headers:H()});
  const j=await r.json();const log=document.getElementById("log");
  log.textContent=(j.history||[]).map(h=>"["+h.role+"] "+h.text).join("\\n");
  if(ES)ES.close();
  ES=new EventSource("/api/sessions/"+id+"/stream?since=0&key=");
  // EventSource はヘッダを打てないので Phase I-1 検証は curl 併用。ここは表示のみ試みる。
  ES.onmessage=(e)=>{try{const d=JSON.parse(e.data);
    if(d.type==="assistant"){const t=(d.message&&d.message.content||[]).filter(b=>b.type==="text").map(b=>b.text).join("");
      if(t)log.textContent+="\\n[assistant] "+t;}
    if(d.type==="result")log.textContent+="\\n[result] "+(d.result||"");
    if(d.type==="worker_error")log.textContent+="\\n[ERROR] "+d.error;
  }catch{}};
}
async function send(){
  const t=document.getElementById("msg").value;if(!SID||!t)return;
  const r=await fetch("/api/sessions/"+SID+"/messages",{method:"POST",headers:{...H(),"content-type":"application/json"},body:JSON.stringify({text:t})});
  const j=await r.json();document.getElementById("log").textContent+="\\n[you] "+t+(j.error?"  <-- "+j.error:"");
  document.getElementById("msg").value="";
}
async function intr(){if(SID)await fetch("/api/sessions/"+SID+"/interrupt",{method:"POST",headers:H()});}
</script>`;

server.listen(PORT, BIND, () => {
  console.log(`[rc-backend] listening on http://${BIND}:${PORT} (key: ${KEY_FILE})`);
});
