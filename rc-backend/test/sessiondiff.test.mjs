// 差分を読む側(`src/sessiondiff.mjs`)の単体。**関数の扉**。
//
// ★此処が緑でも「電話で差分が読める」証拠にはならない。配線(道の白名簿・
//   ハンドラの位置・封筒)は `test/e2e-local.mjs` の扉Fが実サーバへ HTTP を
//   撃って測る —— 2026-08-31 に `server.mjs` の宣言順序で全ルートが死んだ時、
//   1777 件の関数の検査は全部緑のまま、捕まえたのは其の 1 本だけだった。
//   役割を分けたまま両方が見張る。
import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  _inflight, capFiles, DIFF_LIMITS, lineCost, MAX_CONCURRENT, notARepo, parseDiff, parseNumstat,
  readWorkingDiff,
} from "../src/sessiondiff.mjs";

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

/** 大きな file を 1 本作る(1 行 = `len` bytes の text。費用は `lineCost` = len + 1)。 */
function bigFile(path, lines, len) {
  const body = [];
  for (let i = 0; i < lines; i += 1) body.push({ kind: "add", text: "x".repeat(len) });
  return {
    path, staged: false, binary: false, added: lines, removed: 0,
    hunks: [{ header: "@@ -0,0 +1 @@", lines: body }], bytes: lines * lineCost("x".repeat(len)),
  };
}

const SMALL_LIMITS = { maxFileBytes: 100, maxTotalBytes: 250, maxFiles: 3 };

test("capFiles: 天井の下では 1 バイトも切らない", () => {
  const f = bigFile("a", 5, 10); // 5 × 11 = 55
  const r = capFiles([f], SMALL_LIMITS);
  assert.equal(r.truncated, false);
  assert.equal(r.files[0].hunks[0].lines.length, 5);
  assert.equal(r.files[0].truncated, false);
});

test("★capFiles: 1 file の天井を超えたら**行の境で**切り、切ったと名乗る", () => {
  const r = capFiles([bigFile("a", 50, 10)], SMALL_LIMITS); // 50 × 11 = 550 > 100
  assert.equal(r.truncated, true);
  assert.equal(r.files[0].truncated, true);
  const lines = r.files[0].hunks[0].lines;
  assert.equal(lines.length, 9); // floor(100 / 11)
  // ★行の途中で切っていない。半分の行を出すと、読んだ人が「そういうコード」と読む。
  assert.ok(lines.every((l) => l.text.length === 10), JSON.stringify(lines.map((l) => l.text.length)));
});

test("★★capFiles: 切っても `added` / `removed` は切る前の数のまま(数は嘘を吐かない)", () => {
  const r = capFiles([bigFile("a", 50, 10)], SMALL_LIMITS);
  assert.equal(r.files[0].added, 50);          // 出した行は 9 本だけ
  assert.equal(r.files[0].hunks[0].lines.length, 9);
});

test("capFiles: 全体の天井に当たると、以後の file は本文なしで並ぶ(名前は消さない)", () => {
  // 9 × 11 = 99 ずつ。a + b = 198、c の残り室は 52 → 4 行だけ入る。
  const r = capFiles([bigFile("a", 9, 10), bigFile("b", 9, 10), bigFile("c", 9, 10)], SMALL_LIMITS);
  assert.equal(r.truncated, true);
  assert.deepEqual(r.files.map((f) => f.path), ["a", "b", "c"]);
  assert.equal(r.files[0].truncated, false);
  assert.equal(r.files[1].truncated, false);
  // 3 本目は全体の天井(250)にほぼ当たった後なので本文が途中で止まる。だが在る事と数は判る。
  assert.equal(r.files[2].truncated, true);
  assert.equal(r.files[2].hunks[0].lines.length, 4);
  assert.equal(r.files[2].added, 9);
});

