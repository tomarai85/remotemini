#!/usr/bin/env node
/**
 * `--resume` と `--resume --fork-session` の**実挙動**を1回だけ測る。
 *
 * ── なぜ要るか ──────────────────────────────────────────────────────────
 * `DESIGN.md` §2.17 の worker 経路は「既定の `--resume` は**同じ転写ファイルに追記**し、
 * `--fork-session` は**新しい ID の別ファイル**を作る」という前提の上に乗っている。
 * この前提の出所は `claude --help` の**文言**であって、実測ではない。
 * 設計が1点に乗っているのに測っていない —— だから測る。**測るまで「測った」と書かない**。
 *
 * ── 何を観測するか(推測を挟まない3点) ────────────────────────────────
 *   ①各回の `session_id`(`--output-format json` が返す値)
 *   ②`~/.claude/projects/<cwd の符号>/` の **file 数**
 *   ③各 file の **行数**(転写は1行1件の JSONL なので、追記は行数で見える)
 * 「追記した」を size の増加ではなく**行数**で見るのは、size だけだと別 file の増減と
 * 区別が付かない為。
 *
 * ── 安全側の約束 ────────────────────────────────────────────────────────
 *   - 作業場所は**自分で作る使い捨て**(`/tmp/rc-fork.XXXXXX`)。既存の dir は受け取らない。
 *   - 消すのは「**自分が作った物**」だけ。転写 dir は走らせる前に**不在**を確かめ、
 *     不在だった時に限って後で消す。既に在った dir には指1本触れない。
 *   - `~/.claude.json`(信頼一覧)は**読まない・書かない**。信頼をプログラムから
 *     与えるのは安全確認の自動化なので、この道具は端からその経路を持たない。
 *   - 生の出力をそのまま印字しない。起動系の文字列にはアカウントのメールが載り得るので、
 *     取り出した値だけを出し、診断用の抜粋は `redact()` を通す。
 *
 * ── 終了コード ──────────────────────────────────────────────────────────
 *   0 = 測れて、期待通り(既定=追記 / fork=別 file)
 *   1 = 測れたが、**期待と違った**(= 設計の前提が崩れている。DESIGN §2.17 を書き換える)
 *   2 = 準備段で中断(実行ファイルが無い / 転写 dir が既に在る 等) = **未測定**
 *   3 = 利用上限で相手が答えられない = **未測定**
 * ★2 と 3 を 1 に丸めない。「違った」と「測っていない」は別の事実。
 *
 * 使い方: node tools/live-fork-check.mjs [--bin claude] [--keep] [--verbose]
 */
