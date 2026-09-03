// `src/roots.mjs` の対照(2026-09-03、対照表 #11)。守る線は 2 方向: 受けるべき物を受ける / 受けては
// いけない物を**実体で**弾く。文字列の前方一致(prefix trap)と symlink の抜け道は実 fs で確かめる。
import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, symlinkSync, writeFileSync, realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, sep } from "node:path";
import {
  parseRoots, expandHome, labelOf, loadRoots, contains, resolveUnderRoots,
  ROOTS_NONE, ROOTS_OUTSIDE, ROOTS_CWD_GONE, ROOTS_MAX,
} from "../src/roots.mjs";

const HOME = "/home/x";

test("parseRoots: ~ 展開・コメント・空行・重複・相対の扱い", () => {
  const { roots, dropped } = parseRoots("# 台帳\n~/Infra\n\n~/Infra  # 同じ\n/opt/work\nrelative/dir\n~\n", { home: HOME });
  assert.deepEqual(roots, ["/home/x/Infra", "/opt/work", "/home/x"]);
  assert.deepEqual(dropped, ["relative/dir"]);
});

test("parseRoots: 上限を超えた行は読まない", () => {
  const text = Array.from({ length: ROOTS_MAX + 3 }, (_, i) => `/r${i}`).join("\n");
  const { roots, dropped } = parseRoots(text, { home: HOME });
  assert.equal(roots.length, ROOTS_MAX);
  assert.equal(dropped.length, 3);
});

test("expandHome / labelOf は往復する", () => {
  assert.equal(expandHome("~/a/b", HOME), "/home/x/a/b");
  assert.equal(expandHome("~", HOME), "/home/x");
  assert.equal(expandHome("/abs", HOME), "/abs");
  assert.equal(labelOf("/home/x/a", HOME), "~/a");
  assert.equal(labelOf("/home/x", HOME), "~");
  assert.equal(labelOf("/opt/w", HOME), "…/w", "home の外は basename だけ(絶対 path を線に出さない、Codex #4)");
  assert.equal(labelOf("/home/xy/a", HOME), "…/a", "`/home/xy` は home の下ではない(prefix trap)");
});

const DIR = () => ({ isDirectory: () => true });   // 偽 fs: 全部 dir
const FILE = () => ({ isDirectory: () => false });

test("loadRoots: 台帳が無い / 空 / 全行解決不能 = no_roots(fail closed)", () => {
  const enoent = () => { const e = new Error("nope"); e.code = "ENOENT"; throw e; };
  assert.deepEqual(loadRoots({ file: "/nowhere", readFile: enoent, realpath: (p) => p, stat: DIR, home: HOME }),
    { roots: [], reason: ROOTS_NONE, dropped: [] });
  assert.equal(loadRoots({ readFile: () => "\n# only comments\n", realpath: (p) => p, stat: DIR, home: HOME }).reason, ROOTS_NONE);
  const r = loadRoots({ readFile: () => "~/gone\n", realpath: () => { throw new Error("ENOENT"); }, stat: DIR, home: HOME });
  assert.equal(r.reason, ROOTS_NONE);
  assert.deepEqual(r.dropped, ["/home/x/gone"]);
});

test("loadRoots: 読めない台帳も受けない(理由は dropped に残る)", () => {
  const eacces = () => { const e = new Error("denied"); e.code = "EACCES"; throw e; };
  const r = loadRoots({ readFile: eacces, realpath: (p) => p, stat: DIR, home: HOME });
  assert.equal(r.reason, ROOTS_NONE);
  assert.match(r.dropped[0], /unreadable: EACCES/);
});

test("loadRoots: 解決済みの root と札。symlink で同じ実体になる 2 行は 1 つ", () => {
  const realpath = (p) => (p === "/home/x/link" ? "/home/x/Infra" : p);
  const r = loadRoots({ readFile: () => "~/Infra\n~/link\n/opt/work\n", realpath, stat: DIR, home: HOME });
  assert.deepEqual(r.roots, [{ label: "~/Infra", path: "/home/x/Infra" }, { label: "…/work", path: "/opt/work" }]);
  assert.equal(r.reason, null);
});

test("★loadRoots: 台帳の行が file を指す = 受ける場所ではない(落とす)。全行 file なら no_roots", () => {
  const stat = (p) => (p === "/home/x/notes.txt" ? FILE() : DIR());
  const r = loadRoots({ readFile: () => "~/notes.txt\n~/Infra\n", realpath: (p) => p, stat, home: HOME });
  assert.deepEqual(r.roots, [{ label: "~/Infra", path: "/home/x/Infra" }]);
  assert.deepEqual(r.dropped, ["/home/x/notes.txt"]);
  const only = loadRoots({ readFile: () => "~/notes.txt\n", realpath: (p) => p, stat: FILE, home: HOME });
  assert.equal(only.reason, ROOTS_NONE);
});

