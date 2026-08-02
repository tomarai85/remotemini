#!/usr/bin/env node
/**
 * 実機の Claude Code TUI で「**選択画面が出ている時は送らない**」経路を駆動する。
 *
 * なぜ別の台本か: `live-inject-check.mjs` は「送れる画面で送る」側しか回せない。
 * CHOICE の打ち切りは 8/01 まで、写し(単体テスト)と偽 TUI でしか通っていなかった。
 *
 * 選択画面の作り方 = **`/model` のピッカー**。Escape だけで閉じるので完全に戻せる。
 *   信頼確認ダイアログ(「このディレクトリのファイルを信頼しますか」)は**使わない** —
 *   取り返しの要る判断(信頼の付与)を検査の副作用にしない為。
 *
 * 約束(崩さない事):
 *   - 使い捨てのセッション名(`rc-live-<数字6桁以上>`)しか作らない。Tom の実セッションへ届く道が無い。
 *   - **この台本が Enter を送る箇所は1つだけ**(`/model` を入力欄で確定する所)。
 *     選択画面が出た後に送るのは Escape のみ。選択肢は1つも選ばない。
 *   - 写しは repo の外($TMPDIR)。起動バナーにアカウントのメールが載る。
 *
 * 使い方: node tools/live-choice-check.mjs [--cwd <信頼済みの dir>] [--bin "claude --model haiku"]
 * 終了コード: 0 = 全項目 OK / 1 = どれかが NG / 2 = 準備段で中断
 */
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { TmuxInjector, makeTmuxRunner, classifyScreen, tmuxChildEnv, PANE_SEP } from "../src/inject.mjs";

const TMUX_BIN =
  process.env.RC_TMUX_BIN ||
  (existsSync("/opt/homebrew/bin/tmux") ? "/opt/homebrew/bin/tmux" : "tmux");

/**
 * 注入層に渡すランナー。**`makeTmuxRunner` を経由する**のが要点で、こうすると
 * `run`(飲む)と `runStrict`(投げる)の両方が揃う。一覧は runStrict を通るので、
 * ここを裸の `{ run: tmux }` に戻すと構築の時点で落ちる(= M84 が塞いだ穴)。
 * `quiet:false` は今までと同じ意味(この道具では tmux の失敗はそのまま失敗)。
 */
const injectorRunner = () => makeTmuxRunner({
  tmuxBin: TMUX_BIN,
  exec: (bin, args, opts) => execFileSync(bin, args, { ...opts, maxBuffer: 8 * 1024 * 1024 }),
  quiet: false,
});
// ★locale を明示する理由は inject.mjs の PANE_FORMAT 注記(タブが `_` に潰れる)。
const tmux = (args) =>
  execFileSync(TMUX_BIN, args, { encoding: "utf8", maxBuffer: 8 * 1024 * 1024, env: tmuxChildEnv() });
const tmuxOk = (args) => {
  try {
    tmux(args);
    return true;
  } catch {
    return false;
  }
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function parseArgs(argv) {
  const out = { cwd: process.env.HOME, bin: "claude", cols: "120", rows: "40" };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--cwd") out.cwd = argv[++i];
    else if (a === "--bin") out.bin = argv[++i];
    else if (a === "--cols") out.cols = argv[++i];
    else if (a === "--rows") out.rows = argv[++i];
    else throw new Error(`知らない引数: ${a}`);
  }
  return out;
}

/** 画面が `want` になるまで待つ。時間切れでも黙らず、その時の写しを返す。 */
async function waitFor(injector, pane, want, budgetMs) {
  const t0 = Date.now();
  for (;;) {
    const text = injector.capture(pane);
    const c = classifyScreen(text);
    if (c.state === want) return { ok: true, text, waited: Date.now() - t0, c };
    if (Date.now() - t0 >= budgetMs) return { ok: false, text, waited: Date.now() - t0, c };
    await sleep(400);
  }
}

