// `/diff` が読む repo を**自分で決める**(2026-09-03、Codex #1 の 2 の残り)。
//
// 素の `git diff` は repo の設定に従って別の木を読む(実測: `core.worktree=/victim` で victim の
// 木の差分を返した)。`--git-dir` / `--work-tree` を CLI で明示すれば設定より CLI が勝つ。
// 加えて `.gitattributes` の `filter=<driver>` は設定に driver が在ると clean filter を**実行する**
// (git diff は作業木の file を index と比べる為に通す)。設定の driver 名を読んで全部 `cat` に上書きする。
//
// ★守る線(本物の git で、陽性対照つき):
//   1. `core.worktree` が別の dir を指す repo でも、cwd の木を読む(素の git は victim を読む)
//   2. 設定の filter driver が走らない(素の git は走らせる = marker が出来る)
//   3. cwd が repo の子 dir でも repo の根から読む(paths は根からの相対)
//   4. worktree(gitfile)は読める / `.git` symlink・祖先に `.git` 無しは git を撃たずに断る
import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { filterOverrides, locateRepo, readWorkingDiff } from "../src/sessiondiff.mjs";

function hermeticGitEnv(extra = {}) {
  const env = {};
  for (const [k, v] of Object.entries(process.env)) if (!k.startsWith("GIT_")) env[k] = v;
  return { ...env, ...extra };
}

function realRepo() {
  const d = realpathSync(mkdtempSync(join(tmpdir(), "rc-gitpin-")));
  const git = (args, env = {}) => execFileSync("git", args, { cwd: d, encoding: "utf8", env: hermeticGitEnv(env) });
  git(["init", "-q", "."]);
  git(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "init"]);
  writeFileSync(join(d, "f.txt"), "x\n");
  git(["add", "f.txt"]);
  git(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "f"]);
  writeFileSync(join(d, "f.txt"), "x\ny\n"); // 未 stage の変更 1 行
  return { d, git, drop: () => rmSync(d, { recursive: true, force: true }) };
}

test("★★本物の git: `core.worktree` が別の dir を指していても、cwd の木を読む(陽性対照: 素の git は victim を読む)", async () => {
  const repo = realRepo();
  const victim = realpathSync(mkdtempSync(join(tmpdir(), "rc-gitpin-victim-")));
  try {
    writeFileSync(join(victim, "secret.txt"), "s\n");
    repo.git(["config", "core.worktree", victim]);
    // 陽性対照: 素の git は victim の木を作業木として読む = f.txt が「消えた」と言う
    const plain = repo.git(["--no-pager", "diff", "--stat"], { GIT_OPTIONAL_LOCKS: "0" });
    assert.ok(/1 deletion/.test(plain), `陽性対照が立たない(素の git が victim を読んでいない): ${plain}`);
    const r = await readWorkingDiff(repo.d);
    assert.equal(r.reason, null);
    assert.equal(r.files.length, 1);
    assert.equal(r.files[0].path, "f.txt");
    assert.equal(r.files[0].added, 1, "★victim の木を読んだ(f.txt が削除に見える)");
    assert.equal(r.files[0].removed, 0);
  } finally {
    rmSync(victim, { recursive: true, force: true });
    repo.drop();
  }
});

test("★★本物の git: 設定の filter driver を差分の読み取りで**実行しない**(陽性対照: 素の git は走らせる)", async () => {
  const repo = realRepo();
  try {
    const marker = join(repo.d, "MARKER");
    const hook = join(repo.d, "clean.sh");
    writeFileSync(hook, `#!/bin/sh\ntouch "${marker}"\ncat\n`, { mode: 0o755 });
    repo.git(["config", "filter.evil.clean", hook]);
    writeFileSync(join(repo.d, ".gitattributes"), "f.txt filter=evil\n");
    // 陽性対照: 素の git diff は clean filter を走らせる
    repo.git(["--no-pager", "diff", "--stat"], { GIT_OPTIONAL_LOCKS: "0" });
    assert.ok(existsSync(marker), "陽性対照が立たない(素の git が filter を走らせていない)");
    rmSync(marker);
    const r = await readWorkingDiff(repo.d);
    assert.equal(r.reason, null);
    assert.ok(r.files.some((f) => f.path === "f.txt"), JSON.stringify(r.files.map((f) => f.path)));
    assert.equal(existsSync(marker), false, "★repo の設定した filter が机で走った");
  } finally {
    repo.drop();
  }
});

