// 会話の作業木の**未コミットの差分の中身**(対照表 #4「差分を電話で読む」)。
//
// 一覧の ± バッジ(#5)は「幾ら変わったか」だけを出す。此処は其の続きで、
// **何が変わったか**を返す —— ファイル単位に構造化した、読む為の形。
//
// ── 設計 ─────────────────────────────────────────────────────────────────
// ★**読むだけ**。撃つ git は `diff` だけで(通常 2 本、器から溢れた時だけ `--numstat` が
//   足される)、書く動詞は 1 つも無い。さらに:
//     `--no-ext-diff` / `--no-textconv`
//         repo の設定(`diff.external` / `textconv` フィルタ)は**任意のプログラムを
//         走らせる口**。差分を読む為に、その repo が指定した実行ファイルを此の机で
//         起動する道を残さない。読むだけ = 他人の設定で他人のコードを走らせない。
//     `-c core.fsmonitor=false` / `--ignore-submodules=all`(2026-09-03、Codex #1)
//         `core.fsmonitor=<path>` は `git diff` の index refresh で**実行される**(Codex が
//         子プロセスで再現)。`-c` は repo 設定より強いので、其の口を閉じる。submodule の
//         差分機構も同じ理由で切る(読みたいのは此の木だけ)。
//     `GIT_*` の環境変数を渡さない(同日)
//         `GIT_DIR` / `GIT_WORK_TREE` / `GIT_EXTERNAL_DIFF` / `GIT_CONFIG_*` が机の環境に
//         居れば、cwd と違う木を読む・外部プログラムを走らせる。渡すのは此処で決めた
//         2 つ(`LC_ALL` と `GIT_OPTIONAL_LOCKS`)だけ。
//     `.git` が symlink なら読まない(同日、`unsafe_repo`)
//         `.git` の行き先を差し替えると**別の dir を diff する**。worktree の `.git` は
//         file(gitfile)であって symlink ではないので、Tom の木は之で止まらない。
//     `GIT_OPTIONAL_LOCKS=0`
//         `git diff` は既定で index を更新して書き戻す(= `.git/index.lock` を取る)。
//         同じ作業木では Claude Code 本人と Tom の手が同時に git を叩いている。
//         電話が覗いただけで机の git が `index.lock` で失敗する形にはしない。
//     `LC_ALL=C`
//         下の `notARepo()` が git の一文を読むので、言語を固定する。読まない形
//         (`rev-parse` を先に撃つ)も在るが、それは往復が 1 本増える。
//     `--git-dir` / `--work-tree` の明示 + 設定の filter driver の上書き(同日、`locateRepo` の註)
//         repo の設定(`core.worktree`)や `.git` の差し替えで別の木を読む道と、`.gitattributes` の
//         `filter=<driver>` で clean filter が走る道を閉じる(どちらも本物の git で再現してから)。
//   ★残る口(塞いでいない、註として残す): config の include / alternates で**読む**範囲が木の
//     外へ出る道(実行は伴わない)。cwd は Tom 自身の会話の cwd で、其処に敵対的な設定が在る =
//     其の会話の agent が既に乗っ取られている状態なので、此処は defense-in-depth。
//
// ★**生の diff 文字列を丸ごと返さない**。電話は「ファイルの一覧 → その中の塊」で
//   読むので、其の形に机で畳む。文字列のまま渡すと、色分けと横スクロールの為に
//   電話側が 2 つ目の parser を持つ事になり、必ず机とズレる。
//
// ★**切ったら切ったと言う**。上限は 3 つ(1 ファイル / 全体 / ファイル数)で、
//   どれに当たっても `truncated: true` を立てる。★数(`added` / `removed`)は
//   **切る前の全文から**数える —— 本文を途中で止めても「幾ら変わったか」は嘘を
//   吐かない。此の非対称は意図的で、電話は「+42 -18(表示は途中まで)」と言える。
//   ★行の費用は **text の bytes + 1**(記号と改行の分)。空の追加行が 0 byte で
//     天井をすり抜けない為(Codex #1 が 1 byte 上限で空行 10,000 本を通して見せた)。
//   ★器から溢れた時(maxBuffer)は部分の stdout しか無いので、parse した数は下限に
//     なる。其の時だけ `--numstat` を 1 本 足して数を**正確に**取り直す(出力は小さい)。
//     `totalBytes` は読めた分の bytes = 溢れた時は下限(封筒の註に書いた)。
//
// ★読めない事は**異常ではなく状態**。cwd が無い / dir が消えた / git 管理外 /
//   git が落ちた / `.git` が symlink、は `reason` を名乗って 200 で返す(一覧の実装と
//   同じ判断)。例外を上へ投げると、電話は「会話が壊れた」と読む —— 実際には repo が
//   無いだけ。★index の側だけ落ちて**何も読めなかった**時も `reason` を名乗る
//   (2026-09-03。以前は `files:[] reason:null truncated:true` で、切れた成功と見分けが
//   付かなかった = Codex #1 の 5)。作業木の側が読めていれば其れは出し、切ったと言う。
//
// ★同時実行(2026-09-03、Codex #1 の 4)。同じ cwd への要求は**1 本に合流**し、
//   全体で同時に走る git は `MAX_CONCURRENT` 本まで(残りは順番待ち)。電話が画面を
//   連打しても、机で git が要求の数だけ増えない。
import { execFile as nodeExecFile } from "node:child_process";
import { existsSync, lstatSync, readFileSync, realpathSync } from "node:fs";
import { dirname, join } from "node:path";
import { promisify } from "node:util";

