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
import { readFileSync, writeFileSync, mkdirSync, readdirSync, statSync, existsSync, chmodSync, realpathSync } from "node:fs";
import { randomBytes, timingSafeEqual } from "node:crypto";
import { join, basename } from "node:path";
import { homedir } from "node:os";
import { spawn as nodeSpawn, execFileSync, execFile } from "node:child_process";
import { makeDiffCache } from "./gitdiff.mjs";
import { promisify } from "node:util";
import { buildListing, isPhoneVisible, readHistoryFromPath, entriesFromRecord, unreadableRow, readRawRecords, searchHistoryFromPath, permissionModeOf } from "./sessions.mjs";
import { accountBody, diffBody, gapItem, healthzBody, historyBody, historySearchBody, messageItem, pathsBody, pollBodyTmux, pollBodyWorker, sessionRow, sessionsBody, withWho, attachBody, attachFileBody, statusBodyTmux, statusBodyWorker } from "./wire.mjs";
import { completePaths, clampLimit as clampPathsLimit, PATHS_NO_CWD } from "./paths.mjs";
// 差分を読む(対照表 #4)。git を撃つのは此の module だけで、撃つ動詞は `diff` のみ。
import { readWorkingDiff } from "./sessiondiff.mjs";
import { handleDiffGet } from "./diffroute.mjs";
import { publishedBuild } from "./ota-published.mjs";
import { headerBuild } from "./reqlog.mjs";
import { parseFleetAccount, selectionMessage, selectionProblem } from "./account.mjs";
import { parseCswapUsage, usageBackoffMs, usageRefreshDue } from "./usage.mjs";
import { JsonlTail, formatPollCursor, pollDecision, resumeDecision } from "./tail.mjs";
import { MetaCache, readMetaFromPath } from "./listing.mjs";
import { EventRing } from "./ring.mjs";
import { WorkerManager } from "./worker.mjs";
import {
  TmuxInjector,
  looksLikeClaudePane,
  makeTmuxRunner,
  classifyScreen,
  choiceViewOf,
} from "./inject.mjs";
import { CHOICE_KEYS } from "./choice.mjs";
import { makeKeyedMutex } from "./mutex.mjs";
import { PaneRegistry, resolveSessionPane, registryOnlySessions } from "./registry.mjs";
// ★別名で入れる。素の `writeHead` はこのファイルで 3 回使う `res.writeHead` と紛らわしく、
//   手が滑って裸で呼んでも**静かに通る**位置に居る(HTTP 応答のつもりが枝の頭を書く)。
import { readHead as readBranchHead, writeHead as writeBranchHead, readAllHeads } from "./heads.mjs";
import { loadTitles, setTitle, normalizeTitle, loadArchived, setArchived } from "./titles.mjs";
import { DEFAULT_MIRROR_ROOT, checkoutIdForCwd, readReturnRequest, requestReturn } from "./checkouts.mjs";

// remote-mini の mirror root(§9-2)。remote-mini.sh と同じ環境変数で上書きできる。
const MIRROR_ROOT = process.env.REMOTE_MINI_MIRROR_ROOT || DEFAULT_MIRROR_ROOT;
import { psSnapshot } from "./procs.mjs";
import { paneFaultReason, UNDECIDABLE, blockedMessage, blockedBody, WORKER_REFUSAL } from "./blocked.mjs";
import { cwdVerdict } from "./trust.mjs";
// ★向きは server -> view の一方向だけ(view.mjs は node の API を一切 import しない)。
//   ここで view.mjs を呼ぶのは、ネイティブの器が `import "/view.mjs"` を**できない**為
//   (DESIGN §2.13「view.mjs は電話に配られている」)。web は今まで通り自分で import して
//   計算するので、実装は1本のまま = 判断の写しは増えない。
import {
  whoOf, gapNotice, choiceView,
  sendResult, interruptResult, choiceResult, clearQueueResult,
} from "./view.mjs";
import { redact } from "./redact.mjs";
import { attachRequestLog, markResult, noteBody, SESSION_ROUTE_RE, ROOTS_ROUTE_RE } from "./reqlog.mjs";
// roots の口(2026-09-03、対照表 #11)。台帳の読みと包含判定は roots.mjs、口の挙動は rootsroute.mjs。
import { loadRoots, resolveUnderRoots } from "./roots.mjs";
import { handleRootsList, handleRootsPaths, handleRootsNew, resolveRequestedCwd } from "./rootsroute.mjs";
import { rootsBody } from "./wire.mjs";
import { digestOf, digestLine, actionRequired, attentionOf, digestBody } from "./digest.mjs";
import { storeImage, storeFile, pathOf, sweepOld, ATTACH_MAX_BYTES } from "./attach.mjs";
import { loadRules, checkDeny, denyMessage } from "./deny.mjs";
import { createIdemStore, validKey, IDEM_REFUSAL } from "./idem.mjs";

const HOME = homedir();
const PROJECTS_DIR = process.env.RC_PROJECTS_DIR || join(HOME, ".claude", "projects");
const CLAUDE_WORK = process.env.RC_CLAUDE_WORK || join(HOME, "fleet-tools", "claude-work");
// ★電話から新しい会話を始める時に使う(2026-08-31)。既定は `ensure-phone-window.sh` と
//   **同じ値**にする —— 回復用の window と同じ入口で始めないと、登録簿(statusLine が書く)に
//   載らない会話が生まれ、電話の一覧に出ない物を作る事になる。
//   ★但し window の**名前**は分ける(あちらは「1 枚だけ在る」を冪等の鍵にしている)。
const TMUX_SESSION = process.env.RC_PHONE_SESSION || "work";
const CLAUDE_LAUNCHER = process.env.RC_PHONE_CMD || join(HOME, ".local", "bin", "rc-claude");
const FLEET_ACCOUNT = process.env.RC_FLEET_ACCOUNT || join(HOME, "fleet-tools", "fleet-account");
/**
 * 添付の置き場。★同期の木の**外**に置く(deploy の `--delete` に巻き込まれない為)。
 * `~/.rc-backend/` は鍵と登録簿が既に住んでいる場所で、配備台本が明示的に触らない。
 */
const ATTACH_DIR = process.env.RC_ATTACH_DIR || join(HOME, ".rc-backend", "attachments");

/**
 * 机が持つ拒否規則の置き場。★同期ツリーの外(配備の delete 旗に巻き込まれない)。
 * 無ければ規則ゼロ = この層が在る前と挙動が変わらない。
 */
const DENY_FILE = process.env.RC_DENY_FILE || join(HOME, ".rc-backend", "deny.json");
// 配布口の置き場(`ios/tools/adhoc-ota.sh` が `~/ota/<秘密>/` へ置く)。
// ★此処からは **manifest を読むだけ**。配る側でも消す側でもない。
const OTA_ROOT = process.env.RC_OTA_ROOT || join(HOME, "ota");

/**
 * 同じ送信を2回打たない為の記憶。★**プロセスの中だけ**に持つ。
 * file に落とさないのは、落とせば「何をいつ送ったか」の跡が机に残るから ——
 * この repo が明示的に選んでいる「打った物を残さない」線を越える。
 * 再起動で忘れるが、忘れて困るのは「再起動を跨いだ再送」だけで、
 * それは電話から見て別の送信として扱われる方が正しい。
 */
const idem = createIdemStore();
/**
 * 外部台本を諦める時刻。**電話から見える道に居ないので緩い**(2026-08-08)。
 *
 * 実測 med 8.0ms / max 11.2ms(edith)。10000ms は max の 893 倍。
 * `/api/account` と `/api/account/next` は **native app から1回も呼ばれていない** ——
 * `ios/Sources` / `ios/Tests` / `ios/UITests` で `account` に当たるのは
 * `KeychainCredentialStore` の属性名2箇所だけで、道の呼び出しは0。呼ぶのは
 * `server.mjs` 自身が埋め込んでいる HTML と `test/e2e-local.mjs` と書類。
 * 口座の切り替えは spec で v1 の対象外。
 * だから電話の 8 秒に縛られず、版管理の外に在る台本の中身が伸びる余地を取った。
 *
 * ★怖いのは「上限に当たった時に電話へ何と出すか」ではない(電話は此処を見ない)。
 * 逆で、**電話が呼ばない道の hang が、電話が頼っている道を巻き添えにする** ——
 * event loop は1本しか無い。上限が要るのはその為であって、文面の為ではない。
 */
const FLEET_ACCOUNT_TIMEOUT_MS = 10000;
const BIND = process.env.RC_BIND || "127.0.0.1";
const PORT = Number(process.env.RC_PORT || 8787);
const KEY_DIR = process.env.RC_KEY_DIR || join(HOME, ".rc-backend");
const KEY_FILE = join(KEY_DIR, "api.key");
const TMUX_BIN = process.env.RC_TMUX_BIN || "/opt/homebrew/bin/tmux";

// 配備時に `tools/deploy-to-edith.sh` が刻む版(`DEPLOYED-REV` の1行目)。
// ★**起動時に1回だけ**読む。答えたいのは「ディスクに在る版」ではなく
//   **「今動いているプロセスが読み込んだ版」**だから。配備したのに再起動を忘れた場合、
//   古いプロセスは古い版を名乗り続ける = それが正しい(嘘の新版を名乗らない)。
//   読めなければ "unknown"。黙って別の値を名乗らない。
const DEPLOYED_REV = (() => {
  try {
    return readFileSync(new URL("../DEPLOYED-REV", import.meta.url), "utf8")
      .split("\n")[0].trim() || "unknown";
  } catch {
    return "unknown";
  }
})();
const STARTED_AT = Date.now();

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
// 上限は走査ごとに `ensureCapacity()` が観測値から引き上げる。ここは冷えた初回の下限。
// ★2026-08-27 まで固定 4000 で、本番の実体 10,303 を下回っていた = ヒット率 0 が既定だった。
const metaCache = new MetaCache({ max: 4000 });
// キャッシュが連続で効かなかった回数。吠える条件は `scanSessions` の末尾。
let coldScans = 0;

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
function scanSessions({ only = null, limit = 0, heads = null } = {}) {
  // ★§2.18-4b-i 罠1: `only` は**広げてから**使う。登録簿が持っているのは祖先の id だけ
  //   (電話の取っ手が祖先だから)で、枝の id は入っていない。素直に走ると下の `scope.has()`
  //   が枝の file を**開く前に**落とすので、祖先の行は古い `st` のままになり、当てが
  //   `scope=registered` の時だけ静かに死ぬ。手順「地図 → only を広げる → 走査 → 畳む →
  //   sort」はどれ1つ前後させても直らない。
  let scope = only;
  if (only && heads) {
    scope = new Set(only);
    for (const a of only) {
      const h = heads.get(a);
      if (h) scope.add(h);
    }
  }
  let found = [];
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
      if (scope && !scope.has(sessionId)) continue; // ★開く前に落とす
      try {
        const p = join(dir, f);
        const st = statSync(p);
        // `sortMs` = 並びと `updatedAt` に使う時刻。既定は自分の mtime で、fork した
        // 会話だけ下で**枝の mtime**に差し替わる。`st` 自体は触らない(罠2)。
        found.push({ p, slug, sessionId, st, sortMs: st.mtimeMs, head: null });
      } catch {
        continue; // 消えたファイルで一覧全体を落とさない
      }
    }
  }
  // ★§2.18-4b: fork した会話の続きは枝の file に書かれる。ここで `祖先 -> 頭` に畳む。
  //   ★`sort` の**前**でなければ、上限に当たって行が消える型((b))は直らない(変異 P10)。
  if (heads && heads.size) {
    const byId = new Map(found.map((e) => [e.sessionId, e]));
    const headIds = new Set();
    for (const e of found) {
      const h = heads.get(e.sessionId);
      if (!h || h === e.sessionId) continue;
      const he = byId.get(h);
      // 枝の file が無い / 走査の外 → **祖先の値のまま出す**。行は消さない(変異 P12)。
      // `heads.mjs` の「読めない = 頭が無い」と同じ倒れ方に揃える。
      if (!he) continue;
      headIds.add(h);
      // ★`st` と `p` は**組のまま**持つ。`MetaCache.keyOf(st)` は inode 由来で path を
      //   含まない(`listing.mjs` の `keyOf`)ので、片方だけ差し替えると祖先の中身が枝の鍵で
      //   仕舞われる(罠2 / 変異 P15)。畳むのは「どこを見るか」であって行の身元ではない。
      e.head = { p: he.p, st: he.st, slug: he.slug };
      e.sortMs = he.st.mtimeMs; // 並びも updatedAt も枝の側の現在
    }
    // ★頭そのものの行は落とす。枝が別の会話として湧かない(変異 P11)。
    //   `entrypoint` の篩に頼らない —— 篩を触った人にこの正しさは見えない。
    if (headIds.size) found = found.filter((e) => !headIds.has(e.sessionId));
  }
  found.sort((a, b) => b.sortMs - a.sortMs);

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
  // ★上限の引き上げは**読む前**。読み終えてから上げても、その回は既に全部捨てた後で
  //   効かない(Codex 2026-08-27)。件数はこの時点で確定している(`found` は sort 済み)。
  metaCache.beginScan();
  metaCache.ensureCapacity(found.length);
  const entries = [];
  const unreadable = [];
  let read = 0;
  let cached = 0;
  let examined = 0;
  let complete = true; // 途中で読むのを止めたら偽 = 掃除してはいけない
  for (const { p, slug, sessionId, st, sortMs, head } of found) {
    // 出す物が揃ったら**そこで読むのをやめる**。揃う前に file を使い切ったら全部見た事になる。
    if (limit > 0 && entries.length + unreadable.length >= limit) { complete = false; break; }
    examined += 1;
    let meta = metaCache.get(st);
    if (meta === null) {
      try {
        meta = readMetaFromPath(p);
        read += 1;
        metaCache.set(st, meta);
      } catch (e) {
        if (e.code === "ENOENT") continue; // 走査中に消えた = 普通の入れ替わり、黙って良い
        // ★読めない会話を黙って消さない(行の形は sessions.mjs の `unreadableRow`)。
        unreadable.push(unreadableRow({
          id: sessionId,
          project: slug,
          updatedAt: new Date(sortMs).toISOString(),
          errorCode: e.code === "EACCES" ? "TRANSCRIPT_UNREADABLE" : String(e.code || "TRANSCRIPT_UNREADABLE"),
        }));
        continue;
      }
    } else {
      cached += 1;
    }
    // ★出す物だけを数える。ここで混ぜると `limit` がまた「file の件数」に戻る
    //   (判定の正本は sessions.mjs の `isPhoneVisible`。同じ式を書かない)。
    if (!isPhoneVisible(meta)) continue;
    // ★枝から採るのは**枝の側で増える物だけ**(`lastPrompt` / `turns`)。
    //   `cwd` / `project` は**祖先のまま**にする。丸ごと頭から採ると行の所属が化ける
    //   (§3-V より前に開いた枝は `cwd: ~` のまま残っている。変異 P12b)。
    //   見える / 見えないの判定も**祖先**で決める。枝は `-p` 起動なので必ず `sdk-cli` で、
    //   枝で判定すると畳んだ会話が全部消える。
    if (head) {
      let hm = metaCache.get(head.st);
      if (hm === null) {
        try {
          hm = readMetaFromPath(head.p);
          read += 1;
          metaCache.set(head.st, hm);
        } catch {
          hm = null; // 枝が読めない = 祖先の値のまま出す。行は消さない
        }
      } else {
        cached += 1;
      }
      if (hm) meta = { ...meta, lastPrompt: hm.lastPrompt, turns: hm.turns };
    }
    entries.push({ sessionId, projectSlug: slug, mtimeMs: sortMs, meta });
  }
  const swept = metaCache.sweep({ complete });
  // ★計器は「効いていない」を**自分から言う**。旧形は `cached` を応答に載せていたのに、
  //   0 が数週間続いても誰も読まなかった(2026-08-27 に初めて読んで発覚)。在るだけの
  //   計器は読まれない。冷えた初回は当然 0 なので黙り、**連続で効かない時だけ**吠える。
  if (examined > 0) {
    const hitRate = examined === 0 ? 1 : cached / examined;
    if (hitRate < 0.05 && examined >= 200) {
      coldScans += 1;
      if (coldScans >= 2 && coldScans % 10 === 2) {
        console.error(`[rc-backend] 一覧のキャッシュが効いていません(${coldScans}回連続): `
          + `examined=${examined} cached=${cached} read=${read} 上限=${metaCache.max} `
          + `占有=${metaCache.size} 追出し=${metaCache.evictions}`);
      }
    } else {
      coldScans = 0;
    }
  }
  return { entries, unreadable, files: found.length, read, cached, examined, swept,
           cacheMax: metaCache.max, cacheSize: metaCache.size, cacheCapped: metaCache.capped };
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
// ★下の2つは**対照専用の栓**。本番では立てない(既定 = 実測由来の値のまま)。
//   測りたい状態は「送信の鍵が満杯」で、それを外から作るには
//   **容量+1 本の要求が、鍵を持っている1本が降りるより前に届く**必要がある。
//   この2つは、その不等式の左右をそれぞれ動かす:
//     `RC_E2E_ECHO_BUDGET_MS` = 右辺(満杯が続く時間)を伸ばす。既定は inject.mjs の 1500ms。
//     `RC_E2E_MAX_WAITERS`    = 左辺(必要な本数)を減らす。既定は mutex.mjs の 4。
//   経緯(2026-08-02 実測): 予算だけ広げた版は静かな机では緑になったが、12並列では
//   **12回中12回**「満杯を作れない」で赤。要求6本の到着ばらつきが 6s の窓を超えていた
//   (`execFileSync` で event loop ごと止まるので、負荷が乗るほど到着が散る)。予算を
//   さらに伸ばすと今度は 10-e2(耳の無いペインへの送信)が予算ぶん待たされて遅くなる。
//   だから**本数の方を減らす**。満杯の時の振る舞いに容量の数値は関係しないので、
//   これで測る性質は変わらない。
const ECHO_BUDGET_PLUG = Number(process.env.RC_E2E_ECHO_BUDGET_MS || 0);
const MAX_WAITERS_PLUG = Number(process.env.RC_E2E_MAX_WAITERS || 0);
// ★3本目の栓(2026-08-03)。用途は上の2本と違って**速さだけ**で、測る性質は変えない。
//   割り込みの「まだ止まっていない」を e2e で撃つには、印が消えないペインに対して
//   `interruptBudgetMs`(既定 3000ms)を丸ごと待たされる。偽 tmux の画面は同期で
//   書き換わるので、止まった側は予算に関係なく即座に確定する。つまりこの値を縮めても
//   **緑になる条件は一切緩まない**(縮めて壊れるのは「止まった」の側だけで、そちらは
//   1枚目の capture で確定する)。本番では立てない = 既定の 3000ms のまま。
const INTERRUPT_BUDGET_PLUG = Number(process.env.RC_E2E_INTERRUPT_BUDGET_MS || 0);
const injector = new TmuxInjector({
  tmux: tmuxRunner,
  ...(ECHO_BUDGET_PLUG > 0 ? { echoBudgetMs: ECHO_BUDGET_PLUG } : {}),
  ...(INTERRUPT_BUDGET_PLUG > 0 ? { interruptBudgetMs: INTERRUPT_BUDGET_PLUG } : {}),
  ...(MAX_WAITERS_PLUG > 0 ? { mutex: makeKeyedMutex({ defaultMaxWaiters: MAX_WAITERS_PLUG }) } : {}),
});
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