test("★本物の git: cwd が repo の子 dir でも repo の根から読む(paths は根からの相対)", async () => {
  const repo = realRepo();
  try {
    mkdirSync(join(repo.d, "sub", "deep"), { recursive: true });
    const r = await readWorkingDiff(join(repo.d, "sub", "deep"));
    assert.equal(r.reason, null);
    assert.deepEqual(r.files.map((f) => f.path), ["f.txt"]);
    const loc = locateRepo(join(repo.d, "sub", "deep"));
    assert.equal(loc.root, repo.d);
    assert.equal(loc.gitDir, join(repo.d, ".git"));
  } finally {
    repo.drop();
  }
});

test("本物の git: worktree(gitfile `gitdir: …`)は読める / `.git` symlink は断る / 祖先に `.git` が無ければ not_a_repo", async () => {
  const repo = realRepo();
  const wt = join(tmpdir(), `rc-gitpin-wt-${process.pid}`);
  const shell = realpathSync(mkdtempSync(join(tmpdir(), "rc-gitpin-shell-")));
  const bare = realpathSync(mkdtempSync(join(tmpdir(), "rc-gitpin-none-")));
  try {
    repo.git(["worktree", "add", "-q", wt, "-b", "wt"]);
    writeFileSync(join(wt, "f.txt"), "x\nz\n");
    const loc = locateRepo(wt);
    assert.ok(loc.gitDir && /worktrees\/.+/.test(loc.gitDir), JSON.stringify(loc));
    const r = await readWorkingDiff(wt);
    assert.equal(r.reason, null);
    assert.equal(r.files[0].path, "f.txt");

    symlinkSync(join(repo.d, ".git"), join(shell, ".git"));
    assert.deepEqual(locateRepo(shell), { reason: "unsafe_repo" });

    // 祖先に .git が無い(tmp の下): git を撃たずに not_a_repo
    const calls = [];
    const exec = async (b, args) => { calls.push(args); return { stdout: "", stderr: "" }; };
    const none = await readWorkingDiff(bare, { exec });
    assert.equal(none.reason, "not_a_repo");
    assert.equal(calls.length, 0, "repo が無いのに git を撃った");
  } finally {
    try { repo.git(["worktree", "remove", "--force", wt]); } catch { /* 片付けは best-effort */ }
    rmSync(wt, { recursive: true, force: true });
    rmSync(shell, { recursive: true, force: true });
    rmSync(bare, { recursive: true, force: true });
    repo.drop();
  }
});

// ── 偽 git: 撃つ引数の形 ─────────────────────────────────────────────────────
const dirStat = { isSymbolicLink: () => false, isDirectory: () => true, isFile: () => false };
const pinned = { realpath: (p) => p, lstat: (p) => (p.endsWith("/.git") ? dirStat : null) };

test("★`--git-dir` と `--work-tree` を realpath した根で明示し、cwd も根にする", async () => {
  const calls = [];
  const exec = async (bin, args, opts) => { calls.push({ args, opts }); return { stdout: "", stderr: "" }; };
  await readWorkingDiff("/repo/sub", {
    exec, exists: () => true,
    realpath: (p) => p.replace("/repo", "/real/repo"),
    lstat: (p) => (p === "/real/repo/.git" ? dirStat : null),
  });
  const diffs = calls.filter((c) => c.args.includes("diff"));
  assert.equal(diffs.length, 2);
  for (const c of diffs) {
    assert.ok(c.args.includes("--git-dir=/real/repo/.git"), c.args.join(" "));
    assert.ok(c.args.includes("--work-tree=/real/repo"), c.args.join(" "));
    assert.equal(c.opts.cwd, "/real/repo");
    // 明示は subcommand より前
    assert.ok(c.args.indexOf("--work-tree=/real/repo") < c.args.indexOf("diff"));
  }
});

test("★設定に filter driver が在れば、diff の引数に `-c filter.<name>.clean=cat` 等が並ぶ(無ければ並ばない)", async () => {
  const mk = (config) => {
    const calls = [];
    const exec = async (bin, args) => {
      calls.push(args);
      if (args.includes("config")) return { stdout: config, stderr: "" };
      return { stdout: "", stderr: "" };
    };
    return { calls, exec };
  };
  const g = mk("filter.lfs.clean\nfilter.lfs.smudge\nfilter.lfs.process\nfilter.evil.clean\ncore.bare\n");
  await readWorkingDiff("/w", { exec: g.exec, exists: () => true, ...pinned });
  const d = g.calls.find((a) => a.includes("diff"));
  for (const n of ["evil", "lfs"]) {
    for (const k of [`filter.${n}.clean=cat`, `filter.${n}.smudge=cat`, `filter.${n}.process=`, `filter.${n}.required=false`]) {
      assert.ok(d.includes(k), `${k} が無い: ${d.join(" ")}`);
    }
  }
  const g2 = mk("core.bare\nuser.name\n");
  await readWorkingDiff("/w2", { exec: g2.exec, exists: () => true, ...pinned });
  assert.ok(!g2.calls.find((a) => a.includes("diff")).some((x) => /^filter\./.test(x)), "driver が無いのに上書きを並べた");
});