const execFileAsync = promisify(nodeExecFile);

/**
 * 天井。**bytes で持つ**(行数ではない)。1 行が 10 万字の minified な file が
 * 実在するので、行数で切ると天井が天井にならない。
 */
export const DIFF_LIMITS = Object.freeze({
  /** 1 ファイルの本文(hunk の行の費用の合計)。之を超えたら其の file だけ切る。 */
  maxFileBytes: 64 * 1024,
  /** 全体の本文。之を超えたら以後の file は本文なしで並べる。 */
  maxTotalBytes: 256 * 1024,
  /** ファイル数。1 つの commit で 300 file を電話で読む事は無い。 */
  maxFiles: 300,
  /** git 1 本の上限(ms)。動かない repo で電話を待たせない。 */
  timeoutMs: 4000,
  /** git の出力を受ける器。之を超えたら部分の stdout を読んで `truncated` を立てる。 */
  maxBuffer: 8 * 1024 * 1024,
});

/** 同時に走らせる git の上限(全 cwd 合計)。残りは順番待ち。 */
export const MAX_CONCURRENT = 2;

/**
 * 順番待ちの上限(2026-09-03、Codex #1 の 4 の続き)。之を超えた要求は待たずに `busy` を返す
 * (机の口は 503)。無制限に並べると、電話の連打や別の cwd の同時要求で待ち行列だけが伸び、
 * 「いつか返る」が「返らない」と区別できなくなる。8 = 電話 1 台が現実に積める数より多く、
 * git 1 本の上限(4 秒)× 4 巡 = 最悪 16 秒で捌ける数。
 */
export const MAX_WAITING = 8;

/** 1 行の費用。text の bytes + 記号 1 byte。空行も 0 にならない。 */
export function lineCost(text) {
  return Buffer.byteLength(String(text ?? ""), "utf8") + 1;
}

/** `--- a/x` / `+++ b/x` から path を取る。`/dev/null` は null(新規 / 削除の側)。 */
function pathFromMarker(line) {
  const raw = line.slice(4).trim();
  if (!raw || raw === "/dev/null") return null;
  // 既定の接頭辞 `a/` `b/` を落とす。落とせない形(`--no-prefix` で撃たれた等)は
  // そのまま通す —— 判らない物を切り詰めない。
  return /^[ab]\//.test(raw) ? raw.slice(2) : raw;
}

/**
 * `diff --git a/x b/x` から path を取る(binary の様に `+++` が無い時の予備)。
 *
 * ★空白を含む path は此処では正しく割れない(git は特殊文字を含む path を
 *   引用符で包むが、空白だけでは包まない)。**最後の ` b/` で割る**ので、
 *   `foo b/bar` の様な意地の悪い名前だけが崩れる。崩れても崩れた文字列を
 *   そのまま出す = 存在しない path を捏造しない。
 */
