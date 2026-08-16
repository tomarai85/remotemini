// checkouts.mjs — remote-mini の「持ち出し」を電話から**読める・戻しを依頼できる**様にする層。
// REQUIREMENTS §9-2 / DESIGN §2.101(2026-08-16)。
//
// ★役割の線引き(誠実さの要):
//   - 「戻す」を実行できるのは MBP だけ(`~/.claude/tools/remote-mini.sh` の back は受け側で走る)。
//     電話から出来るのは**依頼**まで。此処を「押したら戻る」と見せたら嘘になる。
//   - この層は mirror root(edith 上、同 台本の $MIRROR_ROOT と同じ既定)を
//     **読む + 依頼の印を置く**だけ。worktree の中身には一切触れない。
//   - `--force` に相当する語彙は存在しない(Codex 条件3。渡す道が構造的に無い)。
//
// mirror root の形(remote-mini.sh が作る):
//   $ROOT/<project-id>/ID        … "pid=<id>\nsrc=<MBP側の絶対パス>\n"(所有の印)
//   $ROOT/<project-id>/worktree  … 作業木の写し
//   $ROOT/<project-id>/RETURN-REQUESTED … 此の層が置く依頼の印(JSON、tmp -> rename)

import { readFileSync, readdirSync, statSync, writeFileSync, renameSync, existsSync } from "node:fs";
import { join, resolve, sep } from "node:path";

export const DEFAULT_MIRROR_ROOT = "/Users/Shared/dev/remote-mini";
const REQUEST_FILE = "RETURN-REQUESTED";

/** ID の中身 -> {pid, src}。形が違えば null(所有の印が無い dir は持ち出しではない)。 */
export function parseSentinel(text) {
  if (typeof text !== "string") return null;
  const pid = /^pid=(.+)$/m.exec(text)?.[1];
  const src = /^src=(.+)$/m.exec(text)?.[1];
  if (!pid || !src) return null;
  return { pid, src };
}

/** 依頼の印を読む。無い/壊れている = null(依頼は無い)。 */
export function readReturnRequest(root, pid) {
  try {
    const obj = JSON.parse(readFileSync(join(root, pid, REQUEST_FILE), "utf8"));
    if (obj && typeof obj.at === "string") return obj;
  } catch { /* 無い・壊れている */ }
  return null;
}

/** 持ち出しの一覧。ID を持つ dir だけを数える(印の無い dir は誰の物か判らないので出さない)。 */
export function listCheckouts(root = DEFAULT_MIRROR_ROOT) {
  let names = [];
  try {
    names = readdirSync(root);
  } catch {
    return []; // root ごと無い = 持ち出しは無い
  }
  const out = [];
  for (const name of names) {
    let sentinel;
    try {
      sentinel = parseSentinel(readFileSync(join(root, name, "ID"), "utf8"));
    } catch { continue; }
    if (!sentinel || sentinel.pid !== name) continue; // 印と dir 名の不一致は数えない
    let updatedAt = null;
    try {
      updatedAt = statSync(join(root, name, "worktree")).mtime.toISOString();
    } catch { /* worktree がまだ無い形も一覧には出す(印が在る以上、持ち出しは在る) */ }
    const request = readReturnRequest(root, name);
    out.push({
      id: name,
      source: sentinel.src,          // MBP 側の絶対パス(「どこの仕事か」を人が読む)
      updatedAt,
      returnRequestedAt: request?.at ?? null,
    });
  }
  return out;
}

/**
 * cwd -> 持ち出しの project-id。root の下の worktree に居なければ null。
 * ★前方一致は**区切りまで**見る(`/root/abc` と `/root/abcd` を混同しない)。
 */
export function checkoutIdForCwd(cwd, root = DEFAULT_MIRROR_ROOT) {
  if (typeof cwd !== "string" || cwd.length === 0) return null;
  const r = resolve(root) + sep;
  const c = resolve(cwd);
  if (!c.startsWith(r)) return null;
  const rest = c.slice(r.length).split(sep);
  // <pid>/worktree[/...] の形だけを持ち出しと読む
  if (rest.length >= 2 && rest[1] === "worktree") return rest[0];
  return null;
}

/**
 * 戻しの依頼を置く。戻り値 = {at} / 置けない理由を throw しない —
 * {error} で返す(呼び側の HTTP が理由をそのまま日本語にする)。
 * 冪等: 既に依頼が在れば**その時刻を保つ**(連打で時刻が進むと「今頼んだばかり」に見え続ける)。
 */
export function requestReturn(root, pid, sessionId, now = new Date()) {
  const dir = join(root, pid);
  if (!existsSync(join(dir, "ID"))) return { error: "no-such-checkout" };
  const existing = readReturnRequest(root, pid);
  if (existing) return { at: existing.at, already: true };
  const body = { at: now.toISOString(), sessionId: sessionId ?? null };
  const tmp = join(dir, `${REQUEST_FILE}.tmp-${process.pid}`);
  writeFileSync(tmp, JSON.stringify(body, null, 2) + "\n", { mode: 0o644 });
  renameSync(tmp, join(dir, REQUEST_FILE));
  return { at: body.at, already: false };
}