test("★capFiles: 空の追加行も費用を持つ(0 byte で天井をすり抜けない = Codex #1 の 3)", () => {
  const empties = [];
  for (let i = 0; i < 1000; i += 1) empties.push({ kind: "add", text: "" });
  const f = {
    path: "e", staged: false, binary: false, added: 1000, removed: 0,
    hunks: [{ header: "@@ -0,0 +1,1000 @@", lines: empties }], bytes: 1000 * lineCost(""),
  };
  const r = capFiles([f], { maxFileBytes: 10, maxTotalBytes: 10, maxFiles: 3 });
  assert.equal(r.truncated, true);
  assert.equal(r.files[0].hunks[0].lines.length, 10, "空行が費用 0 で全部通っている");
  assert.equal(r.files[0].added, 1000);
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
      if (args.includes("config")) return { stdout: plan.config ?? "", stderr: "" }; // driver の名前読み(実行なし)
      const cached = args.includes("--cached");
      const r = cached ? plan.staged : plan.unstaged;
      if (r instanceof Error) throw r;
      return { stdout: r ?? "", stderr: "" };
    },
  };
}
const always = () => true;
/** 偽の fs: `<cwd>/.git` は普通の dir、cwd の realpath は其のまま(git を撃たずに repo を決める為の材料)。 */
const dirStat = { isSymbolicLink: () => false, isDirectory: () => true, isFile: () => false };
const pinned = { realpath: (p) => p, lstat: (p) => (p.endsWith("/.git") ? dirStat : null) };

test("★readWorkingDiff: 作業木と index の両方を読み、`staged` で見分けられる", async () => {
  const g = fakeGit({ unstaged: UNSTAGED, staged: STAGED });
  const r = await readWorkingDiff("/w", { exec: g.exec, exists: always, ...pinned });
  assert.equal(r.reason, null);
  assert.deepEqual(
    r.files.map((f) => [f.path, f.staged]),
    [["src/app.js", false], ["notes.txt", false], ["logo.png", false], ["README.md", true]],
  );
});

test("★readWorkingDiff: 撃つ git は `diff` の 2 本だけ(書く動詞が 1 つも無い)", async () => {
  const g = fakeGit({ unstaged: "", staged: "" });
  await readWorkingDiff("/w", { exec: g.exec, exists: always, ...pinned });
  assert.equal(g.calls.length, 3, "config の名前読み 1 本 + diff 2 本");
  const diffs = g.calls.filter((c) => c.args.includes("diff"));
  assert.equal(diffs.length, 2);
  const cfg = g.calls.filter((c) => c.args.includes("config"));
  assert.equal(cfg.length, 1);
  assert.ok(cfg[0].args.includes("--list") && cfg[0].args.includes("--name-only"), "config は名前の一覧だけ(値も書き込みも無し)");
  for (const c of diffs) {
    assert.equal(c.bin, "git");
    // `-c k=v` は subcommand の前に居る。subcommand は `--no-pager` の直後。
    assert.equal(c.args[c.args.indexOf("--no-pager") + 1], "diff");
    assert.ok(c.args.indexOf("-c") < c.args.indexOf("diff"), "`-c` が subcommand の後ろ = 効かない");
    // 書く動詞・状態を変える動詞が 1 つも混じっていない事を、名指しで測る。
    for (const verb of ["add", "commit", "checkout", "reset", "stash", "clean", "restore", "apply"]) {
      assert.equal(c.args.includes(verb), false, `書く動詞が混じった: ${verb} / ${c.args.join(" ")}`);
    }
  }
  assert.equal(diffs[0].args.includes("--cached"), false);
  assert.equal(diffs[1].args.includes("--cached"), true);
});

test("★readWorkingDiff: repo の設定で外部プログラムを走らせない(`--no-ext-diff` / `--no-textconv`)", async () => {
  const g = fakeGit({ unstaged: "", staged: "" });
  await readWorkingDiff("/w", { exec: g.exec, exists: always, ...pinned });
  for (const c of g.calls.filter((x) => x.args.includes("diff"))) {
    assert.ok(c.args.includes("--no-ext-diff"), c.args.join(" "));
    assert.ok(c.args.includes("--no-textconv"), c.args.join(" "));
  }
});

test("★readWorkingDiff: index の錠を取らない(覗いただけで机の git を失敗させない)", async () => {
  const g = fakeGit({ unstaged: "", staged: "" });
  await readWorkingDiff("/w", { exec: g.exec, exists: always, ...pinned });
  assert.equal(g.calls[0].opts.env.GIT_OPTIONAL_LOCKS, "0");
  // 言語を固定する(下の `notARepo` が git の一文を読む為)。
  assert.equal(g.calls[0].opts.env.LC_ALL, "C");
  assert.equal(g.calls[0].opts.cwd, "/w");
  assert.equal(g.calls[0].opts.timeout, DIFF_LIMITS.timeoutMs);
});

