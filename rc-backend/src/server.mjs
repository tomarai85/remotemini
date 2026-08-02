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
import { buildListing, isPhoneVisible, readHistoryFromPath, entriesFromRecord } from "./sessions.mjs";
import { JsonlTail, resumeDecision } from "./tail.mjs";
import { MetaCache, readMetaFromPath } from "./listing.mjs";
import { EventRing } from "./ring.mjs";
import { WorkerManager } from "./worker.mjs";
import { TmuxInjector, looksLikeClaudePane, makeTmuxRunner } from "./inject.mjs";
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
// 読んだメタは dev/ino/size/mtime を鍵に覚える。追記されれば鍵が変わるので、
// 「変わっていないファイルは二度読まない」が自動的に成り立つ(嘘のキャッシュにならない)。
const metaCache = new MetaCache({ max: 4000 });

/**
 * 一覧の材料を集める。**全部読まない**(実測 2026-08-02: 全部読むと 1,644本 /
 * 3,064 MB / 10.8 秒 / rss 1,489 MB。有界読みで 0.75 秒 / rss 107 MB = 14.4倍)。
 *
 * 絞る順序は「読む前に決める」で固定する(Codex 相談 2026-08-02):
 *   ① 名前で絞る(only)→ ② mtime で並べて上限を切る(limit)→ ③ 残った物だけ開く
 * 逆順にすると「全部読んでから捨てる」になり、絞った意味が消える。
 *
 * @param {object} [o]
 * @param {Set<string>|null} [o.only] この sessionId だけ見る(null = 全部)
 * @param {number} [o.limit] mtime の新しい順に何本まで開くか(0 = 無制限)
 * @returns {{entries:Array, unreadable:Array, files:number, read:number, cached:number}}
 */
function scanSessions({ only = null, limit = 0 } = {}) {
  const found = [];
  let slugs = [];
  try {
    slugs = readdirSync(PROJECTS_DIR);
  } catch {
    return { entries: [], unreadable: [], files: 0, read: 0, cached: 0 }; // projects dir 無し = 空一覧
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
      const sessionId = basename(f, ".jsonl");
      if (only && !only.has(sessionId)) continue; // ★開く前に落とす
      try {
        const p = join(dir, f);
        found.push({ p, slug, sessionId, st: statSync(p) });
      } catch {
        continue; // 消えたファイルで一覧全体を落とさない
      }
    }
  }
  found.sort((a, b) => b.st.mtimeMs - a.st.mtimeMs);

  // ★2026-08-02、edith の実機で踏んだ defect を直した形。
  //   旧: `found.slice(0, limit)` = **絞る前の file 数**で切ってから読み、その後で
  //       `entrypoint !== "cli"` を落としていた。edith は jsonl 642本中 636本が adapter の
  //       `sdk-cli` で、mtime 順で最初の `cli` は **113本目**。→ `limit=100` でも一覧は **0本**。
  //       MBP は最初の `cli` が1本目なので、**MBP でだけ試している限り永久に出ない**。
  //   新: mtime 順に見て、**出す物が `limit` 件たまったら止める**。= `limit` は「会話の件数」。
  //
  // ★上限を発明しない。全部読み切る最悪ケースの実測値を持っているから決められる:
  //     edith 642本 20MB → 全 meta 読みで **30 ms**(1本 0.05 ms)
  //     MBP  1,644本 3.0GB(最大の会話 280MB)→ **1,059 ms**(1本 0.64 ms)
  //   tail 読みは1本あたり最大 TAIL_MAX=1MB で頭打ちなので、file 数に比例するだけ。
  //   1秒を「一覧の最悪値」として飲む。飲めなくなったら `examined` が先に上がって見える。
  const entries = [];
  const unreadable = [];
  let read = 0;
  let cached = 0;
  let examined = 0;
  for (const { p, slug, sessionId, st } of found) {
    // 出す物が揃ったら**そこで読むのをやめる**。揃う前に file を使い切ったら全部見た事になる。
    if (limit > 0 && entries.length + unreadable.length >= limit) break;
    examined += 1;
    const key = MetaCache.keyOf(st);
    let meta = metaCache.get(key);
    if (meta === null) {
      try {
        meta = readMetaFromPath(p);
        read += 1;
        metaCache.set(key, meta);
      } catch (e) {
        if (e.code === "ENOENT") continue; // 走査中に消えた = 普通の入れ替わり、黙って良い
        // ★読めない会話を黙って消さない。消えると「一番長い会話だけが居なくなる」型に戻る。
        unreadable.push({
          id: sessionId,
          project: slug,
          cwd: null,
          title: "(読めない)",
          lastPrompt: "",
          turns: null,
          updatedAt: new Date(st.mtimeMs).toISOString(),
          readable: false,
          errorCode: e.code === "EACCES" ? "TRANSCRIPT_UNREADABLE" : String(e.code || "TRANSCRIPT_UNREADABLE"),
        });
        continue;
      }
    } else {
      cached += 1;
    }
    // ★出す物だけを数える。ここで混ぜると `limit` がまた「file の件数」に戻る
    //   (判定の正本は sessions.mjs の `isPhoneVisible`。同じ式を書かない)。
    if (!isPhoneVisible(meta)) continue;
    entries.push({ sessionId, projectSlug: slug, mtimeMs: st.mtimeMs, meta });
  }
  return { entries, unreadable, files: found.length, read, cached, examined };
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
//
// ★ここで自前に execFileSync を書かない。tmux の子には **locale を被せる必要がある**
//   (inject.mjs の PANE_FORMAT 注記。launchd 起動だと `-F` の区切りが潰れ、
//   一覧が 0 件 = 全会話がワーカー経路に落ちる)。被せる場所を1つに保つ為に
//   makeTmuxRunner を通す。
/**
 * tmux のソケットが1つでも在るか。**「接続できない」の2つの意味を分ける唯一の材料**。
 *
 * 本当に tmux が動いていない -> ペイン0 は正しい観測 -> ワーカー経路で良い。
 * 動いているのに別のソケットを見ている -> ペインは在る -> ワーカーに落とすと lost-update。
 * 置き場所は tmux と同じ規則(TMUX_TMPDIR があればその下、無ければ /tmp)。
 * 読めない(権限など)= 分けられないので null を返す -> 呼び側は投げる(fail-closed)。
 */