import { execFileSync } from "node:child_process";
import { mkdtempSync, existsSync, readdirSync, readFileSync, statSync, rmdirSync, unlinkSync, realpathSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";

const argv = process.argv.slice(2);
const arg = (name, dflt) => {
  const i = argv.indexOf(name);
  return i >= 0 && argv[i + 1] ? argv[i + 1] : dflt;
};
const has = (name) => argv.includes(name);

const BIN = arg("--bin", "claude");
const KEEP = has("--keep");
const VERBOSE = has("--verbose");
const PROJECTS = join(homedir(), ".claude", "projects");

/** アカウントのメール等を落としてから印字する。診断の為に生を出す時だけ通す。 */
const redact = (s) =>
  String(s).replace(/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g, "<mail>");

/** 利用上限の告知。`src/inject.mjs` の `limitNoticeIn` と同じ形を見る(日付あり/なし両方)。 */
const looksLimited = (s) => /You['’]?ve hit your[^\n]{0,40}limit|weekly limit|usage limit/i.test(s);

/**
 * ★**鍵束が開いていない**時の文面。2026-08-02 23:1x に実測して足した。
 * 素の ssh で `claude -p` を撃つと、上限ではなく `Not logged in · Please run /login`
 * が返る —— login keychain がロックされていて資格情報が読めないから。
 * launchd(`gui/501`)の中でだけ解錠されている(`test/gui-run-controls.sh` の G5 が
 * 両方向で測っている)。この道具は `claude` を**直に**起動するので、edith では
 * **`tools/edith-gui-run.sh` 越しに走らせないと必ずここに落ちる**。
 * (1-3 の道具は tmux のペインに打ち込む形で、ペインは GUI 由来の tmux server を
 *  継ぐので素の ssh でよい。ここが4だけ経路が違う理由)
 */
const looksLoggedOut = (s) => /Not logged in|Please run \/login|\/login\b/i.test(s);

/** cwd → 転写 dir 名。Claude Code は英数字以外を `-` に潰す。 */
const slugOf = (abs) => abs.replace(/[^A-Za-z0-9]/g, "-");

const fail = (code, why, extra) => {
  console.log("");
  console.log(code === 1 ? `判定: ★期待と違う — ${why}` : `判定: ★未測定 — ${why}`);
  if (extra) console.log(extra);
  process.exitCode = code;
};

// ── 0) 準備段: 実行ファイルが**走らせる側の PATH で**引けるか ───────────────
let binPath = "";
try {
  binPath = execFileSync("/usr/bin/env", ["sh", "-c", `command -v ${JSON.stringify(BIN)}`], {
    encoding: "utf8",
  }).trim();
} catch { binPath = ""; }
if (!binPath) {
  console.log(`★準備段で中断: \`${BIN}\` がこの PATH で引けない`);
  console.log(`  PATH = ${process.env.PATH}`);
  console.log(`  launchd(gui/501)の中は /usr/bin:/bin:/usr/sbin:/sbin なので、絶対パスで渡す事`);
  process.exit(2);
}
if (!existsSync(PROJECTS)) {
  console.log(`★準備段で中断: ${PROJECTS} が無い(Claude Code が一度も走っていない機械)`);
  process.exit(2);
}

// ── 1) 使い捨ての作業場所を自分で作る ────────────────────────────────────
const D = realpathSync(mkdtempSync("/tmp/rc-fork."));
const SLUG = slugOf(D);
const TDIR = join(PROJECTS, SLUG);

console.log(`使い捨て cwd : ${D}`);
console.log(`転写 dir     : ${TDIR}`);

// ★消してよいのは「自分が作った物」だけ。走らせる前の不在がその証拠になる。
const TDIR_PREEXISTED = existsSync(TDIR);
if (TDIR_PREEXISTED) {
  cleanupAll();
  console.log(`★準備段で中断: 転写 dir が既に在る = 自分が作った物と区別できない`);
  console.log(`  (この dir には触らない。名前が衝突しているだけなら撃ち直せば別名になる)`);
  process.exit(2);
}

/** 転写 dir の中身を撮る。file 名 → 行数。 */
function snap() {
  if (!existsSync(TDIR)) return {};
  const out = {};
  for (const f of readdirSync(TDIR)) {
    const p = join(TDIR, f);
    let st;
    try { st = statSync(p); } catch { continue; }
    if (!st.isFile()) { out[f + "/"] = "(dir)"; continue; }
    let lines = 0;
    try { lines = readFileSync(p, "utf8").split("\n").filter(Boolean).length; } catch { lines = -1; }
    out[f] = lines;
  }
  return out;
}

/** claude を1回撃つ。戻り = {ran, sid, limited, raw} */
function shoot(label, extraArgs, prompt) {
  const args = [...extraArgs, "-p", prompt, "--output-format", "json"];
  let raw = "", code = 0;
  try {
    raw = execFileSync(binPath, args, { cwd: D, encoding: "utf8", maxBuffer: 8 * 1024 * 1024 });
  } catch (e) {
    raw = `${e.stdout || ""}${e.stderr || ""}`;
    code = typeof e.status === "number" ? e.status : -1;
  }
  // ★まず「そもそも**答えたか**」。答えていないなら中身の分類はしない。
  //   初版は「JSON が parse できた = 走った」にしていて、対照(F3)に落とされた:
  //   上限の応答は **`is_error:true` の正しい JSON** なので parse は通る。そのまま
  //   進むと file が1つも増えず、台本は「DESIGN §2.17 の前提と違う」= **設計を
  //   書き換えろ**と言い出す。1回も測っていないのに。**形が整っている事と、
  //   答えが返った事は別**。
  let j = null;
  try { j = JSON.parse(raw); } catch { j = null; }
  const errored = !!(j && j.is_error === true);
  const limited = looksLimited(raw) || (j && looksLimited(JSON.stringify(j.result ?? "")));
  const loggedOut = looksLoggedOut(raw) || (j && looksLoggedOut(JSON.stringify(j.result ?? "")));
  const sid = j && (j.session_id || j.sessionId) ? (j.session_id || j.sessionId) : "";
  const rec = { label, ran: !!j && !errored, sid, limited: !!limited, loggedOut: !!loggedOut, code, len: raw.length, raw };
  console.log(
    `  ${label}: exit=${code} JSON=${j ? (errored ? "取れたが is_error=true" : "取れた") : "★取れない"}` +
    ` sid=${sid || "(なし)"}` + (limited ? " ★上限の告知あり" : "") + (loggedOut ? " ★未ログイン" : "")
  );
  if (VERBOSE || !j) console.log(`     抜粋: ${redact(raw).slice(0, 160).replace(/\n/g, " / ")}`);
  return rec;
}

/**
 * ★片付けは**どの出口でも同じ物**を畳む。初版は cwd だけを中断路で消し、転写 dir は
 * 成功路でしか消していなかった —— edith で1回撃っただけで `projects` が 14 → 15 に
 * 増え、`memory/` を抱えた dir が残った(2026-08-02 23:0x 実測)。
 * 「出口が複数ある片付け」は、**必ずどれかの出口が忘れられる**。
 */
function cleanupAll() {
  if (KEEP) return;
  rmTree(D);
  if (!TDIR_PREEXISTED) rmTree(TDIR);   // 自分が作った物だけ。既存には触らない
}

/** 深い順に畳む。再帰的な強制削除(`rm -rf`)は使わない。 */
function rmTree(root) {
  if (!existsSync(root)) return;
  const dirs = [];
  const walk = (d) => {
    dirs.push(d);
    for (const e of readdirSync(d, { withFileTypes: true })) {
      const p = join(d, e.name);
      if (e.isDirectory()) walk(p);
      else { try { unlinkSync(p); } catch {} }
    }
  };
  try { walk(root); } catch {}
  dirs.sort((a, b) => b.length - a.length);
  for (const d of dirs) { try { rmdirSync(d); } catch {} }
}

// ── 2) 3回撃つ ───────────────────────────────────────────────────────────
console.log("");
console.log("--- ①素で建てる ---");
const before = snap();
const A = shoot("①素", [], "ok");
if (!A.ran) {
  cleanupAll();
  const why = A.limited
    ? "利用上限で相手が答えられない(①が返らない)"
    : A.loggedOut
      ? "★鍵束が開いていない(Not logged in)= 素の ssh で撃っている。`tools/edith-gui-run.sh` 越し(launchd gui/501)で走らせる事"
      : "①が答えを返していない(JSON が無い / is_error=true)";
  fail(A.limited ? 3 : 2, why, `  cwd 不在: ${existsSync(D) ? "★残っている" : "OK"}`);
  process.exit(process.exitCode);
}
const s1 = snap();

console.log("--- ②`--resume` で続ける ---");
const B = shoot("②resume", ["--resume", A.sid], "ok2");
const s2 = snap();

console.log("--- ③`--resume --fork-session` で続ける ---");
const C = shoot("③fork", ["--resume", A.sid, "--fork-session"], "ok3");
const s3 = snap();

// ── 3) 判定 ─────────────────────────────────────────────────────────────
const names = (s) => Object.keys(s).sort();
console.log("");
console.log("観測:");
console.log(`  撃つ前   : file ${names(before).length}件`);
console.log(`  ①の後   : file ${names(s1).length}件  ${JSON.stringify(s1)}`);
console.log(`  ②の後   : file ${names(s2).length}件  ${JSON.stringify(s2)}`);
console.log(`  ③の後   : file ${names(s3).length}件  ${JSON.stringify(s3)}`);
console.log(`  session_id: ① ${A.sid} / ② ${B.sid || "(なし)"} / ③ ${C.sid || "(なし)"}`);

if (!B.ran || !C.ran) {
  cleanupAll();
  const lim = B.limited || C.limited;
  const out = B.loggedOut || C.loggedOut;
  fail(lim ? 3 : 2, lim ? "途中で利用上限に当たった"
        : out ? "★途中で鍵束が開いていない(Not logged in)= launchd gui/501 の外で走っている"
              : "②か③が答えを返していない(JSON が無い / is_error=true)");
  process.exit(process.exitCode);
}

// H2a: 既定の --resume は**同じ file に追記**(= file は増えず、①の file の行数が伸びる)
const grew = names(s1).filter((f) => typeof s2[f] === "number" && typeof s1[f] === "number" && s2[f] > s1[f]);
const appended = names(s2).length === names(s1).length && grew.length > 0 && B.sid === A.sid;

// H2b: --fork-session は**新しい ID の別 file**
const newFiles = names(s3).filter((f) => !names(s2).includes(f));
const forked = C.sid !== A.sid && newFiles.length === 1;

console.log("");
console.log(`  H2a 既定=同じ file に追記 : ${appended ? "○" : "×"}` +
  `(file 数 ${names(s1).length}→${names(s2).length} / 伸びた file ${grew.length}件 / sid ${B.sid === A.sid ? "同じ" : "★違う"})`);
console.log(`  H2b fork=新 ID の別 file  : ${forked ? "○" : "×"}` +
  `(増えた file ${newFiles.length}件 ${JSON.stringify(newFiles)} / sid ${C.sid !== A.sid ? "違う" : "★同じ"})`);

cleanupAll();
console.log("");
console.log(`片付け: cwd ${existsSync(D) ? "★残っている" : "不在 OK"} / 転写 dir ${existsSync(TDIR) ? "★残っている" : "不在 OK"}`);

if (appended && forked) {
  console.log("");
  console.log("判定: DESIGN §2.17 の前提どおり(既定=追記 / fork=別 file)");
  process.exit(0);
}
fail(1, "DESIGN §2.17 の前提と違う。worker 経路の設計を書き換える事");
process.exit(1);