test("readWorkingDiff: 差分が無い会話は 0 件で `reason` は null(「無い」と「読めない」は別)", async () => {
  const g = fakeGit({ unstaged: "", staged: "" });
  const r = await readWorkingDiff("/w", { exec: g.exec, exists: always, ...pinned });
  assert.deepEqual(r.files, []);
  assert.equal(r.reason, null);
  assert.equal(r.truncated, false);
  assert.equal(r.totalBytes, 0);
});

test("readWorkingDiff: `totalBytes` は読んだ生 diff の bytes(切る前の量)", async () => {
  const g = fakeGit({ unstaged: UNSTAGED, staged: STAGED });
  const r = await readWorkingDiff("/w", { exec: g.exec, exists: always, ...pinned });
  assert.equal(
    r.totalBytes,
    Buffer.byteLength(UNSTAGED, "utf8") + Buffer.byteLength(STAGED, "utf8"),
  );
});

test("readWorkingDiff: cwd が無い会話は `no_cwd`(git を 1 本も撃たない)", async () => {
  const g = fakeGit({ unstaged: "", staged: "" });
  const r = await readWorkingDiff("", { exec: g.exec, exists: always, ...pinned });
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
  const r = await readWorkingDiff("/w", { exec: fakeGit({ unstaged: e, staged: "" }).exec, exists: always, ...pinned });
  assert.equal(r.reason, "not_a_repo");
  assert.deepEqual(r.files, []);
});

test("readWorkingDiff: 判らない失敗は `git_failed`(repo 無しに丸めない)", async () => {
  const e = new Error("boom");
  e.stderr = "fatal: bad object";
  const r = await readWorkingDiff("/w", { exec: fakeGit({ unstaged: e, staged: "" }).exec, exists: always, ...pinned });
  assert.equal(r.reason, "git_failed");
});

test("★readWorkingDiff: 器から溢れたら**部分を出して切ったと言う**(捨てて 0 件にしない)", async () => {
  const e = new Error("stdout maxBuffer length exceeded");
  e.code = "ERR_CHILD_PROCESS_STDIO_MAXBUFFER";
  e.stdout = UNSTAGED;
  const r = await readWorkingDiff("/w", {
    exec: fakeGit({ unstaged: e, staged: "" }).exec, exists: always, ...pinned,
  });
  assert.equal(r.reason, null);
  assert.equal(r.truncated, true);
  assert.equal(r.files.length, 3);
});

test("★readWorkingDiff: index の側だけ落ちても作業木の側は捨てない(切ったとは言う)", async () => {
  const e = new Error("boom");
  const r = await readWorkingDiff("/w", {
    exec: fakeGit({ unstaged: UNSTAGED, staged: e }).exec, exists: always, ...pinned,
  });
  assert.equal(r.reason, null);
  assert.equal(r.files.length, 3);
  assert.equal(r.truncated, true);
});

// ── 2026-09-03、Codex #1 の 7 所見(`.harness/evidence-2026-09-03/codex-diff-review.md`)──

test("★readWorkingDiff: index の側だけ落ちて**何も読めなかった**時は reason を名乗る(切れた成功に化けない = 所見 5)", async () => {
  const e = new Error("boom");
  e.stderr = "fatal: bad object";
  const r = await readWorkingDiff("/w5", { exec: fakeGit({ unstaged: "", staged: e }).exec, exists: always, ...pinned });
  assert.equal(r.reason, "git_failed");
  assert.deepEqual(r.files, []);
  assert.equal(r.truncated, false);
  // 錨: 「差分が無い」(両側とも空・成功)は今も reason null(上の検査と対になる)
  const ok = await readWorkingDiff("/w5b", { exec: fakeGit({ unstaged: "", staged: "" }).exec, exists: always, ...pinned });
  assert.equal(ok.reason, null);
});