/**
 * `ps` を諦める時刻。**tmux と同じ数字にしていない**(2026-08-08、edith 実測)。
 *
 * 634 プロセス / 89,265 バイトで med 18.4ms / max 21.8ms。5000ms は max の 272 倍。
 * tmux と分けた理由 = `ps` の所要は**プロセス数と command line の長さで伸びる** =
 * 機械の混み具合に連動する。tmux の照会(server に1問投げるだけ)とは伸び方が違うので、
 * 同じ数字を共有すると片方が窮屈になる。一覧経路が `ps` を叩くのは1回だけなので、
 * `ps` だけが固まっても 5 秒 < 電話の読み取り上限 8 秒。
 *
 * ★tmux と `ps` が**同時に**固まると 4+5=9 秒で 8 秒を超える。承知の上で通す ——
 * 独立した2つが同時に固まるのは機械全体の障害で、呼び出しごとの上限で直せる層ではない。
 */
const PS_TIMEOUT_MS = 5000;

/** ps を1回だけ叩く。中身の意味づけは src/procs.mjs(純関数)側。 */
function psRunner(args) {
  // 時間切れも maxBuffer 超過も `psSnapshot` が捕まえて `available: false` = **判らない**に
  // 落とす(既にそう書いてある)。だから此処に枝は要らない。要るのは諦める時刻だけ。
  return execFileSync("ps", args, { encoding: "utf8", timeout: PS_TIMEOUT_MS, killSignal: "SIGKILL" });
}

/**
 * 電話に返す画面状態。**送信可否(screen)と進行中(activity)は別項目**にする。
 * 進行中は1枚あたり **18-39%** 取りこぼす(DESIGN.md §2.9-X-2 の測り直し)ので、
 * これを送信可否と同じ enum に入れると必ずまた遮断条件に流用される。
 * 「観測されなかった」は「待機中」を意味しない。
 */
function screenOf(pane) {
  try {
    // 画面は**1回だけ**撮る。状態と選択肢で撮り直すと、その2枚の間に画面が変わり得る
    // = 電話には「この選択肢」と出しておきながら指紋は別の画面の物、という食い違いが作れる。
    const text = injector.capture(pane);
    const s = classifyScreen(text);
    // limited は state と独立に出す(送れるのに答えが返らない、が実在する)。
    // 電話から見た時「返事が来ない」と「上限に当たっている」は取る行動が全く違うので、
    // 理由の見える化そのものが機能。2026-08-02 edith 実測が出所。
    const base = { screen: s.state, activity: s.activity, limited: s.limited };
    // 選択待ちの時だけ、メニューの中身と指紋を添える。電話はこの指紋を打鍵に添えて返すので、
    // **見た物と押す物が同じ**事がこの1本で担保される(`POST …/choice` の digest)。
    return s.state === "CHOICE" ? { ...base, choice: choiceViewOf(pane, text) } : base;
  } catch {
    return { screen: "UNKNOWN", activity: "unknown", limited: false }; // ペイン消滅など。fail-closed
  }
}

/** 送信を断った理由 -> 電話に出す文。injector.send() の reason と 1:1。 */
const SEND_REFUSAL = {
  choice:
    "The screen is waiting on a choice. Enter could approve or spend, so nothing was sent. Check the screen.",
  unknown:
    "No composer field found (starting up, a different screen, or the pane is gone). Failed safe — nothing was sent.",
  "modal-appeared":
    "A choice screen appeared right after the text was typed. Enter was not pressed. Check the screen.",
  "composer-mismatch":
    "The text did not land in the composer. Enter was not pressed. Try again.",
  // ★鍵が取れなかった時(DESIGN §2.18-1)。どちらも**打鍵を1文字もしていない**。
  //   「混ざった物を送る」より「送らずに断る」が安全側、という決め事の表側。
  "pane-busy":
    "This pane is handling another send and the queue is full. **Nothing was sent.** Wait a moment and try again.",
  "pane-wait-timeout":
    "Timed out while waiting in the queue. **Nothing was sent.** Try again.",
};

/**
 * 選択メニューへの打鍵を断った理由 -> 電話に出す文。injector.choice() の reason と 1:1。
 *
 * ★`choice-hard-stop` と `choice-unrecognized` は**文面が違うだけで守りは同じ**(打たない)。
 *   分けているのは Tom が外出先で取る行動が違うから: 前者は「机まで戻るか、後回しにする」、
 *   後者は「見た事の無い画面が出ている」= 撮って持ち帰る対象。
 *   ★守りが前者の網の完全性に依存しない事が要点(`choice.mjs` 冒頭)。網に穴が在れば
 *   その画面は後者に落ちる = やはり打たない。
 */
const CHOICE_REFUSAL = {
  "not-choice": "This screen is not waiting on a choice. No key was pressed.",
  "choice-hard-stop":
    "This is a permission/trust confirmation. **The phone never answers it** (a standing rule: automation does not press safety prompts). Handle it on the desk.",
  "choice-unrecognized":
    "Unrecognized choice screen. Keys are only sent to screens verified safe, so nothing was sent. Check the screen.",
  "choice-key-not-allowed": "That key is not accepted on this screen. Nothing was sent.",
  "choice-no-such-option": "There is no option with that number on this screen. Nothing was sent.",
  "choice-already-sent":
    "A key was already sent to this choice screen. The screen not moving does **not** mean it was undelivered. Re-sending could hit the next screen, so nothing was sent. Re-read the screen.",
  "digest-mismatch":
    "The choice screen you saw differs from the current one (it changed or went away). **Nothing was sent.** Re-read the screen.",
  "pane-busy":
    "This pane is handling another operation and the queue is full. **Nothing was sent.** Wait a moment and try again.",
  "pane-wait-timeout":
    "Timed out while waiting in the queue. **Nothing was sent.** Try again.",
  unknown: "Could not send the key to the choice screen. Nothing was sent.",
};

/**
 * 打鍵した**後**に電話へ出す但し書き。
 *
 * ★`unverified` を「失敗したから撃ち直せ」と読ませない事が要点(2026-08-03、Codex 指摘)。
 *   画面が動かないのは「届いていない」ではなく「まだ描き直されていない」でもあり得る。
 *   撃ち直すと1発目が入力待ちに溜まったまま2発目が**次の画面**へ流れる。次が許可確認なら、
 *   裁定が名指しで禁じた事が起きる。だから文言は「結果不明・撃ち直さない」で固定する
 *   (注入器の側でも同じ指紋への二度打ちは `choice-already-sent` で断る = 二重の守り)。
 */