function pathFromGitHeader(line) {
  const rest = line.slice("diff --git ".length);
  const at = rest.lastIndexOf(" b/");
  if (at < 0) return rest.trim() || null;
  return rest.slice(at + 3).trim() || null;
}

/**
 * `git diff` の出力 1 本を、ファイル単位の構造へ畳む。**純関数**。
 *
 * ★保持する本文は file ごとに `limits.maxFileBytes` まで(其れを超えた行は数えるだけで
 *   持たない)。8 MiB の出力を丸ごと object にしてから切る形(Codex #1 の 3)を止める為。
 *   数(`added` / `removed` / `bytes`)は**全部**数える。
 *
 * @param {string} text  git の標準出力
 * @param {boolean} staged  index の側か(`--cached` で撃った物か)
 * @param {object} [limits]  `maxFileBytes` だけ読む
 * @returns {Array<{path,staged,binary,added,removed,hunks,bytes}>}
 */
export function parseDiff(text, staged, limits = DIFF_LIMITS) {
  const keep = Number.isFinite(limits?.maxFileBytes) ? limits.maxFileBytes : DIFF_LIMITS.maxFileBytes;
  const files = [];
  let cur = null;
  let hunk = null;
  let retained = 0; // 今の file で持っている本文の費用

  const closeFile = () => {
    if (cur) files.push(cur);
    cur = null;
    hunk = null;
    retained = 0;
  };

  for (const line of String(text ?? "").split("\n")) {
    if (line.startsWith("diff --git ")) {
      closeFile();
      cur = {
        path: pathFromGitHeader(line),
        staged,
        binary: false,
        added: 0,
        removed: 0,
        hunks: [],
        bytes: 0,
      };
      continue;
    }
    if (!cur) continue; // 頭書き(`diff --git` )より前の行は捨てる
    if (line.startsWith("+++ ")) {
      const p = pathFromMarker(line);
      if (p) cur.path = p;
      continue;
    }
    if (line.startsWith("--- ")) {
      // `+++` が `/dev/null`(= 削除)の時だけ此方が名前を持つ。順序は git が
      // 必ず `---` → `+++` なので、`+++` 側が後から上書きする形で正しい。
      const p = pathFromMarker(line);
      if (p && !cur.path) cur.path = p;
      continue;
    }
    if (line.startsWith("@@")) {
      hunk = { header: line, lines: [] };
      cur.hunks.push(hunk);
      continue;
    }
    // 2 進の file は hunk を持たない。git は `Binary files … differ` か
    // `GIT binary patch` を出す。★中身は運ばない(電話で読める物ではない)。
    if (line.startsWith("Binary files ") || line.startsWith("GIT binary patch")) {
      cur.binary = true;
      hunk = null;
      continue;
    }
    if (!hunk) continue; // `index …` / `new file mode …` 等の頭書き
    let entry = null;
    if (line.startsWith("+")) {
      cur.added += 1;
      entry = { kind: "add", text: line.slice(1) };
    } else if (line.startsWith("-")) {
      cur.removed += 1;
      entry = { kind: "del", text: line.slice(1) };
    } else if (line.startsWith(" ")) {
      entry = { kind: "ctx", text: line.slice(1) };
    } else if (line.startsWith("\\")) {
      // `\ No newline at end of file`。数には入れない(足しても引いてもいない)が、
      // 落とすと「最後の行に改行が無い」が電話から消える。文脈として運ぶ。
      entry = { kind: "ctx", text: line };
    } else {
      // 出力の末尾の素の空行など。hunk の中の空行は git が必ず ` ` を頭に付ける。
      continue;
    }
    const cost = lineCost(entry.text);
    cur.bytes += cost;
    // ★持つのは天井まで。超えた行は数だけ(上で足した)。`capFiles` が f.bytes > 天井を
    //   見て truncated を立てるので、此処で印は要らない。
    if (retained + cost <= keep) {
      retained += cost;
      hunk.lines.push(entry);
    }
  }
  closeFile();
  return files;
}

