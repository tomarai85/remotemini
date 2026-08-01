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
import { extractSessionMeta, buildListing, extractHistory, entriesFromRecord } from "./sessions.mjs";
import { JsonlTail, resumeDecision } from "./tail.mjs";
import { EventRing } from "./ring.mjs";
import { WorkerManager } from "./worker.mjs";
import { TmuxInjector, looksLikeClaudePane } from "./inject.mjs";
import { PaneRegistry, resolveSessionPane, registryOnlySessions } from "./registry.mjs";
import { psSnapshot } from "./procs.mjs";

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
 * 今の tmux サーバの世代 "socket_path,server_pid"。
 *
 * ペイン id(%0, %1...)は**サーバごとに %0 から振り直される**ので、世代が違えば同じ
 * "%0" でも別のペインを指す。登録に書かれた世代と突き合わせるためにこれを取る。
 * 取れない(tmux が居ない)場合は空文字 = 同一性の検証は不可能 -> 登録は生きているとみなさない。
 */
function tmuxServerId() {
  const out = tmuxRunner.run(["display-message", "-p", "#{socket_path},#{pid}"]).trim();
  return /^.+,\d+$/.test(out) ? out : "";
}

/** ps を1回だけ叩く。中身の意味づけは src/procs.mjs(純関数)側。 */
function psRunner(args) {
  return execFileSync("ps", args, { encoding: "utf8" });
}

/**
 * 電話に返す画面状態。**送信可否(screen)と進行中(activity)は別項目**にする。
 * 進行中は 6.5 秒の生成中に 31% しか観測できない(DESIGN.md §2.9 M3)ので、
 * これを送信可否と同じ enum に入れると必ずまた遮断条件に流用される。
 * 「観測されなかった」は「待機中」を意味しない。
 */
function screenOf(pane) {
  try {
    const s = injector.state(pane);
    return { screen: s.state, activity: s.activity };
  } catch {
    return { screen: "UNKNOWN", activity: "unknown" }; // ペイン消滅など。fail-closed
  }
}

/** 送信を断った理由 -> 電話に出す文。injector.send() の reason と 1:1。 */
const SEND_REFUSAL = {
  choice:
    "画面が選択待ちです。Enter が承認や課金の選択になるため送信しません。画面を確認してください。",
  unknown:
    "入力欄が見つかりません(起動中・別画面・ペイン消滅のいずれか)。安全側に倒して送信しませんでした。",
  "modal-appeared":
    "本文を入れた直後に選択画面が出ました。Enter を押さずに中断しました。画面を確認してください。",
  "composer-mismatch":
    "本文が入力欄に載りませんでした。Enter は押していません。もう一度お試しください。",
};

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
function livePaneFor(sessionId, sessionCwd, panes, entries, ctx) {
  const es = entries || registry.read();
  return resolveSessionPane({
    sessionId,
    cwd: sessionCwd,
    entries: es,
    panes: panes || injector.listPanes(),
    isClaude: looksLikeClaudePane,
    resolveByCwd: (cwd, free) => injector.resolvePane(cwd, free),
    ...(ctx || registryCtx(es)),
  });
}

/**
 * 登録の生死を判定するのに要る現実側の情報。**1リクエストにつき1回**作る。
 *
 * 一覧描画は会話ごとに resolveSessionPane を呼ぶので、ここを毎回作ると tmux と ps を
 * 会話の数だけ起動することになる。登録が1件も無ければ何も叩かない。
 * tmux の世代照会は同一性を書いた登録が在る時だけ(古い書き手しか居ない機械で余計な
 * プロセスを起こさない)。ps は「近くに生きた claude が居るか」の判定にも要るので、
 * 登録が在るなら常に取る。
 */
function registryCtx(entries) {
  const now = Date.now();
  if (entries.length === 0) {
    return { now, server: "", procOf: () => null, procAvailable: false, claudeTtys: null };
  }
  const snap = psSnapshot(psRunner);
  const hasIdentity = entries.some((e) => e.server && e.pid);
  return {
    now,
    server: hasIdentity ? tmuxServerId() : "",
    procOf: snap.procOf,
    procAvailable: snap.available,
    claudeTtys: snap.claudeTtys,
  };
}

/** 決められなかった理由のうち、ワーカー経路にも落としてはいけないもの。 */
const UNDECIDABLE = new Set(["ambiguous", "unregistered", "stale", "cwd-mismatch"]);