test("contains: 等しい / 下 / prefix trap / 親", () => {
  assert.equal(contains("/a/b", "/a/b"), true);
  assert.equal(contains("/a/b", "/a/b/c"), true);
  assert.equal(contains("/a/b", "/a/bc"), false, "`/a/bc` は `/a/b` の下ではない");
  assert.equal(contains("/a/b", "/a"), false);
  assert.equal(contains("/", "/etc"), true, "root が `/` なら sep の二重化で外れない");
});

test("resolveUnderRoots: 偽 realpath での判定(下 / 外 / 無い / 相対 / roots 無し)", () => {
  const roots = [{ label: "~/Infra", path: "/home/x/Infra" }];
  const realpath = (p) => { if (p.includes("gone")) throw new Error("ENOENT"); return p; };
  const stat = (p) => (p.endsWith(".txt") ? FILE() : DIR());
  assert.deepEqual(resolveUnderRoots(roots, "~/Infra/app", { realpath, stat, home: HOME }),
    { ok: true, cwd: "/home/x/Infra/app", root: roots[0] });
  assert.deepEqual(resolveUnderRoots(roots, "/home/x/Infrastructure", { realpath, stat, home: HOME }), { ok: false, reason: ROOTS_OUTSIDE });
  assert.deepEqual(resolveUnderRoots(roots, "/etc", { realpath, stat, home: HOME }), { ok: false, reason: ROOTS_OUTSIDE });
  assert.deepEqual(resolveUnderRoots(roots, "~/Infra/gone", { realpath, stat, home: HOME }), { ok: false, reason: ROOTS_CWD_GONE });
  assert.deepEqual(resolveUnderRoots(roots, "~/Infra/notes.txt", { realpath, stat, home: HOME }), { ok: false, reason: ROOTS_CWD_GONE },
    "★file は cwd にならない(tmux は chdir に失敗すると $HOME へ落ちて其のまま起動する、Codex #1)");
  assert.deepEqual(resolveUnderRoots(roots, "Infra/app", { realpath, stat, home: HOME }), { ok: false, reason: ROOTS_OUTSIDE }, "相対は受けない");
  assert.deepEqual(resolveUnderRoots([], "~/Infra", { realpath, stat, home: HOME }), { ok: false, reason: ROOTS_NONE });
  assert.deepEqual(resolveUnderRoots(roots, "", { realpath, stat, home: HOME }), { ok: false, reason: ROOTS_OUTSIDE });
});

test("resolveUnderRoots: 実 fs — symlink の抜け道と `..` は実体で弾く、root の下の symlink が root 内を指せば受ける", () => {
  const base = realpathSync(mkdtempSync(join(tmpdir(), "roots-")));
  const root = join(base, "root"); const outside = join(base, "outside");
  mkdirSync(join(root, "inner", "deep"), { recursive: true }); mkdirSync(outside);
  symlinkSync(outside, join(root, "escape"));           // root/escape -> outside(抜け道)
  symlinkSync(join(root, "inner"), join(root, "alias")); // root/alias -> root/inner(内側)
  writeFileSync(join(root, "file.txt"), "x");
  const roots = [{ label: "root", path: root }];
  const inside = resolveUnderRoots(roots, join(root, "inner", "deep"));
  assert.equal(inside.ok, true); assert.equal(inside.cwd, join(root, "inner", "deep"));
  assert.deepEqual(resolveUnderRoots(roots, join(root, "escape")), { ok: false, reason: ROOTS_OUTSIDE }, "symlink 経由で外へ出た実体は外");
  assert.deepEqual(resolveUnderRoots(roots, join(root, "inner", "..", "..", "outside")), { ok: false, reason: ROOTS_OUTSIDE }, "`..` で root の外へ出た物は外");
  const alias = resolveUnderRoots(roots, join(root, "alias", "deep"));
  assert.equal(alias.ok, true); assert.equal(alias.cwd, join(root, "inner", "deep"), "内側を指す symlink は実体に畳んで受ける");
  assert.equal(resolveUnderRoots(roots, join(root, "missing")).reason, ROOTS_CWD_GONE);
  assert.equal(resolveUnderRoots(roots, join(root, "file.txt")).reason, ROOTS_CWD_GONE, "★実 fs でも file は受けない(Codex #1)");
  assert.equal(resolveUnderRoots(roots, join(base, "root-2")).reason, ROOTS_CWD_GONE, "`root-2` は無いので gone(在れば prefix trap で outside)");
  mkdirSync(join(base, "root-2"));
  assert.equal(resolveUnderRoots(roots, join(base, "root-2")).reason, ROOTS_OUTSIDE, "`<root>-2` は `<root>` の下ではない");
  assert.equal(sep, "/");
});