/**
 * 天井を当てる。**数は切る前の物を残す**(この関数は `hunks` しか削らない)。
 *
 * @returns {{files: Array, truncated: boolean}}
 */
export function capFiles(files, limits = DIFF_LIMITS) {
  let total = 0;
  let truncated = false;
  const out = [];
  for (const f of files) {
    if (out.length >= limits.maxFiles) { truncated = true; break; }
    const room = Math.min(limits.maxFileBytes, Math.max(0, limits.maxTotalBytes - total));
    if (f.bytes <= room) {
      total += f.bytes;
      out.push({ ...f, truncated: false });
      continue;
    }
    // 此の file は入り切らない。**行の途中では切らない** —— 半分の行を出すと、
    // 読んだ人が「そういうコードだ」と読む。行の境で止めて、切った事を名乗る。
    truncated = true;
    let used = 0;
    const hunks = [];
    let stop = false;
    for (const h of f.hunks) {
      if (stop) break;
      const lines = [];
      for (const l of h.lines) {
        const b = lineCost(l.text);
        if (used + b > room) { stop = true; break; }
        used += b;
        lines.push(l);
      }
      if (lines.length) hunks.push({ header: h.header, lines });
    }
    total += used;
    out.push({ ...f, hunks, truncated: true });
  }
  return { files: out, truncated };
}

/** git が「此処は repo ではない」と言ったか。★言語は `LC_ALL=C` で固定してある。 */
export function notARepo(stderr) {
  return /not a git repository/i.test(String(stderr ?? ""));
}

/**
 * `git diff --numstat` の出力を `path -> {added, removed}` に畳む。**純関数**。
 * 行の形は `<added>\t<removed>\t<path>`、2 進は `-\t-\t<path>`(数は持たない = null)。
 * rename の `{a => b}` 形は `--numstat` では出ない(`-M` を渡していない)。
 */
export function parseNumstat(text) {
  const out = new Map();
  for (const line of String(text ?? "").split("\n")) {
    const m = /^(\d+|-)\t(\d+|-)\t(.+)$/.exec(line);
    if (!m) continue;
    const num = (s) => (s === "-" ? null : Number(s));
    out.set(m[3], { added: num(m[1]), removed: num(m[2]) });
  }
  return out;
}

/** 机の環境から `GIT_*` を落とし、此処で決めた物だけ足す。 */
function gitEnv(base = process.env) {
  const env = {};
  for (const [k, v] of Object.entries(base)) {
    if (k.startsWith("GIT_")) continue;
    env[k] = v;
  }
  env.LC_ALL = "C";
  env.GIT_OPTIONAL_LOCKS = "0";
  return env;
}

// ── 同時実行の抑え ────────────────────────────────────────────────────────
const inflight = new Map(); // cwd -> Promise(同じ cwd は合流)
let running = 0;
const waiting = []; // 順番待ち(FIFO)

/**
 * 席を 1 つ取って `fn` を走らせる。席が無ければ順番待ち。
 *
 * @param {Function} fn
 * @param {{signal?: AbortSignal, maxWaiting?: number}} [o]
 *   `signal` = 要求の側が居なくなった合図(HTTP の `close`)。**待っている間だけ**効く —— 待ち行列から
 *   外れ、git は 1 本も起こさない。走り始めた後は効かない(同じ cwd の他の要求が其の結果を待って
 *   いる事が在るので、途中で殺すと其方が巻き添えになる。git 1 本は `timeoutMs` で上から切れる)。
 *   `maxWaiting` = 待ち行列の上限。超えていれば待たずに `BUSY` で reject。
 */
