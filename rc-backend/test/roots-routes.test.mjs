// roots の口(`src/rootsroute.mjs` + server.mjs の字面、2026-09-03、対照表 #11)。
// spec = .harness/spec-2026-09-03-roots-new-session.md「Tests and controls」の 15 本。
//
// 3 層を測る: ① 道が**届く**(regex / LOG_PATHS / 会話の 404 より前)② 口の挙動を偽 req/res で実際に通す
// ③ 包含は本物の `resolveUnderRoots`(実 fs の tmp 木)で —— 偽物に差し替えると「allowlist が効いている」を
// 測っているのが偽物の側になる。
import { test } from "node:test";
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { mkdtempSync, mkdirSync, readFileSync, realpathSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { ROOTS_ROUTE_RE, SESSION_ROUTE_RE, pathShape } from "../src/reqlog.mjs";
import { resolveUnderRoots, ROOTS_NONE, ROOTS_OUTSIDE, ROOTS_CWD_GONE } from "../src/roots.mjs";
import { handleRootsList, handleRootsPaths, handleRootsNew, resolveRequestedCwd, rootAt } from "../src/rootsroute.mjs";
import { rootsBody, pathsBody } from "../src/wire.mjs";
import { completePaths } from "../src/paths.mjs";

const SERVER = readFileSync(join(dirname(fileURLToPath(import.meta.url)), "..", "src", "server.mjs"), "utf8");

// ---- 道具 ---------------------------------------------------------------------------------------

function sink() {
  const writes = [];
  const json = (r, code, obj) => { writes.push({ code, obj }); return "written"; };
  return { writes, json, res: { id: "res" }, last: () => writes[writes.length - 1] };
}

/** 実 fs の木: root/ (inner/deep, escape -> outside), outside/ */
function tree() {
  const base = realpathSync(mkdtempSync(join(tmpdir(), "roots-route-")));
  const root = join(base, "root"); const outside = join(base, "outside");
  mkdirSync(join(root, "inner", "deep"), { recursive: true }); mkdirSync(join(root, "other"));
  mkdirSync(outside);
  symlinkSync(outside, join(root, "escape"));
  writeFileSync(join(root, "package.json"), "{}"); // file: cwd にならない(Codex #1)
  return { base, root, outside };
}

function reqWith(text) {
  const req = new EventEmitter();
  const readBody = async () => text;
  return { req, readBody };
}
class FakeTooLarge extends Error {}
const tooLarge = (req, res, e) => ({ tooLarge: true });

// ---- ① 届く ----------------------------------------------------------------------------------

test("★到達できる: /api/roots/:i/paths と /api/roots/:i/new が ROOTS_ROUTE_RE に当たる", () => {
  assert.deepEqual(ROOTS_ROUTE_RE.exec("/api/roots/0/paths").slice(1), ["0", "paths"]);
  assert.deepEqual(ROOTS_ROUTE_RE.exec("/api/roots/12/new").slice(1), ["12", "new"]);
  assert.equal(ROOTS_ROUTE_RE.exec("/api/roots/x/new"), null, "index は数字だけ");
  assert.equal(ROOTS_ROUTE_RE.exec("/api/roots/1/delete"), null, "動詞は 2 つだけ");
  assert.equal(ROOTS_ROUTE_RE.exec("/api/roots/1/new/extra"), null);
  assert.equal(pathShape("/api/roots/3/paths", new Set()), "/api/roots/:i/paths", "ログの型に畳まれる");
  assert.equal(SESSION_ROUTE_RE.exec("/api/roots/1/new"), null, "会話の道とは別物");
});

test("★到達できる: /api/roots が LOG_PATHS に居て、server.mjs が同じ字面で振り分けている", () => {
  assert.match(SERVER, /path === "\/api\/roots" && req\.method === "GET"/);
  const logPaths = SERVER.slice(SERVER.indexOf("const LOG_PATHS = new Set(["), SERVER.indexOf("]);", SERVER.indexOf("const LOG_PATHS")));
  assert.match(logPaths, /"\/api\/roots",/);
});

test("★roots の道は SESSION_ROUTE_RE の 404 より前に居る", () => {
  const roots = SERVER.indexOf('path === "/api/roots"');
  const rootsRe = SERVER.indexOf("ROOTS_ROUTE_RE.exec(path)");
  const session404 = SERVER.indexOf("const m = SESSION_ROUTE_RE.exec(path);");
  assert.ok(roots > 0 && rootsRe > 0 && session404 > 0);
  assert.ok(roots < session404 && rootsRe < session404, "会話の 404 の後ろに置くと届かない");
  assert.equal((SERVER.match(/\/api\\\/roots\\\/\(/g) || []).length, 0, "server.mjs が regex の写しを持っている");
});

// ---- ② 一覧 --------------------------------------------------------------------------------------

test("GET /api/roots: 札と index だけ返す(絶対 path を本文に一度も出さない)", () => {
  const s = sink();
  const loadRoots = () => ({ roots: [{ label: "~/Infra", path: "/Users/x/Infra" }, { label: "…/w", path: "/opt/w" }], reason: null, dropped: [] });
  handleRootsList({ res: s.res, json: s.json, loadRoots, rootsBody });
  assert.equal(s.last().code, 200);
  assert.deepEqual(s.last().obj, { roots: [{ index: 0, label: "~/Infra" }, { index: 1, label: "…/w" }], reason: null });
  assert.ok(!JSON.stringify(s.last().obj).includes("/Users/x/Infra"), "絶対 path が線に出た");
  assert.deepEqual(Object.keys(s.last().obj.roots[0]).sort(), ["index", "label"]);
});

test("GET /api/roots: 台帳が無い = 200 + 空 + no_roots", () => {
  const s = sink();
  handleRootsList({ res: s.res, json: s.json, loadRoots: () => ({ roots: [], reason: ROOTS_NONE, dropped: [] }), rootsBody });
  assert.equal(s.last().code, 200);
  assert.deepEqual(s.last().obj, { roots: [], reason: "no_roots" });
});

// ---- ② 補完 --------------------------------------------------------------------------------------

test("GET /api/roots/:i/paths: root 起点で dirsOnly で歩き、pathsBody の 3 鍵で返す", () => {
  const t = tree();
  const s = sink();
  const loadRoots = () => ({ roots: [{ label: "root", path: t.root }], reason: null, dropped: [] });
  let seen;
  const spy = (root, q, opts) => { seen = { root, q, opts }; return completePaths(root, q, opts); };
  handleRootsPaths({ res: s.res, index: "0", q: "", limit: 40, json: s.json, loadRoots, completePaths: spy, pathsBody });
  assert.equal(s.last().code, 200);
  assert.equal(seen.root, t.root); assert.equal(seen.opts.dirsOnly, true);
  assert.deepEqual(Object.keys(s.last().obj).sort(), ["paths", "reason", "truncated"]);
  const kinds = new Set(s.last().obj.paths.map((p) => p.kind));
  assert.deepEqual([...kinds], ["dir"], "dir 以外が混じった");
  assert.ok(s.last().obj.paths.every((p) => !p.path.startsWith("/")), "相対 path のはず");
});

test("GET /api/roots/:i/paths: 範囲外の index は 404(code を置かない)", () => {
  const s = sink();
  const loadRoots = () => ({ roots: [{ label: "r", path: "/r" }], reason: null, dropped: [] });
  handleRootsPaths({ res: s.res, index: "1", q: "", limit: 40, json: s.json, loadRoots, completePaths, pathsBody });
  assert.equal(s.last().code, 404);
  assert.equal("code" in s.last().obj, false, "`code` は 401/404 の復旧語彙専用。此処に書くと電話の遷移が壊れる");
  assert.equal(rootAt([{ path: "/r" }], "-1"), null); assert.equal(rootAt([{ path: "/r" }], "abc"), null);
});

// ---- ② 起動 --------------------------------------------------------------------------------------

function newHarness(t, { ledger } = {}) {
  const s = sink();
  const started = [];
  const startWindow = (cwd) => { started.push(cwd); return { window: "@7", pane: "%9" }; };
  const loadRoots = () => (ledger ?? { roots: [{ label: "root", path: t.root }], reason: null, dropped: [] });
  const run = (text, index = "0") => {
    const { req, readBody } = reqWith(text);
    return handleRootsNew({ req, res: s.res, index, json: s.json, loadRoots, resolveUnderRoots, readBody, tooLarge, BodyTooLarge: FakeTooLarge, startWindow });
  };
  return { s, started, run };
}

test("POST /api/roots/:i/new: root の下 = 202 started/window/pane、本文に cwd を出さない", async () => {
  const t = tree(); const h = newHarness(t);
  await h.run(JSON.stringify({ path: "inner/deep" }));
  assert.equal(h.s.last().code, 202);
  assert.deepEqual(h.s.last().obj, { started: true, window: "@7", pane: "%9" });
  assert.deepEqual(h.started, [join(t.root, "inner", "deep")]);
  await h.run("{}");
  assert.equal(h.s.last().code, 202, "path 空 = root 自身");
  assert.equal(h.started[1], t.root);
});

test("★POST /api/roots/:i/new: root の外へ抜ける相対 path = 400 outside_roots", async () => {
  const t = tree(); const h = newHarness(t);
  for (const p of ["../outside", "inner/../../outside", "escape"]) {
    await h.run(JSON.stringify({ path: p }));
    assert.equal(h.s.last().code, 400, `${p} を受けた`);
    assert.equal(h.s.last().obj.reason, ROOTS_OUTSIDE, p);
  }
  assert.deepEqual(h.started, [], "外の path で tmux を撃った");
});

test("POST /api/roots/:i/new: 絶対 path / ~ 始まりの本文 = 400 outside_roots", async () => {
  const t = tree(); const h = newHarness(t);
  await h.run(JSON.stringify({ path: join(t.root, "inner") }));
  assert.equal(h.s.last().code, 400); assert.equal(h.s.last().obj.reason, ROOTS_OUTSIDE, "絶対 path は契約外(root の下でも)");
  await h.run(JSON.stringify({ path: "~/inner" }));
  assert.equal(h.s.last().code, 400); assert.equal(h.s.last().obj.reason, ROOTS_OUTSIDE);
  assert.deepEqual(h.started, []);
});

test("POST /api/roots/:i/new: 無い dir = 409 cwd_gone", async () => {
  const t = tree(); const h = newHarness(t);
  await h.run(JSON.stringify({ path: "inner/missing" }));
  assert.equal(h.s.last().code, 409); assert.equal(h.s.last().obj.reason, ROOTS_CWD_GONE);
  assert.deepEqual(h.started, []);
});

test("★POST /api/roots/:i/new: file を指す path = 409 cwd_gone(tmux の $HOME fallback を踏ませない、Codex #1)", async () => {
  const t = tree(); const h = newHarness(t);
  await h.run(JSON.stringify({ path: "package.json" }));
  assert.equal(h.s.last().code, 409); assert.equal(h.s.last().obj.reason, ROOTS_CWD_GONE);
  assert.deepEqual(h.started, [], "file を cwd として tmux へ渡した");
});

test("POST /api/roots/:i/new: 本文の形が違う(配列 / path が非文字列)= 400 bad_body、root 自身で起動しない(Codex #5)", async () => {
  const t = tree(); const h = newHarness(t);
  for (const body of ["[]", '{"path": 5}', '{"path": ["inner"]}', '{"path": {"x": 1}}', "null", '"inner"']) {
    await h.run(body);
    assert.equal(h.s.last().code, 400, body); assert.equal(h.s.last().obj.reason, "bad_body", body);
  }
  assert.deepEqual(h.started, []);
});

test("★POST /api/roots/:i/new: 台帳が空 = 400 no_roots(fail closed)", async () => {
  const t = tree(); const h = newHarness(t, { ledger: { roots: [], reason: ROOTS_NONE, dropped: [] } });
  await h.run(JSON.stringify({ path: "" }));
  assert.equal(h.s.last().code, 400); assert.equal(h.s.last().obj.reason, ROOTS_NONE);
  assert.deepEqual(h.started, []);
  const h2 = newHarness(t);
  await h2.run("{}", "5");
  assert.equal(h2.s.last().code, 404, "範囲外の index");
  assert.equal("code" in h2.s.last().obj, false);
});

test("POST /api/roots/:i/new: 本文が読めない / 64KB 超は 400・413(台本を一度も呼ばない)", async () => {
  const t = tree(); const h = newHarness(t);
  await h.run("{not json");
  assert.equal(h.s.last().code, 400); assert.equal(h.s.last().obj.reason, "bad_body");
  const s = sink(); const started = [];
  const { req } = reqWith("");
  const out = await handleRootsNew({
    req, res: s.res, index: "0", json: s.json,
    loadRoots: () => ({ roots: [{ label: "root", path: t.root }], reason: null, dropped: [] }),
    resolveUnderRoots, readBody: async () => { throw new FakeTooLarge("too large"); },
    tooLarge, BodyTooLarge: FakeTooLarge, startWindow: (cwd) => { started.push(cwd); return { window: "@1", pane: "%1" }; },
  });
  assert.deepEqual(out, { tooLarge: true }, "BodyTooLarge は tooLarge(413)へ");
  assert.deepEqual(started, []); assert.deepEqual(h.started, []);
});

// ---- ② 会話の道の `cwd` ------------------------------------------------------------------------------

test("POST /api/sessions/:id/new: 本文なしは今までどおり会話の cwd で起動する", () => {
  const t = tree();
  const loadRoots = () => ({ roots: [{ label: "root", path: t.root }], reason: null, dropped: [] });
  assert.deepEqual(resolveRequestedCwd({ body: {}, loadRoots, resolveUnderRoots }), { cwd: null });
  // ★`cwd` 鍵が在るのに空 / 非文字列、top-level が object でない = 400 bad_body(黙って会話の cwd へ落とさない、Codex #2 後半)
  for (const body of [{ cwd: "" }, { cwd: 5 }, { cwd: [] }, { cwd: null }, null, [], "x"]) {
    const r = resolveRequestedCwd({ body, loadRoots, resolveUnderRoots });
    assert.equal(r.status, 400, JSON.stringify(body)); assert.equal(r.body.reason, "bad_body", JSON.stringify(body));
  }
  // ★file は cwd にならない(Codex #1)
  assert.equal(resolveRequestedCwd({ body: { cwd: join(t.root, "package.json") }, loadRoots, resolveUnderRoots }).status, 409);
  // 字面: handler は本文 → resolveRequestedCwd → cwdOfSessionFile → startPhoneWindow の順
  const h = SERVER.slice(SERVER.indexOf('if (action === "new" && req.method === "POST")'));
  const i = (s) => h.indexOf(s);
  assert.ok(i("readBody(req)") < i("resolveRequestedCwd(") && i("resolveRequestedCwd(") < i("cwdOfSessionFile(file)") && i("cwdOfSessionFile(file)") < i("startPhoneWindow(cwd)"));
});

test("★POST /api/sessions/:id/new: cwd 付きは roots の外なら 400 outside_roots", () => {
  const t = tree();
  const loadRoots = () => ({ roots: [{ label: "root", path: t.root }], reason: null, dropped: [] });
  const inside = resolveRequestedCwd({ body: { cwd: join(t.root, "inner") }, loadRoots, resolveUnderRoots });
  assert.deepEqual(inside, { cwd: join(t.root, "inner") });
  const out = resolveRequestedCwd({ body: { cwd: t.outside }, loadRoots, resolveUnderRoots });
  assert.deepEqual(out, { status: 400, body: { error: "outside the desk roots", reason: ROOTS_OUTSIDE } });
  const esc = resolveRequestedCwd({ body: { cwd: join(t.root, "escape") }, loadRoots, resolveUnderRoots });
  assert.equal(esc.status, 400, "symlink で外へ出た実体");
  const gone = resolveRequestedCwd({ body: { cwd: join(t.root, "nope") }, loadRoots, resolveUnderRoots });
  assert.deepEqual(gone, { status: 409, body: { error: "directory gone", reason: ROOTS_CWD_GONE } });
  const none = resolveRequestedCwd({ body: { cwd: t.root }, loadRoots: () => ({ roots: [], reason: ROOTS_NONE, dropped: [] }), resolveUnderRoots });
  assert.deepEqual(none, { status: 400, body: { error: "no roots on the desk", reason: ROOTS_NONE } });
});

test("POST /api/sessions/:id/new: 本文が読めない / 64KB 超は 400・413(台本を一度も呼ばない)", () => {
  // 字面: 会話の道は `BodyTooLarge` を `tooLarge` へ、他の parse 失敗を 400 `bad_body` へ、tmux の前に流す
  const h = SERVER.slice(SERVER.indexOf('if (action === "new" && req.method === "POST")'), SERVER.indexOf("startPhoneWindow(cwd)"));
  assert.match(h, /if \(e instanceof BodyTooLarge\) return tooLarge\(req, res, e\);/);
  assert.match(h, /reason: "bad_body"/);
});
