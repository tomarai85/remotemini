// 差分を読む側(`src/sessiondiff.mjs`)の単体。**関数の扉**。
//
// ★此処が緑でも「電話で差分が読める」証拠にはならない。配線(道の白名簿・
//   ハンドラの位置・封筒)は `test/e2e-local.mjs` の扉Fが実サーバへ HTTP を
//   撃って測る —— 2026-08-31 に `server.mjs` の宣言順序で全ルートが死んだ時、
//   1777 件の関数の検査は全部緑のまま、捕まえたのは其の 1 本だけだった。
//   役割を分けたまま両方が見張る。
import { test } from "node:test";
import assert from "node:assert/strict";
import { capFiles, DIFF_LIMITS, notARepo, parseDiff, readWorkingDiff } from "../src/sessiondiff.mjs";

// 実物を写した 1 本(`git diff` の既定の出力)。★手で綺麗にしない ——
// `index …` の行も `\ No newline` も本物には在るので、在るまま食わせる。
const UNSTAGED = `diff --git a/src/app.js b/src/app.js
index 1111111..2222222 100644
--- a/src/app.js
+++ b/src/app.js
@@ -1,4 +1,5 @@
 const x = 1;
-const y = 2;
+const y = 3;
+const z = 4;
 module.exports = { x };
diff --git a/notes.txt b/notes.txt
deleted file mode 100644
index 3333333..0000000
--- a/notes.txt
+++ /dev/null
@@ -1,2 +0,0 @@
-古い覚書
-2 行目
diff --git a/logo.png b/logo.png
index 4444444..5555555 100644
Binary files a/logo.png and b/logo.png differ
`;

const STAGED = `diff --git a/README.md b/README.md
new file mode 100644
index 0000000..6666666
--- /dev/null
+++ b/README.md
@@ -0,0 +1,2 @@
+# 題
+本文
\\ No newline at end of file
`;

// --- parseDiff -----------------------------------------------------------------

test("parseDiff: file ごとに割れて、path は `+++` から取る", () => {
  const files = parseDiff(UNSTAGED, false);
  assert.deepEqual(files.map((f) => f.path), ["src/app.js", "notes.txt", "logo.png"]);
  // 接頭辞 `b/` は落ちている(落とし忘れると電話に `b/src/app.js` と出る)。
  assert.equal(files[0].path.startsWith("b/"), false);
});

test("parseDiff: 削除された file は `--- a/…` から名前を取る(`+++` は /dev/null)", () => {
  const del = parseDiff(UNSTAGED, false).find((f) => f.removed === 2);
  assert.equal(del.path, "notes.txt");
  assert.equal(del.added, 0);
});

test("parseDiff: 足した行と引いた行を数える(文脈は数えない)", () => {
  const f = parseDiff(UNSTAGED, false)[0];
  assert.equal(f.added, 2);
  assert.equal(f.removed, 1);
  const kinds = f.hunks[0].lines.map((l) => l.kind);
  assert.deepEqual(kinds, ["ctx", "del", "add", "add", "ctx"]);
});

test("parseDiff: 塊の頭書きをそのまま運ぶ(電話が `@@` の行を出せる)", () => {
  const f = parseDiff(UNSTAGED, false)[0];
  assert.equal(f.hunks.length, 1);
  assert.equal(f.hunks[0].header, "@@ -1,4 +1,5 @@");
});

test("parseDiff: 行の text から先頭の記号を落とす(色は kind が持つ)", () => {
  const f = parseDiff(UNSTAGED, false)[0];
  const add = f.hunks[0].lines.filter((l) => l.kind === "add").map((l) => l.text);
  assert.deepEqual(add, ["const y = 3;", "const z = 4;"]);
});

test("parseDiff: 2 進の file は `binary` を名乗り、本文を運ばない", () => {
  const bin = parseDiff(UNSTAGED, false).find((f) => f.path === "logo.png");
  assert.equal(bin.binary, true);
  assert.deepEqual(bin.hunks, []);
  // ★0 は「変わっていない」ではなく「行では数えられない」。電話は `binary` で読む。
  assert.equal(bin.added + bin.removed, 0);
});

test("parseDiff: `\\ No newline at end of file` は文脈として残す(数には入れない)", () => {
  const f = parseDiff(STAGED, true)[0];
  const last = f.hunks[0].lines[f.hunks[0].lines.length - 1];
  assert.equal(last.kind, "ctx");
  assert.match(last.text, /No newline/);
  assert.equal(f.added, 2); // 印の行を足し算に混ぜていない
});

test("parseDiff: `staged` は呼び手が決める(同じ parser で 2 面を読む)", () => {
  assert.equal(parseDiff(STAGED, true)[0].staged, true);
  assert.equal(parseDiff(UNSTAGED, false)[0].staged, false);
});

test("parseDiff: 空の出力は 0 件(差分が無い事は異常ではない)", () => {
  assert.deepEqual(parseDiff("", false), []);
  assert.deepEqual(parseDiff(null, false), []);
});

// --- capFiles ------------------------------------------------------------------