const NOTE_AFTER_CHOICE = {
  unverified:
    "The key was sent. A screen change was not confirmed (**that does not mean it was undelivered**). Do not re-send to the same screen. Until it actually changes, this menu will refuse keys (that refusal is intended). Re-read the screen to see whether it moved.",
  "moved-to-hard-stop":
    "★After the key, the screen changed to a **permission/trust confirmation**. The phone never answers it. Handle it on the desk.",
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
 * @param {ReturnType<PaneRegistry["read"]>}      [entries] 同上(登録簿の読み直しを1回に)。
 *   ★**1リクエストの中でだけ**渡してよい。寿命の長い物(配信の timer)に渡すと、
 *   `registryCtx` は `now` を毎回取り直すのに mtime は凍ったままになり、経過時間だけで
 *   全部が心拍切れ(= unregistered)に見える。渡さなければ毎回読み直す。
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
 * jsonl 由来の cwd。無い / 読めない = 空 = 突き合わせを省く(resolveSessionPane の仕様)。
 * ★全部読むと 280 MB のファイルで毎回それを払う一方、cwd 経路は仕様上 "ok" を返せない
 *   (registry.mjs: 同定は名乗りだけ)ので、払う対価に対して得られる物が無い。末尾から有界に採る。
 */
function cwdOfSessionFile(file) {
  if (!file) return "";
  try {
    return readMetaFromPath(file).cwd || "";
  } catch {
    return "";
  }
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

// `paneFaultReason` / `UNDECIDABLE` / `blockedMessage` / `blockedBody` は `blocked.mjs` へ出した。
// ★このファイルは import した瞬間に listen する(末尾)= **単体検査から呼べない**。文面の判断を
//   ここに置いていた間、覆い漏れ(`none` / `not-claude` が cwd 不一致の文に化ける)は e2e で
//   実行するまで誰も掴めなかった。判断は listen しない層に置き、domain を検査で押さえる。

// ---- ワーカー ---------------------------------------------------------------
// ★転写の枝の頭を置く場所。`panes/` を使い回さない(`heads.mjs` が明示的に禁じている:
//   別の物を同じ dir に混ぜると、片方の掃除がもう片方を巻き込む)。
const HEADS_DIR = join(KEY_DIR, "heads");
mkdirSync(HEADS_DIR, { recursive: true, mode: 0o700 });

/**
 * `祖先 -> 頭` の地図。fork した会話は続きが**枝の file** に書かれるので、一覧はこの地図で
 * 「今の様子はどの file に在るか」を決める(§2.18-4b)。頭が自分自身の物は載せない
 * (畳む必要が無い = 下流で「頭の行を落とす」に巻き込まれない)。
 * 読めない頭は `readAllHeads` が黙って落とす = 地図に載らない = 祖先のまま出る。
 */
function headMap() {
  const m = new Map();
  for (const { ancestor, head } of readAllHeads(HEADS_DIR)) {
    if (head && head !== ancestor) m.set(ancestor, head);
  }
  return m;
}

const manager = new WorkerManager({
  // H2(DESIGN §2.18-4〜6, §2.18-10): 既定の `--resume` は**元の ID を再利用する**ので、
  // 机の TUI が同じ会話を開いていると同じ転写 JSONL へ2人が書く。初回は fork して
  // 自分の枝を持ち、その枝の先端をここに記録して2通目以降はそこへ resume する。
  heads: {
    read: (ancestor) => readBranchHead(HEADS_DIR, ancestor),
    write: (ancestor, head) => writeBranchHead(HEADS_DIR, ancestor, head),
  },
  spawn: (sessionId, plan) => {
    // ★検査(route 側)と spawn の間で dir が消える競合。ここで**同期に**確かめて投げると
    //   `manager.send()` が同期で失敗し、電話には 202 でなく 409 が返る。非同期の
    //   `proc.on("error")` に任せると「受け付けた」と答えた**後**に死ぬ(= 変異 W22)。
    realpathSync(plan.cwd);
    // ★`|| HOME` を**書かない**(= 変異 W20)。書くと「会話の居場所で開く」という当てが
    //   無音で消え、$HOME で開いた子が別の場所を作業場所だと思い込む。
    //   cwd を持たない会話は route 側が 409 `cwd_unknown` で既に断っている。
    return nodeSpawn(CLAUDE_WORK, [
      "-p",
      ...(plan.fork ? ["--fork-session"] : []),
      "--resume", plan.resumeId,
      "--input-format", "stream-json",
      "--output-format", "stream-json",
      "--verbose",
    ], { stdio: ["pipe", "pipe", "pipe"], cwd: plan.cwd });
  },
});
setInterval(() => manager.sweep(), 30_000).unref();
// 注入キューは撤去した(2026-08-01 実測)。生成中に送っても Claude Code 自身がキューして
// 次のターンとして処理することを実機で確認したので、我々のキューは二重実装だった。
// 固有の挙動は「状態判定を外した時に本文を滞留させる」ことだけ。★撤去を支えている脚は
// 検出率ではなく **M5**(TUI 自身がキューし、画面にそう出す)= DESIGN.md §2.9-X-8。
// 滞留先が2つになる事は「今どの本文が待っているか」に答える者が2人になる事(H2)。
// 契約は最善努力 + 拒否の明示 + 電話から再送。

// SSE 購読者: sessionId -> Set<res>
const subscribers = new Map();
// ワーカー経路で保留中の poll。tmux 経路の `f.wakers` と同じ役目だが、あちらは feed という
// 器があるのに対しこちらは無いので、購読者と同じ形の Map で持つ。
const workerWakers = new Map(); // sessionId -> Set<fn>
/**
 * 空になった器を Map から外す。`f.wakers` と違い此処は **feed という寿命の器を持たない**ので、
 * 消さないと会話ID1つにつき空の Set が1つ永久に残る(電話が触った会話の数だけ増える)。
 *
 * ★同一性で守る: `workerWakers.get(...) === set` を確かめてから消す。確かめずに消すと、
 *   後から来た poll が作った**新しい器**を巻き添えに外し、その待ち手が二度と起きない。
 */
function pruneWorkerWakers(sessionId, set) {
  if (set.size === 0 && workerWakers.get(sessionId) === set) workerWakers.delete(sessionId);
}
function wakeWorkerPolls(sessionId) {
  const set = workerWakers.get(sessionId);
  if (!set || set.size === 0) return;
  const woken = [...set];
  set.clear();
  pruneWorkerWakers(sessionId, set);
  for (const w of woken) {
    try {
      w();
    } catch {
      /* 1本の失敗で他を起こさない */
    }
  }
}
function pushToSubscribers(sessionId, seq, data) {
  wakeWorkerPolls(sessionId);
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

/**
 * SSE の本文に語を足す口。**此処が唯一の口**。
 *
 * ★`json()` の `speaks`/`DISPLAY` と同じ理由でここに置く: `sendEvent` の呼び口は今6箇所
 *   あり(gap 4 / message 1 / screen 1)、呼び口ごとに語を配ると**次に足された枝だけが
 *   黙って欄無しで通る**。`reqlog.mjs` の `noteBody` が同じ轍で学んだ形。
 * ★`data` を書き換えない。message の `data` は ring に入っている**その物**なので、
 *   その場で足すと保持中の過去イベントに後から語が生えて、再生が撮った時と変わる。
 */
const SSE_SPEAKS = {
  gap: (d) => ({ ...d, display: { notice: gapNotice(d.why) } }),
  message: (d) => (Array.isArray(d.entries) ? { ...d, entries: d.entries.map(withWho) } : d),
  // screen の `data` は画面の本体そのもの。poll 側が `choiceView(f.screen.body)` に渡す物と
  // 同じ材料を、同じ関数に渡している。SSE では**変わった時しか流れない**ので、poll のような
  // 「変わっていない = null」の作法は要らない —— イベントが来た事自体が変化の合図。
  screen: (d) => ({ ...d, display: { choice: choiceView(d) } }),
};

function sendEvent(res, { id, event, data }) {
  const speak = SSE_SPEAKS[event];
  if (speak && data && typeof data === "object" && !Array.isArray(data) && !("display" in data)) {
    data = speak(data);
  }
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
const POLL_MAX_WAIT_MS = 20_000; // トンネルで切断通知が遅れても待ち手を残さない上限
const POLL_MAX_ITEMS = 64; // 1応答の頭打ち。ring 256 件を丸ごと返すと電話が潰れる
const POLL_MAX_HELD = 4; // 同一会話で保留できる poll の本数
const POLL_LEASE_MS = 30_000; // 最後の poll からこれだけは feed を止めない

/**
 * 世代の印。**連番にしない**。
 * 連番だと process が再起動した時に最初の feed がまた同じ値を取り、再起動前の栞
 * (`1.50`)が偶然一致して `ring.since(50)` が空 = 「追いついた」と黙って嘘をつく。
 * ★これは poll を足して見つけた欠陥ではなく、**SSE 側に前から在った**もの
 *   (`feedEpochSeq` は 0 起点の連番だった)。同じ穴を2本目に掘らない為に先に塞ぐ。
 */
function newEpochToken() {
  return randomBytes(4).toString("hex"); // `.` を含まない = 栞の区切りと衝突しない
}

function getFeed(sessionId) {
  let f = feeds.get(sessionId);
  if (!f) {
    f = {
      epoch: newEpochToken(),
      ring: new EventRing(256),
      tail: null,
      timer: null,
      tick: 0,
      lastScreen: null,
      // 画面は**順序を持たない最新値**なので ring に入れず1セルに置く。混ぜると 256 件の
      // 保持枠を画面の写しが食い、本文が溢れて gap が増える = 最大 280MB の jsonl 読み直しが増える。
      screen: null, // { rev, body }
      screenRev: 0,
      work: [], // 直近の「生成中を観測したか」。1枚ごとの真偽をそのまま流さない為の窓
      subs: new Set(),
      wakers: new Set(), // 保留中の poll。中身は「今すぐ返せ」の関数
      pollLeaseUntil: 0,
      leaseTimer: null, // feed あたり**1本**。poll ごとに積むと未発火の timer が溜まる
    };
    feeds.set(sessionId, f);
  }
  return f;
}

function feedBroadcast(f, frame) {
  for (const res of f.subs) if (!sendEvent(res, frame)) f.subs.delete(res);
  // ★保留中の poll を起こすのは**此処だけ**。message / gap / screen は全部この口を通るので、
  //   起こし忘れの枝が生まれない(呼び口ごとに書けば、次に足した枝だけが静かに眠る)。
  if (f.wakers.size) {
    const woken = [...f.wakers];
    f.wakers.clear();
    for (const w of woken) {
      try {
        w();
      } catch {
        /* 1本の失敗で他を起こさないのは本末転倒 */
      }
    }
  }
}

/**
 * 取りこぼしの合図。**ring に seq を振って**流す。
 *
 * ★以前は id 無しで流していた。SSE の再接続でも poll でも**再生できない** = 購読が
 *   切れている間に起きた gap は消えていた。「読み直せ」の合図が消えるという事は、
 *   電話が古い履歴を正しいと思い込んだまま静かに走り続けるという事。
 */
function feedGap(f, why) {
  const seq = f.ring.push({ kind: "gap", why });
  feedBroadcast(f, { id: `${f.epoch}.${seq}`, event: "gap", data: { rereadHistory: true, why } });
}

/** 1 tick 分の観測。例外は握って配信を止めない(見に行けない事自体は screen で伝わる)。 */
function feedTick(sessionId, f, file) {
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
        feedGap(f, "tail-attached");
      }
    }
  }
  if (f.tail) {
    const r = f.tail.poll();
    if (r.reset) {
      // 差分では繋がらない(世代交代・切り詰め・印の不一致)。嘘の連続性を作らず読み直させる。
      feedGap(f, r.error || "reset");
    }
    for (const rec of r.records) {
      const entries = entriesFromRecord(rec.obj);
      if (entries.length === 0) continue;
      const seq = f.ring.push({ kind: "message", entries });
      feedBroadcast(f, { id: `${f.epoch}.${seq}`, event: "message", data: { entries } });
    }
  }
  if (++f.tick % FEED_SCREEN_EVERY === 0) {
    // ★登録簿は**毎回読み直す**。ここに呼び出し元の写しを持ち込むと、`registryCtx` の
    //   `now` だけが進んで mtime は凍り、配信が始まって 15 秒(HEARTBEAT_TTL_MS)で
    //   全ての登録が心拍切れに見える —— 実際には statusline が 2 秒ごとに打っているのに、
    //   電話には「ペイン登録をしていない」が出続ける(2026-08-05 実測: 登録の見かけの
    //   齢が 22-26 秒、同時に測った心拍の最大間隔は 1003ms)。読み直しは 1.4 秒に 1 回。
    const r = livePaneFor(sessionId, cwdOfSessionFile(file), undefined, undefined);
    // ★旧: `{ route:"gone" }`。**産む所1・使う所0**の死んだ経路名で、`routeLabel` に分岐が
    //   無いので画面には「状態不明」としか出なかった(2026-08-02 に実行して確認)。
    //   ★ここは `blockedBody()` に**理由の全域**を渡す唯一の呼び口(他は `UNDECIDABLE` で
    //   絞ってから渡す)。一度 `reason || "pane-gone"` と書いたが、`resolveSessionPane()` は
    //   **文字列 "none" を返す**ので偽が真にならず素通りした(実行して判明)。正規化は
    //   `blockedBody()` 側の1箇所に移した — 呼び口ごとに書けば書き忘れた口だけが嘘を出す。
    const body = r.pane ? screenBody(f, r.pane) : blockedBody(r);
    const key = JSON.stringify(body);
    if (key !== f.lastScreen) {
      f.lastScreen = key;
      // ★poll 経路は `screenBody()` を**呼べない**(あれは `f.work` を書き換えるので、
      //   読みに来た者が観測窓を進めてしまう)。だから撮った物を此処で1セルに置いて、
      //   poll は**それを読むだけ**にする。rev は「この画面を見たか」を栞で言う為の版。
      f.screen = { rev: ++f.screenRev, body };
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
    // 選択待ちの中身は**変化の検出にも効く**: 別のメニューに変われば指紋が変わり、
    // `lastScreen` の比較が動いて電話に新しい画面が流れる。
    ...(s.choice ? { choice: s.choice } : {}),
    work: f.work.some(Boolean) ? "observed" : "quiet",
    // ★窓は「溜まった枚数ぶん」。固定値だと購読直後に**4倍の窓を主張する**(1枚しか
    //   撮っていないのに 5.6 秒見たと言う)。画面はこの数字をそのまま「N秒 動く印なし」と
    //   出すので、ここが嘘だとそのまま嘘が出る。`f.work` は FEED_WORK_WINDOW で頭打ちなので
    //   定常状態は今まで通り 5600。変わるのは立ち上がりだけ。
    windowMs: f.work.length * FEED_SCREEN_EVERY * FEED_TICK_MS,
  };
}

/**
 * 配信を建てる。**解決関数は引数で受け取らない**。
 * 以前はここに poll/SSE の `resolvePane` をそのまま渡していたが、あの閉包は
 * 「登録簿は1リクエストにつき1回だけ読む」為の**リクエスト寿命の写し**を握っている。
 * timer は最初に建てた1本が生き続けるので、写しも一緒に生き続け、15 秒後には
 * その会話が永久に `unregistered` に見えた。渡せない形にして構造から外す。
 */
function startFeed(sessionId, file) {
  const f = getFeed(sessionId);
  if (!f.timer) {
    f.timer = setInterval(() => {
      try {
        feedTick(sessionId, f, file);
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
  if (!f) return;
  // 見に来ている者が3種いる: SSE の購読・保留中の poll・**さっき poll して次を撃つ途中**の電話。
  // 3番目が要るのは、poll は接続が繋がりっぱなしではないから —— 応答の度に止めると
  // 電話が次を撃つ間に tail が外れ、毎回 `tail-attached` の gap が出る(= 履歴の読み直しが
  // 永久に続く)。だから最後の poll から一定時間は**貸し出し中**として止めない。
  if (f.subs.size > 0 || f.wakers.size > 0 || Date.now() < f.pollLeaseUntil) return;
  clearInterval(f.timer);
  f.timer = null;
  f.lastScreen = null;
  // 画面は最新値の一時状態なので捨てる(次の tick で撮り直す)。ただし **rev は戻さない** ——
  // 戻すと古い栞の screenRev と一致して「その画面は見た」と嘘になる。
  f.screen = null;
  if (f.leaseTimer) {
    clearTimeout(f.leaseTimer);
    f.leaseTimer = null;
  }
  // ring / epoch / tail の位置は**残す**。捨てて作り直すと seq が 1 に戻り、
  // 再接続してきた電話に「追いついた」と嘘をつく経路ができる。
}

/**
 * poll の貸し出しを延長し、切れる頃に**1本だけ**後始末を予約する。
 * ★timer は feed あたり1本。poll ごとに `setTimeout` を積むと、電話が10秒に1回撃つだけで
 *   未発火の timer が溜まり続ける(応答の度に積んで誰も消さない、この手の漏れの定番)。
 */
function renewPollLease(sessionId, f) {
  f.pollLeaseUntil = Date.now() + POLL_LEASE_MS;
  if (f.leaseTimer) return;
  f.leaseTimer = setTimeout(function check() {
    f.leaseTimer = null;
    if (Date.now() < f.pollLeaseUntil && (f.timer || f.subs.size || f.wakers.size)) {
      // まだ貸し出し中。切れる時刻に合わせて張り直す(= 常に1本)。
      f.leaseTimer = setTimeout(check, Math.max(1000, f.pollLeaseUntil - Date.now()));
      f.leaseTimer.unref();
      return;
    }
    stopFeedIfIdle(sessionId);
  }, POLL_LEASE_MS);
  f.leaseTimer.unref();
}

// ---- HTTP -------------------------------------------------------------------
/**
 * この応答の「画面語」を作る `view.mjs` の関数を、**枝に入る前に1回だけ**宣言する。
 *
 * ★`noteBody` と同じ理由で口を1つにする(直下の注記): 送信の応答は `messages` だけで
 *   8枝あり、呼び口ごとに `display` を書くと**次に足された枝が黙って欄無しで通る**。
 *   欄が無い応答は電話側で「確認できませんでした」に落ちる = 成功しているのに warn が出る。
 *   宣言を枝の外に置けば、後から枝が増えても勝手に付く。
 */
const DISPLAY = Symbol("display-formatter");
function speaks(res, fn) {
  res[DISPLAY] = fn;
}

/**
 * 「操作の結果」ではなく、**操作へ入る手前で決まった事**の応答。
 *
 * 契約 (2026-08-05, Codex 助言を受けて明文化): client は表示する文言を status や本文から
 * 独自に導出してはならず、`display`(系統B)をそのまま描く。**但しこの2つだけは表示判断
 * ではなく復旧・遷移の制御**として扱ってよい —— 認証要求は鍵入力へ、対象セッション不在は
 * 一覧へ。除外の理由は「`speaks()` の宣言より手前に在るから」という実装上の偶然ではなく、
 * **操作処理より手前のプロトコル / 資源解決の結果だから**である。
 *
 * ★`code` を持たせる理由が「将来 404 の意味が増えるかもしれない」ではない事。
 *   2026-08-05 に数えたら 404 は既に3箇所・意味は2種類在った:
 *     ① `/api/` 以外の道 ② `/api/` だが道が無い ③ セッション id が不明
 *   電話側は status だけで分岐して**全部を「セッションが見つかりません → 一覧へ戻る」**に
 *   していたので、①②(= client が組み立てた path が間違っている)を「セッションが消えた」と
 *   表示していた。しかも path は変異監査で「変えても 214 件が緑」と実測された一番弱い所で、
 *   その弱さを**利用者向けの誤った説明で覆い隠す**形になっていた。
 *   `code` で分ければ、path のバグは一覧へ戻らず「応答契約違反」として目に見える。
 *
 * ★これを**定数**にするのは、意味の一覧を呼び口に配らない為。呼び口に直書きすると、
 *   404 を1本足した人が新しい意味を作った事に誰も気付かない(この案件で最も多い型)。
 *
 * ★`freeze` する理由: 定数は全リクエストで**同じ物**を指す。`json()` は写しを作ってから
 *   `display` を足すので今は安全だが、後から誰かが本文へ1欄書き足すと、その値が
 *   次のリクエストへ持ち越される。凍らせておけば黙って漏れずに其の場で例外になる。
 */
const AUTH_REQUIRED = Object.freeze({ error: "unauthorized", code: "AUTH_REQUIRED" });
/// 転写検索の後方走査の上限。素の履歴の `TAIL_MAX`(1 MiB)とは**別に持つ** —— 用途が違う。
export const SEARCH_TAIL_MAX = 16 * 1024 * 1024;
/// 作業木の差分の数(一覧の ± バッジ)。同期で返し、裏で cwd ごとに取り直す。
const diffCache = makeDiffCache();
const SESSION_NOT_FOUND = Object.freeze({ error: "unknown session", code: "SESSION_NOT_FOUND" });
const NO_SUCH_ROUTE = Object.freeze({ error: "not found", code: "NO_SUCH_ROUTE" });

/**
 * 診断用の errno。**上の `code` とは別の欄にする**理由が2つ在る(2026-08-05):
 *
 * ① 名前の衝突。`code` は上の語彙 = 電話が**画面を移す判断**に使う鍵になった。
 *    同じ名前で errno も流すと、電話から見て `code` の意味が2つになる。
 * ② 値の際限。旧実装は `String(e.code || e.message)` で、`e.code` を持たない例外
 *    (JSON の解析失敗・TypeError 等)では **`e.message` がそのまま線に出ていた**。
 *    Node の fs 由来の文面は path を含む。認証を通った先とはいえ、`code` を名乗る欄に
 *    自由文が入るのは契約として壊れている。
 *
 * ★一覧を持たずに閉じる: 大文字の errno の**形**だけを通し、それ以外は `UNKNOWN` へ潰す。
 *   既知の errno を列挙すると、その一覧が古くなった日に静かに `UNKNOWN` が増える。
 */
function errnoOf(e) {
  const c = e && e.code;
  return typeof c === "string" && /^[A-Z][A-Z0-9_]{1,30}$/.test(c) ? c : "UNKNOWN";
}

function json(res, code, obj) {
  const fn = res[DISPLAY];
  // ★既に `display` を持つ本文には触らない。一覧のように**枝の中で**組み立てる応答が
  //   在るので、ここで上書きすると出所が2つになる(どちらが勝つかを読む人が追う羽目になる)。
  const out =
    fn && obj && typeof obj === "object" && !Array.isArray(obj) && !("display" in obj)
      ? { ...obj, display: fn(code, obj) }
      : obj;
  const body = JSON.stringify(out);
  // ★ログの欄は**応答を作る唯一の口**で拾う。呼び口40箇所に注記を配ると、次に足された枝が
  //   黙って欄無しで通る(= 一覧を配ると必ず片方が古くなる、この案件で最も多い型)。
  noteBody(res, out);
  res.writeHead(code, { "content-type": "application/json; charset=utf-8" });
  res.end(body);
}

/// 本文が上限を超えた事だけを名乗る誤り。`JSON.parse` の失敗と**別の型**にしてあるのは、
/// 返す番号が違うから(400 = 送った物が壊れている / 413 = 大きすぎる)。文面で見分けると、
/// 次に文面を直した人が黙って番号を潰す。
class BodyTooLarge extends Error {
  constructor(limit) {
    super(`body larger than ${limit} bytes`);
    this.name = "BodyTooLarge";
    this.limit = limit;
  }
}

/// 上限を超えた時の唯一の返し方。**応答を書き切ってからソケットを閉じる**。
///
/// ★2026-08-15(Codex 指摘)。元は `readBody` の中で `req.destroy()` を呼んでいた。
///   `IncomingMessage.destroy()` は受信ソケットごと壊すので、その後に書く応答は電話へ
///   届かない —— 電話から見えるのは「接続が切れた」だけで、上限に当たった事も、
///   本文が大きすぎた事も名乗れないまま終わる。静的な検査(A10)は道の形しか見ないので
///   此の欠陥を掴めない。
function tooLarge(req, res, e) {
  res.on("finish", () => req.destroy());
  return json(res, 413, { error: `Request body too large (limit ${e.limit} bytes)` });
}

/**
 * ★バイナリ用。`readBody` は utf8 文字列に潰すので画像には使えない
 *   (通しても中身が壊れ、壊れた事は形式判定でしか分からない = 診断が1段遠くなる)。
 *   上限の扱い・閉じ方は `readBody` と**同じ規約**にしてある。
 */
async function readBodyBytes(req, limit) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on("data", (c) => {
      size += c.length;
      if (size > limit) { req.pause(); reject(new BodyTooLarge(limit)); return; }
      chunks.push(c);
    });
    req.on("end", () => resolve(Buffer.concat(chunks)));
    req.on("error", reject);
  });
}

async function readBody(req, limit = 64 * 1024) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on("data", (c) => {
      size += c.length;
      if (size > limit) {
        // 読むのを止めるだけ。閉じるのは応答が出てから(`tooLarge`)。
        req.pause();
        reject(new BodyTooLarge(limit));
        return;
      }
      chunks.push(c);
    });
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    req.on("error", reject);
  });
}