/** 拒否理由を Tom が読める1文にする(画面にそのまま出る)。 */
function blockedMessage(r) {
  if (r.reason === "ambiguous") {
    return `同じフォルダで Claude が ${r.candidates} 個開いています。どの画面かを特定できないため送信しません。`;
  }
  if (r.reason === "unregistered") {
    // 直せる拒否なので、直し方まで書く。ここが「エラーで終わり」だと電話側で詰む。
    return "この会話はペイン登録をしていないため、宛先を確定できません(同じフォルダの画面に送ると別の会話に入る恐れがあります)。その画面を rc-claude で開き直すと送れるようになります。";
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
// 注入キューは撤去した(2026-08-01 実測)。生成中に送っても Claude Code 自身がキューして
// 次のターンとして処理することを実機で確認したので、我々のキューは二重実装だった。
// 固有の挙動は「状態判定を外した時に本文を滞留させる」ことだけで、その状態判定は
// 画面から7割外れる(DESIGN.md §2.9 M3)。契約は最善努力 + 拒否の明示 + 電話から再送。

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

function sendEvent(res, { id, event, data }) {
  let frame = "";
  if (id !== undefined) frame += `id: ${id}\n`;
  if (event) frame += `event: ${event}\n`;
  frame += `data: ${JSON.stringify(data)}\n\n`;
  try {
    res.write(frame);
    return true;
  } catch {
    return false;
  }
}

// ---- tmux 経路のライブ配信 ---------------------------------------------------
// worker 経路(-p --resume)は自分が動かすので出来事を知っているが、tmux 経路の会話は
// **本物の TUI が勝手に進む**ので、こちらから見に行かないと何も分からない。
// 実測(2026-08-02 `tools/live-http-check.mjs` 初回): tmux 経路の /stream は実イベント 0 件。
// 見に行く先は2つ、性質が違うので分けて扱う(Codex 2026-08-02 の裁定):
//   message = jsonl の追記。**再生可能**な永続イベント。取りこぼしたら困るので seq を振る。
//   screen  = 画面の状態。**最新値だけ意味がある**一時状態。履歴の再生はしない = id を振らない。
const FEED_TICK_MS = 700;
const FEED_SCREEN_EVERY = 2; // 2 tick(=1.4秒)ごとに画面を撮る。tmux を無駄に叩かない。
const FEED_WORK_WINDOW = 4; // 直近4回の観測(≒5.6秒)を1つの窓として見る
const feeds = new Map(); // sessionId -> feed
let feedEpochSeq = 0;

function getFeed(sessionId) {
  let f = feeds.get(sessionId);
  if (!f) {
    // epoch は「この配信の世代」。購読が絶えて作り直された時に seq が 1 に戻るため、
    // epoch を付けないと再接続の Last-Event-ID が偶然一致して**取りこぼしを黙って埋める**。
    f = {
      epoch: ++feedEpochSeq,
      ring: new EventRing(256),
      tail: null,
      timer: null,
      tick: 0,
      lastScreen: null,
      work: [], // 直近の「生成中を観測したか」。1枚ごとの真偽をそのまま流さない為の窓
      subs: new Set(),
    };
    feeds.set(sessionId, f);
  }
  return f;
}

function feedBroadcast(f, frame) {
  for (const res of f.subs) if (!sendEvent(res, frame)) f.subs.delete(res);
}

/** 1 tick 分の観測。例外は握って配信を止めない(見に行けない事自体は screen で伝わる)。 */
function feedTick(sessionId, f, resolvePaneFn) {
  // jsonl は**最初の発言まで存在しない**(edith 実測 2026-07-31)。購読を始めた時点で
  // 無かったからと諦めると、いちばん見たい「開いたばかりの会話」だけが無音になる
  // (2026-08-02 実測: 実機で message が1件も流れなかった原因はこれ)。
  if (!f.tail) {
    const file = findSessionFile(sessionId);
    if (file) {
      f.tail = new JsonlTail({ path: file });
      const first = f.tail.poll(); // 末尾に位置合わせ。過去分は流さない
      // ★ここで嘘をつかない: 電話は購読より前に /history を撮っている。その撮影から
      // この位置合わせまでの間に書かれた行は、差分にも履歴にも出ない = 黙って消える。
      // 継ぎ目が見えないのだから「繋がった」と言わず、一度だけ読み直させる。
      if (first.ok && f.tail.offset > 0) {
        feedBroadcast(f, { event: "gap", data: { rereadHistory: true, why: "tail-attached" } });
      }
    }
  }
  if (f.tail) {
    const r = f.tail.poll();
    if (r.reset) {
      // 差分では繋がらない(世代交代・切り詰め・印の不一致)。嘘の連続性を作らず読み直させる。
      feedBroadcast(f, { event: "gap", data: { rereadHistory: true, why: r.error || "reset" } });
    }
    for (const rec of r.records) {
      const entries = entriesFromRecord(rec.obj);
      if (entries.length === 0) continue;
      const seq = f.ring.push({ entries });
      feedBroadcast(f, { id: `${f.epoch}.${seq}`, event: "message", data: { entries } });
    }
  }
  if (++f.tick % FEED_SCREEN_EVERY === 0) {
    const r = resolvePaneFn();
    const body = r.pane ? screenBody(f, r.pane) : { route: "gone", reason: r.reason || "pane-gone" };
    const key = JSON.stringify(body);
    if (key !== f.lastScreen) {
      f.lastScreen = key;
      feedBroadcast(f, { event: "screen", data: body }); // id は振らない = 再生対象ではない
    }
  }
}

/**
 * 電話に出す画面状態。1枚ごとの `activity` を**そのまま流さない**。
 * 実測(2026-08-02): 生成中の印は1枚ごとに出たり消えたりするので、そのまま送ると
 * 1.4秒ごとに observed/unknown が交互に飛ぶ。細い回線でこれは通信も電池も無駄で、
 * しかも人が見て意味が取れない。直近の窓で1回でも観測できたかに畳む。
 * ★`quiet` は「待機中」ではない — 生成中を**観測できなかった**だけ(inject.mjs M3 と同じ規律)。
 */
function screenBody(f, pane) {
  const s = screenOf(pane);
  f.work.push(s.activity === "observed");
  if (f.work.length > FEED_WORK_WINDOW) f.work.shift();
  return {
    route: "tmux",
    pane,
    screen: s.screen,
    work: f.work.some(Boolean) ? "observed" : "quiet",
    windowMs: FEED_WORK_WINDOW * FEED_SCREEN_EVERY * FEED_TICK_MS,
  };
}

function startFeed(sessionId, file, resolvePaneFn) {
  const f = getFeed(sessionId);
  if (!f.timer) {
    f.timer = setInterval(() => {
      try {
        feedTick(sessionId, f, resolvePaneFn);
      } catch {
        /* 1 tick の失敗で配信を止めない */
      }
    }, FEED_TICK_MS);
    f.timer.unref();
  }
  return f;
}

function stopFeedIfIdle(sessionId) {
  const f = feeds.get(sessionId);
  if (!f || f.subs.size > 0) return;
  clearInterval(f.timer);
  f.timer = null;
  f.lastScreen = null;
  // ring / epoch / tail の位置は**残す**。捨てて作り直すと seq が 1 に戻り、
  // 再接続してきた電話に「追いついた」と嘘をつく経路ができる。
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
      const ctx = registryCtx(entries); // 登録の生死判定も1回だけ(tmux/ps を会話数ぶん起こさない)
      const scanned = buildListing(scanSessions());
      // jsonl がまだ無い会話(開いただけ・未発言)も、登録簿に居てペインが生きていれば出す。
      // 見えないと電話から最初の一言を送れない = Tom 裁定「いつでも干渉できる」に反する。
      // 並びは updatedAt の新しい順で混ぜる。未発言の会話の updatedAt は登録簿の mtime
      // = 「まだ生きている」の心拍なので、開きっぱなしの間ずっと上に居座る。承知の上:
      // 未発言の会話に対して電話からできる唯一の操作が「最初の一言を送る」であり、
      // それを一覧の底に埋めると D5 裁定(いつでも干渉できる)を満たせない。
      const listing = [
        ...scanned,
        ...registryOnlySessions({ listing: scanned, entries, panes, isClaude: looksLikeClaudePane, ...ctx }),
      ].sort((a, b) => (a.updatedAt < b.updatedAt ? 1 : a.updatedAt > b.updatedAt ? -1 : 0)).map((s) => {
        // 机で開かれている会話は画面が真実。開かれていなければワーカーの状態。
        const r = livePaneFor(s.id, s.cwd, panes, entries, ctx);
        const live = r.pane
          ? { route: "tmux", pane: r.pane, ...screenOf(r.pane) }
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
          ...screenOf(r.pane),
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
        // 注入経路。入力欄(composer)が実在する時だけ送る。CHOICE(承認/上限の選択肢)には
        // 何も送らない — Enter が課金や承認になる。生成中でも composer はあるので送れる
        // (Claude Code 自身が次ターンとして扱う = 自前のキューは持たない)。
        const r = await injector.send(pane, text);
        if (r.sent) {
          return json(res, 202, {
            accepted: true, route: "tmux", pane, source: found.source,
            // verified = 入力欄から本文が消えた(= TUI が取り込んだ)。
            // unverified = **確認できなかった**。中身は2通りあり、画面からは区別できない:
            //   (a) 本文が入力欄に残っている  (b) 入力欄それ自体が見えなくなった
            // ★文面で (a) だと断定しない(8/01 夜、同じ「観測していない事を断言する」型を
            //   inject.mjs の echo 相で踏んだ直後にここも直した)。
            delivered: r.delivered,
            ...(r.delivered === "unverified"
              ? {
                  note:
                    "Enter は送りましたが、本文が取り込まれた事を確認できませんでした" +
                    "(入力欄に残っているか、入力欄自体が見えなくなっています)。画面を確認してください。",
                }
              : {}),
          });
        }
        return json(res, 409, {
          error: SEND_REFUSAL[r.reason] || SEND_REFUSAL.unknown,
          route: "tmux", pane, screen: r.state, reason: r.reason,
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
      const rawLast = String(req.headers["last-event-id"] || url.searchParams.get("since") || "");
      const ping = setInterval(() => {
        try {
          res.write(`: ping\n\n`);
        } catch {
          /* close handler が拾う */
        }
      }, 25_000);

      // 経路は購読の時点で決める。机で開かれている会話(tmux)は画面と jsonl を見に行く。
      // 開かれていなければ従来通りワーカーの出来事を流す。
      const found = resolvePane();
      if (found.pane) {
        const f = startFeed(sessionId, file, resolvePane);
        f.subs.add(res);
        // 追いつき: `epoch.seq` の epoch が今の配信と同じ時だけ差分で繋ぐ。
        // 違う epoch(サーバ再起動・購読が絶えて作り直された)や、数字でない物、
        // ワーカー経路用の素の数字が来た時は、繋がった事にせず読み直させる。
        const d = resumeDecision(rawLast, f.epoch);
        if (d.kind === "gap") {
          sendEvent(res, { event: "gap", data: { rereadHistory: true, why: d.why } });
        } else if (d.kind === "resume") {
          const missed = f.ring.since(d.seq);
          if (missed.gap) sendEvent(res, { event: "gap", data: { rereadHistory: true, why: "ring-overflow" } });
          for (const e of missed) sendEvent(res, { id: `${f.epoch}.${e.seq}`, event: "message", data: e.data });
        }
        // 今の画面は経路によらず必ず1件。履歴は /history が正なのでここでは流さない。
        sendEvent(res, { event: "screen", data: screenBody(f, found.pane) });
        req.on("close", () => {
          clearInterval(ping);
          f.subs.delete(res);
          stopFeedIfIdle(sessionId);
        });
        return;
      }

      // ワーカー経路。id は素の整数。tmux 用の `epoch.seq` が来たら追いつけないので
      // 素直に gap を出す(Number("3.7") は NaN になり、黙って空を返す = 嘘の追いつき)。
      const last = /^\d+$/.test(rawLast) ? Number(rawLast) : 0;
      const missed = manager.eventsSince(sessionId, last);
      if (missed.gap || (rawLast !== "" && !/^\d+$/.test(rawLast))) {
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
    // screen=送信できるか / activity=生成が見えたか。**別物**。activity は見えた時だけ意味があり、
    // 「見えない」は待機中の意味にならない(観測率31%)ので印にも文言にもしない。
    const mark=L.route==="tmux"?(L.screen==="SENDABLE"?(L.activity==="observed"?"◐ ":"● ")
                                :L.screen==="CHOICE"?"⚠ ":"? ")
              :L.route==="blocked"?"✖ ":(L.worker==="running"?"● ":"○ ");
    const why={ambiguous:"同cwdに"+L.candidates+"個",unregistered:"ペイン未登録",stale:"ペインを別会話が使用中","cwd-mismatch":"登録ペインの居場所が不一致"}[L.reason]||L.reason;
    const label={SENDABLE:"送信可",CHOICE:"選択待ち(送信しない)",UNKNOWN:"入力欄なし(送信しない)"}[L.screen]||L.screen;
    const tail=L.route==="tmux"?" ["+label+(L.activity==="observed"?" / 生成中":"")+"]"
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
  const j=await r.json();const note=j.error||j.note||"";
  document.getElementById("log").textContent+="\\n[you] "+t+(note?"  <-- "+note:"");
  // 送れなかった時は本文を残す(打ち直させない)。
  if(!j.error)document.getElementById("msg").value="";
}
async function intr(){if(SID)await fetch("/api/sessions/"+SID+"/interrupt",{method:"POST",headers:H()});}
</script>`;

server.listen(PORT, BIND, () => {
  console.log(`[rc-backend] listening on http://${BIND}:${PORT} (key: ${KEY_FILE})`);
});
