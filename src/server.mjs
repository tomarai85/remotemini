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
import { TmuxInjector, looksLikeClaudePane } from "./inject.mjs";
import { PaneRegistry, resolveSessionPane, registryOnlySessions } from "./registry.mjs";

const HOME = homedir();
const PROJECTS_DIR = process.env.RC_PROJECTS_DIR || join(HOME, ".claude", "projects");
const CLAUDE_WORK = process.env.RC_CLAUDE_WORK || join(HOME, "fleet-tools", "claude-work");
const FLEET_ACCOUNT = process.env.RC_FLEET_ACCOUNT || join(HOME, "fleet-tools", "fleet-account");
const BIND = process.env.RC_BIND || "127.0.0.1";
const PORT = Number(process.env.RC_PORT || 8787);
const KEY_DIR = process.env.RC_KEY_DIR || join(HOME, ".rc-backend");
const KEY_FILE = join(KEY_DIR, "api.key");
const TMUX_BIN = process.env.RC_TMUX_BIN || "/opt/homebrew/bin/tmux";

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

// ---- 経路の振り分け(2026-07-31 に設計が変わった箇所) ---------------------
// 旧: 対話 TUI が開いているセッションは lost-update を恐れて 409 で拒否していた。
// 新: Tom 裁定「返答待ちであれ作業中であれいつでも見て干渉できればいい」(DESIGN §2.9)。
//     拒否する代わりに **そのペインへ注入** する。会話は1プロセスのままなので
//     二重実行(lost-update)は原理的に起きない — 拒否より安全で、要求も満たす。
//
// 振り分け:
//   机で開かれている(cwd に一致する tmux ペインがある) -> 注入経路(TmuxInjector)
//   開かれていない                                      -> ワーカー経路(-p --resume)
const tmuxRunner = {
  run: (args) => {
    try {
      return execFileSync(TMUX_BIN, args, { encoding: "utf8" });
    } catch {
      return ""; // tmux が無い/対象が消えた -> 空文字。呼び側は UNKNOWN 扱いになり fail-closed。
    }
  },
};
const injector = new TmuxInjector({ tmux: tmuxRunner });
const registry = new PaneRegistry({ dir: join(KEY_DIR, "panes") });

/**
 * その会話が今どのペインで開かれているか。
 *
 * 第一の根拠は**登録簿**(会話自身が statusline から名乗った session_id -> pane)。
 * cwd 一致は登録が無い会話のためのフォールバックでしかない — 同じ cwd に会話が
 * 何十件も居るのが常態なので、cwd だけでは原理的に特定できない(DESIGN §2.10)。
 *
 * 決められない時は pane=null + 理由。**理由で扱いが変わる**(ここを潰すと事故る):
 *   none         -> tmux に居ない。ワーカー経路に落として安全。
 *   not-claude   -> ペインは在るが claude ではない(素のシェル等)。注入しない。ワーカー経路。
 *   ambiguous    -> cwd 経路で複数候補。どちらの会話か決められない。
 *   stale        -> 登録簿が現実と矛盾(同じペインをより新しい会話が名乗っている)。
 *   cwd-mismatch -> 登録されたペインの居場所が会話の cwd と違う。
 * 後半3つは**ワーカーにも落とさない**。開いたままの会話を別プロセスで触ると
 * 同じ会話を2実行が読む(lost-update)ため、拒否する方が安全。
 *
 * @param {ReturnType<TmuxInjector["listPanes"]>} [panes]   一覧描画時に使い回す(tmux 起動を1回に)
 * @param {ReturnType<PaneRegistry["read"]>}      [entries] 同上(登録簿の読み直しを1回に)
 */
function livePaneFor(sessionId, sessionCwd, panes, entries) {
  return resolveSessionPane({
    sessionId,
    cwd: sessionCwd,
    entries: entries || registry.read(),
    panes: panes || injector.listPanes(),
    isClaude: looksLikeClaudePane,
    resolveByCwd: (cwd, free) => injector.resolvePane(cwd, free),
  });
}

/** 決められなかった理由のうち、ワーカー経路にも落としてはいけないもの。 */
const UNDECIDABLE = new Set(["ambiguous", "stale", "cwd-mismatch"]);