function withSlot(fn, o = {}) {
  return new Promise((resolve, reject) => {
    const signal = o.signal;
    const maxWaiting = Number.isFinite(o.maxWaiting) ? o.maxWaiting : MAX_WAITING;
    if (signal?.aborted) { reject(abortError()); return; }
    let entry = null;
    const onAbort = () => {
      const i = waiting.indexOf(entry);
      if (i >= 0) waiting.splice(i, 1);   // 待っている間だけ外せる
      reject(abortError());
    };
    const go = () => {
      signal?.removeEventListener("abort", onAbort);
      running += 1;
      Promise.resolve()
        .then(fn)
        .then(resolve, reject)
        .finally(() => {
          running -= 1;
          const next = waiting.shift();
          if (next) next();
        });
    };
    if (running < MAX_CONCURRENT) { go(); return; }
    if (waiting.length >= maxWaiting) { reject(busyError()); return; }
    entry = go;
    waiting.push(entry);
    signal?.addEventListener("abort", onAbort, { once: true });
  });
}

function abortError() { const e = new Error("diff request aborted while waiting"); e.code = "DIFF_ABORTED"; return e; }
function busyError() { const e = new Error("too many diff requests waiting"); e.code = "DIFF_BUSY"; return e; }

/** 検査用: 今 走っている本数と、順番待ちの本数。 */
export function _inflight() {
  return { running, waiting: waiting.length, keys: [...inflight.keys()] };
}

/**
 * 作業木の未コミットの差分を読む。**書く動詞を撃たない**。
 *
 * @param {string} cwd
 * @param {object} [o]
 * @param {Function} [o.exec]   `execFile` の promise 版(検査で差し替える)
 * @param {Function} [o.exists] dir の実在(同上)
 * @param {Function} [o.lstat]  `.git` の正体を見る(同上)。無ければ「無い」と同じ扱い
 * @param {object}   [o.limits]
 * @param {AbortSignal} [o.signal]  要求の側が居なくなった合図。待っている間だけ効く(`withSlot` の註)
 * @param {number}   [o.maxWaiting] 待ち行列の上限(検査で差し替える)
 * @returns {Promise<{files: Array, truncated: boolean, totalBytes: number, reason: string|null}>}
 *   ★待ち行列が一杯なら `reason: "busy"`、待っている間に要求が消えたら `reason: "aborted"`
 *     (どちらも git を 1 本も起こしていない。口(`server.mjs`)は `busy` を 503 にし、`aborted` は
 *     相手が居ないので何も書かない)。
 */
export async function readWorkingDiff(cwd, o = {}) {
  const exists = o.exists ?? existsSync;
  const empty = (reason) => ({ files: [], truncated: false, totalBytes: 0, reason });

  if (typeof cwd !== "string" || !cwd) return empty("no_cwd");
  if (!exists(cwd)) return empty("cwd_missing");

  // ★同じ cwd への要求は合流する。鍵は cwd の文字列(正規化はしない —— 別の綴りは
  //   別の要求で良い。合流は最適化であって正しさの条件ではない)。
  //   合流した要求には `signal` を効かせない —— 走っている 1 本は先客の物。
  const key = cwd;
  if (inflight.has(key)) return inflight.get(key);
  const p = withSlot(() => readWorkingDiffOnce(cwd, o), { signal: o.signal, maxWaiting: o.maxWaiting })
    .catch((e) => {
      if (e?.code === "DIFF_BUSY") return empty("busy");
      if (e?.code === "DIFF_ABORTED") return empty("aborted");
      throw e;
    })
    .finally(() => {
      if (inflight.get(key) === p) inflight.delete(key);
    });
  inflight.set(key, p);
  return p;
}

/**
 * cwd から repo の場所を**自分で**決める(2026-09-03、Codex #1 の 2 の残り)。
 *
 * git の自動発見に任せると、repo の設定(`core.worktree`)や `.git` の差し替えで**別の dir を
 * diff する**(実測: `core.worktree=/victim` の repo で素の `git diff` は victim の木を読んだ)。
 * 此処で決めた `--git-dir` / `--work-tree` を明示すれば、設定より CLI が勝つ。
 *
 * 規則(全部「読まない側に倒す」向き):
 *   - cwd を realpath する(symlink 越しの綴りを本物の場所に直す)
 *   - `.git` を cwd から祖先へ探す。symlink なら `unsafe_repo`。dir なら其れが git-dir。
 *     file(gitfile、worktree の形 `gitdir: <path>`)なら其の行き先を realpath し、dir で無ければ
 *     `unsafe_repo`。見つからなければ `not_a_repo`(git を撃たない)。
 *   - work-tree は `.git` を持つ祖先。cwd が repo の中の子 dir でも、diff は repo の根から。
 *
 * @returns {{root: string, gitDir: string} | {reason: string}}
 */