test("★readWorkingDiff: 溢れたのが stderr の側なら失敗(stdout の部分を差分として読まない = 所見 6)", async () => {
  const e = new Error("stderr maxBuffer length exceeded");
  e.code = "ERR_CHILD_PROCESS_STDIO_MAXBUFFER";
  e.stdout = UNSTAGED;
  const r = await readWorkingDiff("/w6", { exec: fakeGit({ unstaged: e, staged: "" }).exec, exists: always, ...pinned });
  assert.equal(r.reason, "git_failed");
  assert.deepEqual(r.files, []);
});

/** args を見て答えを変える git(`--numstat` の有無 / `--cached` の有無)。 */
function fakeGitByArgs(table) {
  const calls = [];
  return {
    calls,
    exec: async (bin, args, opts) => {
      calls.push({ bin, args, opts });
      if (args.includes("config")) return { stdout: table.config ?? "", stderr: "" };
      const k = `${args.includes("--numstat") ? "numstat" : "diff"}:${args.includes("--cached") ? "staged" : "unstaged"}`;
      const r = table[k];
      if (r instanceof Error) throw r;
      return { stdout: r ?? "", stderr: "" };
    },
  };
}

test("★★readWorkingDiff: 器から溢れたら `--numstat` で数を取り直す(部分の stdout の数は下限でしかない = 所見 6)", async () => {
  // 溢れた stdout は app.js の途中で切れている(= parse すると +1 -1 に見える)。本当は +2 -1。
  const cutStdout = UNSTAGED.split("\n").slice(0, 8).join("\n"); // `+const y = 3;` まで
  const e = new Error("stdout maxBuffer length exceeded");
  e.code = "ERR_CHILD_PROCESS_STDIO_MAXBUFFER";
  e.stdout = cutStdout;
  const g = fakeGitByArgs({
    "diff:unstaged": e,
    "diff:staged": "",
    "numstat:unstaged": "2\t1\tsrc/app.js\n0\t2\tnotes.txt\n-\t-\tlogo.png\n",
  });
  const r = await readWorkingDiff("/w6b", { exec: g.exec, exists: always, ...pinned });
  assert.equal(r.truncated, true);
  assert.equal(r.reason, null);
  const app = r.files.find((f) => f.path === "src/app.js");
  assert.equal(app.added, 2, "溢れた部分から数えた下限(1)のまま = 数が嘘");
  assert.equal(app.removed, 1);
  // numstat は溢れた側にだけ撃つ(index の側は溢れていないので 2 本のまま)
  assert.equal(g.calls.filter((c) => c.args.includes("--numstat")).length, 1);
  assert.ok(!g.calls.find((c) => c.args.includes("--numstat")).args.includes("--cached"));
  // 錨: 溢れていなければ numstat は撃たない
  const g2 = fakeGitByArgs({ "diff:unstaged": UNSTAGED, "diff:staged": STAGED });
  await readWorkingDiff("/w6c", { exec: g2.exec, exists: always, ...pinned });
  assert.equal(g2.calls.filter((c) => c.args.includes("diff")).length, 2);
});

test("parseNumstat: `added\\tremoved\\tpath`、2 進は `-` = null、壊れた行は捨てる", () => {
  const m = parseNumstat("2\t1\tsrc/app.js\n-\t-\tlogo.png\ngarbage\n\n");
  assert.deepEqual(m.get("src/app.js"), { added: 2, removed: 1 });
  assert.deepEqual(m.get("logo.png"), { added: null, removed: null });
  assert.equal(m.size, 2);
});

test("★parseDiff: 持つ本文は file ごとに天井まで、数は全部(8 MiB を object にしてから切らない = 所見 3)", () => {
  const lines = ["diff --git a/big b/big", "--- a/big", "+++ b/big", "@@ -0,0 +1,1000 @@"];
  for (let i = 0; i < 1000; i += 1) lines.push("+" + "y".repeat(9)); // 費用 10 / 行
  const [f] = parseDiff(lines.join("\n"), false, { maxFileBytes: 100 });
  assert.equal(f.added, 1000);
  assert.equal(f.bytes, 1000 * 10);
  assert.equal(f.hunks[0].lines.length, 10, "天井を超えた行まで持っている");
  // 錨: 既定の天井(64 KiB)なら 1,000 行 × 10 は全部持つ
  assert.equal(parseDiff(lines.join("\n"), false)[0].hunks[0].lines.length, 1000);
});

