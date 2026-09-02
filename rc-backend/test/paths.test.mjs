// `src/paths.mjs` —— `@` の補完が歩く範囲と、止まる条件。
//
// ★実物の file system で測る(作り物の `readdir` を既定にしない)。此の module の
//   主張は「symlink の輪で止まらない」「読めない dir で全体を落とさない」の様に
//   **file system の振る舞いに乗っている**物が多く、作り物で測ると「私が想像した
//   file system」を測る事になる。予算(時間)だけは注入する —— 実時間に頼ると
//   速い機械で緑・遅い機械で赤という、検査の側が非決定になる形しか作れない。
//
// ★★此の file は**関数の扉**。配線(ルート表 / 宣言順)は此処では一切測れないので、
//   往復は `test/e2e-local.mjs` が持つ(2026-08-31 の実害と同じ形)。
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, symlinkSync, chmodSync, rmSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import {
  completePaths, clampLimit, matches, mayContain, normalizeQuery,
  PATHS_DEFAULT_LIMIT, PATHS_MAX_LIMIT, PATHS_NO_CWD, PATHS_QUERY_MAX,
  PATHS_SKIPPED, PATHS_UNREADABLE,
} from "../src/paths.mjs";

/** 検査ごとに使い捨ての木を作る。**同じ木を使い回さない**(前の検査の残骸で緑になる)。 */
function tree() {
  const root = mkdtempSync(join(tmpdir(), "rc-paths-"));
  mkdirSync(join(root, "src"));
  mkdirSync(join(root, "src", "deep"));
  mkdirSync(join(root, "test"));
  mkdirSync(join(root, "node_modules"));
  mkdirSync(join(root, "node_modules", "left"));
  mkdirSync(join(root, ".git"));
  mkdirSync(join(root, "build"));
  writeFileSync(join(root, "README.md"), "x");
  // ★直下に「問いを**含む**が、問いで**始まらない**」名前を置く(2026-09-02、変異 M2)。
  //   之が無いと、前方一致の主張を測っているのは `mayContain` の枝刈りだけになる ——
  //   実測: `matches` を `includes` に変えても、深い所は枝刈りが先に止めるので緑のままだった。
  //   根の直下は枝刈りを通らないので、此処が `matches` そのものへ届く唯一の的。
  writeFileSync(join(root, "mywire.mjs"), "x");
  writeFileSync(join(root, "src", "wire.mjs"), "x");
  writeFileSync(join(root, "src", "widget.mjs"), "x");
  writeFileSync(join(root, "src", "server.mjs"), "x");
  writeFileSync(join(root, "src", "deep", "wonder.txt"), "x");
  writeFileSync(join(root, "test", "wire.test.mjs"), "x");
  writeFileSync(join(root, "node_modules", "left", "index.js"), "x");
  writeFileSync(join(root, ".git", "HEAD"), "x");
  writeFileSync(join(root, "build", "out.o"), "x");
  return root;
}

const paths = (r) => r.paths.map((p) => p.path);
const kindOfPath = (r, p) => r.paths.find((x) => x.path === p)?.kind;

// ── 一致の形 ──────────────────────────────────────────────────────────────

