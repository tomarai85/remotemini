#!/usr/bin/env node
/**
 * 使い捨ての本物 TUI を**建てて、置いておく**道具。
 *
 * なぜ要るか: `tools/live-http-check.mjs` は建てて測って畳むまでを1本で走らせるので、
 * 「建てたまま**別の機械から**送る」が出来ない。Sprint 5 の DoD 9行目
 * (電話の `SendClient` を本物の rc-backend へ当てる)は、送る側が Jervis の swift 製の殻で、
 * 建てる側が edith という**二機にまたがる**形なので、建てる/畳むを外から呼べる必要が在る。
 *
 * 使い方:
 *   node tools/disposable-session.mjs up [--cwd DIR] [--bin rc-claude]
 *       → stdout に **会話 id だけ**を1行。経過は stderr。tmux セッション名は
 *         `rc-e2e-<数字>` で、この道具はその形以外を作らない(Tom の実セッションに触る道が無い)。
 *   node tools/disposable-session.mjs lines <会話 id>
 *       → 転写(jsonl)の**行数だけ**を1行。本文は絶対に出さない。
 *   node tools/disposable-session.mjs busy <会話 id>
 *       → `observed <材料>` / `unknown -` の**1行だけ**。画面は出さない。
 *         `unknown` は「待機中」ではなく「観測できなかった」(輪で回す事)。
 *   node tools/disposable-session.mjs down <tmux セッション名> <会話 id>
 *       → ペインを畳み、登録簿(`panes/`・`heads/`)の**完全一致の1本だけ**を消し、不在を確認。
 *
 * 終了コード: 0 = 出来た / 1 = 出来なかった / 2 = 測れていない(起動が入力欄まで行かない等)
 *
 * ★画面は stdout に出さない。起動バナーにはアカウントのメールが載る(`live-http-check.mjs`
 *   が証拠を repo の外へ置いているのと同じ理由)。失敗した時は $TMPDIR に落として
 *   **その path と state だけ**を stderr に出す。
 */
import { execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, readdirSync, unlinkSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import {
  TmuxInjector,
  makeTmuxRunner,
  classifyScreen,
  limitNoticeIn,
  tmuxChildEnv,
} from "../src/inject.mjs";

const HOME = homedir();
const TMUX_BIN =
  process.env.RC_TMUX_BIN ||
  (existsSync("/opt/homebrew/bin/tmux") ? "/opt/homebrew/bin/tmux" : "tmux");
const RC_DIR = process.env.RC_KEY_DIR || join(HOME, ".rc-backend");
const PANE_DIR = process.env.RC_PANE_DIR || join(RC_DIR, "panes");
const HEADS_DIR = join(RC_DIR, "heads");
const PROJECTS_DIR = process.env.RC_PROJECTS_DIR || join(HOME, ".claude", "projects");

const tmux = (args) =>
  execFileSync(TMUX_BIN, args, { encoding: "utf8", maxBuffer: 8 * 1024 * 1024, env: tmuxChildEnv() });
const tmuxOk = (args) => {
  try {
    // ★stderr は捨てる。`has-session` で「can't find session」が出るのは**答え**であって
    //   異常ではないのに、素通しすると走行 log の中で失敗の顔をして残る
    //   (2026-08-05 の初回走行で、成功した走行の真ん中に2回出た)。
    execFileSync(TMUX_BIN, args, {
      encoding: "utf8",
      maxBuffer: 8 * 1024 * 1024,
      env: tmuxChildEnv(),
      stdio: ["ignore", "pipe", "ignore"],
    });
    return true;
  } catch {
    // tmux が「そんなセッションは無い」で落ちるのは失敗ではなく**答え**。
    return false;
  }
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const say = (s) => process.stderr.write(`${s}\n`);

async function waitFor(fn, budgetMs, everyMs = 500) {
  const t0 = Date.now();
  for (;;) {
    const v = await fn();
    if (v) return { ok: true, v, waited: Date.now() - t0 };
    if (Date.now() - t0 > budgetMs) return { ok: false, v: null, waited: Date.now() - t0 };
    await sleep(everyMs);
  }
}

const readPanes = () => {
  try {
    return readdirSync(PANE_DIR).filter((f) => f.endsWith(".json"));
  } catch {
    // 登録簿の dir が読めない = **「登録が1件も無い」ではない**。此処では上位が
    // 「30 秒で名乗らない」として扱うので、空を返しつつ理由を stderr に出す。
    say("注意: 登録簿の dir が読めない(登録が無いのとは別の事)");
    return [];
  }
};

/** 転写(jsonl)の path。server.mjs の findSessionFile と同じ探し方。 */
function transcriptPath(sessionId) {
  if (!/^[0-9a-f-]{8,64}$/i.test(sessionId)) return null;
  let slugs;
  try {
    slugs = readdirSync(PROJECTS_DIR);
  } catch {
    return null;
  }
  for (const slug of slugs) {
    const p = join(PROJECTS_DIR, slug, `${sessionId}.jsonl`);
    if (existsSync(p)) return p;
  }
  return null;
}

/**
 * 建てる場所が**信頼済みか**を、建てる前に読む(読むだけ)。
 * ★信頼は**与えない**。`~/.claude.json` を書く道はこの file の何処にも無い —— 自動化に
 *   安全確認を押させない。読んだ結果、未信頼なら信頼済みの dir へ寄せるか、名指しで落ちる。
 * 返り値: { cwd, note } / null = 信頼済みの dir が1つも無い(建てても選択画面で止まる)
 */
function resolveTrustedCwd(want) {
  const trustFile = process.env.RC_PHONE_TRUST_FILE || join(HOME, ".claude.json");
  let trusted = null;
  try {
    const j = JSON.parse(readFileSync(trustFile, "utf8"));
    trusted = Object.entries(j.projects || {})
      .filter(([, v]) => v && v.hasTrustDialogAccepted === true)
      .map(([k]) => k);
  } catch {
    // 読めない = **分からない**。未信頼と決めつけない(決めつけると建てられる物が建たない)。
    return { cwd: want, note: "確かめられなかった(信頼の記録が読めない)" };
  }
  if (trusted.includes(want)) return { cwd: want, note: "信頼済み" };
  if (trusted.length === 0) return null;
  const picked = trusted.find((d) => d.startsWith("/private/tmp") || d.startsWith("/tmp")) || trusted[0];
  return { cwd: picked, note: `${want} は未信頼 → 信頼済みの dir に寄せた(--cwd で上書き可)` };
}

async function cmdUp(argv) {
  let cwd = "/private/tmp";
  let bin = "rc-claude";
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--cwd") cwd = argv[++i];
    else if (argv[i] === "--bin") bin = argv[++i];
  }

  const trust = resolveTrustedCwd(cwd);
  if (!trust) {
    say(`建てる場所が未信頼で、信頼済みの dir が1つも無い: ${cwd}`);
    say("  この状態で建てると入力欄でなく信頼確認の選択画面で止まる。");
    say("  次の手: その機械で一度手で claude を起動し、画面を読んだ上で人が信頼を答える。");
    return 2;
  }
  cwd = trust.cwd;
  say(`建てる場所: ${cwd}(${trust.note})`);

  const stamp = new Date().toISOString().replace(/\D/g, "").slice(0, 14);
  const session = `rc-e2e-${stamp}`;
  // ★名前の fail-closed。使い捨ての形以外は**建てない**(この道具の唯一の安全装置)。
  if (!/^rc-e2e-[0-9]{6,}$/.test(session)) {
    say(`使い捨ての名前になっていない: ${session}`);
    return 1;
  }
  if (tmuxOk(["has-session", "-t", `=${session}`])) {
    say(`同名のセッションが既に居る: ${session}`);
    return 1;
  }

  const before = new Set(readPanes());
  tmux(["new-session", "-d", "-s", session, "-x", "120", "-y", "40", "-c", cwd]);
  const pane = tmux(["list-panes", "-t", `=${session}`, "-F", "#{pane_id}"]).trim().split("\n")[0];
  const injector = new TmuxInjector({ tmux: makeTmuxRunner({
    tmuxBin: TMUX_BIN,
    exec: (b, a, o) => execFileSync(b, a, { ...o, maxBuffer: 8 * 1024 * 1024 }),
    quiet: false,
  }) });
  tmux(["send-keys", "-t", pane, "-l", "--", bin]);
  tmux(["send-keys", "-t", pane, "Enter"]);

  const boot = await waitFor(async () => {
    const t = injector.capture(pane);
    return classifyScreen(t).state === "SENDABLE" ? t : null;
  }, 90_000);

  if (!boot.ok) {
    const screen = injector.capture(pane);
    const dir = mkdtempSync(join(tmpdir(), "rc-disposable-"));
    const p = join(dir, "boot.txt");
    writeFileSync(p, screen);
    // 画面は出さない(バナーにメールが載る)。名指しできる物だけ名指しする。
    if (limitNoticeIn(screen)) say("入力欄まで行かない: 画面は**利用上限の告知**。直す物は無い");
    else if (/Is this a project you created or one you trust\?/.test(screen)) {
      say(`入力欄まで行かない: **信頼確認の選択画面**(cwd=${cwd})。この道具は答えない`);
    } else say(`起動 90 秒で入力欄が出ない(state=${classifyScreen(screen).state})`);
    say(`画面全体: ${p}`);
    tmuxOk(["kill-session", "-t", `=${session}`]);
    return 2;
  }
  say(`起動 ok(${boot.waited}ms) セッション=${session}`);

  const reg = await waitFor(async () => {
    for (const f of readPanes()) {
      if (before.has(f)) continue;
      try {
        const j = JSON.parse(readFileSync(join(PANE_DIR, f), "utf8"));
        if (j.pane === pane) return f.replace(/\.json$/, "");
      } catch {
        // 書き込み途中の json。輪の中なので次の周回で読み直す。
      }
    }
    return null;
  }, 30_000);

  if (!reg.ok) {
    say("30 秒で登録簿に名乗らない(statusLine が無い起動かもしれない)");
    tmuxOk(["kill-session", "-t", `=${session}`]);
    return 2;
  }
  say(`登録 ok(${reg.waited}ms)`);
  // stdout はこの2行だけ。呼ぶ側が変数に取る物なので、余計な字を混ぜない。
  process.stdout.write(`${session}\n${reg.v}\n`);
  return 0;
}

function cmdLines(sessionId) {
  const p = transcriptPath(sessionId);
  if (!p) {
    say("転写が見つからない");
    return 1;
  }
  // 行数だけ。本文は読み込むが**出さない**(会話の中身は記録に残す物ではない)。
  const n = readFileSync(p, "utf8").split("\n").filter((l) => l.trim()).length;
  process.stdout.write(`${n}\n`);
  return 0;
}

/**
 * 転写の中に**その本文が居るか**を数える。出すのは**件数だけ**。
 *
 * ★なぜ行数の増分では足りないか(2026-08-05 に踏みかけた): 使い捨ての会話は転写が
 *   **無い所から始まる**ので、送った後の「0 → 7 行」には**起動そのものが書いた行**が
 *   混ざる。増えた事は「私の本文が着いた事」を意味しない。着いた事を言うには、
 *   一意な本文そのものを数えるしかない。
 */
function cmdContains(sessionId, needle) {
  const p = transcriptPath(sessionId);
  if (!p) {
    say("転写が見つからない");
    return 1;
  }
  if (!needle) {
    say("探す本文が空");
    return 1;
  }
  // 本文は読むが**出さない**。出すのは数だけ。
  const n = readFileSync(p, "utf8").split(needle).length - 1;
  process.stdout.write(`${n}\n`);
  return 0;
}

/**
 * そのペインが**今、生成中に見えるか**。出すのは1行
 * `<activity> <activityFrom|->` だけ —— 画面は絶対に出さない。
 *
 * 何に使うか: 割り込みの実機検査(`ios/tools/live-interrupt-check.sh`)は、
 * **本当に動いている最中に** Escape を撃たないと `stopped:"verified"` が出ない。
 * 「送ってから n 秒待つ」で撃つと、その n は観測ではなく当て推量になる
 * (短ければ `null`、長ければ `already-done`。どちらも緑にならないのに、
 *  原因が検査の側なのか経路の側なのか**区別できない**)。だから撃つ直前に此処で観測する。
 *
 * ★`activityFrom` を一緒に出すのは「何で観測したか」を答えの横に置く為
 * (`classifyScreen` の見出しと同じ規律)。電話が触る `rc-claude` 起動では
 * footer の印は 0/76 で出ないので、実際に立つのは `spinner` のはず ——
 * `hint` が出たなら**素の claude を掴んでいる**合図で、それは別の話になる。
 *
 * ★`unknown` は「待機中」ではなく「観測できなかった」(M3)。スピナーの被覆は
 * 61-82% なので、呼ぶ側は1枚で決めずに輪で回す事。
 */
function cmdBusy(sessionId) {
  if (!/^[0-9a-f-]{8,64}$/i.test(sessionId)) {
    say("会話 id の形ではない");
    return 1;
  }
  const p = join(PANE_DIR, `${sessionId}.json`);
  if (!existsSync(p)) {
    say("登録簿にこの会話が無い");
    return 1;
  }
  let pane;
  try {
    pane = JSON.parse(readFileSync(p, "utf8")).pane;
  } catch {
    say("登録簿が読めない");
    return 1;
  }
  if (!pane) {
    say("登録簿に pane が無い");
    return 1;
  }
  const injector = new TmuxInjector({ tmux: makeTmuxRunner({
    tmuxBin: TMUX_BIN,
    exec: (b, a, o) => execFileSync(b, a, { ...o, maxBuffer: 8 * 1024 * 1024 }),
    quiet: true,
  }) });
  let screen;
  try {
    screen = injector.capture(pane);
  } catch {
    say("ペインが撮れない(畳まれた後かもしれない)");
    return 1;
  }
  const c = classifyScreen(screen);
  process.stdout.write(`${c.activity} ${c.activityFrom || "-"}\n`);
  return 0;
}

function cmdDown(session, sessionId, purgeTranscript = false) {
  if (!/^rc-e2e-[0-9]{6,}$/.test(session)) {
    say(`使い捨ての名前ではない。畳まない: ${session}`);
    return 1;
  }
  tmuxOk(["kill-session", "-t", `=${session}`]);
  const gone = !tmuxOk(["has-session", "-t", `=${session}`]);
  say(`セッション ${session}: ${gone ? "不在を確認" : "★まだ居る"}`);

  let bad = !gone;
  if (/^[0-9a-f-]{8,64}$/i.test(sessionId)) {
    for (const p of [join(PANE_DIR, `${sessionId}.json`), join(HEADS_DIR, `${sessionId}.json`)]) {
      if (!existsSync(p)) continue;
      try {
        unlinkSync(p);
      } catch (e) {
        say(`★消せない: ${p.replace(HOME, "~")}(${String(e?.message || e)})`);
        bad = true;
        continue;
      }
      const stillThere = existsSync(p);
      say(`${p.replace(HOME, "~")}: ${stillThere ? "★まだ在る" : "不在を確認"}`);
      if (stillThere) bad = true;
    }
  }

  // 転写(jsonl)の後始末。**既定では消さない** —— 走行が転んだ時に人が読む唯一の物だから。
  // 呼ぶ側が「測り終えて緑だった」と分かっている時にだけ `--purge-transcript` を付ける。
  // ★2026-08-05: 付ける前の2走行が edith の projects 配下に転写を2本置き去りにした
  //   (この機械に恒久物を残さない、という線を私自身が破っていた)。
  if (purgeTranscript && /^[0-9a-f-]{8,64}$/i.test(sessionId)) {
    const t = transcriptPath(sessionId);
    if (!t) {
      say("転写: 元から無い");
    } else {
      try {
        unlinkSync(t);
      } catch (e) {
        say(`★転写が消せない(${String(e?.message || e)})`);
        return 1;
      }
      say(`転写: ${existsSync(t) ? "★まだ在る" : "不在を確認"}`);
      if (existsSync(t)) bad = true;
    }
  }
  return bad ? 1 : 0;
}

const [, , cmd, ...rest] = process.argv;
let code = 1;
if (cmd === "up") code = await cmdUp(rest);
else if (cmd === "lines") code = cmdLines(rest[0] || "");
else if (cmd === "contains") code = cmdContains(rest[0] || "", rest.slice(1).join(" "));
else if (cmd === "busy") code = cmdBusy(rest[0] || "");
else if (cmd === "down") code = cmdDown(rest[0] || "", rest[1] || "", rest.includes("--purge-transcript"));
else say("使い方: disposable-session.mjs up|lines <id>|contains <id> <本文>|busy <id>|down <session> <id> [--purge-transcript]");
process.exit(code);