function tmuxSocketsPresent() {
  const base = process.env.TMUX_TMPDIR || "/tmp";
  try {
    return readdirSync(join(base, `tmux-${process.getuid()}`)).length > 0;
  } catch (e) {
    return e?.code === "ENOENT" ? false : null;
  }
}
const tmuxRunner = makeTmuxRunner({
  tmuxBin: TMUX_BIN,
  exec: execFileSync,
  socketsPresent: tmuxSocketsPresent,
});
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
    // limited は state と独立に出す(送れるのに答えが返らない、が実在する)。
    // 電話から見た時「返事が来ない」と「上限に当たっている」は取る行動が全く違うので、
    // 理由の見える化そのものが機能。2026-08-02 edith 実測が出所。
    return { screen: s.state, activity: s.activity, limited: s.limited };
  } catch {
    return { screen: "UNKNOWN", activity: "unknown", limited: false }; // ペイン消滅など。fail-closed
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
  // ★ペイン一覧が**読めなかった**時は、決められない側に倒す。空一覧として扱うと
  //   reason="none" -> ワーカー経路 = tmux で開いている会話を別プロセスで開く。
  if (!panes) {
    try {
      panes = injector.listPanes();
    } catch (e) {
      return { pane: null, reason: paneFaultReason(e), candidates: 0, detail: e.message };
    }
  }
  return resolveSessionPane({
    sessionId,
    cwd: sessionCwd,
    entries: es,
    panes,
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

/**
 * ペイン一覧が取れなかった時の理由札。**「読めた出力が壊れている」と「そもそも届かない」は別**。
 * 直し方が違う(前者=書式/locale、後者=tmux 自体かソケット)ので画面にも別の文で出す。
 */
function paneFaultReason(e) {
  return e?.code === "TMUX_UNAVAILABLE" ? "tmux-unavailable" : "panes-unreadable";
}

/** 決められなかった理由のうち、ワーカー経路にも落としてはいけないもの。 */
const UNDECIDABLE = new Set([
  "ambiguous",
  "unregistered",
  "stale",
  "cwd-mismatch",
  "panes-unreadable",
  "tmux-unavailable",
]);

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
  if (r.reason === "panes-unreadable") {
    // 電話の持ち主が取れる手が無い種類の故障なので、**故障だと分かる文**にする。
    // 「ペインが無い」風に書くと、机で開いている会話が消えたように読めて誤解を招く。
    return "サーバが tmux の画面一覧を読めていません(書式の壊れた出力が返っています)。宛先を確定できないため送信しません。復旧するまでこの会話には送れません。";
  }
  if (r.reason === "tmux-unavailable") {
    return "サーバが tmux に届いていません(画面一覧を取れませんでした)。宛先を確定できないため送信しません。復旧するまでこの会話には送れません。";
  }
  return `登録されたペインの現在地(${r.panePath || "不明"})が、この会話のフォルダと一致しません。宛先を確定できないため送信しません。`;
}
function blockedBody(r) {
  // ★文面の出所を1つに保つ。電話側に同じ日本語を書くと、直した時に片方だけ古くなる。
  // 一覧の行にも 409 の本文にも、ここで作った同じ1文が載る(e2e が同一性を検査する)。
  return { route: "blocked", reason: r.reason, candidates: r.candidates, source: r.source,
           message: blockedMessage(r) };
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

    if (req.method === "GET" && STATIC.has(path)) {
      // 認証の**外**に置くのは、鍵を貼る画面そのものだから(中身に秘密を含まない)。
      const [body, type] = STATIC.get(path);
      res.writeHead(200, { "content-type": type, "cache-control": "no-cache" });
      res.end(body);
      return;
    }

    // ★表に無いパスはここで落ちる = 総当たりの静的ファイルサーバを作らない。
    //   パスから file 名を組み立てる実装にすると `/../keys/api.key` の入口ができる。
    if (!path.startsWith("/api/")) return json(res, 404, { error: "not found" });
    if (!authorized(req)) return json(res, 401, { error: "unauthorized" });

    if (path === "/api/sessions" && req.method === "GET") {
      // ペイン一覧と登録簿は1回だけ引いて全セッションで使い回す
      // (会話数ぶん tmux を起動したり登録簿を読み直したりしない)
      // ★読めなかった時に空一覧へ倒さない。空 = 「tmux に何も無い」= 全会話をワーカー経路に
      //   落とす、が本番で実際に起きた形(2026-08-02、launchd に locale が無くタブが潰れた)。
      let panes = [];
      let paneFault = null; // { reason, detail } — 読めなかった時だけ入る
      try {
        panes = injector.listPanes();
      } catch (e) {
        paneFault = { pane: null, reason: paneFaultReason(e), candidates: 0, detail: e.message };
        console.error(`[rc-backend] ペイン一覧が取れない(${paneFault.reason}): ${e.message}`);
      }
      const entries = registry.read();
      const ctx = registryCtx(entries); // 登録の生死判定も1回だけ(tmux/ps を会話数ぶん起こさない)
      // ① scope を確定してから ② 読む対象を決める(読んでから捨てない)。
      // ★既定は `all`。当初 `registered` を既定にしかけたが、REQUIREMENTS 4-3 を読み直すと
      //   D5 の Tom 裁定は**どの機体を対象にするか**(edith / 持ち出し / Mac 直接)であって
      //   「登録した会話だけ出せ」ではない。むしろ設計は逆向きで、jsonl がまだ無い会話も
      //   登録簿から拾って**足している**(下の registryOnlySessions)。既定で絞ると
      //   その裁定と正面から衝突するので、絞りは電話側が明示した時だけ効かせる。
      const requestedScope = url.searchParams.get("scope") === "registered" ? "registered" : "all";
      const limit = Math.max(0, Math.trunc(Number(url.searchParams.get("limit")) || 0));
      const registered = new Set(entries.map((e) => e.sessionId));
      const scan = scanSessions({ only: requestedScope === "registered" ? registered : null, limit });
      const scanned = [...buildListing(scan.entries), ...scan.unreadable];
      // jsonl がまだ無い会話(開いただけ・未発言)も、登録簿に居てペインが生きていれば出す。
      // 見えないと電話から最初の一言を送れない = Tom 裁定「いつでも干渉できる」に反する。
      // 並びは updatedAt の新しい順で混ぜる。未発言の会話の updatedAt は登録簿の mtime
      // = 「まだ生きている」の心拍なので、開きっぱなしの間ずっと上に居座る。承知の上:
      // 未発言の会話に対して電話からできる唯一の操作が「最初の一言を送る」であり、
      // それを一覧の底に埋めると D5 裁定(いつでも干渉できる)を満たせない。
      const listing = [
        ...scanned,
        // ★一覧が読めていない時は**足さない**。読めない状態で「未発言の会話が居る/居ない」を
        //   名乗ると、居るのに出ない(見落とし)か、居ないのに出る(嘘)のどちらかになる。
        ...(paneFault
          ? []
          : registryOnlySessions({ listing: scanned, entries, panes, isClaude: looksLikeClaudePane, ...ctx })),
      ].sort((a, b) => (a.updatedAt < b.updatedAt ? 1 : a.updatedAt > b.updatedAt ? -1 : 0)).map((s) => {
        // 机で開かれている会話は画面が真実。開かれていなければワーカーの状態。
        const r = paneFault || livePaneFor(s.id, s.cwd, panes, entries, ctx);
        const live = r.pane
          ? { route: "tmux", pane: r.pane, ...screenOf(r.pane) }
          : UNDECIDABLE.has(r.reason)
            ? blockedBody(r)
            : { route: "worker", ...manager.status(s.id) };
        return { ...s, live };
      });
      // 何本見て何本開いたかを毎回名乗る。★「速い」を主張する側が計器を持たないと、
      // 遅くなった時に「気のせい」で片付く(この置き換え自体、測って初めて見つかった)。
      return json(res, 200, {
        sessions: listing,
        // `examined` = 実際に開いて中身を見た file 数。`files` は候補の総数。
        // ★これが要る理由: `limit` が「会話の件数」になったので、**一覧が短い理由が2つ**ある —
        //   (a) ページが埋まって止めた(`examined < files`) (b) 全部見た上でこれだけ
        //   (`examined === files` = これ以上は無い)。区別できないと「以前を読む」が
        //   押しても何も起きないボタンになる(変異 M65 と同じ形)。
        scan: { scope: requestedScope, limit, files: scan.files, read: scan.read, cached: scan.cached, examined: scan.examined },
        // ★故障を一覧の本文に載せる。行が全部 blocked になった時、原因が「机で開いていない」
        //   なのか「サーバが tmux を読めない」なのかは電話から区別できない。
        //   reason まで載せるのは、直す先が違うから(書式/locale か、tmux 自体かソケットか)。
        paneFault: paneFault ? { reason: paneFault.reason, detail: paneFault.detail } : null,
      });
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
    // ★ここは送信・割り込みの度に通る。全部読むと 280 MB のファイルで毎回それを払う一方、
    //   cwd 経路は仕様上 "ok" を返せない(registry.mjs: 同定は名乗りだけ)ので、
    //   払う対価に対して得られる物が無い。末尾から有界に採る。
    const sessionCwd = () => {
      if (!file) return "";
      try {
        return readMetaFromPath(file).cwd || "";
      } catch {
        return "";
      }
    };
    const resolvePane = () => livePaneFor(sessionId, sessionCwd(), undefined, regEntries);

    if (action === "history" && req.method === "GET") {
      const limit = Math.min(Number(url.searchParams.get("limit") || 50), 500);
      if (!file) return json(res, 200, { history: [] }); // まだ何も言っていない会話
      try {
        const h = readHistoryFromPath(file, limit);
        // truncated = これより前がある。電話側が「以前を読む」を出せる様に名乗る。
        return json(res, 200, { history: h.history, truncated: h.truncated });
      } catch (e) {
        if (e.code === "ENOENT") return json(res, 200, { history: [], truncated: false });
        return json(res, 500, { error: "TRANSCRIPT_UNREADABLE", code: String(e.code || e.message) });
      }
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
        "cache-control": "no-cache, no-transform",
        connection: "keep-alive",
        // 中継(tailscale serve / nginx 等)が挟まった時に溜め込まれない為。
        // ※ Safari 自身のバッファリング(DESIGN §8-4)には効かない。効くのは中継側だけ。混同しない。
        "x-accel-buffering": "no",
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
  // ★`server.close()` は既存接続を切らない。電話が SSE を1本張っているだけで
  //   callback は来ないので、常設(launchd)にすると再起動のたびに SIGKILL 待ちの
  //   20 秒を毎回払う。自分で降りる。`unref` にするのは、他に仕事が無ければ
  //   この timer が終了を遅らせない為(= 接続が無い時は今まで通り即座に終わる)。
  setTimeout(() => process.exit(0), 3000).unref();
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

/** 配る静的ファイルはこの表が全て。起動時に1回読んで持つ(中身は起動後変わらない)。 */
function asset(name) {
  return readFileSync(new URL(`./${name}`, import.meta.url));
}
const STATIC = new Map([
  ["/",                     [asset("app.html"),             "text/html; charset=utf-8"]],
  ["/debug",                [TEST_PAGE,                     "text/html; charset=utf-8"]],
  ["/frames.mjs",           [asset("frames.mjs"),           "text/javascript; charset=utf-8"]],
  ["/view.mjs",             [asset("view.mjs"),             "text/javascript; charset=utf-8"]],
  ["/manifest.webmanifest", [asset("manifest.webmanifest"), "application/manifest+json"]],
  ["/icon.png",             [asset("icon.png"),             "image/png"]],
]);

// ★起動に失敗した時に**読める行**を残す(2026-08-02)。
// これが無いと listen の失敗は `uncaughtException` に落ち、`fatal: Error: listen
// EADDRINUSE ...` という一行になる。常設(launchd)にすると読むのは移動中の Tom で、
// その場に手元の機械は無い。既に上がっている物が居るのか、権限で塞がれているのかを
// **ログの一行で**決着させる。exit(1) は保つ = 半端に上がるより落ちている方が安全
// (電話には「繋がらない」として出る。中途半端に応答する物が居るより判りやすい)。
server.on("error", (e) => {
  const why = e && e.code === "EADDRINUSE"
    ? `ポート ${PORT} は既に使われています。rc-backend が二重に上がっていないか確認してください`
    : e && e.code === "EACCES"
      ? `ポート ${PORT} を開く権限がありません`
      : `listen に失敗しました: ${e && e.message}`;
  // ★人が読む散文と**機械が読む code** を同じ行に両方残す(2026-08-02 に外して学んだ)。
  //   最初この行は code を散文に翻訳して捨てていた。その結果 e2e 側の環境死判定
  //   (`/EADDRINUSE|EACCES/` を探す)が**原理的に当たらない**状態になり、本物の
  //   port 衝突を起こしても関門は「環境死ではない」と答えた = 当たらない探し物は
  //   「無い」と報告される、をまた踏んだ。散文だけにすると、翻訳した瞬間に
  //   下流の機械読みが全部黙って外れる。
  console.error(`[rc-backend] 起動できません — ${why} (${(e && e.code) || "code不明"})`);
  process.exit(1);
});

server.listen(PORT, BIND, () => {
  // ★出すのは**実際に bind した番号**であって設定値ではない(2026-08-02)。
  // 差が出るのは `RC_PORT=0`(= カーネルに空きを選ばせる)の時で、検査がこの行から
  // 番号を読む。設定値をそのまま出していると `:0` と書かれた無意味なログになり、
  // 常設のログとしても「どこで待っているか」を答えられない行になる。
  const actual = server.address()?.port ?? PORT;
  console.log(`[rc-backend] listening on http://${BIND}:${actual} (key: ${KEY_FILE})`);
});
