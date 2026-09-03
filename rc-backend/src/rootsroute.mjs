// roots の 3 本の口(2026-09-03、対照表 #11、spec = .harness/spec-2026-09-03-roots-new-session.md)。
//
// `diffroute.mjs` と同じ理由で server.mjs から切り出す: server.mjs は import した瞬間に listen する
// ので単体から呼べない。此処は **偽の req / res で叩ける純粋な形**にして、tmux も fs も知らない
// (`loadRoots` / `completePaths` / `startWindow` は全部 server.mjs から渡される)。
//
// ★台帳(`loadRoots`)は**要求ごとに**読む。caching しない。台帳は人が机で書く 32 行以内の file で、
//   1 行足した直後に電話から見えるべき物。e2e が台帳を消して `no_roots` を測れるのも此の性質。
// ★線に**絶対 path を出さない**: 一覧は index + 札、補完は root からの相対、202 も cwd を返さない。
// ★分類は全部 `reason`。`code` は 401/404 の復旧語彙専用なので此処では一度も書かない。
import { join } from "node:path";
import { ROOTS_NONE, ROOTS_OUTSIDE, ROOTS_CWD_GONE } from "./roots.mjs";

/** 範囲外の index。`code` を置かない(電話は status だけで `.rootGone` へ落とす)。 */
const ROOT_NOT_FOUND = Object.freeze({ error: "no such root" });

/** JSON の top-level が plain object か(配列・null・数値・文字列は本文の形として受けない)。 */
export function isPlainObject(v) {
  return v !== null && typeof v === "object" && !Array.isArray(v);
}

/** index の文字列(道の regex は `\d{1,3}` を通す)→ 台帳の要素。無ければ null。 */
export function rootAt(roots, index) {
  const i = Number(index);
  if (!Number.isInteger(i) || i < 0 || i >= roots.length) return null;
  return roots[i];
}

/** `GET /api/roots` — 札と index だけ。台帳が無い / 空 = 200 + 空 + `no_roots`(答えられている。断りではない)。 */
export function handleRootsList({ res, json, loadRoots, rootsBody }) {
  const { roots, reason } = loadRoots();
  return json(res, 200, rootsBody({ roots, reason }));
}

/** `GET /api/roots/<i>/paths?q=&limit=` — root 起点で **dir だけ**歩く。範囲外 = 404。 */
export function handleRootsPaths({ res, index, q, limit, json, loadRoots, completePaths, pathsBody }) {
  const { roots } = loadRoots();
  const root = rootAt(roots, index);
  if (!root) return json(res, 404, ROOT_NOT_FOUND);
  const r = completePaths(root.path, q || "", { limit, dirsOnly: true });
  return json(res, 200, pathsBody({ entries: r.paths, truncated: r.truncated, reason: r.reason }));
}

/**
 * `POST /api/roots/<i>/new` 本文 `{ "path": "<相対 or 空>" }`。
 * 202 `{started, window, pane}`(cwd は返さない)/ 外 = 400 `outside_roots` / 無い = 409 `cwd_gone` /
 * 台帳空 = 400 `no_roots` / 範囲外 = 404 / 本文が読めない = 400 `bad_body`。
 *
 * ★本文の `path` が絶対 / `~` 始まり = 400 `outside_roots`。此の口の契約は「root からの相対」1 通りで、
 *   絶対を受けると台帳の外を指す道が 1 本増える(受けたとしても `resolveUnderRoots` が弾くが、
 *   契約を 2 通りにしない)。
 * ★包含は `resolveUnderRoots` に任せる(realpath 同士。`..` と symlink の抜け道は其方の検査)。
 *   `join(root, path)` を其のまま tmux へ渡す実装は、此の関数の変異 M1 として検査 9 が殺す。
 */