/** 大きな file を 1 本作る(1 行 = `len` bytes)。 */
function bigFile(path, lines, len) {
  const body = [];
  for (let i = 0; i < lines; i += 1) body.push({ kind: "add", text: "x".repeat(len) });
  return {
    path, staged: false, binary: false, added: lines, removed: 0,
    hunks: [{ header: "@@ -0,0 +1 @@", lines: body }], bytes: lines * len,
  };
}

const SMALL_LIMITS = { maxFileBytes: 100, maxTotalBytes: 250, maxFiles: 3 };

test("capFiles: 天井の下では 1 バイトも切らない", () => {
  const f = bigFile("a", 5, 10); // 50 bytes
  const r = capFiles([f], SMALL_LIMITS);
  assert.equal(r.truncated, false);
  assert.equal(r.files[0].hunks[0].lines.length, 5);
  assert.equal(r.files[0].truncated, false);
});

test("★capFiles: 1 file の天井を超えたら**行の境で**切り、切ったと名乗る", () => {
  const r = capFiles([bigFile("a", 50, 10)], SMALL_LIMITS); // 500 bytes > 100
  assert.equal(r.truncated, true);
  assert.equal(r.files[0].truncated, true);
  const lines = r.files[0].hunks[0].lines;
  assert.equal(lines.length, 10); // 100 / 10
  // ★行の途中で切っていない。半分の行を出すと、読んだ人が「そういうコード」と読む。
  assert.ok(lines.every((l) => l.text.length === 10), JSON.stringify(lines.map((l) => l.text.length)));
});

test("★★capFiles: 切っても `added` / `removed` は切る前の数のまま(数は嘘を吐かない)", () => {
  const r = capFiles([bigFile("a", 50, 10)], SMALL_LIMITS);
  assert.equal(r.files[0].added, 50);          // 出した行は 10 本だけ
  assert.equal(r.files[0].hunks[0].lines.length, 10);
});

test("capFiles: 全体の天井に当たると、以後の file は本文なしで並ぶ(名前は消さない)", () => {
  const r = capFiles([bigFile("a", 10, 10), bigFile("b", 10, 10), bigFile("c", 10, 10)], SMALL_LIMITS);
  assert.equal(r.truncated, true);
  assert.deepEqual(r.files.map((f) => f.path), ["a", "b", "c"]);
  // 3 本目は全体の天井(250)を使い切った後なので本文が無い。だが在る事は判る。
  assert.equal(r.files[2].truncated, true);
  assert.equal(r.files[2].added, 10);
});

test("capFiles: file の本数の天井(並べるだけでも費用が在る)", () => {
  const many = [];
  for (let i = 0; i < 5; i += 1) many.push(bigFile(`f${i}`, 1, 1));
  const r = capFiles(many, SMALL_LIMITS);
  assert.equal(r.files.length, 3);
  assert.equal(r.truncated, true);
});

test("★陰性対照: 判定は常に真を返していない(天井を上げれば truncated は下りる)", () => {
  const f = bigFile("a", 50, 10);
  assert.equal(capFiles([f], SMALL_LIMITS).truncated, true);
  assert.equal(capFiles([f], DIFF_LIMITS).truncated, false);
});

// --- notARepo ------------------------------------------------------------------

test("notARepo: git の一文を読み分ける(他の失敗を repo 無しに丸めない)", () => {
  assert.equal(notARepo("fatal: not a git repository (or any of the parent directories): .git"), true);
  assert.equal(notARepo("fatal: bad object HEAD"), false);
  assert.equal(notARepo(""), false);
  assert.equal(notARepo(undefined), false);
});

// --- readWorkingDiff -----------------------------------------------------------

/** git を差し替える。`calls` に撃った物が全部残る。 */
function fakeGit(plan) {
  const calls = [];
  return {
    calls,
    exec: async (bin, args, opts) => {
      calls.push({ bin, args, opts });
      const cached = args.includes("--cached");
      const r = cached ? plan.staged : plan.unstaged;
      if (r instanceof Error) throw r;
      return { stdout: r ?? "", stderr: "" };
    },
  };
}
const always = () => true;

test("★readWorkingDiff: 作業木と index の両方を読み、`staged` で見分けられる", async () => {
  const g = fakeGit({ unstaged: UNSTAGED, staged: STAGED });
  const r = await readWorkingDiff("/w", { exec: g.exec, exists: always });
  assert.equal(r.reason, null);
  assert.deepEqual(
    r.files.map((f) => [f.path, f.staged]),
    [["src/app.js", false], ["notes.txt", false], ["logo.png", false], ["README.md", true]],
  );
});