export function locateRepo(cwd, o = {}) {
  const realpath = o.realpath ?? ((p) => realpathSync(p));
  const lstat = o.lstat ?? ((p) => { try { return lstatSync(p); } catch { return null; } });
  const readFile = o.readFile ?? ((p) => readFileSync(p, "utf8"));
  let real;
  try { real = realpath(cwd); } catch { return { reason: "cwd_missing" }; }
  let dir = real;
  for (let depth = 0; depth < 64; depth += 1) {
    const dotGit = join(dir, ".git");
    const st = lstat(dotGit);
    if (st) {
      if (typeof st.isSymbolicLink === "function" && st.isSymbolicLink()) return { reason: "unsafe_repo" };
      if (typeof st.isDirectory === "function" && st.isDirectory()) return { root: dir, gitDir: dotGit };
      if (typeof st.isFile === "function" && st.isFile()) {
        let text;
        try { text = String(readFile(dotGit)); } catch { return { reason: "unsafe_repo" }; }
        const m = /^gitdir:\s*(.+?)\s*$/m.exec(text);
        if (!m) return { reason: "unsafe_repo" };
        const target = m[1].startsWith("/") ? m[1] : join(dir, m[1]);
        let gitDir;
        try { gitDir = realpath(target); } catch { return { reason: "unsafe_repo" }; }
        const gs = lstat(gitDir);
        if (!gs || typeof gs.isDirectory !== "function" || !gs.isDirectory()) return { reason: "unsafe_repo" };
        return { root: dir, gitDir };
      }
      return { reason: "unsafe_repo" }; // socket・device 等
    }
    const parent = dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }
  return { reason: "not_a_repo" };
}

/**
 * 設定に定義された filter driver を全部 `cat` に上書きする `-c` の列(同日、所見 2 の続き)。
 *
 * `.gitattributes` の `filter=<name>` は**設定に driver が在って初めて**走る。`git diff` は作業木の
 * file を index と比べる為に clean filter を通す = repo の設定で任意のプログラムが走る口。
 * driver 名は事前に判らないので、設定の名前だけを読み(`git config --list --name-only`、実行なし)、
 * 見つかった driver の clean / smudge を `cat`、process を空(= 無し)、required を false にする。
 *
 * @param {string} text  `git config --list --name-only` の出力
 * @returns {string[]}  `-c k=v` の列(flat)
 */
export function filterOverrides(text) {
  const names = new Set();
  for (const line of String(text ?? "").split("\n")) {
    const m = /^filter\.(.+)\.(clean|smudge|process|required)$/.exec(line.trim());
    if (m) names.add(m[1]);
  }
  const out = [];
  for (const n of [...names].sort()) {
    out.push("-c", `filter.${n}.clean=cat`, "-c", `filter.${n}.smudge=cat`, "-c", `filter.${n}.process=`, "-c", `filter.${n}.required=false`);
  }
  return out;
}