async function main() {
  const opt = parseArgs(process.argv.slice(2));
  const stamp = new Date().toISOString().replace(/[-:T]/g, "").slice(0, 14);
  const session = `rc-live-${stamp}`;
  if (!/^rc-live-[0-9]{6,}$/.test(session)) {
    console.error(`使い捨てのセッション名ではない: ${session}`);
    process.exit(2);
  }
  if (tmuxOk(["has-session", "-t", `=${session}`])) {
    console.error(`同名のセッションが既に在る: ${session}。触らずに止める。`);
    process.exit(2);
  }
  if (!opt.cwd || !existsSync(opt.cwd)) {
    console.error(`--cwd が無い: ${opt.cwd}`);
    process.exit(2);
  }
  const outDir = join(tmpdir(), `rc-choice-${stamp}`);
  if (outDir.includes("/mobile-work/")) {
    console.error(`写しの置き場が repo の中を指している: ${outDir}`);
    process.exit(2);
  }
  mkdirSync(outDir, { recursive: true });
  console.log(`tmux      : ${TMUX_BIN} (${tmux(["-V"]).trim()})`);
  console.log(`セッション: ${session}(使い捨て)`);
  console.log(`起動      : ${opt.bin}  cwd=${opt.cwd}  ${opt.cols}x${opt.rows}`);
  console.log(`写し      : ${outDir}\n`);

  const check = (name, ok, detail) => {
    console.log(`${ok ? "OK " : "NG "} ${name}(${detail})`);
    if (!ok) failed = true;
  };

  try {
    tmux(["new-session", "-d", "-s", session, "-x", opt.cols, "-y", opt.rows, "-c", opt.cwd]);
    // 区切りは本体と同じ物を使う(タブは locale 次第で `_` に潰れる。inject.mjs の PANE_SEP 注記)。
    const listed = tmux(["list-panes", "-t", `=${session}`, "-F", `#{session_name}${PANE_SEP}#{pane_id}`])
      .split("\n")
      .map((l) => l.split(PANE_SEP))
      .filter((p) => p[0] === session && p[1]);
    if (listed.length !== 1) throw new Error(`ペインが1つに定まらない: ${listed.length}`);
    const pane = listed[0][1];
    const injector = new TmuxInjector({ tmux: injectorRunner(), echoBudgetMs: 8000 });

    tmux(["send-keys", "-t", pane, "-l", "--", opt.bin]);
    tmux(["send-keys", "-t", pane, "Enter"]);
    const boot = await waitFor(injector, pane, "SENDABLE", 90000);
    writeFileSync(join(outDir, "00-boot.txt"), boot.text);
    if (!boot.ok) {
      console.error(`起動後 90 秒で入力欄が出ない(state=${boot.c.state})。写し: ${outDir}/00-boot.txt`);
      console.error("  → 上限や信頼確認の可能性。**Enter は押さない**。");
      // ★`process.exit()` を使わない: try の中で撃つと finally が走らず、
      //   建てた使い捨てセッションが**生きたまま残る**(8/01 の負の対照で実際に1つ残した)。
      failed = true;
      return;
    }
    console.log(`起動 ok(${boot.waited}ms)`);

    // ★この台本で唯一 Enter を送る所。SENDABLE な入力欄で `/model` を確定する。
    tmux(["send-keys", "-t", pane, "-l", "--", "/model"]);
    await sleep(400);
    tmux(["send-keys", "-t", pane, "Enter"]);

    const choice = await waitFor(injector, pane, "CHOICE", 15000);
    writeFileSync(join(outDir, "01-choice.txt"), choice.text);
    if (!choice.ok) {
      console.error(`選択画面が出ない(state=${choice.c.state})。写し: ${outDir}/01-choice.txt`);
      console.error("  → `/model` の見た目が変わった可能性。写しを読んで menuAt の前提を確かめる事。");
      failed = true;
      return; // finally を必ず通す(片付けを飛ばさない)
    }
    console.log(`選択画面 ok(${choice.waited}ms)`);

    // 本題。選択画面が出ている実機へ送信を試みる = 打ち切らなければならない。
    const before = injector.capture(pane);
    const r = await injector.send(pane, "この本文は選択画面では送られてはならない");
    const after = injector.capture(pane);
    writeFileSync(join(outDir, "02-after-send.txt"), after);

    check("送信しない", r.sent === false, `sent=${r.sent}`);
    check("理由が選択画面", String(r.reason ?? "").toLowerCase().includes("choice"), `reason=${r.reason}`);
    check("届いたと言わない", r.delivered !== "verified", `delivered=${JSON.stringify(r.delivered)}`);
    check("画面を変えない", after === before, after === before ? "送信前後の写しが同一" : "★変化あり");
    check("本文が画面に出ていない", !after.includes("選択画面では送られてはならない"), "-");
    check("まだ選択画面のまま", classifyScreen(after).state === "CHOICE", `state=${classifyScreen(after).state}`);

    // 後始末は Escape のみ。選択肢は選ばない。
    tmux(["send-keys", "-t", pane, "Escape"]);
    const back = await waitFor(injector, pane, "SENDABLE", 10000);
    writeFileSync(join(outDir, "03-after-escape.txt"), back.text);
    check("Escape で入力欄に戻る", back.ok, `${back.waited}ms, state=${back.c.state}`);
  } catch (e) {
    console.log(`★落ちた: ${e.message}`);
    failed = true;
  } finally {
    tmuxOk(["kill-session", "-t", `=${session}`]);
    const gone = !tmuxOk(["has-session", "-t", `=${session}`]);
    console.log(`片付け: ${session} は ${gone ? "不在を確認" : "★まだ在る"}`);
    if (!gone) failed = true;
    console.log(`写し(repo の外): ${outDir}`);
  }
}

// ★終了コードは main の**外**で決める。try の中の `return` は finally を通した上で
//   main を抜けるので、main の中に置いた `process.exit` には届かない(= 失敗しても 0 で終わる)。
let failed = false;
main().then(() => process.exit(failed ? 1 : 0));