test("filterOverrides / locateRepo の単体: 名前の抽出、gitfile の相対 path、symlink の拒否", () => {
  assert.deepEqual(filterOverrides(""), []);
  assert.deepEqual(filterOverrides("filter.a.clean\nfilter.a.clean\nnot.a.filter\nfilter.b.required\n"),
    ["-c", "filter.a.clean=cat", "-c", "filter.a.smudge=cat", "-c", "filter.a.process=", "-c", "filter.a.required=false",
     "-c", "filter.b.clean=cat", "-c", "filter.b.smudge=cat", "-c", "filter.b.process=", "-c", "filter.b.required=false"]);
  const fileStat = { isSymbolicLink: () => false, isDirectory: () => false, isFile: () => true, size: 60 };
  // worktree の形: `/wt/.git` = gitfile、行き先 `/main/.git/worktrees/wt` は dir で、其の `gitdir` が此の gitfile を指し返す
  const fs = {
    realpath: (p) => p,
    lstat: (p) => (p === "/wt/.git" ? fileStat : p === "/main/.git/worktrees/wt" ? dirStat : null),
    readFile: (p) => (p === "/wt/.git" ? "gitdir: ../main/.git/worktrees/wt\n" : p === "/main/.git/worktrees/wt/gitdir" ? "/wt/.git\n" : (() => { throw new Error("ENOENT"); })()),
  };
  assert.deepEqual(locateRepo("/wt", fs), { root: "/wt", gitDir: "/main/.git/worktrees/wt" });
  // ★逆リンクが別の gitfile を指す(= 任意の repo を指す gitfile)は断る(Codex #5 の 3)
  const foreign = { ...fs, readFile: (p) => (p === "/wt/.git" ? "gitdir: ../main/.git/worktrees/wt\n" : "/other/.git\n") };
  assert.deepEqual(locateRepo("/wt", foreign), { reason: "unsafe_repo" });
  // ★逆リンクの file が無い(submodule の形)も当面 断る
  const noBack = { ...fs, readFile: (p) => (p === "/wt/.git" ? "gitdir: ../main/.git/worktrees/wt\n" : (() => { throw new Error("ENOENT"); })()) };
  assert.deepEqual(locateRepo("/wt", noBack), { reason: "unsafe_repo" });
  // ★先頭にゴミが在る gitfile は git も通さない
  const garbage = { ...fs, readFile: (p) => (p === "/wt/.git" ? "garbage\ngitdir: ../main/.git/worktrees/wt\n" : "/wt/.git\n") };
  assert.deepEqual(locateRepo("/wt", garbage), { reason: "unsafe_repo" });
  // ★1 MiB を超える gitfile は読まない
  const huge = { ...fs, lstat: (p) => (p === "/wt/.git" ? { ...fileStat, size: 2 * 1024 * 1024 } : fs.lstat(p)) };
  assert.deepEqual(locateRepo("/wt", huge), { reason: "unsafe_repo" });
  const sym = locateRepo("/s", { realpath: (p) => p, lstat: (p) => (p === "/s/.git" ? { isSymbolicLink: () => true } : null) });
  assert.deepEqual(sym, { reason: "unsafe_repo" });
  const badFile = locateRepo("/b", { realpath: (p) => p, lstat: (p) => (p === "/b/.git" ? fileStat : null), readFile: () => "garbage" });
  assert.deepEqual(badFile, { reason: "unsafe_repo" });
});

test("★filterOverrides: 空の名前・`=` を含む名前は fail-closed、driver が多すぎても断る(Codex #5 の 1)", () => {
  for (const bad of ["filter..clean\n", "filter.x=y.clean\n", "filter.a b.clean\n"]) {
    assert.throws(() => filterOverrides(bad), (e) => e.code === "unsafe_filter", bad);
  }
  const many = Array.from({ length: 40 }, (_, i) => `filter.d${i}.clean`).join("\n");
  assert.throws(() => filterOverrides(many), (e) => e.code === "unsafe_filter");
  // 錨: 普通の名前は今まで通り
  assert.equal(filterOverrides("filter.lfs.clean\n").length, 8);
});