/**
 * `fleet-account` を引数なしで叩いて、**今の**口座の状態を観測する。
 *
 * ★切替の道はどれも、副作用を起こした後で此れを呼ぶ。台本の「切替: team」という
 *   自己申告ではなく、symlink を読み直した結果を電話へ返す為 —— exit 0 は
 *   「命令が通った」であって「今この口座に成っている」ではない(Codex 指摘 2026-08-14)。
 */
// ★2026-08-27: `execFileSync` から非同期へ。**読み取りは事象ループを止めてはいけない**。
//
//   実測(friday 本番): `fleet-account-cswap.sh` は 1回 **180ms** かかる。同期で呼ぶと
//   その間 Node は他の要求を1つも処理できない —— `healthz` は単独 **0.4ms** なのに、
//   `/api/account` の最中に投げると **164ms**(390倍)返って来なかった。
//   そして電話は `/api/account` を **アプリを開くたび・前面へ戻るたび**に
//   `/api/sessions` と**同時に**撃つ(`AccountBar.swift` の `.task` / `.onChange(scenePhase)`)。
//   = Tom が開く瞬間ちょうど、机が 180ms 凍る。一覧を 533ms から 104ms へ削った後では、
//   この凍結の方が大きい。
//
//   ★書き込み側(`select` / `--next` の実行そのもの)は同期のまま残してある。あちらは
//   人が押して結果を待っている操作で頻度が低く、順序の意味も違う(実行と読み直しの間に
//   別の要求が割り込む形を、測らずに作らない)。**残っている的として明記する**。
const execFileAsync = promisify(execFile);

// ── 口座の使用量(2026-08-29) ─────────────────────────────────────────────
// 出典 = `cswap list --json`(friday 実測 0.15s)。/api/account の床(0.14-0.21s)を
// 守る為に**返してから測る**(stale-while-revalidate): 応答はキャッシュを載せ、
// 古ければ裏で測り直す。初回だけ usage は null で返る(次の poll で埋まる)。
// 失敗した日は古い値が残り、`usageAgeSeconds` が齢を正直に語る。
// keychain unlock は cswap-distribute と同じ理由(unlock は session を跨がない)。
const USAGE_TTL_MS = Number(process.env.RC_USAGE_TTL_MS || 300_000);
// ★上限は cold の実測から決める(2026-08-29 friday: cold 1.31s / warm 0.12s・0.13s)。
//   Codex は「1〜2秒に縮めろ」と言ったが、それでは**冷えた1発目が必ず切れる** ——
//   縮める方向は正しく、値は測ってから決める。8s = cold の約6倍。
const USAGE_TIMEOUT_MS = Number(process.env.RC_USAGE_TIMEOUT_MS || 8_000);
// 失敗中の再試行の間隔(指数)。★成功時刻(`at`)と**試行時刻を分ける**のがこの直しの核心:
//   分けないと、期限切れ後に失敗が続く間**要求のたびに**子プロセスが立つ
//   (single-flight は同時実行を1本にするだけで、連続実行を止めない)。
//   実測: `/api/account` は 20-23回/時。恒久障害ならその頻度で `security` を起こし続けていた。
const USAGE_BACKOFF_BASE_MS = 30_000;
const USAGE_BACKOFF_MAX_MS = 30 * 60_000;
// ★絶対パスで起動する(2026-08-29)。`PATH="$HOME/.local/bin:$PATH"` に頼ると、
//   launchd の環境や `BASH_ENV` の差で**別の cswap**を掴みうる。実在の検証は起動時に1回。
const CSWAP_BIN = process.env.RC_CSWAP_BIN || join(HOME, ".local", "bin", "cswap");
const USAGE_KEYCHAIN = process.env.RC_USAGE_KEYCHAIN
  || join(HOME, "Library", "Keychains", "claude-code.keychain-db");
// bash を1枚噛ませるのは、**unlock と読みが同じシェルに居る必要がある**からではない
// (Codex の指摘どおり keychain の状態は共有で、シェル局所ではない)。理由は
// 「unlock が失敗しても読みは試す」という順接を1コマンドで表せる事だけ。
// 変数は挟まない —— 全部この場で解決した絶対パスを埋める。
const USAGE_CMD = `/usr/bin/security unlock-keychain -p "" ${JSON.stringify(USAGE_KEYCHAIN)} 2>/dev/null; `
  + `exec ${JSON.stringify(CSWAP_BIN)} list --json`;

const usageCache = {
  at: 0,             // 最後に**成功**した時刻(古さの正本)
  byEmail: null,
  inflight: null,
  lastAttemptAt: 0,  // 最後に**試した**時刻(成否を問わない = backoff の起点)
  failures: 0,       // 連続失敗回数
};

// 判定と待ち時間は `usage.mjs`(純粋な側)に居る。此の file は import した瞬間 listen するので、
// 検査から直に呼べる場所へ置く必要が在った。既定値も向こうが持つ(30秒 → 最大 30分)。

function refreshUsage() {
  if (usageCache.inflight) return usageCache.inflight;
  usageCache.lastAttemptAt = Date.now();
  usageCache.inflight = execFileAsync("/bin/bash", ["-c", USAGE_CMD], {
    encoding: "utf8", timeout: USAGE_TIMEOUT_MS, killSignal: "SIGKILL", maxBuffer: 4 * 1024 * 1024,
  })
    .then(({ stdout }) => {
      const parsed = parseCswapUsage(stdout);
      // unreadable は捨てて古い値を保つ(「読めなかった」を「0件」にしない — account.mjs と同じ線)。
      // ただし**失敗として数える** —— 読めない出力が続く事は、値が無い事と同じくらい報告に値する。
      if (parsed.status !== "ok") throw new Error("cswap の出力を読み切れない");
      const recovered = usageCache.failures > 0;
      usageCache.byEmail = parsed.byEmail;
      usageCache.at = Date.now();
      usageCache.failures = 0;
      if (recovered) console.log("[rc-backend] 口座の使用量: 復帰(測り直せた)");
    })
    .catch((e) => {
      // ★黙って捨てない(2026-08-29、Codex の指摘2)。捨てていた間、keychain・cswap・
      //   出力形式のどの恒久障害でも、電話は**先週の数字を今の値として**描き続け、
      //   しかも机側に痕跡が1行も残らなかった。口座の切替という実操作の判断材料なので、
      //   「古い」が見えない事は「出ない」より危険。
      //   backoff が在るので、この行の頻度は 30秒 → 最大 30分 へ自然に落ちる(氾濫しない)。
      usageCache.failures += 1;
      console.error(`[rc-backend] 口座の使用量を測れない(${usageCache.failures}回連続、`
        + `次は${Math.round(usageBackoffMs(usageCache.failures) / 1000)}秒後): ${e && e.message}`);
    })
    .finally(() => { usageCache.inflight = null; });
  return usageCache.inflight;
}

function usageForWire() {
  if (usageRefreshDue(usageCache, Date.now())) refreshUsage();
  return {
    usageByEmail: usageCache.byEmail,
    usageAgeSeconds: usageCache.at ? Math.round((Date.now() - usageCache.at) / 1000) : null,
  };
}

async function readFleetAccount() {
  const { stdout } = await execFileAsync(FLEET_ACCOUNT, [], {
    encoding: "utf8", timeout: FLEET_ACCOUNT_TIMEOUT_MS, killSignal: "SIGKILL",
  });
  return { raw: stdout, parsed: parseFleetAccount(stdout) };
}