test("★readWorkingDiff: `-c core.fsmonitor=false` と `--ignore-submodules=all` を撃つ(所見 1)", async () => {
  const g = fakeGit({ unstaged: "", staged: "" });
  await readWorkingDiff("/w1", { exec: g.exec, exists: always, ...pinned });
  for (const c of g.calls.filter((x) => x.args.includes("diff"))) {
    const i = c.args.indexOf("-c");
    assert.ok(i >= 0 && c.args[i + 1] === "core.fsmonitor=false", c.args.join(" "));
    assert.ok(c.args.includes("--ignore-submodules=all"), c.args.join(" "));
  }
});

test("★readWorkingDiff: 机の `GIT_*` 環境変数を git に渡さない(所見 1・2)", async () => {
  const g = fakeGit({ unstaged: "", staged: "" });
  const saved = process.env.GIT_DIR;
  process.env.GIT_DIR = "/somewhere/else/.git";
  try {
    await readWorkingDiff("/w2", { exec: g.exec, exists: always, ...pinned });
  } finally {
    if (saved === undefined) delete process.env.GIT_DIR; else process.env.GIT_DIR = saved;
  }
  assert.equal("GIT_DIR" in g.calls[0].opts.env, false, "GIT_DIR が漏れた");
  assert.equal(g.calls[0].opts.env.GIT_OPTIONAL_LOCKS, "0");
  assert.equal(g.calls[0].opts.env.LC_ALL, "C");
  assert.ok(Object.keys(g.calls[0].opts.env).length > 2, "PATH まで落としている");
});

test("★readWorkingDiff: `.git` が symlink なら読まない(`unsafe_repo`、git を撃たない = 所見 2)", async () => {
  const g = fakeGit({ unstaged: UNSTAGED, staged: "" });
  const link = { isSymbolicLink: () => true };
  const r = await readWorkingDiff("/w2b", { exec: g.exec, exists: always, ...pinned, lstat: () => link });
  assert.equal(r.reason, "unsafe_repo");
  assert.equal(g.calls.length, 0);
  // 錨: 普通の `.git`(dir)/ 無い(null)は読む
  const ok = await readWorkingDiff("/w2c", { exec: g.exec, exists: always, ...pinned, lstat: () => dirStat });
  assert.equal(ok.reason, null);
  const before = g.calls.length;
  const none = await readWorkingDiff("/w2d", { exec: g.exec, exists: always, ...pinned, lstat: () => null });
  assert.equal(none.reason, "not_a_repo", "祖先まで `.git` が無い = git 管理外(git を撃たずに判る)");
  assert.equal(g.calls.length, before, "repo が無いのに git を撃った");
});

test("★readWorkingDiff: 同じ cwd への同時要求は 1 本に合流する(所見 4)", async () => {
  let release;
  const gate = new Promise((res) => { release = res; });
  const calls = [];
  const exec = async (bin, args) => { calls.push(args); await gate; return { stdout: "", stderr: "" }; };
  const a = readWorkingDiff("/w4-same", { exec, exists: always, ...pinned });
  const b = readWorkingDiff("/w4-same", { exec, exists: always, ...pinned });
  assert.deepEqual(_inflight().keys, ["/w4-same"]);
  release();
  const [ra, rb] = await Promise.all([a, b]);
  assert.equal(calls.filter((a) => a.includes("diff")).length, 2, "2 要求で git が 4 本 走った(合流していない)");
  assert.deepEqual(ra, rb);
  assert.deepEqual(_inflight().keys, []);
});