test("問いは相対 path の前方一致で、区切りを跨ぐ(`src/wi` → `src/wire.mjs`)", () => {
  const root = tree();
  try {
    const r = completePaths(root, "src/wi");
    assert.deepEqual(paths(r).sort(), ["src/widget.mjs", "src/wire.mjs"]);
    assert.equal(r.truncated, false);
    assert.equal(r.reason, null);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("★対照: 部分一致では**ない**(「wire」は「mywire.mjs」も `src/wire.mjs` も出さない)", () => {
  // 之が緑のままだと「前方一致」という主張が測られていない —— 曖昧一致へ広げた
  // 実装でも上の検査は通る(前方一致は部分一致の部分集合)。
  //
  // ★2 つの的を**両方**当てる(2026-09-02、変異 M2 が教えた):
  //   「mywire.mjs」= 根の直下 = 枝刈りを通らないので `matches` そのものへ届く
  //   `src/wire.mjs` = 深い所 = `mayContain` の枝刈りが止める
  //   実測: `matches` だけを `includes` に変えると、後者は枝刈りに守られて緑のまま。
  //   片方だけ置くと「前方一致を測っている」の半分が嘘になる。
  const root = tree();
  try {
    assert.deepEqual(paths(completePaths(root, "wire")), []);
    // 錨: 前方一致なら当たる問いでは、其の同じ file が出る(検体が的として生きている)
    assert.deepEqual(paths(completePaths(root, "mywire")), ["mywire.mjs"]);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("dir も候補に出て、`kind` で file と区別が付く", () => {
  const root = tree();
  try {
    const r = completePaths(root, "src");
    assert.equal(kindOfPath(r, "src"), "dir");
    assert.equal(kindOfPath(r, "src/wire.mjs"), "file");
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("★問いが空なら cwd の**直下だけ**(全走査しない)。之は上限ではないので truncated は立たない", () => {
  const root = tree();
  try {
    const r = completePaths(root, "");
    assert.deepEqual(paths(r).sort(), ["README.md", "mywire.mjs", "src", "test"]);
    assert.equal(r.truncated, false, "直下だけ返すのは範囲の定義であって打ち切りではない");
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("並びは名前順に固定する(readdir の順に左右されない)", () => {
  const root = tree();
  try {
    const a = paths(completePaths(root, "src/"));
    const b = paths(completePaths(root, "src/"));
    assert.deepEqual(a, b);
    assert.deepEqual(a.slice(0, 3), ["src/deep", "src/server.mjs", "src/widget.mjs"]);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("浅い物が先に出る(幅優先)", () => {
  const root = tree();
  try {
    const r = paths(completePaths(root, "src/"));
    assert.ok(r.indexOf("src/deep") < r.indexOf("src/deep/wonder.txt"),
      `幅優先になっていない: ${JSON.stringify(r)}`);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

// ── 除外 ──────────────────────────────────────────────────────────────────

test("★生成木は候補にも出ず、中へも降りない", () => {
  const root = tree();
  try {
    for (const d of PATHS_SKIPPED) {
      const r = completePaths(root, d);
      assert.deepEqual(paths(r), [], `${d} が候補に出ている`);
      assert.equal(r.truncated, false, `${d} の除外が打ち切りとして数えられている`);
    }
    // 中の物も出ない(降りていない事の直接の証拠)
    assert.deepEqual(paths(completePaths(root, "node_modules/left")), []);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("★対照: 除外の一覧に無い dir は同じ深さで出る(除外が効き過ぎていない)", () => {
  const root = tree();
  try {
    assert.deepEqual(paths(completePaths(root, "test")).sort(),
      ["test", "test/wire.test.mjs"]);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

// ── 有界 ──────────────────────────────────────────────────────────────────

test("★件数の上限に当たったら truncated を名乗る(黙って切らない)", () => {
  const root = tree();
  try {
    const r = completePaths(root, "src/", { limit: 1 });
    assert.equal(r.paths.length, 1);
    assert.equal(r.truncated, true);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("★対照: 上限に届かなければ truncated は偽(定数を焼いていない)", () => {
  const root = tree();
  try {
    assert.equal(completePaths(root, "src/", { limit: 50 }).truncated, false);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("★深さの上限に当たったら truncated を名乗る", () => {
  const root = tree();
  try {
    const r = completePaths(root, "src/", { maxDepth: 2 });
    assert.ok(!paths(r).includes("src/deep/wonder.txt"), "上限を越えて降りている");
    assert.equal(r.truncated, true);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("★見た項目の上限に当たったら truncated を名乗る", () => {
  const root = tree();
  try {
    const r = completePaths(root, "src/", { entryBudget: 1 });
    assert.equal(r.truncated, true);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("★時間の上限に当たったら truncated を名乗る(時計は注入する)", () => {
  const root = tree();
  try {
    // 1歩ごとに 10ms 進む時計。5ms の予算なら最初の項目で切れる。
    let t = 0;
    const r = completePaths(root, "src/", { msBudget: 5, now: () => (t += 10) });
    assert.equal(r.truncated, true);
    // 対照: 同じ時計でも予算が十分なら切れない
    t = 0;
    assert.equal(completePaths(root, "src/", { msBudget: 10_000, now: () => (t += 10) }).truncated, false);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

// ── 問いを path として使わない ────────────────────────────────────────────

test("★★木の外を指す問いは 0 件(問いを join も resolve もしていない事の証拠)", () => {
  const root = tree();
  try {
    for (const q of ["../", "../../etc/passwd", "/etc/passwd", "..", "./src"]) {
      const r = completePaths(root, q);
      assert.deepEqual(paths(r), [], `${q} で何かが返った`);
      assert.equal(r.reason, null, `${q} で断りの語が出た(0 件で足りる)`);
    }
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("長い問いは切って扱う(長さで走査を膨らませない)", () => {
  const long = "a".repeat(PATHS_QUERY_MAX + 50);
  assert.equal(normalizeQuery(long).length, PATHS_QUERY_MAX);
  assert.equal(normalizeQuery("src/wi"), "src/wi", "短い問いは書き換えない");
});

// ── 読めない場所 ──────────────────────────────────────────────────────────

test("★根が読めない = 空 + `cwd_unreadable`(例外を投げない)", () => {
  const r = completePaths(join(tmpdir(), "rc-paths-does-not-exist-2026"), "x");
  assert.deepEqual(r.paths, []);
  assert.equal(r.truncated, false);
  assert.equal(r.reason, PATHS_UNREADABLE);
});

test("★途中の dir が読めなくても全体は答える(其の枝だけ諦め、打ち切りを名乗る)", () => {
  const root = tree();
  const locked = join(root, "src", "locked");
  try {
    mkdirSync(locked);
    writeFileSync(join(locked, "inside.txt"), "x");
    chmodSync(locked, 0o000);
    const r = completePaths(root, "src/");
    assert.ok(paths(r).includes("src/wire.mjs"), "読めた枝まで捨てている");
    // root で走らせると chmod 000 でも読めてしまう機械が在る。読めた場合は
    // `inside.txt` が出るので、其の時は「打ち切りを名乗る」の主張は当たらない。
    if (!paths(r).includes("src/locked/inside.txt")) {
      assert.equal(r.truncated, true, "読めなかった枝を黙って落としている");
    }
  } finally {
    try { chmodSync(locked, 0o755); } catch { /* 作れていない */ }
    rmSync(root, { recursive: true, force: true });
  }
});

test("★symlink は解決先の種別で名乗り、その先へは降りない(輪で止まらない)", () => {
  const root = tree();
  try {
    symlinkSync(root, join(root, "loop")); // 自分自身への輪
    symlinkSync(join(root, "README.md"), join(root, "readme-link"));
    const r = completePaths(root, "");
    assert.equal(kindOfPath(r, "loop"), "dir", "解決先が dir なのに file と名乗っている");
    assert.equal(kindOfPath(r, "readme-link"), "file");
    // 降りていれば `loop/loop/...` が無限に生えて予算で切れる。切れていない = 降りていない。
    const deep = completePaths(root, "loop/");
    assert.deepEqual(paths(deep), [], "symlink の先へ降りている(輪を作られる)");
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("壊れた symlink は候補に出さない(差せない物を出さない)", () => {
  const root = tree();
  try {
    symlinkSync(join(root, "nothing-here"), join(root, "dangling"));
    assert.ok(!paths(completePaths(root, "")).includes("dangling"));
  } finally { rmSync(root, { recursive: true, force: true }); }
});

// ── 純関数 ────────────────────────────────────────────────────────────────

test("`matches` は前方一致、空の問いは何にでも当たる", () => {
  assert.equal(matches("src/wire.mjs", "src/wi"), true);
  assert.equal(matches("src/wire.mjs", "wire"), false);
  assert.equal(matches("src/wire.mjs", ""), true);
});

test("★`mayContain` は「降りる価値が在るか」を両向きで答える", () => {
  // 問いの方が長い = 其の dir を通っていく道
  assert.equal(mayContain("src", "src/wi"), true);
  // 問いの方が短い = 其の dir の下は全部当たる
  assert.equal(mayContain("src/deep", "src/"), true);
  // 枝が違う
  assert.equal(mayContain("test", "src/wi"), false);
  // 根と空の問いは常に真
  assert.equal(mayContain("", "src/wi"), true);
  assert.equal(mayContain("test", ""), true);
  // ★接頭辞の取り違え。`srcx` は `src/` で始まらないので降りてはいけない。
  assert.equal(mayContain("srcx", "src/wi"), false);
});

test("上限の枠。読めない値・空欄は既定へ(1 件に潰さない)", () => {
  assert.equal(clampLimit(null), PATHS_DEFAULT_LIMIT);
  assert.equal(clampLimit(undefined), PATHS_DEFAULT_LIMIT);
  assert.equal(clampLimit(""), PATHS_DEFAULT_LIMIT);
  assert.equal(clampLimit("abc"), PATHS_DEFAULT_LIMIT);
  assert.equal(clampLimit("-5"), PATHS_DEFAULT_LIMIT);
  assert.equal(clampLimit("0"), PATHS_DEFAULT_LIMIT);
  assert.equal(clampLimit("7"), 7);
  assert.equal(clampLimit("999999"), PATHS_MAX_LIMIT);
});

test("断りの語は `reqlog` の語彙に通る綴りである(行の `reason=` が `-` にならない)", () => {
  for (const w of [PATHS_NO_CWD, PATHS_UNREADABLE]) {
    assert.match(w, /^[a-z][a-z0-9_-]{0,23}$/, `記録に載らない綴り: ${w}`);
  }
});

// ── 配線の順序 ────────────────────────────────────────────────────────────
//
// ★2026-08-31 の実害の型そのもの: `server.mjs` に新しいルートを `const` の宣言より
//   **前**へ置き、全ルートを壊したまま検査 1777 件が緑だった。捕まえたのは実サーバへ
//   HTTP を撃つ対照 1 本だけ。此の 2 本は其の 1 本の**安い前哨**で、赤の理由を
//   「補完だけが落ちた」ではなく「宣言順が壊れている」と名前で言う。
//   本物の守りは `test/e2e-local.mjs` の往復の側に在る(此処では代えられない)。
const SERVER_SRC = readFileSync(join(dirname(fileURLToPath(import.meta.url)), "..", "src", "server.mjs"), "utf8");

test("★補完の道が、会話の存在検査(SESSION_ROUTE_RE)より後ろに居る", () => {
  const route = SERVER_SRC.indexOf('if (action === "paths" && req.method === "GET")');
  const guard = SERVER_SRC.indexOf("SESSION_ROUTE_RE.exec(path)");
  assert.notEqual(route, -1, "補完の道が server.mjs に無い");
  assert.ok(guard !== -1 && guard < route,
    "存在しない会話の cwd を歩ける実装を落とす(存在検査の前に道が居る)");
});

test("★★補完の道が `sessionCwd` の**宣言より後ろ**に居る(2026-08-31 の型)", () => {
  const decl = SERVER_SRC.indexOf("const sessionCwd = ");
  const route = SERVER_SRC.indexOf('if (action === "paths" && req.method === "GET")');
  assert.notEqual(decl, -1, "`sessionCwd` の宣言が見つからない(改名したら此の錨も直す)");
  assert.ok(decl < route,
    "`const` の宣言より前で使っている = 実行時に TDZ で落ち、**この道より下の全ルートが死ぬ**");
});