export async function handleRootsNew({ req, res, index, json, loadRoots, resolveUnderRoots, readBody, tooLarge, BodyTooLarge, startWindow }) {
  let body;
  try {
    body = JSON.parse((await readBody(req)) || "{}");
  } catch (e) {
    if (BodyTooLarge && e instanceof BodyTooLarge) return tooLarge(req, res, e);
    return json(res, 400, { error: `Request body unreadable: ${e.message}`, reason: "bad_body" });
  }
  // ★本文の形(Codex 2026-09-03 #5): top-level は plain object、`path` は**無いか文字列**。object / array /
  //   number を黙って "" に丸めると、壊れた要求が root 自身で会話を起こす(allowlist の外へは出ないが、
  //   fail-open な検証)。此処で 400 `bad_body` に倒す。
  if (!isPlainObject(body) || ("path" in body && typeof body.path !== "string")) {
    return json(res, 400, { error: "body must be an object with an optional string path", reason: "bad_body" });
  }
  const { roots, reason } = loadRoots();
  if (!roots.length) return json(res, 400, { error: "no roots on the desk", reason: reason || ROOTS_NONE });
  const root = rootAt(roots, index);
  if (!root) return json(res, 404, ROOT_NOT_FOUND);
  const rel = typeof body.path === "string" ? body.path : "";
  if (rel.startsWith("/") || rel.startsWith("~")) {
    return json(res, 400, { error: "path must be relative to the root", reason: ROOTS_OUTSIDE });
  }
  const r = resolveUnderRoots([root], rel === "" ? root.path : join(root.path, rel));
  if (!r.ok) {
    if (r.reason === ROOTS_CWD_GONE) return json(res, 409, { error: "directory gone", reason: ROOTS_CWD_GONE });
    return json(res, 400, { error: "outside the desk roots", reason: r.reason });
  }
  const started = startWindow(r.cwd);
  if (!started) return json(res, 502, { error: "new_window_failed", reason: "tmux_failed" });
  return json(res, 202, { started: true, window: started.window, pane: started.pane });
}

/**
 * `POST /api/sessions/<id>/new` の `cwd` 付き本文の判定(server.mjs の handler から呼ぶ)。
 * 本文なし / `cwd` 鍵なし = `{ cwd: null }`(今までの道 = 会話の cwd)。
 * `cwd` 在り = roots の下なら `{ cwd: <realpath> }`、さもなくば `{ status, body }` で断り。
 * `cwd` 鍵は在るのに文字列でない / 空 = 400 `bad_body`(黙って会話の cwd へ落とさない。Codex 2026-09-03 #2 の後半)。
 *
 * ★会話の cwd(本文なし)は allowlist を**通さない**(Codex #2 の前半は受けなかった)。理由: 其の会話へ
 *   本文を送れる鍵は、既に其の cwd で Claude を動かせる —— 同じ場所にもう 1 本起こしても、鍵が持つ能力は
 *   1 つも増えない。allowlist が絞るのは「電話が**新しく**選ぶ場所」。台帳の外に在る既存の会話の隣で
 *   始められなくすると、道具として退行するだけで守りは増えない。
 */
export function resolveRequestedCwd({ body, loadRoots, resolveUnderRoots }) {
  if (!isPlainObject(body)) return { status: 400, body: { error: "body must be an object", reason: "bad_body" } };
  if (!("cwd" in body)) return { cwd: null };
  if (typeof body.cwd !== "string" || body.cwd === "") {
    return { status: 400, body: { error: "cwd must be a non-empty string", reason: "bad_body" } };
  }
  const want = body.cwd;
  const { roots, reason } = loadRoots();
  if (!roots.length) return { status: 400, body: { error: "no roots on the desk", reason: reason || ROOTS_NONE } };
  const r = resolveUnderRoots(roots, want);
  if (r.ok) return { cwd: r.cwd };
  if (r.reason === ROOTS_CWD_GONE) return { status: 409, body: { error: "directory gone", reason: ROOTS_CWD_GONE } };
  return { status: 400, body: { error: "outside the desk roots", reason: r.reason } };
}