const server = createServer(async (req, res) => {
  // ★try の**外**。中に入れると、URL の解釈で落ちた要求だけログに出ない
  //   = 一番読みたい種類の要求が一番出ない。
  attachRequestLog(req, res, { knownPaths: LOG_PATHS });
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

    // ★外向きの生存信号(DESIGN §7-P)。認証の**外**、`/api/` の外に置く。
    //   認証を掛けない理由: 掛けると観測者に鍵の複製が要る = 秘密の置き場が1つ増える。
    //   代わりに**返す物を秘密でない値だけに絞る**。セッション名も cwd も一覧も**件数も**返さない
    //   (件数は「今日は何本開いていたか」を外へ漏らす)。
    //   tailnet + `tailscale serve` の内側なので公開面でもない。
    if (req.method === "GET" && path === "/healthz") {
      return json(res, 200, healthzBody({
        pid: process.pid,
        uptime: Math.floor((Date.now() - STARTED_AT) / 1000),
        version: DEPLOYED_REV,
      }));
    }

    // ★表に無いパスはここで落ちる = 総当たりの静的ファイルサーバを作らない。
    //   パスから file 名を組み立てる実装にすると `/../keys/api.key` の入口ができる。
    if (!path.startsWith("/api/")) return json(res, 404, NO_SUCH_ROUTE);
    if (!authorized(req)) return json(res, 401, AUTH_REQUIRED);

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
      // scope=archived は §9-1 の「外した物の置き場」。既定の一覧は保管済みを**出さない**。
      const scopeParam = url.searchParams.get("scope");
      const requestedScope = scopeParam === "registered" ? "registered"
        : scopeParam === "archived" ? "archived" : "all";
      const limit = Math.max(0, Math.trunc(Number(url.searchParams.get("limit")) || 0));
      const registered = new Set(entries.map((e) => e.sessionId));
      // ★地図は走査の**前**に1回だけ読む(手順の1番目)。走査の中で会話ごとに読むと
      //   open が file 数だけ増える上、`only` を広げる判断が走査より後になって罠1 を踏む。
      const heads = headMap();
      const scan = scanSessions({ only: requestedScope === "registered" ? registered : null, limit, heads });
      // 明示名と保管の台帳。要求ごとに1回読む(登録簿と同じ扱い)。
      const explicitTitles = loadTitles(KEY_DIR);
      const archivedLedger = loadArchived(KEY_DIR);
      const scanned = [...buildListing(scan.entries, explicitTitles), ...scan.unreadable];
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
      ]
        // ★明示名と保管の絞りは**合流後に一括で**当てる(生産者は buildListing /
        //   registryOnlySessions / unreadableRow の3人居るので、各自に台帳を配ると
        //   1人だけ配り忘れる形になる)。読めない行に名前が当たるのも意図どおり。
        //   保管の絞り(§9-1): 既定 = 保管済みを出さない / scope=archived = 保管済みだけ。
        //   「消す」機構は存在しない — transcript に触るコードをそもそも持たない。
        .map((s) => (explicitTitles[s.id] ? { ...s, title: explicitTitles[s.id] } : s))
        .filter((s) => (requestedScope === "archived" ? !!archivedLedger[s.id] : !archivedLedger[s.id]))
        .sort((a, b) => (a.updatedAt < b.updatedAt ? 1 : a.updatedAt > b.updatedAt ? -1 : 0)).map((s) => {
        // 机で開かれている会話は画面が真実。開かれていなければワーカーの状態。
        const r = paneFault || livePaneFor(s.id, s.cwd, panes, entries, ctx);
        const live = r.pane
          ? { route: "tmux", pane: r.pane, ...screenOf(r.pane) }
          : UNDECIDABLE.has(r.reason)
            ? blockedBody(r)
            : { route: "worker", ...manager.status(s.id) };
        // §9-2: 持ち出し(remote-mini)の仕事は機体を名乗る。cwd が mirror root の
        // worktree の下に在る事だけが判定で、名前や題名からは推測しない。
        const checkoutId = checkoutIdForCwd(s.cwd || "", MIRROR_ROOT);
        const machine = checkoutId
          ? {
              kind: "checkout",
              checkoutId,
              returnRequestedAt: readReturnRequest(MIRROR_ROOT, checkoutId)?.at ?? null,
            }
          : { kind: "desk", checkoutId: null, returnRequestedAt: null };
        return sessionRow(s, live, machine, diffCache.get(s.cwd));
      });
      // 何本見て何本開いたかを毎回名乗る。★「速い」を主張する側が計器を持たないと、
      // 遅くなった時に「気のせい」で片付く(この置き換え自体、測って初めて見つかった)。
      // ★キャッシュの効きも一緒に出す。2026-08-27 まで `cached` だけは載っていたのに、
      //   0 が数週間続いても誰も読まなかった。読まれなかったのは、それが「効いていない」
      //   を意味すると判る文脈(上限と占有)が隣に無かったからでもある。
      const scanBody = { scope: requestedScope, limit, files: scan.files, read: scan.read,
        cached: scan.cached, examined: scan.examined, swept: scan.swept,
        cacheMax: scan.cacheMax, cacheSize: scan.cacheSize, cacheCapped: scan.cacheCapped };
      // 封筒の形と、その形である理由は `src/wire.mjs`(単体から実行して鍵名を採れる場所)。
      // ここは観測値を渡すだけ。
      // ★配布口が配っている版と、**要求して来た電話の版**(既定 User-Agent 由来)を渡す。
      //   文面を決めるのは `wire.mjs` の `updateNotice` —— 「描くのは display」に揃える。
      //   どちらか読めなければ `null` = 出さない。此処は観測値を渡すだけ。
      return json(res, 200, sessionsBody({
        sessions: listing, scan: scanBody, paneFault,
        publishedBuild: publishedBuild(OTA_ROOT),
        // ★**電話が名乗った版だけ**を採る。`User-Agent` へ落ちる道は 2026-08-31 に消した ——
        //   UA が運ぶのは `CFBundleShortVersionString`(売り物の版)であって build 番号ではなく、
        //   落ちた先で**売り物の版と build 番号を引き算する**事になっていた
        //   (実測: 短版 0.1 / build 106、机の log の app 要求は全部 `build=1`)。
        //   名乗らない版は `"-"` → `updateNotice` が `null` を返す = 帯を出さない。
        //   ★之で「名乗らない古い版には知らせない」事になるが、**知らせられない**のが事実:
        //     build 105(今 配っている物)は帯の UI 自体を持たない(6e2a5a0 は 105 の 2h 後)。
        //     嘘の数字を出すより黙る方が良い。106 以降は名乗るので正しく出る。
        appBuild: headerBuild(req.headers["x-app-build"]),
      }));
    }

    if (path === "/api/account" && req.method === "GET") {
      try {
        const { raw, parsed } = await readFleetAccount();
        return json(res, 200, accountBody(parsed, { raw, ...usageForWire() }));
      } catch (e) {
        return json(res, 500, { error: `fleet-account failed: ${e.message}` });
      }
    }
    if (path === "/api/account/select" && req.method === "POST") {
      // ★本文の解釈は台本の try の**外**。中に置くと、本文が JSON として読めなかっただけの
      //   要求に `fleet-account <name> failed: ...` の 500 が返る —— 台本を一度も呼んで
      //   いないのに edith 側が壊れたと名指しする応答で、読んだ人を机へ走らせる。
      //   64KB 超で `readBody` が落ちる道も同じ所へ流れ込んでいた。
      let want;
      try {
        want = JSON.parse((await readBody(req)) || "{}")?.name;
      } catch (e) {
        if (e instanceof BodyTooLarge) return tooLarge(req, res, e);
        return json(res, 400, { error: `Request body unreadable: ${e.message}` });
      }
      try {
        // ★白名簿(今の一覧に在る)と**名前の不変条件**の両方を通す。片方では足りない ——
        //   `--next` という名の口座が `.order` に在れば、白名簿だけでは
        //   「切替」ではなく「次へ送る」が走る(台本の `case "$1"`、Codex 指摘)。
        const before = await readFleetAccount();
        const problem = selectionProblem(before.parsed, want);
        // ★`code` は**使わない**。あれは電話が画面を移す為の凍らせた語彙で
        //   (`test/recovery-codes.test.mjs`)、断り理由を同じ鍵で流すと遷移の判断が壊れる。
        if (problem) return json(res, 400, { error: selectionMessage(problem), reason: problem });
        // 副作用。出力は読み捨てる —— 「切替: team」は台本の自己申告で、観測値ではない。
        execFileSync(FLEET_ACCOUNT, [want], {
          encoding: "utf8", timeout: FLEET_ACCOUNT_TIMEOUT_MS, killSignal: "SIGKILL",
        });
        // 観測し直して返す。頼んだ名前を返すと、切替が効かなかった日に画面だけが嘘を吐く。
        const after = await readFleetAccount();
        return json(res, 200, accountBody(after.parsed, { raw: after.raw, ...usageForWire() }));
      } catch (e) {
        return json(res, 500, { error: `fleet-account <name> failed: ${e.message}` });
      }
    }
    if (path === "/api/account/next" && req.method === "POST") {
      try {
        // ★此処だけ副作用が在る(口座を進める)。時間切れは**取り消しではない** ——
        //   台本が進めた後で固まった場合、上限で殺しても口座は進んでいる。
        //   だから 500 を見て自動で撃ち直す物を作らない(今は誰も撃ち直していない)。
        execFileSync(FLEET_ACCOUNT, ["--next"], {
          encoding: "utf8", timeout: FLEET_ACCOUNT_TIMEOUT_MS, killSignal: "SIGKILL",
        });
        const after = await readFleetAccount();
        return json(res, 200, accountBody(after.parsed, { raw: after.raw, ...usageForWire() }));
      } catch (e) {
        return json(res, 500, { error: `fleet-account --next failed: ${e.message}` });
      }
    }

    // ★道の一覧は `reqlog.mjs` の1本だけ(写しを持たない)。振り分けとログが別々に持つと、
    //   道を1本足した時に片方だけが古くなり、ログは新しい道を `(other)` と書き続ける。
    // ★roots の口(2026-09-03、対照表 #11)。会話に**紐づかない** 3 本 = 会話が 0 本の机でも
    //   電話から新しい会話を始められる唯一の道。中身は `src/rootsroute.mjs`(偽 req/res で検査)。
    //   `/api/roots` は字面で書く(`LOG_PATHS` の両向き検査と対)。`/api/roots/<i>/…` は
    //   `ROOTS_ROUTE_RE`(reqlog.mjs が唯一の写し)。会話の道の 404 より**前**に居る事が要点
    //   (後ろだと `SESSION_ROUTE_RE` に当たらない道は全部 404 で、handler が在っても届かない)。
    if (path === "/api/roots" && req.method === "GET") {
      return handleRootsList({ res, json, loadRoots, rootsBody });
    }
    const rm = ROOTS_ROUTE_RE.exec(path);
    if (rm) {
      const [, rootIndex, rootAction] = rm;
      if (rootAction === "paths" && req.method === "GET") {
        return handleRootsPaths({
          res, index: rootIndex, q: url.searchParams.get("q") || "",
          limit: clampPathsLimit(url.searchParams.get("limit")),
          json, loadRoots, completePaths, pathsBody,
        });
      }
      if (rootAction === "new" && req.method === "POST") {
        return await handleRootsNew({
          req, res, index: rootIndex, json, loadRoots, resolveUnderRoots,
          readBody, tooLarge, BodyTooLarge, startWindow: startPhoneWindow,
        });
      }
      return json(res, 404, NO_SUCH_ROUTE);
    }

    const m = SESSION_ROUTE_RE.exec(path);
    if (!m) return json(res, 404, NO_SUCH_ROUTE);
    const [, sessionId, action] = m;
    const file = findSessionFile(sessionId);
    // 登録簿は1リクエストにつき1回だけ読む。2回読むと、その間に書き手(statusLine が
    // 2秒ごとに書く)が挟まって「存在すると判定した直後の解決では別内容」になりうる。
    const regEntries = registry.read();
    // jsonl は最初の発言まで作られない(2026-07-31 edith 実測)。開いただけの会話は
    // 登録簿にしか居ないので、そこにペインがあるなら操作対象として通す。
    const registeredOnly = !file && regEntries.some((e) => e.sessionId === sessionId);
    if (!file && !registeredOnly) return json(res, 404, SESSION_NOT_FOUND);
    // cwd は jsonl 由来。無い場合は空 = 突き合わせを省く(resolveSessionPane の仕様)。
    // ★ここは送信・割り込みの度に通る。全部読むと 280 MB のファイルで毎回それを払う一方、
    //   cwd 経路は仕様上 "ok" を返せない(registry.mjs: 同定は名乗りだけ)ので、
    //   払う対価に対して得られる物が無い。末尾から有界に採る。
    const sessionCwd = () => cwdOfSessionFile(file);
    const resolvePane = () => livePaneFor(sessionId, sessionCwd(), undefined, regEntries);

    // ── 明示名(rename)。本家 RC のタイトル優先順の1段目(spec-audit A1)────────
    // body: {"title": "名前"} で付け、{"title": null} で外す。付けた名前は
    // /api/sessions の一覧に**合流後の一括 override** で乗る(生産者3人に配らない)。
    // ★電話から**新しい会話を始める**(2026-08-31、調査の4位)。
    //
    //   今まで worker は `--resume` 固定(spawn の註)で、**既に在る会話にしか入れなかった**。
    //   競合(omnara / vibe-kanban / claude-squad …)は全社 持っていて、
    //   此の製品だけが構造的に持たない唯一の能力だった。
    //
    // ★部品は既に在る —— `ensure-phone-window.sh` が
    //   「window を 1 枚 足すだけ・既存のペインには一切触れない」形を確立している。
    //   其の形をそのまま使う(既存ペインへ打ち込む案は、人が打ちかけた行を壊し得るので
    //   あちらで既に棄却されている)。
    //
    // ★何処で始めるかは**既に在る会話の cwd**から採る。「この会話と同じ場所で、もう1本」
    //   が電話から一番自然な始め方。
    // ★★2026-09-02: 此の判断が元に持っていた理由(「`@` 補完が未着手なので盲打ちになる」)は
    //   **消えた** —— 補完は下の `paths` の道として入った。だが其れが歩けるのは
    //   **既に在る会話の cwd の下**で、任意のディレクトリを 0 から選ぶ道(対照表 #11)は
    //   机に一覧の口が無い。今は「まだ作っていない」であって「作らないと決めた」ではない。
    //
    // ★window 名は**回復用の `phone` と分ける**。あちらは「1 枚だけ在る」を冪等の鍵に
    //   しているので、同じ名前で足すと 60 秒ごとの回復が此の window を自分の物と誤認する。
    // ★`code` を本文へ書かない(2026-08-31、門が捕まえた)。`code` は 401/404 の
    //   **復旧語彙専用**で、電話は其の鍵で画面を移す。別の意味を同じ名前で流すと
    //   遷移の判断が壊れる。此処の分類は `reason` へ寄せる。
    if (action === "new" && req.method === "POST") {
      // ★本文(2026-09-03、対照表 #11): `{ "cwd": "<絶対 or ~/…>" }` が在れば **roots の下だけ**で其処に
      //   始める。無ければ今までどおり会話の cwd。本文の解釈は `/api/account/select` と同じ形で
      //   台本(tmux)の前に済ませる —— 読めない本文で tmux を一度も呼ばない。
      let body;
      try {
        body = JSON.parse((await readBody(req)) || "{}");
      } catch (e) {
        if (e instanceof BodyTooLarge) return tooLarge(req, res, e);
        return json(res, 400, { error: `Request body unreadable: ${e.message}`, reason: "bad_body" });
      }
      const wanted = resolveRequestedCwd({ body, loadRoots, resolveUnderRoots });
      if (wanted.status) return json(res, wanted.status, wanted.body);

      let cwd = wanted.cwd;
      if (cwd === null) {
        cwd = cwdOfSessionFile(file);
        if (!cwd) return json(res, 409, { error: "cwd_unknown", reason: "no_cwd" });
        // ★実在を**同期に**確かめてから作る(spawn 側と同じ理由 —— 検査と実行の間に
        //   dir が消える競合。作った後で気付くと「始めた」と答えた後に死ぬ)。
        try { realpathSync(cwd); }
        catch { return json(res, 409, { error: "cwd_gone", reason: "no_cwd" }); }
      }

      const started = startPhoneWindow(cwd);
      if (!started) return json(res, 502, { error: "new_window_failed", reason: "tmux_failed" });
      // ★202。会話の id は**まだ無い** —— Claude Code が jsonl を書き、登録簿が拾って
      //   初めて一覧に出る。此処で id を作って返すと、存在しない物を電話に持たせる事になる。
      //   電話は一覧を引き直して新しい行を見つける。
      // ★`cwd` は返さない(Codex 2026-09-03 #4): 電話は読まない鍵で、絶対 path を線に出す理由が無い。
      return json(res, 202, { started: true, window: started.window, pane: started.pane });
    }

    if (action === "title" && req.method === "POST") {
      let body;
      try {
        body = JSON.parse(await readBody(req));
      } catch {
        // 語彙は messages 道の "text required" と同じ流儀(小文字の英語句)。
        // 新しい大文字コードを鋳造すると wire-vocabulary の門が正しく止める(実測 2026-08-16)。
        return json(res, 400, { error: "title required" });
      }
      if (body.title === null) {
        setTitle(KEY_DIR, sessionId, null);
        return json(res, 200, { title: null });
      }
      const t = normalizeTitle(body.title);
      // ★空・60字超・文字列でない、は全部同じ1つの拒否(1〜60文字・改行なし)。
      if (t === null) return json(res, 400, { error: "title required" });
      setTitle(KEY_DIR, sessionId, t);
      return json(res, 200, { title: t });
    }

    // ── 戻しの依頼(§9-2)。電話から出来るのは**依頼を置く**まで ────────────────
    // 実行は MBP 側(`remote-mini.sh requests`)。force に相当する語彙は此の API に無い。
    if (action === "return-request" && req.method === "POST") {
      const cwd = sessionCwd();
      const checkoutId = checkoutIdForCwd(cwd || "", MIRROR_ROOT);
      if (!checkoutId) {
        return json(res, 409, {
          error: "not-a-checkout",
          message: "This session is not checked-out work. There is nothing to return.",
        });
      }
      const r = requestReturn(MIRROR_ROOT, checkoutId, sessionId);
      if (r.error) {
        return json(res, 409, {
          error: "checkout-gone",
          message: "The checkout marker is missing. It may already have been returned on the desk side.",
        });
      }
      return json(res, 200, { requestedAt: r.at, already: !!r.already });
    }

    // ── 保管(§9-1)。一覧から外す / 戻す。transcript には一切触れない ──────────
    if (action === "archive" && req.method === "POST") {
      let body;
      try {
        body = JSON.parse(await readBody(req));
      } catch {
        return json(res, 400, { error: "archived required" });
      }
      if (typeof body.archived !== "boolean") {
        return json(res, 400, { error: "archived required" });
      }
      setArchived(KEY_DIR, sessionId, body.archived);
      return json(res, 200, { archived: body.archived });
    }

    // ── `@` のパス補完(2026-09-02、対照表 #10)────────────────────────────────
    //
    // ★**読むだけ**の口。dir を開いて名前を読むだけで、file の中身は1バイトも読まない。
    //   走査の規則と上限は全部 `src/paths.mjs` に在る(此処は cwd を渡すだけ)。
    //
    // ★★此の分岐は `sessionCwd` の**宣言より後**に在る事(2026-08-31 の実害:
    //   新しいルートを `const` の宣言より前に置いて全ルートを壊し、検査 1777 件が
    //   緑のままだった)。守っているのは `test/e2e-local.mjs` の往復 —— 関数の扉では
    //   宣言順の誤りは決して赤くならない。
    //
    // ★答えられない時も **200 + 空 + 語**。404 / 500 にしない理由は、電話にとって
    //   次の一手が全部同じ(補完は出ない、会話は使える)だから。断りを status で
    //   割ると、電話は「鍵が切れた」「会話が消えた」の判断と混ぜて読む事になる。
    if (action === "paths" && req.method === "GET") {
      const cwd = sessionCwd();
      if (!cwd) {
        return json(res, 200, pathsBody({ entries: [], truncated: false, reason: PATHS_NO_CWD }));
      }
      // 上限は `paths.mjs` が枠に収める(読めない値・空欄は既定へ)。此処で `Number()` を
      // 挟むと、判断が2箇所に分かれて必ず片方が先に古くなる。
      const r = completePaths(cwd, url.searchParams.get("q") || "", {
        limit: clampPathsLimit(url.searchParams.get("limit")),
      });
      return json(res, 200, pathsBody({
        entries: r.paths, truncated: r.truncated, reason: r.reason,
      }));
    }

    // ★差分を電話で読む(2026-09-02、対照表 #4)。一覧の ± バッジ(#5)が
    //   「幾ら変わったか」を出すのに対し、此処は**何が変わったか**を返す。
    //
    // ★読むだけの道。撃つ git は `diff` の 2 本で、書く動詞は 1 つも無い
    //   (repo の設定で外部プログラムを走らせない事・index の錠を取らない事は
    //   `src/sessiondiff.mjs` の頭に書いた)。
    // ★読めない事は**異常ではなく状態**なので 200 + `reason` で返す。
    //   cwd が無い会話は珍しくないし、git 管理外の dir で作業する事も在る ——
    //   其れを 4xx/5xx にすると、電話は「壊れた」と読んで再試行を勧める。
    if (action === "diff" && req.method === "GET") {
      // ★口の挙動は `src/diffroute.mjs` に切り出した(2026-09-03、Codex #4 の 4)。此処は
      //   会話の cwd を渡して委ねるだけ。cwd 無し → 200 no_cwd / close → 順番待ちから外れる /
      //   busy → 503 / aborted → 何も書かない、は其方の `test/diff-route-handler.test.mjs` が
      //   偽の req / res で**実際に**通す。
      // ★`await` を落とさない(Codex #6 の High)。返すだけだと reject が此の関数の外側の try/catch を
      //   素通りし、`readWorkingDiff` が投げた時に 500 が返らず応答が無いまま終わる。
      return await handleDiffGet({ req, res, cwd: sessionCwd(), readWorkingDiff, json, diffBody });
    }

    /**
     * この会話の転写がどの file に在るか。
     *
     * ★§2.18-4b: fork の後、本文も返事も**枝の file** に書かれる。祖先を読むと電話には
     *   fork より前しか出ず、送った筈の一言が消えて見える。引き先を頭へ付け替える
     *   (変異 P13)。頭が無い / 頭の file が見つからない = 祖先のまま = 何も失わない。
     *
     * ★2026-08-26 に関数へ括った。digest がこの解決を要る様になった時、同じ1行を
     *   2箇所へ書き写した —— 変異 P13 の的が2箇所に当たって**見張りが外れた**。
     *   1つの規則は1箇所に置く(写しは必ず片方だけ古くなる)。
     */
    const transcriptTarget = () => {
      const headId = readBranchHead(HEADS_DIR, sessionId);
      return (headId && headId !== sessionId && findSessionFile(headId)) || file;
    };

    /**
     * 対照表 #16。`status` の付帯情報なので**読めない事を異常にしない** ——
     * 画面(送信可否)は転写が読めなくても正しく返せる。permission mode だけが
     * null に落ちる(電話は「無ければ出さない」)。
     */
    const currentPermissionMode = () => {
      const target = transcriptTarget();
      if (!target) return null;
      try { return permissionModeOf(target); } catch { return null; }
    };

    if (action === "history" && req.method === "GET") {
      const limit = Math.min(Number(url.searchParams.get("limit") || 50), 500);
      // ★§2.18-4b: fork の後、本文も返事も**枝の file** に書かれる。祖先を読むと電話には
      //   fork より前しか出ず、送った筈の一言が消えて見える。引き先を頭へ付け替える
      //   (変異 P13)。頭が無い / 頭の file が見つからない = 祖先のまま = 何も失わない。
      const target = transcriptTarget();
      if (!target) return json(res, 200, { history: [] }); // まだ何も言っていない会話
      // ★転写の中を探す(2026-08-31)。`q` が在る時だけ経路が変わる。
      //   0 件には 2 つの意味が在る —— 走査した範囲に無かった / 会話の最初まで見て無かった。
      //   混ぜると「無い」と言い切れない物を言い切る事になるので、`reachedStart` を返して
      //   電話側が「此処までは見た」と言える様にする。
      const q = (url.searchParams.get("q") || "").trim();
      if (q) {
        try {
          // ★2026-09-02: 走査距離を `TAIL_MAX`(1 MiB)から `SEARCH_TAIL_MAX` へ。
          //   `opts` を渡さないと `readLinesBackward` の既定 1 MiB に落ち、最長の会話
          //   (280 MB)では**末尾 0.36% しか見ない**。検索は submit の時だけ走る(毎打鍵では
          //   ない)ので、素の履歴と同じ上限に縛る理由が無い。
          //   ★上げ過ぎない —— 280 MB を毎回 舐めると机が固まる。16 MiB は数千行ぶんで、
          //     「3 時間前に転けた所」を探す動機には足り、読み切りに 1 秒かからない。
          const r = searchHistoryFromPath(target, q, limit, { maxBytes: SEARCH_TAIL_MAX });
          // ★封筒は `historySearchBody`(`src/wire.mjs`)。直書きへ戻すと、
          //   電話の `TranscriptSearchResponse` と鍵名を突き合わせる者が
          //   居なくなる(`test/wire-key-agreement.test.mjs` の⑦が之を測る)。
          return json(res, 200, historySearchBody({
            entries: r.history, matched: r.matched, reachedStart: r.reachedStart,
          }));
        } catch (e) {
          // まだ file が無い = 「頭まで見て 0 件」で正しい。**同じ封筒**を通す ——
          // 枝ごとに手で組むと、鍵が 1 つ増えた日に片方だけが古くなる。
          if (e.code === "ENOENT") {
            return json(res, 200, historySearchBody({ entries: [], matched: 0, reachedStart: true }));
          }
          return json(res, 500, { error: "TRANSCRIPT_UNREADABLE", errno: errnoOf(e) });
        }
      }
      try {
        const h = readHistoryFromPath(target, limit);
        // truncated = これより前がある。電話側が「以前を読む」を出せる様に名乗る。
        // ★上下の `{ history: [] }` / `{ history: [], truncated: false }` は**均さない**。
        //   空の応答に2つの形が実在する事を電話側が明示的に受けている(HistoryModels.swift)ので、
        //   1つに揃えるとその受け方が測れない物になる(S8-26)。
        return json(res, 200, historyBody({ entries: h.history, truncated: h.truncated }));
      } catch (e) {
        if (e.code === "ENOENT") return json(res, 200, { history: [], truncated: false });
        return json(res, 500, { error: "TRANSCRIPT_UNREADABLE", errno: errnoOf(e) });
      }
    }

    // ★電話の写真をこの機械へ置き、エージェントが読める形にする(2026-08-26)。
    //   研究の1位 —— **電話でしか出来ない用途**(手の中の端末で起きているバグを撮って送る)。
    //
    // ★応答に**絶対パスを出さない**(Codex 2026-08-26)。出すと内部構造が API に固まり、
    //   置き場を動かせなくなる。電話が必要なのは「送れた」事と id だけ。
    // ★Enter は打たない。パスを**文へ差し込むだけ**で、送るかどうかは人が決める
    //   (既存の送信経路が本文と Enter を分けているのと同じ規約)。
    if (action === "attach" && req.method === "POST") {
      let buf;
      try {
        buf = await readBodyBytes(req, ATTACH_MAX_BYTES);
      } catch (e) {
        if (e instanceof BodyTooLarge) return tooLarge(req, res, e);
        return json(res, 400, { error: "ATTACH_READ_FAILED" });
      }
      let stored;
      try {
        stored = storeImage(buf, { baseDir: ATTACH_DIR });
      } catch (e) {
        // ★理由を語彙で返す。「失敗しました」だけだと、電話の持ち主は
        //   撮り直せばよいのか諦めるのかが分からない。
        const code = String(e.message || "");
        const known = ["too-large", "empty-body", "unknown-format", "too-many-pixels"];
        if (known.includes(code)) return json(res, 400, { error: "ATTACH_REJECTED", reason: code });
        return json(res, 500, { error: "ATTACH_FAILED", reason: "store-failed" });
      }
      // 置けた物の在り処は**サーバの中だけ**で解決し、pane へ差し込む文だけを作る。
      const abs = pathOf(ATTACH_DIR, stored.id, stored.ext);
      let injected = false;
      let injectReason = null;
      try {
        const r = resolvePane();
        if (r.pane) {
          // 本文だけ。Enter は送らない。
          injector.typeLiteral(r.pane, abs);
          injected = true;
        } else {
          injectReason = r.reason || "no-pane";
        }
      } catch (e) {
        injectReason = "inject-failed";
      }
      // 掃除はここで安く回す(別 job を増やさない)。消すのは形の合う古い物だけ。
      const swept = sweepOld(ATTACH_DIR, Date.now());
      return json(res, 200, attachBody(stored, injected, injectReason, swept.removed));
    }

    // ★電話から**非画像**の文書(log tail / CSV / JSON / Markdown / ソース)を置く道
    //   (2026-09-03、行 #23「非画像の添付」)。`attach` の隣に置く —— 読み方(バイト読み・
    //   413/401/404 の扱い・pane への差し込み・掃除)は画像と同じ規約で、変わるのは
    //   検め方(sniff ではなく sanitise した申告名)と応答の鍵だけ。
    // ★申告名は `?name=` に載る。ファイル名として使うのは `storeFile` が sanitise した後の
    //   値だけで、ディスク上の名前(`<id>.<ext>`)には一度も使わない(`attach` と同じ規約)。
    if (action === "attach-file" && req.method === "POST") {
      let buf;
      try {
        buf = await readBodyBytes(req, ATTACH_MAX_BYTES);
      } catch (e) {
        if (e instanceof BodyTooLarge) return tooLarge(req, res, e);
        return json(res, 400, { error: "ATTACH_READ_FAILED" });
      }
      let stored;
      try {
        stored = storeFile(buf, { baseDir: ATTACH_DIR, name: url.searchParams.get("name") });
      } catch (e) {
        // ★理由を語彙で返す(`attach` と同じ判断)。「失敗しました」だけだと、
        //   電話の持ち主は名前を直せばよいのか諦めるのかが分からない。
        const code = String(e.message || "");
        const known = ["too-large", "empty-body", "use-image-door", "binary", "bad-name"];
        if (known.includes(code)) return json(res, 400, { error: "ATTACH_REJECTED", reason: code });
        return json(res, 500, { error: "ATTACH_FAILED", reason: "store-failed" });
      }
      // 置けた物の在り処は**サーバの中だけ**で解決し、pane へ差し込む文だけを作る。
      const abs = pathOf(ATTACH_DIR, stored.id, stored.ext);
      let injected = false;
      let injectReason = null;
      try {
        const r = resolvePane();
        if (r.pane) {
          // 本文だけ。Enter は送らない。
          injector.typeLiteral(r.pane, abs);
          injected = true;
        } else {
          injectReason = r.reason || "no-pane";
        }
      } catch (e) {
        injectReason = "inject-failed";
      }
      // 掃除はここで安く回す(別 job を増やさない)。消すのは形の合う古い物だけ。
      const swept = sweepOld(ATTACH_DIR, Date.now());
      return json(res, 200, attachFileBody(stored, injected, injectReason, swept.removed));
    }

    // ★「留守中に何が起きたか」を1画面ぶんで返す(2026-08-26)。研究で判った実際の
    //   使われ方(移動中に短く覗く)に、生の流れは合っていない。知りたいのは1行の判断
    //   —— **今すぐノートを開く必要があるか**。
    //   ★`attention` は転写ではなく**生の画面**から取る。転写からの推測は当たり外れが
    //     混ざり、混ざった物で「待っています」と言い切ると一番肝心な判断が汚れる。
    if (action === "digest" && req.method === "GET") {
      const minutes = Math.min(Math.max(Number(url.searchParams.get("minutes") || 60), 1), 24 * 60);
      const nowMs = Date.now();
      const sinceMs = nowMs - minutes * 60000;
      const target = transcriptTarget();

      // 画面は在れば読む。読めない事は**異常ではなく状態**なので、そのまま unknown で運ぶ。
      let attention = "unknown";
      let screen = null;
      try {
        const r = resolvePane();
        if (r.pane) { screen = screenOf(r.pane); attention = attentionOf(screen); }
      } catch { /* 画面が読めない = unknown のまま。ここで 500 にしない */ }

      if (!target) {
        const d = digestOf([], { sinceMs, nowMs, reachedStart: true });
        const act = actionRequired(attention, d);
        return json(res, 200, digestBody(d, attention, act));
      }
      try {
        // ★`readHistoryFromPath` は表示用に均した項目を返すが、digest は**時刻**が要る。
        //   生のレコードを読むのは此処だけなので、上限は digest 側の定数に合わせる。
        const raw = readRawRecords(target, sinceMs);
        const d = digestOf(raw.records, { sinceMs, nowMs, reachedStart: raw.reachedStart });
        const act = actionRequired(attention, d);
        return json(res, 200, digestBody(d, attention, act));
      } catch (e) {
        if (e.code === "ENOENT") {
          const d = digestOf([], { sinceMs, nowMs, reachedStart: true });
          const act = actionRequired(attention, d);
          return json(res, 200, digestBody(d, attention, act));
        }
        return json(res, 500, { error: "TRANSCRIPT_UNREADABLE", errno: errnoOf(e) });
      }
    }

    if (action === "status" && req.method === "GET") {
      const r = resolvePane();
      if (r.pane) {
        // 机で開かれている会話。画面(送信可否)の真実は画面から取る。permission mode
        // だけは画面に出ないので転写から足す(対照表 #16)。
        return json(res, 200, statusBodyTmux({
          pane: r.pane,
          screen: screenOf(r.pane),
          source: r.source,
          permissionMode: currentPermissionMode(),
        }));
      }
      if (UNDECIDABLE.has(r.reason)) return json(res, 200, blockedBody(r));
      return json(res, 200, statusBodyWorker({
        worker: manager.status(sessionId),
        permissionMode: currentPermissionMode(),
      }));
    }

    if (action === "messages" && req.method === "POST") {
      speaks(res, sendResult);
      let body;
      try {
        body = JSON.parse(await readBody(req));
      } catch (e) {
        // ★ログの理由は定数で名乗る。`e.message` は構文解析器が**受け取った本文の断片**を
        //   引用する事があるので、語彙に流すと本文がログへ漏れる経路になる。
        markResult(res, { reason: "bad-body" });
        if (e instanceof BodyTooLarge) return tooLarge(req, res, e);
        return json(res, 400, { error: `bad body: ${e.message}` });
      }
      const text = typeof body.text === "string" ? body.text.trim() : "";
      if (!text) return json(res, 400, { error: "text required" });

      // ★同じ送信を2回打たない(2026-08-26)。実測: 本番で同じ本文を2回投げると
      //   2回とも verified で通り、**実画面に2回入った**。電話の `.unreachable` は
      //   「もう一度やれば通るかもしれない」と定義され下書きも残るので、
      //   タイムアウトしたが実は届いていた時、再送で同じ指示が2回実行される。
      //
      // ★鍵が無い要求は**今まで通り通す**。古い電話が黙って打てなくなるのは、
      //   防いでいる害より大きい。鍵を付けた要求だけが守られる。
      const sendId = typeof body.sendId === "string" ? body.sendId : null;
      if (sendId && !validKey(sendId)) {
        return json(res, 400, { error: "sendId must be 8-64 chars of [A-Za-z0-9_-]" });
      }
      let idemHeld = false;
      if (sendId) {
        const g = idem.begin(sendId, text);
        if (!g.go) {
          if (g.why === "duplicate") {
            // ★1回目の結果をそのまま返す。**打ち直さない。**
            //   ★status も1回目と同じ 202 にする。200 で返すと `sendResult` が
            //   「知らない形」と読んで電話に error の顔で出る —— 実際に届いている
            //   送信を失敗として見せる事になり、Tom はもう一度押す(実測 2026-08-26)。
            return json(res, 202, { ...(g.result || {}), duplicate: true });
          }
          return json(res, 409, { error: IDEM_REFUSAL[g.why], reason: g.why });
        }
        idemHeld = true;
      }

      // ★机の拒否規則(2026-08-26)。**電話が何を送っても効く唯一の層**。
      //   生の打鍵注入は万能権限なので、電話側の確認やエンドポイント単位の権限では
      //   原理的に迂回される(Codex 2026-08-26)。止めるなら打つ直前のここ。
      //   ★毎回読み直す。プロセスに抱えると、Tom が規則を足しても再起動まで効かない
      //     —— 「書いたのに効かない」はこの repo が何度も踏んだ型。
      const loaded = loadRules(DENY_FILE);
      const hit = checkDeny(text, loaded.rules);
      if (hit.denied) {
        // 予約を外す。外さないと、規則を直した後も同じ鍵で打てないままになる。
        if (idemHeld) idem.abandon(sendId);
        return json(res, 409, {
          error: denyMessage(hit),
          reason: "denied-by-desk",
          // どの規則かは返す(直せない断りは、ただの壁)。規則の一覧は返さない。
          rule: hit.id,
          route: "tmux",
        });
      }

      const found = resolvePane();

      if (!file && !found.pane) {
        // 発言も無く、開いていたペインも無い = 掴めるものが何も無い。
        // ワーカー(-p --resume)に落とすと存在しない会話を再開しようとして失敗する。
        if (idemHeld) idem.abandon(sendId);
        return json(res, 409, {
          error: "This session has no messages yet and its open pane can no longer be found.",
          route: "blocked", reason: "pane-gone", candidates: 0, source: "registry",
        });
      }

      if (UNDECIDABLE.has(found.reason)) {
        // 宛先を確定できない。送らないし、ワーカー経路にも落とさない
        // (開かれている会話を別プロセスで触ると同じ会話を2実行が読む = lost-update)。
        if (idemHeld) idem.abandon(sendId);
        return json(res, 409, { error: blockedMessage(found), ...blockedBody(found) });
      }

      if (found.pane) {
        const pane = found.pane;
        // 注入経路。入力欄(composer)が実在する時だけ送る。CHOICE(承認/上限の選択肢)には
        // 何も送らない — Enter が課金や承認になる。生成中でも composer はあるので送れる
        // (Claude Code 自身が次ターンとして扱う = 自前のキューは持たない)。
        const r = await injector.send(pane, text);
        if (r.sent) {
          // ★**打った後**に記録する。前だけだと落ちた時に永久に打てなくなり、
          //   後だけだと同時の2本が両方通る —— だから予約(begin)は打つ前、
          //   結果(finish)は打った後、と位置を分けてある。
          const sentBody = {
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
                    "Enter was sent, but the text was not confirmed as taken " +
                    "(it may remain in the composer, or the composer is no longer visible). Check the screen.",
                }
              : {}),
          };
          // 打てた。ここで初めて「済んだ」にする。再送は打ち直さずこの結果を返す。
          if (idemHeld) idem.finish(sendId, sentBody);
          return json(res, 202, sentBody);
        }
        // 送れなかった = 予約を外す。外さないと、原因を直した後も同じ鍵で打てない。
        if (idemHeld) idem.abandon(sendId);
        return json(res, 409, {
          error: SEND_REFUSAL[r.reason] || SEND_REFUSAL.unknown,
          route: "tmux", pane, screen: r.state, reason: r.reason,
        });
      }

      // 机で開かれていない会話 = ワーカー経路(-p --resume)
      // ★**子を起こす前に**断る(= 変異 W21/W22 の的)。未信頼の場所で先に spawn すると、
      //   信頼確認の画面を1枚作ってから謝る事になる —— そして電話はそれに答えられない。
      const wcwd = sessionCwd();
      const verdict = cwdVerdict(wcwd);
      if (verdict !== "ok") {
        if (idemHeld) idem.abandon(sendId);
        return json(res, 409, {
          accepted: false, route: "worker", reason: verdict,
          error: WORKER_REFUSAL[verdict],
        });
      }
      let seq;
      try {
        seq = manager.send(sessionId, text, {
          onEvent: (s, d) => pushToSubscribers(sessionId, s, d),
          cwd: wcwd,
        });
      } catch (e) {
        // 検査と spawn の間で dir が消えた(競合)。**202 を返してから死ぬより 409**。
        if (e?.code === "ENOENT") {
          if (idemHeld) idem.abandon(sendId);
          return json(res, 409, {
            accepted: false, route: "worker", reason: "cwd_missing",
            error: WORKER_REFUSAL.cwd_missing,
          });
        }
        // それ以外は握り潰さない。理由は伏せてから出す(src/redact.mjs)。
        if (idemHeld) idem.abandon(sendId);
        return json(res, 500, {
          accepted: false, route: "worker", reason: "spawn_failed",
          error: redact(String(e?.message || e)),
        });
      }
      const workerBody = { accepted: true, route: "worker", seq };
      if (idemHeld) idem.finish(sendId, workerBody);
      return json(res, 202, workerBody);
    }

    if (action === "interrupt" && req.method === "POST") {
      speaks(res, interruptResult);
      const r = resolvePane();
      if (UNDECIDABLE.has(r.reason)) {
        // 止める先を確定できない = 別の会話を止めうる。何もしない。
        return json(res, 409, { error: blockedMessage(r), ...blockedBody(r) });
      }
      if (r.pane) {
        // Escape のみ。C-c は送らない。**送信と同じ鍵**を取るので、送信の途中には割り込まない
        // (割り込むと送信側が「入力欄が空 = 届いた」と誤認する。inject.mjs の interrupt を参照)。
        const out = await injector.interrupt(r.pane);
        // ★2026-08-04、ここに在った「`pressed:false` なら 409」を**落とした**。
        //   §2.18-11 で割り込みが上限に数えられなくなった時点で、注入器が
        //   `pressed:false` を返す道が本番から消えていた(残っていたのは、差し込んだ鍵が
        //   断ってきた時だけ)。継ぎ目を撃つ変異 W6 は**素通り** —— 到達しない枝は、
        //   守っている様に見えるだけで**測れない**(`mutex.mjs` の見出しの規律)。
        //   鍵が契約を破った時は注入器が投げ、外側の catch が 500 を返す。
        // ★2026-08-03、`interrupted: true` を**押した事**でなく**止まった事**に結び直した。
        //   旧版は Escape を送れたら必ず `true` を返していた。電話には
        //   `view.mjs` が「止めました(Escape)。」と出すので、止まっていないのに
        //   止まったと読める文が出ていた。ここが分かれるのは4通り(inject.mjs の interrupt 参照):
        //     verified     … 止まったのを見た。実機の止まり方は2つあり、どちらでもここに来る:
        //                    ① `⎿ Interrupted` が増える(出力が出た後に押した時)
        //                    ② 進行の印が消えて戻らない(出力前に押すと**番ごと巻き戻る**)
        //     already-done … 押した時には自力で終わっていた(完了行が増えた)= 止めていない
        //     unverified   … 動いていたが期限内に止まりを観測できない = **まだ止まっていない**
        //     null         … 止める対象を観測できていない
        //   `interrupted` は verified の時だけ true。残り3つは false + `stopped` で理由が出る。
        return json(res, 200, {
          interrupted: out.stopped === "verified",
          stopped: out.stopped, reason: out.reason, waitedMs: out.waited,
          route: "tmux", pane: r.pane,
        });
      }
      // ★2026-08-08、ここも tmux と同じ形に揃えた(§2.64)。旧版は
      //   `{ interrupted: had }` —— `had` は「止める対象が**居た**か」であって
      //   「止まったか」ではない。表示層はこれを受けて「止めました(Escape)。」と
      //   出していたので、SIGTERM を撃っただけの状態が**止まったと読める文**になっていた。
      //   しかも Escape はこの経路では一度も押されない。tmux 側は 2026-08-03 に
      //   同じ誤りを直しており、**片方の経路にだけ残っていた**形。
      const out = await manager.interrupt(sessionId);
      return json(res, 200, {
        interrupted: out.stopped === "verified",
        stopped: out.stopped, reason: out.reason, waitedMs: out.waited,
        route: "worker",
      });
    }

    if (action === "queue" && req.method === "DELETE") {
      speaks(res, clearQueueResult);
      // 「待っている送信を捨てる」(2026-08-04)。**走っている番は止めない** ——
      // 止めるのは `interrupt` の側。2つを1つのボタンに畳むと、人が「取り消す」と読んだ操作が
      // 生成中の turn を殺す事になる。取り消せるのは**まだワーカーへ書いていない**分だけ。
      const r = resolvePane();
      if (UNDECIDABLE.has(r.reason)) {
        // 割り込みと同じ理由。宛先を確定できない = 別の会話の行列を捨てうる。何もしない。
        return json(res, 409, { error: blockedMessage(r), ...blockedBody(r) });
      }
      if (r.pane) {
        // 机で開かれている会話の行列は **Claude Code の TUI が持っている**。数も中身も
        // 観測できないし、捨てるには打鍵が要る = 電話からは撃たない。
        // ★ここで 200 + `dropped: 0` を返さない。それは「無かった」という**観測の主張**で、
        //   我々が観測していない事の反対を言う事になる。断る方が正しい。
        markResult(res, { reason: "queue-not-ours" });
        return json(res, 409, {
          error: "This session is open on the desk. Queued sends are held by Claude Code itself and can't be cancelled from the phone.",
          route: "tmux", reason: "queue-not-ours", pane: r.pane,
        });
      }
      const dropped = manager.dropQueued(sessionId, "user_cleared");
      // ★**捨てた時だけ**起こす。初版は無条件に起こしていて、自分の diff を読み直して
      //   欠陥だと分かった(2026-08-04):
      //     ・捨てた時 → `_dropQueued` の `user_dropped` が listener を通って
      //       `pushToSubscribers` → `wakeWorkerPolls` を既に呼んでいる。**二度目は空振り**。
      //     ・捨てなかった時(行列が空 / ワーカーが居ない)→ 出来事が1つも無いのに保留を
      //       起こす事になり、電話は**空の 200 を受けて即座に張り直す**。長待ち受けを
      //       選んだ理由(§2.36 = 短周期のポーリングは電池と回線を食う)を自分で壊す。
      //   残してあるのは**保険**であって主経路ではない —— 主経路が emit 側に在る事を
      //   此処で言っておかないと、次に読む人が emit を消しても平気だと読む。
      if (dropped > 0) wakeWorkerPolls(sessionId);
      return json(res, 200, { dropped, route: "worker" });
    }

    if (action === "choice" && req.method === "POST") {
      speaks(res, choiceResult);
      let body;
      try {
        body = JSON.parse(await readBody(req));
      } catch (e) {
        markResult(res, { reason: "bad-body" }); // 語彙は定数で(本文の断片をログに流さない)
        if (e instanceof BodyTooLarge) return tooLarge(req, res, e);
        return json(res, 400, { error: `bad body: ${e.message}` });
      }
      const key = typeof body.key === "string" ? body.key.trim().toLowerCase() : "";
      if (!CHOICE_KEYS.includes(key)) {
        return json(res, 400, { error: `key must be one of: ${CHOICE_KEYS.join(", ")}` });
      }
      // ★指紋は**必須**。省略を「今の画面でよい」と読むと、電話が一覧を見てから押すまでの
      //   間にメニューが入れ替わった時に、見ていない選択肢を押す事になる。省略時に
      //   サーバが今の指紋を埋める形は、この検査を丸ごと無効にするので採らない。
      const digest = typeof body.digest === "string" ? body.digest.trim() : "";
      if (!digest) {
        return json(res, 400, {
          error: "digest required(画面と一緒に返した choice.digest をそのまま添えてください)",
        });
      }

      const r = resolvePane();
      if (UNDECIDABLE.has(r.reason)) {
        return json(res, 409, { error: blockedMessage(r), ...blockedBody(r) });
      }
      if (!r.pane) {
        // ワーカー経路(別プロセスの `claude -p`)に選択画面は存在しない。
        return json(res, 409, {
          error: "This session is not open on the desk. There is no choice screen.",
          route: "worker", reason: "not-tmux",
        });
      }
      // ★危険な承認は**1タップで通さない**(2026-08-26、Codex の裁定)。
      //
      //   端末ごとの認証は、実際の脅威 —— 気が散った本人の誤タップと、注入された
      //   LLM の破壊的要求 —— を1ミリも防がない。防ぐのは「その操作に束ねた承認」。
      //   だから 30 分の書き込みモードのような**再利用できる権限**は作らず、
      //   **この画面のこの指紋にだけ**効く第2手を要求する。
      //
      //   束縛が指紋なのが肝: 構えた後に画面が変われば指紋も変わり、既存の指紋検査が
      //   そのまま断る。「危ない画面で構えて、別の画面で押す」が構造的に作れない。
      //
      //   ★判定は**今の画面**から取る。要求本文の言い分は見ない —— 見ると、
      //   注入された側が「これは危険ではない」と名乗って段を下げられる。
      const nowScreen = screenOf(r.pane);
      const nowRisk = choiceView(nowScreen).risk;
      if (nowRisk?.tier === "danger") {
        const confirm = typeof body.confirm === "string" ? body.confirm.trim() : "";
        if (confirm !== digest) {
          return json(res, 409, {
            error: "This action is hard to undo. Confirm it deliberately before it is sent.",
            route: "tmux", pane: r.pane, reason: "danger-confirm-required",
            // 何が危ないかを一緒に返す。電話が独自に文を作ると、判定と文言が2箇所に散る。
            risk: nowRisk,
            // 構え直す時に添える値。指紋そのものなので、別の画面では使えない。
            digest,
          });
        }
      }

      const out = await injector.choice(r.pane, key, { digest });
      if (!out.sent) {
        return json(res, 409, {
          error: CHOICE_REFUSAL[out.reason] || CHOICE_REFUSAL.unknown,
          route: "tmux", pane: r.pane, screen: out.state, reason: out.reason,
          // 断った時こそ**今の指紋**を返す。電話は画面を撮り直さずに、次の要求で
          // これを添えれば済む(食い違いが解けたのに押せない、を作らない)。
          ...(out.digest ? { digest: out.digest } : {}),
        });
      }
      return json(res, 200, {
        accepted: true, route: "tmux", pane: r.pane, key,
        // applied は**画面が動いたか**。「送った」を「効いた」と読まない
        // (割り込みの `stopped` と同じ規律)。
        applied: out.applied, waitedMs: out.waited,
        // 着地した画面。★`applied` だけでは「動いた」しか言えず、**どこへ動いたか**が落ちる。
        ...(out.after ? { after: out.after } : {}),
        ...(NOTE_AFTER_CHOICE[out.applied] ? { note: NOTE_AFTER_CHOICE[out.applied] } : {}),
      });
    }

    if (action === "poll" && req.method === "GET") {
      // 電話の**本線**(2026-08-04、DESIGN §2.36)。SSE ではなくこちらを使う理由は
      // 「iPhone Safari が本文を溜め込むか」を我々が測れないから(§8-4 は人の門)。
      // ★検出器は作らない。検出器の発火条件はその測れない端末でしか再現できず、
      //   「到達しない守りは、守っている様に見えるだけで**測れない**」(mutex.mjs)に真向から反する。
      //   完了した応答は中継も browser も溜め込めない —— 構造で正しい方を採る。
      const rawCursor = String(url.searchParams.get("cursor") || "");
      const rawWait = Number(url.searchParams.get("wait"));
      const waitMs = Number.isFinite(rawWait) ? Math.min(Math.max(rawWait, 0), POLL_MAX_WAIT_MS) : 0;
      const found = resolvePane();
      const route = found.pane ? "tmux" : "worker";
      markResult(res, { route });

      // ★`cache-control: no-store` は全ての返り口に付ける。中継が poll の応答を握ると、
      //   電話は**永久に同じ古い物**を受け取り続け、しかも 200 なので「繋がっている」と見える。
      if (route === "tmux") {
        const f = startFeed(sessionId, file);
        renewPollLease(sessionId, f);
        const d = pollDecision(rawCursor, "tmux", f.epoch);

        // 状態を1回だけ読む純粋な組み立て。**保留の前後で同じ物を使う**ので写しを作らない。
        const collect = () => {
          const items = [];
          let more = false;
          let cutSeq = null;
          if (d.kind === "resume") {
            const missed = f.ring.since(d.seq);
            if (missed.gap) items.push(gapItem("ring-overflow"));
            const take = missed.slice(0, POLL_MAX_ITEMS);
            more = missed.length > take.length;
            for (const e of take) {
              cutSeq = e.seq;
              if (e.data.kind === "gap") items.push(gapItem(e.data.why, e.seq));
              else items.push(messageItem({ entries: e.data.entries.map(withWho), seq: e.seq }));
            }
          } else if (d.kind === "gap") {
            items.push(gapItem(d.why));
          }
          // 栞の seq: 今回返した最後の物。1件も返していなければ据え置き(初回は今の先端)。
          const seq = cutSeq !== null ? cutSeq : d.kind === "resume" ? d.seq : f.ring.nextSeq - 1;
          // 画面は**読むだけ**。`screenBody()` は `f.work` を書き換えるので poll からは呼ばない。
          const screenChanged = f.screen && f.screen.rev !== (d.kind === "resume" ? d.screenRev : -1);
          // ★封筒そのものは `src/wire.mjs` が組む(S8-26)。此処に literal で書くと、
          //   `server.mjs` は import した瞬間に listen する為に単体検査から**一度も呼べず**、
          //   電話の Decodable との鍵名照合が写しの目視に戻る。読む状態(リングの巻き戻し・
          //   画面の版)は此処に残し、渡すのは**既に決まった観測値**だけ。
          //   `display.choice` を `screen` に揃える規則も builder 側の1箇所に在る。
          return pollBodyTmux({
            items,
            screen: screenChanged ? f.screen.body : null,
            cursor: formatPollCursor({
              route: "tmux",
              token: f.epoch,
              seq,
              screenRev: f.screen ? f.screen.rev : d.kind === "resume" ? d.screenRev : 0,
            }),
            more,
          });
        };

        const first = collect();
        if (first.items.length > 0 || first.screen || waitMs === 0 || f.wakers.size >= POLL_MAX_HELD) {
          // ★上限を超えた時は 429 にせず**即座に返す**。電話が壊れるより遅い方がまし
          //   (429 を返すと電話は「切れた」と読んで帯を赤くし、Tom は理由の無い障害を見る)。
          res.setHeader("cache-control", "no-store");
          return json(res, 200, first);
        }

        // ---- 保留(long-poll)。此処から下は `await` を1つも挟まない ----------------
        // node は単一 thread なので、**待ち手の登録を先・状態の読み取りを後**にしておけば
        // その隙間に起きた出来事は取りこぼせない。上の `collect()` は既に走っているので、
        // 登録より前に起きた分は上で返っている。
        let settled = false;
        let timer = null;
        const waker = () => finish();
        const finish = () => {
          if (settled) return; // 冪等。close / timeout / 起床 が同時に来ても1回しか返さない
          settled = true;
          if (timer) clearTimeout(timer);
          f.wakers.delete(waker);
          if (res.writableEnded || res.destroyed) return;
          try {
            res.setHeader("cache-control", "no-store");
            json(res, 200, collect());
          } catch {
            /* 既に切れている */
          }
        };
        f.wakers.add(waker);
        timer = setTimeout(finish, waitMs);
        timer.unref();
        req.on("close", () => {
          // 電話がトンネルに入った / 画面を閉じた。待ち手を必ず外す(残すと feed が止まらない)。
          if (settled) return;
          settled = true;
          clearTimeout(timer);
          f.wakers.delete(waker);
          stopFeedIfIdle(sessionId);
        });
        return;
      }

      // ---- ワーカー経路 --------------------------------------------------------
      const d = pollDecision(rawCursor, "worker", manager.generation);
      const collectW = () => {
        const items = [];
        let more = false;
        let seq = d.kind === "resume" ? d.seq : 0;
        if (d.kind === "gap") {
          items.push(gapItem(d.why));
          // 読み直させた上で**先端**に合わせる。★「件数」を seq に使わない ——
          //   リングが溢れた後は件数 < 先端 seq になり、既に消えた番号から再開する事になる。
          const all = manager.eventsSince(sessionId, 0);
          seq = all.length ? all[all.length - 1].seq : 0;
        } else {
          const from = d.kind === "resume" ? d.seq : 0;
          const missed = manager.eventsSince(sessionId, from);
          if (missed.gap) items.push(gapItem("ring-overflow"));
          const take = missed.slice(0, POLL_MAX_ITEMS);
          more = missed.length > take.length;
          for (const e of take) {
            seq = e.seq;
            // ★ワーカー経路の item は `entries` ではなく `event`(我々が起こした子の NDJSON
            //   1行)。`whoOf` の材料になる `role` を持たないので**語を足さない** ——
            //   ここに `display` を足すと、無い物から作った名前が付く。
            items.push(messageItem({ event: e.data, seq: e.seq }));
          }
          // ★初回(栞なし)は**先端に合わせず 0 から返す**。tmux 経路と違い、ワーカーの出来事は
          //   我々が起こした物なので /history に載らない種類(worker_closed 等)が在る。
        }
        // ★封筒は `src/wire.mjs`(S8-26)。tmux 経路との差が `display` の有無1つだけである事は
        //   builder の側で見える —— 此処に2つの literal を並べていた間は、差が**意図か
        //   書き漏れか**を読む側が判別できなかった。
        return pollBodyWorker({
          items,
          // ★数は**持ち主から貰う**。ring からは復元できない —— 積む時は `user_queued` が
          //   出るが、降ろす時は `entry.queue.shift()` して書くだけで**何も出ない**
          //   (worker.mjs の `result` 処理)。事象を数えれば増える一方の数になる。
          //   `collectW` は保留の前後で同じ物を使うので、起きた時点の値が返る。
          queued: manager.status(sessionId).queued,
          cursor: formatPollCursor({ route: "worker", token: manager.generation, seq }),
          more,
        });
      };

      const firstW = collectW();
      let wset = workerWakers.get(sessionId);
      if (firstW.items.length > 0 || waitMs === 0 || (wset && wset.size >= POLL_MAX_HELD)) {
        res.setHeader("cache-control", "no-store");
        return json(res, 200, firstW);
      }
      if (!wset) {
        wset = new Set();
        workerWakers.set(sessionId, wset);
      }
      let settledW = false;
      let timerW = null;
      const wakerW = () => finishW();
      const finishW = () => {
        if (settledW) return;
        settledW = true;
        if (timerW) clearTimeout(timerW);
        wset.delete(wakerW);
        pruneWorkerWakers(sessionId, wset);
        if (res.writableEnded || res.destroyed) return;
        try {
          res.setHeader("cache-control", "no-store");
          json(res, 200, collectW());
        } catch {
          /* 既に切れている */
        }
      };
      wset.add(wakerW);
      timerW = setTimeout(finishW, waitMs);
      timerW.unref();
      req.on("close", () => {
        if (settledW) return;
        settledW = true;
        clearTimeout(timerW);
        wset.delete(wakerW);
        pruneWorkerWakers(sessionId, wset);
      });
      return;
    }

    if (action === "stream" && req.method === "GET") {
      // ★経路の判定を **`writeHead` より前**へ動かした(2026-08-03、§3-U)。理由は2つ:
      //   ① ログの1行に `route` を載せる為。行が出る合図は `writeHead` なので、判定が後だと
      //      「電話が繋がった」の行に**経路が入らない** = §3-W が刺さった当の欄が欠ける。
      //   ② ここで例外が出た時、まだ SSE の頭を書いていないので外側の catch が 500 を返せる。
      //      従来は 200 の SSE 頭を書いた後だったので、失敗が**無言の空ストリーム**に化けた。
      const found = resolvePane();
      markResult(res, { route: found.pane ? "tmux" : "worker" });
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

      // 経路は購読の時点で決める(判定は上の `found`)。机で開かれている会話(tmux)は
      // 画面と jsonl を見に行く。開かれていなければ従来通りワーカーの出来事を流す。
      if (found.pane) {
        const f = startFeed(sessionId, file);
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
          // ★ring には本文と gap の**両方**が並ぶ(2026-08-04)。種別を見ずに `message` として
          //   再生すると、取りこぼしの合図が「中身の無い本文」に化けて消える。
          for (const e of missed) {
            if (e.data.kind === "gap") {
              sendEvent(res, { id: `${f.epoch}.${e.seq}`, event: "gap", data: { rereadHistory: true, why: e.data.why } });
            } else {
              sendEvent(res, { id: `${f.epoch}.${e.seq}`, event: "message", data: { entries: e.data.entries } });
            }
          }
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
      // ★理由は `internal` と名乗るだけ。生の `e.message` をログの語彙に流さない ——
      //   ここは自由書式が入りうる唯一の口で、中身が何であれ**欄に入れない**のが fail-closed。
      //   電話へ返す本文は従来どおり(そちらは Tom 自身しか見ない面)。
      markResult(res, { reason: "internal" });
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
    // 「見えない」は待機中の意味にならない(1枚あたり 18-39% 取りこぼす)ので印にも文言にもしない。
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

/**
 * ログに**そのまま出してよいパス**(それ以外は `(other)` に畳む = 生のパスを disk に残さない)。
 * ★配る表は写さずに `STATIC` から作る。固定の api 4本だけは此処に書くしか無いので、
 *   `test/reqlog.test.mjs` が server.mjs の `path === "…"` を読んで**両方向**に突き合わせる
 *   (足りない = 新しい道が `(other)` に化ける / 余る = 消えた道が一覧に残っている)。
 */
const LOG_PATHS = new Set([
  ...STATIC.keys(),
  "/healthz",
  "/api/sessions",
  "/api/account",
  "/api/account/select",
  "/api/account/next",
  "/api/roots",
]);

/**
 * 電話から新しい会話を始める(tmux の window を 1 枚起こして `rc-claude` を exec)。
 * `POST /api/sessions/<id>/new` と `POST /api/roots/<i>/new` の 2 口が共有する(2026-09-03)。
 * @returns {{window: string, pane: string} | null}  作れなければ null(呼び手が 502 `tmux_failed`)
 *
 * ★window 名は**回復用の `phone` と分ける**。あちらは「1 枚だけ在る」を冪等の鍵に
 *   しているので、同じ名前で足すと 60 秒ごとの回復が此の window を自分の物と誤認する。
 */
function startPhoneWindow(cwd) {
  const name = `phone-new-${Date.now().toString(36)}`;
  // ★`RC_PHONE_LAUNCH=1`(2026-09-03、Codex 所見 #3 の後追い): 起動側(`rc-claude`)が物理 cwd を台帳と
  //   突き合わせる合図。机の realpath 検査と tmux の chdir は別の瞬間なので、最後の瞬間にもう一度見る。
  //   手で起動する `rc-claude` には此の合図が無い = 台帳の外でも今までどおり動く。
  const out = tmuxRunner.run([
    "new-window", "-d", "-P", "-F", "#{window_id} #{pane_id}",
    "-t", TMUX_SESSION, "-n", name, "-c", cwd, `RC_PHONE_LAUNCH=1 exec ${CLAUDE_LAUNCHER}`,
  ]);
  const ids = String(out || "").trim().split(/\s+/);
  if (ids.length < 2 || !ids[0].startsWith("@")) return null;
  return { window: ids[0], pane: ids[1] };
}

// ★起動に失敗した時に**読める行**を残す(2026-08-02)。
// これが無いと listen の失敗は `uncaughtException` に落ち、`fatal: Error: listen
// EADDRINUSE ...` という一行になる。常設(launchd)にすると読むのは移動中の Tom で、
// その場に手元の機械は無い。既に上がっている物が居るのか、権限で塞がれているのかを
// **ログの一行で**決着させる。exit(1) は保つ = 半端に上がるより落ちている方が安全
// (電話には「繋がらない」として出る。中途半端に応答する物が居るより判りやすい)。
server.on("error", (e) => {
  const why = e && e.code === "EADDRINUSE"
    ? `port ${PORT} is already in use. Check for a duplicate rc-backend`
    : e && e.code === "EACCES"
      ? `no permission to open port ${PORT}`
      : `listen failed: ${e && e.message}`;
  // ★人が読む散文と**機械が読む code** を同じ行に両方残す(2026-08-02 に外して学んだ)。
  //   最初この行は code を散文に翻訳して捨てていた。その結果 e2e 側の環境死判定
  //   (`/EADDRINUSE|EACCES/` を探す)が**原理的に当たらない**状態になり、本物の
  //   port 衝突を起こしても関門は「環境死ではない」と答えた = 当たらない探し物は
  //   「無い」と報告される、をまた踏んだ。散文だけにすると、翻訳した瞬間に
  //   下流の機械読みが全部黙って外れる。
  console.error(`[rc-backend] Cannot start — ${why} (${(e && e.code) || "unknown code"})`);
  process.exit(1);
});

server.listen(PORT, BIND, () => {
  // ★出すのは**実際に bind した番号**であって設定値ではない(2026-08-02)。
  // 差が出るのは `RC_PORT=0`(= カーネルに空きを選ばせる)の時で、検査がこの行から
  // 番号を読む。設定値をそのまま出していると `:0` と書かれた無意味なログになり、
  // 常設のログとしても「どこで待っているか」を答えられない行になる。
  const actual = server.address()?.port ?? PORT;
  console.log(`[rc-backend] listening on http://${BIND}:${actual} (key: ${KEY_FILE})`);

  // ★起動直後の1発目を冷やさない(2026-08-27)。一覧のメタキャッシュは in-process なので
  //   再起動のたびに空になり、その後の**最初の実要求**が全件読みを払う
  //   (friday 実測: 冷 0.50s / 温 0.06s)。再起動は実質デプロイ時だけだが、
  //   デプロイ直後に電話を開いた人がちょうどその1回を踏む —— それは Tom が
  //   「最初の読み込みが異様に長い」と名指しした症状そのものなので、誰も待っていない
  //   今のうちに払っておく。
  //   ★`listen` を待たせない。温めは小分けにして事象ループへ譲るので、その最中に来た
  //     要求も普通に捌ける(詳細と、そう作り直した経緯は `prewarmListing` の doc)。
  //   ★失敗は落とさない。温めは最適化であって、起動を落とす理由にならない。
  //     ただし黙らない —— 読めなかった本数を出す(Codex 2026-08-27:「harmless は強すぎる」)。
  if (process.env.RC_PREWARM !== "0") {
    prewarmListing();
  }
});

/**
 * 一覧のメタキャッシュを、**事象ループを止めずに**温める。
 *
 * ★2026-08-27 の第1版は `scanSessions()` を1回呼ぶだけだった。Codex が完了を認めず、
 *   測ったら正しかった: 走査は全部同期なので、**ポートが開いた後に 489ms(FS が冷えて
 *   いれば 2537ms)イベントループが止まる**。実測でその窓に投げた `healthz` は 483ms
 *   待たされた —— 直前に `/api/account` で潰したのと**同じ種類の凍結を、自分で作っていた**。
 *
 *   `listen` の前へ動かす案は採らない: その間ポートが無いので、来た電話は「待つ」ではなく
 *   **接続拒否**になる。500ms 待つより悪い。
 *
 *   採ったのは小分け + 譲り。1 slice ごとに `setImmediate` で戻すので、温めの最中に来た
 *   要求は普通に捌ける(その要求が同じ file を1回読み直すだけで、正しさには関与しない)。
 *
 * ★`scanSessions` を呼ばず読み口(`readMetaFromPath`)だけを共有している事の代償を明記:
 *   走査側の畳み方(fork の頭 / limit / 篩)が変わっても此処は追随しない。だが此処が
 *   温めるのは**キャッシュだけ**で、鍵は inode + 指紋なので、ずれた時に起きるのは
 *   「温め損ねる」だけ。**間違った答えを返す道は無い**。
 */
function prewarmListing() {
  const SLICE = 400; // 1 slice = 数十 ms 程度。譲る回数と総時間の釣り合いで決めた
  const t0 = Date.now();
  let files;
  try {
    files = [];
    for (const slug of readdirSync(PROJECTS_DIR)) {
      const dir = join(PROJECTS_DIR, slug);
      try {
        for (const f of readdirSync(dir)) if (f.endsWith(".jsonl")) files.push(join(dir, f));
      } catch { /* 消えた dir は温めを落とさない */ }
    }
  } catch (e) {
    console.warn(`[rc-backend] 一覧の事前温めを開始できません(最初の要求が冷えたまま払う): ${e && e.message}`);
    return;
  }
  let i = 0, read = 0, failed = 0;
  metaCache.beginScan();
  metaCache.ensureCapacity(files.length);
  const step = () => {
    const end = Math.min(i + SLICE, files.length);
    for (; i < end; i += 1) {
      try {
        const st = statSync(files[i]);
        if (metaCache.get(st) === null) { metaCache.set(st, readMetaFromPath(files[i])); read += 1; }
      } catch { failed += 1; } // 消えた / 読めない file は温めの対象外。要求側が改めて扱う
    }
    if (i < files.length) { setImmediate(step); return; }
    // ★掃除はしない。此処は走査ではないので「見なかった = 消えた」と言えない。
    const ms = Date.now() - t0;
    if (failed > 0) {
      console.warn(`[rc-backend] 一覧を先に温めた(${failed}本は読めず、その分は最初の要求が払う): `
        + `${files.length}本 read=${read} ${ms}ms`);
    } else {
      console.log(`[rc-backend] 一覧を先に温めた: ${files.length}本 read=${read} ${ms}ms`);
    }
  };
  setImmediate(step);
}