/** 拒否理由を Tom が読める1文にする(画面にそのまま出る)。 */
function blockedMessage(r) {
  if (r.reason === "ambiguous") {
    return `同じフォルダで Claude が ${r.candidates} 個開いています。どの画面かを特定できないため送信しません。`;
  }
  if (r.reason === "stale") {
    return "この会話が登録したペインは、今は別の会話が使っています。宛先を確定できないため送信しません。";
  }
  return `登録されたペインの現在地(${r.panePath || "不明"})が、この会話のフォルダと一致しません。宛先を確定できないため送信しません。`;
}
function blockedBody(r) {
  return { route: "blocked", reason: r.reason, candidates: r.candidates, source: r.source };
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
// 注入キューの掃き出し: BUSY で待たせた分を READY になり次第1件ずつ流す(連続送信しない)
setInterval(() => {
  for (const pane of injector.queues.keys()) {
    try { injector.drain(pane); } catch { /* ペイン消滅など。次周期で再評価 */ }
  }
}, 3_000).unref();

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
      // ペイン一覧と登録簿は1回だけ引いて全セッションで使い回す
      // (会話数ぶん tmux を起動したり登録簿を読み直したりしない)
      const panes = injector.listPanes();
      const entries = registry.read();
      const scanned = buildListing(scanSessions());
      // jsonl がまだ無い会話(開いただけ・未発言)も、登録簿に居てペインが生きていれば出す。
      // 見えないと電話から最初の一言を送れない = Tom 裁定「いつでも干渉できる」に反する。
      // 並びは updatedAt の新しい順で混ぜる。未発言の会話の updatedAt は登録簿の mtime
      // = 「まだ生きている」の心拍なので、開きっぱなしの間ずっと上に居座る。承知の上:
      // 未発言の会話に対して電話からできる唯一の操作が「最初の一言を送る」であり、
      // それを一覧の底に埋めると D5 裁定(いつでも干渉できる)を満たせない。
      const listing = [
        ...scanned,
        ...registryOnlySessions({ listing: scanned, entries, panes, isClaude: looksLikeClaudePane }),
      ].sort((a, b) => (a.updatedAt < b.updatedAt ? 1 : a.updatedAt > b.updatedAt ? -1 : 0)).map((s) => {
        // 机で開かれている会話は画面が真実。開かれていなければワーカーの状態。
        const r = livePaneFor(s.id, s.cwd, panes, entries);
        const live = r.pane
          ? { route: "tmux", pane: r.pane, screen: injector.state(r.pane), queued: injector.pending(r.pane).length }
          : UNDECIDABLE.has(r.reason)
            ? blockedBody(r)
            : { route: "worker", ...manager.status(s.id) };
        return { ...s, live };
      });
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
    // 登録簿は1リクエストにつき1回だけ読む。2回読むと、その間に書き手(statusLine が
    // 2秒ごとに書く)が挟まって「存在すると判定した直後の解決では別内容」になりうる。
    const regEntries = registry.read();
    // jsonl は最初の発言まで作られない(2026-07-31 edith 実測)。開いただけの会話は
    // 登録簿にしか居ないので、そこにペインがあるなら操作対象として通す。
    const registeredOnly = !file && regEntries.some((e) => e.sessionId === sessionId);
    if (!file && !registeredOnly) return json(res, 404, { error: "unknown session" });
    // cwd は jsonl 由来。無い場合は空 = 突き合わせを省く(resolveSessionPane の仕様)。
    const sessionCwd = () => (file ? extractSessionMeta(readFileSync(file, "utf8")).cwd : "");
    const resolvePane = () => livePaneFor(sessionId, sessionCwd(), undefined, regEntries);

    if (action === "history" && req.method === "GET") {
      const limit = Math.min(Number(url.searchParams.get("limit") || 50), 500);
      if (!file) return json(res, 200, { history: [] }); // まだ何も言っていない会話
      const text = readFileSync(file, "utf8");
      return json(res, 200, { history: extractHistory(text, limit) });
    }

    if (action === "status" && req.method === "GET") {
      const r = resolvePane();
      if (r.pane) {
        // 机で開かれている会話。真実は画面から取る。
        return json(res, 200, {
          route: "tmux",
          pane: r.pane,
          screen: injector.state(r.pane),
          queued: injector.pending(r.pane).length,
          source: r.source,
        });
      }
      if (UNDECIDABLE.has(r.reason)) return json(res, 200, blockedBody(r));
      return json(res, 200, { route: "worker", ...manager.status(sessionId) });
    }

    if (action === "messages" && req.method === "POST") {
      let body;
      try {
        body = JSON.parse(await readBody(req));
      } catch (e) {
        return json(res, 400, { error: `bad body: ${e.message}` });
      }
      const text = typeof body.text === "string" ? body.text.trim() : "";
      if (!text) return json(res, 400, { error: "text required" });

      const found = resolvePane();

      if (!file && !found.pane) {
        // 発言も無く、開いていたペインも無い = 掴めるものが何も無い。
        // ワーカー(-p --resume)に落とすと存在しない会話を再開しようとして失敗する。
        return json(res, 409, {
          error: "この会話はまだ発言が無く、開いていたペインも見つかりません。",
          route: "blocked", reason: "pane-gone", candidates: 0, source: "registry",
        });
      }

      if (UNDECIDABLE.has(found.reason)) {
        // 宛先を確定できない。送らないし、ワーカー経路にも落とさない
        // (開かれている会話を別プロセスで触ると同じ会話を2実行が読む = lost-update)。
        return json(res, 409, { error: blockedMessage(found), ...blockedBody(found) });
      }

      if (found.pane) {
        const pane = found.pane;
        // 注入経路。CHOICE(承認/上限の選択肢)には何も送らない — Enter が課金や承認になる。
        const r = injector.send(pane, text);
        if (r.sent) return json(res, 202, { accepted: true, route: "tmux", pane, source: found.source });
        if (r.state === "CHOICE") {
          return json(res, 409, {
            error: "画面が選択待ちです。Enter が承認や課金の選択になるため送信しません。画面を確認してください。",
            route: "tmux", pane, screen: r.state,
          });
        }
        // BUSY / UNKNOWN はキューに積んだ(UNKNOWN は積むだけで流れない = fail-closed)
        return json(res, 202, {
          accepted: true, queued: true, route: "tmux", pane, screen: r.state,
          note: "生成中のため待機列に入れました。入力可能になったら1件ずつ流します。",
        });
      }

      // 机で開かれていない会話 = ワーカー経路(-p --resume)
      const seq = manager.send(sessionId, text, {
        onEvent: (s, d) => pushToSubscribers(sessionId, s, d),
      });
      return json(res, 202, { accepted: true, route: "worker", seq });
    }

    if (action === "interrupt" && req.method === "POST") {
      const r = resolvePane();
      if (UNDECIDABLE.has(r.reason)) {
        // 止める先を確定できない = 別の会話を止めうる。何もしない。
        return json(res, 409, { error: blockedMessage(r), ...blockedBody(r) });
      }
      if (r.pane) {
        injector.interrupt(r.pane); // Escape のみ。C-c は送らない。
        return json(res, 200, { interrupted: true, route: "tmux", pane: r.pane });
      }
      const had = manager.interrupt(sessionId);
      return json(res, 200, { interrupted: had, route: "worker" });
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
    const L=s.live||{};
    // 経路と画面状態をそのまま出す(机で開いている=tmux / 開いてない=worker / 特定不能=blocked)
    const mark=L.route==="tmux"?({READY:"● ",BUSY:"◐ ",CHOICE:"⚠ ",UNKNOWN:"? "}[L.screen]||"? ")
              :L.route==="blocked"?"✖ ":(L.worker==="running"?"● ":"○ ");
    const why={ambiguous:"同cwdに"+L.candidates+"個",stale:"ペインを別会話が使用中","cwd-mismatch":"登録ペインの居場所が不一致"}[L.reason]||L.reason;
    const tail=L.route==="tmux"?" ["+L.screen+(L.queued?" +"+L.queued:"")+"]"
              :L.route==="blocked"?" [特定不能: "+why+"]":"";
    li.textContent=mark+s.title+" — "+s.updatedAt+" ("+s.project+")"+tail;
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