test("★readWorkingDiff: 撃つ git は `diff` の 2 本だけ(書く動詞が 1 つも無い)", async () => {
  const g = fakeGit({ unstaged: "", staged: "" });
  await readWorkingDiff("/w", { exec: g.exec, exists: always });
  assert.equal(g.calls.length, 2);
  for (const c of g.calls) {
    assert.equal(c.bin, "git");
    assert.equal(c.args[1], "diff");
    // 書く動詞・状態を変える動詞が 1 つも混じっていない事を、名指しで測る。
    for (const verb of ["add", "commit", "checkout", "reset", "stash", "clean", "restore", "apply"]) {
      assert.equal(c.args.includes(verb), false, `書く動詞が混じった: ${verb} / ${c.args.join(" ")}`);
    }
  }
  assert.equal(g.calls[0].args.includes("--cached"), false);
  assert.equal(g.calls[1].args.includes("--cached"), true);
});

test("★readWorkingDiff: repo の設定で外部プログラムを走らせない(`--no-ext-diff` / `--no-textconv`)", async () => {
  const g = fakeGit({ unstaged: "", staged: "" });
  await readWorkingDiff("/w", { exec: g.exec, exists: always });
  for (const c of g.calls) {
    assert.ok(c.args.includes("--no-ext-diff"), c.args.join(" "));
    assert.ok(c.args.includes("--no-textconv"), c.args.join(" "));
  }
});

test("★readWorkingDiff: index の錠を取らない(覗いただけで机の git を失敗させない)", async () => {
  const g = fakeGit({ unstaged: "", staged: "" });
  await readWorkingDiff("/w", { exec: g.exec, exists: always });
  assert.equal(g.calls[0].opts.env.GIT_OPTIONAL_LOCKS, "0");
  // 言語を固定する(下の `notARepo` が git の一文を読む為)。
  assert.equal(g.calls[0].opts.env.LC_ALL, "C");
  assert.equal(g.calls[0].opts.cwd, "/w");
  assert.equal(g.calls[0].opts.timeout, DIFF_LIMITS.timeoutMs);
});

test("readWorkingDiff: 差分が無い会話は 0 件で `reason` は null(「無い」と「読めない」は別)", async () => {
  const g = fakeGit({ unstaged: "", staged: "" });
  const r = await readWorkingDiff("/w", { exec: g.exec, exists: always });
  assert.deepEqual(r.files, []);
  assert.equal(r.reason, null);
  assert.equal(r.truncated, false);
  assert.equal(r.totalBytes, 0);
});

test("readWorkingDiff: `totalBytes` は読んだ生 diff の bytes(切る前の量)", async () => {
  const g = fakeGit({ unstaged: UNSTAGED, staged: STAGED });
  const r = await readWorkingDiff("/w", { exec: g.exec, exists: always });
  assert.equal(
    r.totalBytes,
    Buffer.byteLength(UNSTAGED, "utf8") + Buffer.byteLength(STAGED, "utf8"),
  );
});

test("readWorkingDiff: cwd が無い会話は `no_cwd`(git を 1 本も撃たない)", async () => {
  const g = fakeGit({ unstaged: "", staged: "" });
  const r = await readWorkingDiff("", { exec: g.exec, exists: always });
  assert.equal(r.reason, "no_cwd");
  assert.equal(g.calls.length, 0);
});

test("readWorkingDiff: dir が消えていれば `cwd_missing`(git に訊く前に判る)", async () => {
  const g = fakeGit({ unstaged: "", staged: "" });
  const r = await readWorkingDiff("/gone", { exec: g.exec, exists: () => false });
  assert.equal(r.reason, "cwd_missing");
  assert.equal(g.calls.length, 0);
});

test("readWorkingDiff: git 管理外は `not_a_repo`(異常ではなく状態)", async () => {
  const e = new Error("fatal");
  e.stderr = "fatal: not a git repository (or any of the parent directories): .git";
  const r = await readWorkingDiff("/w", { exec: fakeGit({ unstaged: e, staged: "" }).exec, exists: always });
  assert.equal(r.reason, "not_a_repo");
  assert.deepEqual(r.files, []);
});

test("readWorkingDiff: 判らない失敗は `git_failed`(repo 無しに丸めない)", async () => {
  const e = new Error("boom");
  e.stderr = "fatal: bad object";
  const r = await readWorkingDiff("/w", { exec: fakeGit({ unstaged: e, staged: "" }).exec, exists: always });
  assert.equal(r.reason, "git_failed");
});

test("★readWorkingDiff: 器から溢れたら**部分を出して切ったと言う**(捨てて 0 件にしない)", async () => {
  const e = new Error("stdout maxBuffer length exceeded");
  e.code = "ERR_CHILD_PROCESS_STDIO_MAXBUFFER";
  e.stdout = UNSTAGED;
  const r = await readWorkingDiff("/w", {
    exec: fakeGit({ unstaged: e, staged: "" }).exec, exists: always,
  });
  assert.equal(r.reason, null);
  assert.equal(r.truncated, true);
  assert.equal(r.files.length, 3);
});

test("★readWorkingDiff: index の側だけ落ちても作業木の側は捨てない(切ったとは言う)", async () => {
  const e = new Error("boom");
  const r = await readWorkingDiff("/w", {
    exec: fakeGit({ unstaged: UNSTAGED, staged: e }).exec, exists: always,
  });
  assert.equal(r.reason, null);
  assert.equal(r.files.length, 3);
  assert.equal(r.truncated, true);
});