test("★設定の列挙が落ちたら `git_failed` で止まり、diff は撃たない(fail-open にしない = Codex #5 の 2)", async () => {
  const calls = [];
  const exec = async (bin, args) => {
    calls.push(args);
    if (args.includes("config")) { const e = new Error("stdout maxBuffer length exceeded"); e.code = "ERR_CHILD_PROCESS_STDIO_MAXBUFFER"; throw e; }
    return { stdout: "", stderr: "" };
  };
  const r = await readWorkingDiff("/w", { exec, exists: () => true, ...pinned });
  assert.equal(r.reason, "git_failed");
  assert.equal(calls.filter((a) => a.includes("diff")).length, 0, "★列挙が落ちたのに diff を撃った(其の設定で filter が走る)");
  // 敵対的な driver 名は unsafe_repo
  const exec2 = async (bin, args) => ({ stdout: args.includes("config") ? "filter.x=y.clean\n" : "", stderr: "" });
  const r2 = await readWorkingDiff("/w2", { exec: exec2, exists: () => true, ...pinned });
  assert.equal(r2.reason, "unsafe_repo");
});

test("★本物の git: 空の名前 / `=` を含む名前の filter driver は読まない(unsafe_repo、marker も出来ない)", async () => {
  const repo = realRepo();
  try {
    const marker = join(repo.d, "MARKER");
    const hook = join(repo.d, "clean.sh");
    writeFileSync(hook, `#!/bin/sh\ntouch "${marker}"\ncat\n`, { mode: 0o755 });
    repo.git(["config", "filter..clean", hook]);          // 空の名前(git は受ける)
    writeFileSync(join(repo.d, ".gitattributes"), "f.txt filter=\n");
    const r = await readWorkingDiff(repo.d);
    assert.equal(r.reason, "unsafe_repo");
    assert.equal(existsSync(marker), false, "★空の名前の driver が走った");
    repo.git(["config", "--unset", "filter..clean"]);
    repo.git(["config", "filter.x=y.clean", hook]);       // `=` を含む名前
    writeFileSync(join(repo.d, ".gitattributes"), "f.txt filter=x=y\n");
    const r2 = await readWorkingDiff(repo.d);
    assert.equal(r2.reason, "unsafe_repo");
    assert.equal(existsSync(marker), false, "★`=` を含む名前の driver が走った");
  } finally {
    repo.drop();
  }
});

test("★本物の git: 任意の repo を指す gitfile は断る / bare repo・`.git/objects` の中から外側を読まない(Codex #5 の 3・4)", async () => {
  const victim = realRepo();
  const shell = realpathSync(mkdtempSync(join(tmpdir(), "rc-gitpin-foreign-")));
  const bare = realpathSync(mkdtempSync(join(tmpdir(), "rc-gitpin-bare-")));
  try {
    writeFileSync(join(shell, ".git"), `gitdir: ${join(victim.d, ".git")}\n`);
    writeFileSync(join(shell, "f.txt"), "z\n");
    const r = await readWorkingDiff(shell);
    assert.equal(r.reason, "unsafe_repo", "★被害者の repo を指す gitfile を受けた");
    // `.git/objects` の中を cwd にしても外側の repo を読まない
    const inside = await readWorkingDiff(join(victim.d, ".git", "objects"));
    assert.equal(inside.reason, "unsafe_repo");
    // bare repo の dir も同じ
    execFileSync("git", ["init", "-q", "--bare", bare], { encoding: "utf8", env: hermeticGitEnv() });
    const b = await readWorkingDiff(bare);
    assert.equal(b.reason, "unsafe_repo");
    // 錨: 本物は今まで通り読める
    const ok = await readWorkingDiff(victim.d);
    assert.equal(ok.reason, null);
  } finally {
    rmSync(shell, { recursive: true, force: true });
    rmSync(bare, { recursive: true, force: true });
    victim.drop();
  }
});

test("深い cwd(70 段)でも root まで遡って repo を見つける(Codex #5 の 5)", () => {
  const deep = "/r" + "/d".repeat(70);
  const loc = locateRepo(deep, { realpath: (p) => p, lstat: (p) => (p === "/r/.git" ? dirStat : null) });
  assert.deepEqual(loc, { root: "/r", gitDir: "/r/.git" });
});
