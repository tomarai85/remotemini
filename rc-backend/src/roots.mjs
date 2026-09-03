// 机の **roots 台帳**(2026-09-03、対照表 #11「任意のディレクトリで新規セッション」、Tom 裁定 = roots の下だけ)。
//
// 「任意の path で `claude` を起動できる」は机の任意の場所で process を起こせる事なので、
// 受ける場所を **allowlist の下だけ**に絞る。台帳は `~/.rc-backend/roots`(1 行 1 path、`~` は home、
// `#` 行と空行は無視)。★台帳が無い / 空 = **何処も受けない**(fail closed)。「無ければ home 全体」の
// 様な既定を置くと、台帳を書き忘れた日に一番広い口が開く。
//
// ★包含は **realpath 同士**で判定する。文字列の前方一致だと `/a/b` が `/a/bc` を受ける(prefix trap)し、
//   root の下に置いた symlink が root の外を指していれば、文字列上は下でも実体は外。
//   判定の順: 候補を realpath → root(realpath 済み)と等しいか、`root + sep` で始まるか。
// ★root 自身が解決できない(無い・読めない)行は台帳から**落とす**。存在しない場所には会話を
//   立てられないので、残しても `cwd_gone` を後で返すだけ。落とした事は `dropped` で観測できる。
import { readFileSync, realpathSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { basename, isAbsolute, join, resolve, sep } from "node:path";

/**
 * realpath 済みの path が **dir として使える**か。Codex 2026-09-03 #1(High): realpath は file にも通るが、
 * tmux 3.6a は `-c` の chdir に失敗すると `$HOME`、更に失敗すると `/` へ移って**其のまま子を起こす**
 * (spawn.c)。つまり file を cwd として受けると、allowlist の外で Claude が起動する。
 * dir で無い物は「無い」と同じ扱い(`cwd_gone`)にする。
 */
function isDir(p, stat) {
  try { return stat(p).isDirectory(); } catch { return false; }
}

export const ROOTS_FILE = process.env.RC_ROOTS_FILE || join(homedir(), ".rc-backend", "roots");
/** 台帳の行数の上限。之を超えた分は読まない(台帳は人が書く物で、数十行を超える理由が無い)。 */
export const ROOTS_MAX = 32;

/** 電話へ返す `reason`(`code` は 401/404 の復旧語彙専用なので使わない)。 */
export const ROOTS_NONE = "no_roots";        // 台帳が無い / 空 / 全行が解決不能
export const ROOTS_OUTSIDE = "outside_roots"; // 候補が全 root の外
export const ROOTS_CWD_GONE = "cwd_gone";     // 候補の dir が無い(realpath 失敗)

/** `~` / `~/x` を home に展開する。`~user` 形は扱わない(台帳は 1 人の机の物)。 */
export function expandHome(p, home = homedir()) {
  if (p === "~") return home;
  if (p.startsWith("~/")) return join(home, p.slice(2));
  return p;
}

/**
 * 台帳の本文 → 絶対 path の一覧(順序保持・重複除去)。相対 path の行は**捨てる**(何処から見た相対か
 * が定まらない = 受ける範囲が定まらない)。`dropped` に捨てた行を返す。
 */
export function parseRoots(text, { home = homedir() } = {}) {
  const roots = [];
  const dropped = [];
  const seen = new Set();
  const lines = String(text ?? "").split(/\r?\n/);
  for (const raw of lines) {
    const line = raw.replace(/\s+#.*$/, "").trim();
    if (line === "" || line.startsWith("#")) continue;
    if (roots.length >= ROOTS_MAX) { dropped.push(line); continue; }
    const p = expandHome(line, home);
    if (!isAbsolute(p)) { dropped.push(line); continue; }
    const norm = resolve(p);
    if (seen.has(norm)) continue;
    seen.add(norm);
    roots.push(norm);
  }
  return { roots, dropped };
}

/**
 * 表示用の札。home の下なら `~/…`、其れ以外は `…/<basename>`(Codex 2026-09-03 #4: home 外の root を
 * 絶対 path のまま出すと `/Volumes/…` の様な机の地図が線に出る。札は人が root を見分ける為の物で、
 * index が指す鍵なので、basename で足りる)。
 */
export function labelOf(p, home = homedir()) {
  if (p === home) return "~";
  if (p.startsWith(home + sep)) return "~" + p.slice(home.length);
  return "…/" + basename(p);
}

/**
 * 台帳を読んで、解決済みの root の一覧を返す。
 * @returns {{roots: {label: string, path: string}[], reason: string|null, dropped: string[]}}
 *   `roots` が空なら `reason` = `no_roots`。file が無い事と空な事を区別しない(どちらも「何処も受けない」)。
 */
export function loadRoots({ file = ROOTS_FILE, readFile = readFileSync, realpath = realpathSync, stat = statSync, home = homedir() } = {}) {
  let text = "";
  try { text = String(readFile(file, "utf8")); }
  catch (e) {
    if (e && e.code === "ENOENT") return { roots: [], reason: ROOTS_NONE, dropped: [] };
    // 在るのに読めない = 判定不能。fail closed(受けない)だが、理由は「無い」と別にしておく。
    return { roots: [], reason: ROOTS_NONE, dropped: [`unreadable: ${e?.code || e?.message || "error"}`] };
  }
  const parsed = parseRoots(text, { home });
  const roots = [];
  const dropped = [...parsed.dropped];
  const seen = new Set();
  for (const p of parsed.roots) {
    let real;
    try { real = realpath(p); } catch { dropped.push(p); continue; }
    if (!isDir(real, stat)) { dropped.push(p); continue; } // 台帳の行が file を指す = 受ける場所ではない
    if (seen.has(real)) continue;
    seen.add(real);
    roots.push({ label: labelOf(p, home), path: real });
  }
  return { roots, reason: roots.length ? null : ROOTS_NONE, dropped };
}

/** `candidate` が `root` と等しいか、其の下か(両方 realpath 済みの前提)。prefix trap を踏まない。 */
export function contains(root, candidate) {
  return candidate === root || candidate.startsWith(root.endsWith(sep) ? root : root + sep);
}

/**
 * 候補の dir を roots の下に**実体で**収める。
 * @param {{label: string, path: string}[]} roots  `loadRoots` の出力
 * @param {string} candidate  絶対 path か `~/…`。相対は受けない
 * @returns {{ok: true, cwd: string, root: {label: string, path: string}} | {ok: false, reason: string}}
 */
export function resolveUnderRoots(roots, candidate, { realpath = realpathSync, stat = statSync, home = homedir() } = {}) {
  if (!Array.isArray(roots) || roots.length === 0) return { ok: false, reason: ROOTS_NONE };
  const p = expandHome(String(candidate ?? ""), home);
  if (!isAbsolute(p)) return { ok: false, reason: ROOTS_OUTSIDE };
  let real;
  try { real = realpath(p); } catch { return { ok: false, reason: ROOTS_CWD_GONE }; }
  if (!isDir(real, stat)) return { ok: false, reason: ROOTS_CWD_GONE }; // file は cwd にならない(上の isDir の註)
  for (const root of roots) {
    if (contains(root.path, real)) return { ok: true, cwd: real, root };
  }
  return { ok: false, reason: ROOTS_OUTSIDE };
}