async function readWorkingDiffOnce(cwd, o) {
  const exec = o.exec ?? execFileAsync;
  const limits = o.limits ?? DIFF_LIMITS;
  const empty = (reason) => ({ files: [], truncated: false, totalBytes: 0, reason });

  // repo の場所は自分で決める(git の自動発見に任せない)。読めない理由は状態として返す。
  const loc = locateRepo(cwd, o);
  if (loc.reason) return empty(loc.reason);

  const opts = {
    cwd: loc.root,
    encoding: "utf8",
    timeout: limits.timeoutMs,
    maxBuffer: limits.maxBuffer,
    killSignal: "SIGKILL",
    env: gitEnv(),
  };
  // ★`--git-dir` / `--work-tree` を明示 = repo の設定(`core.worktree`)や `.git` の差し替えより
  //   CLI が勝つ。`cwd:` も root にする(dir が消えていた時の失敗は上の locateRepo で先に判る)。
  // ★`-c` は subcommand より前。`core.fsmonitor=false` は repo 設定の値より強い。
  const pin = [`--git-dir=${loc.gitDir}`, `--work-tree=${loc.root}`];

  // 設定に在る filter driver を読む(名前だけ。実行なし)。読めなければ driver 無しとして進む
  // —— 之は fail-open ではない: driver が無ければ filter は走らないし、在るのに読めない事は
  // `git diff` 自体も読めない事を意味する(其方が `git_failed` で止まる)。
  let overrides = [];
  try {
    const { stdout } = await exec("git", [...pin, "config", "--list", "--name-only"], opts);
    overrides = filterOverrides(stdout);
  } catch { overrides = []; }

  const base = [
    ...pin,
    "-c", "core.fsmonitor=false",
    ...overrides,
    "--no-pager", "diff", "--no-color", "--no-ext-diff", "--no-textconv", "--ignore-submodules=all",
  ];

  /** 1 本撃つ。切れた stdout も拾う(上限に当たった時に部分を捨てない為)。 */
  const run = async (args) => {
    try {
      const { stdout } = await exec("git", args, opts);
      return { stdout: stdout ?? "", cut: false, reason: null };
    } catch (e) {
      const stdout = typeof e?.stdout === "string" ? e.stdout : "";
      if (String(e?.code) === "ERR_CHILD_PROCESS_STDIO_MAXBUFFER" || e?.code === "ENOBUFS") {
        // 器から溢れた = 「読めなかった」ではなく「**多すぎた**」。部分を出して切ったと言う。
        // ★溢れたのが stderr の側なら、それは git が大量に文句を言った = 失敗(stdout の
        //   部分を差分として読まない)。
        if (/stderr/i.test(String(e?.message ?? ""))) return { stdout: "", cut: false, reason: "git_failed" };
        return { stdout, cut: true, reason: null };
      }
      if (notARepo(e?.stderr)) return { stdout: "", cut: false, reason: "not_a_repo" };
      if (e?.code === "ENOENT") return { stdout: "", cut: false, reason: "cwd_missing" };
      return { stdout: "", cut: false, reason: "git_failed" };
    }
  };

  // ★順は **働いている木 → index**。一覧の ± バッジが数えているのは
  //   `git diff --shortstat`(= 未 stage の側)なので、電話を開いた人が最初に見る物が
  //   バッジの数と同じ側になる。
  const unstaged = await run(base);
  if (unstaged.reason) return empty(unstaged.reason);
  const staged = await run([...base, "--cached"]);
  const totalBytes =
    Buffer.byteLength(unstaged.stdout, "utf8") + Buffer.byteLength(staged.stdout, "utf8");
  const parsed = [
    ...parseDiff(unstaged.stdout, false, limits),
    ...parseDiff(staged.stdout, true, limits),
  ];
  // ★index の側だけ落ちて、作業木の側にも何も無かった = 読めた物が 0。其れは「差分が無い」
  //   ではなく「読めなかった」なので reason を名乗る(切れた成功と同じ形にしない)。
  if (staged.reason && parsed.length === 0) return { ...empty(staged.reason), totalBytes };

  // ★器から溢れた側は parse した数が下限でしかない。`--numstat` で数だけ取り直す
  //   (出力は 1 file 1 行なので溢れない)。取れなければ parse の数のまま(下限)。
  for (const side of [{ r: unstaged, cached: false }, { r: staged, cached: true }]) {
    if (!side.r.cut) continue;
    const ns = await run([...base, "--numstat", ...(side.cached ? ["--cached"] : [])]);
    if (ns.reason || ns.cut) continue;
    const counts = parseNumstat(ns.stdout);
    for (const f of parsed) {
      if (f.staged !== side.cached) continue;
      const c = counts.get(f.path);
      if (!c) continue;
      if (c.added !== null) f.added = c.added;
      if (c.removed !== null) f.removed = c.removed;
    }
  }

  const capped = capFiles(parsed, limits);
  return {
    files: capped.files,
    truncated: capped.truncated || unstaged.cut || staged.cut || Boolean(staged.reason),
    totalBytes,
    reason: null,
  };
}
