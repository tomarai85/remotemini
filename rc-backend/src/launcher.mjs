// worker 経路の launcher(`claude-work`)を**決める**層(2026-09-06)。純関数、fs は注入。
//
// ── なぜ在るか ──────────────────────────────────────────────────────────────
// `server.mjs` は `RC_CLAUDE_WORK || ~/fleet-tools/claude-work` を spawn していた。friday には
// `~/fleet-tools/` が無い(2026-09-06 実測、`.harness/evidence-2026-09-06/friday-new-sessions-not-logged-in.md`)。
// Node の `spawn` は無い path でも同期には投げず、非同期の `error` で死ぬ —— つまり電話は 202「Sent」を
// 受け取った後に `worker_error` を流され、其れを描く client は無い。**起動する前に**在るかを決め、
// 無ければ名前の付いた理由で断る(202 の後で死なない)。
//
// ★**要求ごとに決め直す**(起動時に 1 回ではない — Codex 2026-09-06): 起動時だけだと「後で消えた」を
//   202 の後の `worker_error` に戻し、「後で同期で現れた」を再起動まで 409 に固める。exists は安いので毎回。
// 順序 = 明示(env)> 艦隊の置き場(`~/fleet-tools/claude-work`)> git 同期される置き場
// (`~/.claude/tools/claude-work`、2026-09-06 に新設。5 分毎の pull で全機に届く)。
// ★env が指す path が無い時は**黙って次へ落ちない**(人が指した物が無いのは設定の誤りで、
//   別の物を起動すると「直った顔」になる)。
import { accessSync, constants } from "node:fs";
import { isAbsolute, join, resolve } from "node:path";

export const LAUNCHER_NAME = "claude-work";

/** 既定の「在るか」= **実行できるか**(在るが x が無い file を起動しても同じ死に方をする — Codex 2026-09-06)。 */
export function executableSync(p) {
  try { accessSync(p, constants.X_OK); return true; } catch { return false; }
}

/** `~/…` を home で展開し、相対 path は起動時の cwd で絶対にする(spawn は `plan.cwd` で走るので、
 *  相対のまま持つと exists() と spawn() が**別の file** を見る — Codex 2026-09-06)。 */
function absolutize(p, home, cwd) {
  if (p === "~" || p.startsWith("~/")) return home ? join(home, p.slice(2)) : p;
  return isAbsolute(p) ? p : resolve(cwd, p);
}

/**
 * @returns {{ path: string|null, source: "env"|"fleet-tools"|"synced"|null, tried: string[] }}
 *   path=null の時は `reason` を持つ(`launcher_missing` / `env-launcher-missing`)。
 */
export function resolveLauncher({ env = process.env, home, cwd = process.cwd(), exists = executableSync } = {}) {
  const tried = [];
  const raw = typeof env.RC_CLAUDE_WORK === "string" && env.RC_CLAUDE_WORK.trim() ? env.RC_CLAUDE_WORK.trim() : null;
  const explicit = raw ? absolutize(raw, home, cwd) : null;
  if (explicit) {
    tried.push(explicit);
    if (exists(explicit)) return { path: explicit, source: "env", tried, reason: null };
    return { path: null, source: null, tried, reason: "env-launcher-missing" };
  }
  if (!home) return { path: null, source: null, tried, reason: "launcher_missing" };
  const candidates = [
    ["fleet-tools", join(home, "fleet-tools", LAUNCHER_NAME)],
    ["synced", join(home, ".claude", "tools", LAUNCHER_NAME)],
  ];
  for (const [source, p] of candidates) {
    tried.push(p);
    if (exists(p)) return { path: p, source, tried, reason: null };
  }
  return { path: null, source: null, tried, reason: "launcher_missing" };
}

/** `/healthz` に載せる 1 枚。**path は載せない**(認証の外に user 名と機械の配置を出さない — Codex 2026-09-06)。
 *  path と tried は起動 log にだけ出す。 */
export function launcherView(r) {
  return { source: r?.source ?? null, reason: r?.reason ?? null };
}