test("★readWorkingDiff: 全体で同時に走る git は MAX_CONCURRENT 本まで、残りは順番待ち(所見 4)", async () => {
  let peak = 0, live = 0;
  const exec = async () => {
    live += 1; peak = Math.max(peak, live);
    await new Promise((r) => setTimeout(r, 15));
    live -= 1;
    return { stdout: "", stderr: "" };
  };
  const all = [];
  for (let i = 0; i < 6; i += 1) all.push(readWorkingDiff(`/w4-${i}`, { exec, exists: always, ...pinned }));
  const snap = _inflight();
  assert.ok(snap.running <= MAX_CONCURRENT && snap.waiting >= 1, JSON.stringify(snap));
  await Promise.all(all);
  assert.ok(peak <= MAX_CONCURRENT, `同時 ${peak} 本 > ${MAX_CONCURRENT}`);
  assert.deepEqual(_inflight(), { running: 0, waiting: 0, keys: [] });
});

// ── 本物の git(所見 7: 偽 git で引数の有無を見る検査は「走らない」の証拠ではない)──

/**
 * ★★git を撃つ検査は `GIT_*` を**剥いだ**環境で撃つ(2026-09-03、実害あり)。
 *   此の検査は pre-commit の門(commit-suite)の中でも走る。hook の中では git 自身が
 *   `GIT_DIR` / `GIT_INDEX_FILE` / `GIT_PREFIX` を子に export しているので、`process.env` を
 *   そのまま渡すと `git init` / `git config` / `git commit` が temp dir ではなく**本物の repo**
 *   に効く。実際に `.git/config` が `bare = true` に書き換わり、主 worktree の `git status` が
 *   「must be run in a work tree」で死んだ(枝の先端は無事、手で `core.bare=false` に戻した)。
 */
function hermeticGitEnv(extra = {}) {
  const env = {};
  for (const [k, v] of Object.entries(process.env)) if (!k.startsWith("GIT_")) env[k] = v;
  return { ...env, ...extra };
}

function realRepo() {
  const d = mkdtempSync(join(tmpdir(), "rc-sessiondiff-"));
  const git = (args, env = {}) => execFileSync("git", args, { cwd: d, encoding: "utf8", env: hermeticGitEnv(env) });
  git(["init", "-q", "."]);
  git(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "init"]);
  writeFileSync(join(d, "f.txt"), "x\n");
  git(["add", "f.txt"]);
  writeFileSync(join(d, "f.txt"), "x\ny\n");
  return { d, git, drop: () => rmSync(d, { recursive: true, force: true }) };
}

test("★★本物の git: repo の `core.fsmonitor` を差分の読み取りで**実行しない**(陽性対照つき、所見 1)", async (t) => {
  const repo = realRepo();
  try {
    const marker = join(repo.d, "MARKER");
    const hook = join(repo.d, "hook.sh");
    writeFileSync(hook, `#!/bin/sh\ntouch "${marker}"\necho "/"\n`, { mode: 0o755 });
    repo.git(["config", "core.fsmonitor", hook]);
    // 陽性対照: 素の `git diff` は hook を走らせる(之が真でなければ下の陰性は何も証明しない)
    repo.git(["--no-pager", "diff", "--no-color"], { GIT_OPTIONAL_LOCKS: "0" });
    if (!existsSync(marker)) { t.skip("此の git は diff で fsmonitor を呼ばない(陽性対照が立たない)"); return; }
    rmSync(marker);
    const r = await readWorkingDiff(repo.d);
    assert.equal(r.reason, null);
    // f.txt は index(add 済み)と作業木(其の後の書き足し)の両側に出る = 2 件
    assert.deepEqual(r.files.map((f) => [f.path, f.staged]), [["f.txt", false], ["f.txt", true]]);
    assert.equal(existsSync(marker), false, "★repo の設定した実行ファイルが机で走った");
  } finally {
    repo.drop();
  }
});

test("★本物の git: `.git` が symlink の repo は読まない(所見 2)", async () => {
  const real = realRepo();
  const shell = mkdtempSync(join(tmpdir(), "rc-sessiondiff-link-"));
  try {
    symlinkSync(join(real.d, ".git"), join(shell, ".git"));
    writeFileSync(join(shell, "f.txt"), "z\n");
    const r = await readWorkingDiff(shell);
    assert.equal(r.reason, "unsafe_repo");
    // 錨: 本物の方はそのまま読める
    const ok = await readWorkingDiff(real.d);
    assert.equal(ok.reason, null);
    assert.equal(ok.files[0].path, "f.txt");
  } finally {
    rmSync(shell, { recursive: true, force: true });
    real.drop();
  }
});
