// 会話の作業木の**未コミットの差分の中身**(対照表 #4「差分を電話で読む」)。
//
// 一覧の ± バッジ(#5)は「幾ら変わったか」だけを出す。此処は其の続きで、
// **何が変わったか**を返す —— ファイル単位に構造化した、読む為の形。
//
// ── 設計 ─────────────────────────────────────────────────────────────────
// ★**読むだけ**。撃つ git は `diff` の 2 本だけで、書く動詞は 1 つも無い。
//   さらに:
//     `--no-ext-diff` / `--no-textconv`
//         repo の設定(`diff.external` / `textconv` フィルタ)は**任意のプログラムを
//         走らせる口**。差分を読む為に、その repo が指定した実行ファイルを此の机で
//         起動する道を残さない。読むだけ = 他人の設定で他人のコードを走らせない。
//     `GIT_OPTIONAL_LOCKS=0`
//         `git diff` は既定で index を更新して書き戻す(= `.git/index.lock` を取る)。
//         同じ作業木では Claude Code 本人と Tom の手が同時に git を叩いている。
//         電話が覗いただけで机の git が `index.lock` で失敗する形にはしない。
//     `LC_ALL=C`
//         下の `notARepo()` が git の一文を読むので、言語を固定する。読まない形
//         (`rev-parse` を先に撃つ)も在るが、それは往復が 1 本増える。
//
// ★**生の diff 文字列を丸ごと返さない**。電話は「ファイルの一覧 → その中の塊」で
//   読むので、其の形に机で畳む。文字列のまま渡すと、色分けと横スクロールの為に
//   電話側が 2 つ目の parser を持つ事になり、必ず机とズレる。
//
// ★**切ったら切ったと言う**。上限は 3 つ(1 ファイル / 全体 / ファイル数)で、
//   どれに当たっても `truncated: true` を立てる。★数(`added` / `removed`)は
//   **切る前の全文から**数える —— 本文を途中で止めても「幾ら変わったか」は嘘を
//   吐かない。此の非対称は意図的で、電話は「+42 -18(表示は途中まで)」と言える。
//
// ★読めない事は**異常ではなく状態**。cwd が無い / dir が消えた / git 管理外 /
//   git が落ちた、の 4 つは `reason` を名乗って 200 で返す(一覧の実装と同じ判断)。
//   例外を上へ投げると、電話は「会話が壊れた」と読む —— 実際には repo が無いだけ。
import { execFile as nodeExecFile } from "node:child_process";
import { existsSync } from "node:fs";
import { promisify } from "node:util";

const execFileAsync = promisify(nodeExecFile);

/**
 * 天井。**bytes で持つ**(行数ではない)。1 行が 10 万字の minified な file が
 * 実在するので、行数で切ると天井が天井にならない。
 */
export const DIFF_LIMITS = Object.freeze({
  /** 1 ファイルの本文(hunk の行の text の合計)。之を超えたら其の file だけ切る。 */
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
 * @param {string} text  git の標準出力
 * @param {boolean} staged  index の側か(`--cached` で撃った物か)
 * @returns {Array<{path,staged,binary,added,removed,hunks,bytes}>}
 */
export function parseDiff(text, staged) {
  const files = [];
  let cur = null;
  let hunk = null;

  const closeFile = () => {
    if (cur) files.push(cur);
    cur = null;
    hunk = null;
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
    if (line.startsWith("+")) {
      cur.added += 1;
      hunk.lines.push({ kind: "add", text: line.slice(1) });
    } else if (line.startsWith("-")) {
      cur.removed += 1;
      hunk.lines.push({ kind: "del", text: line.slice(1) });
    } else if (line.startsWith(" ")) {
      hunk.lines.push({ kind: "ctx", text: line.slice(1) });
    } else if (line.startsWith("\\")) {
      // `\ No newline at end of file`。数には入れない(足しても引いてもいない)が、
      // 落とすと「最後の行に改行が無い」が電話から消える。文脈として運ぶ。
      hunk.lines.push({ kind: "ctx", text: line });
    } else if (line === "") {
      // 出力の末尾。hunk の中の空行は git が必ず ` ` を頭に付けるので、
      // 素の空行は本文ではない。
      continue;
    } else {
      continue;
    }
    const last = hunk.lines[hunk.lines.length - 1];
    cur.bytes += Buffer.byteLength(last.text, "utf8");
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
        const b = Buffer.byteLength(l.text, "utf8");
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
 * 作業木の未コミットの差分を読む。**書く動詞を撃たない**。
 *
 * @param {string} cwd
 * @param {object} [o]
 * @param {Function} [o.exec]   `execFile` の promise 版(検査で差し替える)
 * @param {Function} [o.exists] dir の実在(同上)
 * @param {object}   [o.limits]
 * @returns {Promise<{files: Array, truncated: boolean, totalBytes: number, reason: string|null}>}
 */
export async function readWorkingDiff(cwd, o = {}) {
  const exec = o.exec ?? execFileAsync;
  const exists = o.exists ?? existsSync;
  const limits = o.limits ?? DIFF_LIMITS;
  const empty = (reason) => ({ files: [], truncated: false, totalBytes: 0, reason });

  if (typeof cwd !== "string" || !cwd) return empty("no_cwd");
  if (!exists(cwd)) return empty("cwd_missing");

  const opts = {
    cwd,
    encoding: "utf8",
    timeout: limits.timeoutMs,
    maxBuffer: limits.maxBuffer,
    killSignal: "SIGKILL",
    env: { ...process.env, LC_ALL: "C", GIT_OPTIONAL_LOCKS: "0" },
  };
  // ★`-C cwd` ではなく `cwd:` で渡す。`-C` は「其の dir へ移ってから」で同じだが、
  //   dir が消えていた時の失敗が git の中で起きる(= 上の `cwd_missing` と
  //   区別が付かない一文になる)。此方なら spawn が ENOENT で落ちるので、
  //   境目が机の側に残る。
  const base = ["--no-pager", "diff", "--no-color", "--no-ext-diff", "--no-textconv"];

  /** 1 本撃つ。切れた stdout も拾う(上限に当たった時に部分を捨てない為)。 */
  const run = async (args) => {
    try {
      const { stdout } = await exec("git", args, opts);
      return { stdout: stdout ?? "", cut: false, reason: null };
    } catch (e) {
      const stdout = typeof e?.stdout === "string" ? e.stdout : "";
      // 器から溢れた = 「読めなかった」ではなく「**多すぎた**」。部分を出して切ったと言う。
      if (String(e?.code) === "ERR_CHILD_PROCESS_STDIO_MAXBUFFER" || e?.code === "ENOBUFS") {
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
  // 2 本目だけが落ちた時に 1 本目を捨てない。読めた側は出し、切った事を名乗る。
  const totalBytes =
    Buffer.byteLength(unstaged.stdout, "utf8") + Buffer.byteLength(staged.stdout, "utf8");
  const parsed = [
    ...parseDiff(unstaged.stdout, false),
    ...parseDiff(staged.stdout, true),
  ];
  const capped = capFiles(parsed, limits);
  return {
    files: capped.files,
    truncated: capped.truncated || unstaged.cut || staged.cut || Boolean(staged.reason),
    totalBytes,
    reason: null,
  };
}
