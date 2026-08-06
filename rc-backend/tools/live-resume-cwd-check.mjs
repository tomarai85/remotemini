#!/usr/bin/env node
/**
 * `claude --resume <id>` の引き当てが**起動時の cwd に固定されているか**を1回だけ測る。
 * = DESIGN §8-9 の C、HANDOFF §3-V の本体。
 *
 * ── 終了コード ──────────────────────────────────────────────────────────
 *   0 = §3-V のとおり(②通る / ③は引き当てられない)
 *   1 = ★③が別の cwd から引き当てた(または黙って別会話を建てた)
 *   2 = 準備段/錨で中断 = **未測定**
 *   3 = 利用上限 = **未測定**
 * ★2 と 3 を 0 にも 1 にも丸めない。
 * ★★**0 と 1 のどちらが正常かは claude 本体の版で入れ替わる**(下の「版に依存する」)。
 *   だから判定には**測った版を必ず載せる**。
 *
 * ── なぜ要るか(★ここが `live-fork-check.mjs` と違う) ──────────────────
 * §3-V は「引き当ては起動 cwd に固定」を **`claude` 本体 2.1.220 の `ZBy` を読んで**
 * 確定させた(quota ゼロ)。読みは丁寧で、Codex の refute 2点もその場で閉じている。
 * それでも**読みは実測ではない**。そして此の読みの上には、既に**出荷済みの拒否**が
 * 乗っている —— `src/trust.mjs` が未信頼の cwd を **409** で断る面は、
 * 「ワーカーが会話ごとの本物の dir で開く」様になって初めて到達可能になった物で、
 * その変更の動機が §3-V だった。
 *
 * つまり読みが逆だった場合に消えるのは §3-V の記述だけではない:
 * **正当な会話を電話から締め出すだけの拒否が1つ残る**。渡米中に効く。だから測る。
 *
 * ── ★この判定は claude 本体の版に依存する(2026-08-07 に実測して判明) ──────
 * 実測すると③が引き当てた。原因は読み違いではなく**版で経路が増えていた**:
 * 2.1.223 に `tengu_transcript_id_scan_fallback` という第2の落とし先が入り、
 * cwd スコープの探索が外れた後に `~/.claude/projects` 直下を全部走査して
 * `<session-id>.jsonl` を探す。**ちょうど1件の時だけ**引き当て、2件以上なら拒否する。
 * 目印の文字列を数えると 2.1.220 / .221 / .222 = 0本、2.1.223 = 2本。
 * よって §3-V は**それが読んだ版については正しかった**。陳腐化したのは下のバイナリの方。
 * → 版ごとに正常な終了コードが違う: 2.1.223 以降 = 1、2.1.220-222 = 0。
 *   だから此の道具は**測った版を必ず出力に載せる**。載せないと後から判定を読めない。
 *
 * ★併せて訂正: 以前ここには「読みが崩れると `src/trust.mjs` の 409 が空振りになる」と
 * 書いてあったが**繋がっていない**。409 の3つの理由はどれも引き当て機構と独立している
 * —— `cwd_missing` は子プロセスを起こせない(ENOENT)、`cwd_untrusted` は信頼確認の画面が
 * 出て電話が答えられない、`cwd_unknown` は渡す cwd が無い。どれも「resume が横断で
 * 引けるか」では変わらない。実測でも `cwd_unknown` は転写 1,453本中 **0件**、
 * 同一 id が2箇所に在る形(走査が拒否する形)も **0件**。409 は現状のままで正しい。
 *
 * ── 何を観測するか(推測を挟まない) ──────────────────────────────────
 *   ①使い捨て cwd **D1** で会話を1つ建てる → `session_id` S
 *   ②**同じ D1** から `--resume S` → ★**陽性の錨**。此処が通らないと③は解釈できない
 *   ③**別の使い捨て cwd D2** から `--resume S` → ★**これが問いその物**
 *
 * ★②を撃つ理由: ③が失敗した時、「cwd に固定されているから」なのか「S が壊れている /
 * resume が全面的に効かない」のかを、③単体では区別できない。②が通って③が落ちて
 * 初めて「**cwd の違いだけが効いた**」と言える。片側だけの観測は原因を名指しできない。
 *
 * ★HOME ではなく **D2(2つ目の使い捨て)** で撃つ。§3-V の文面は `cwd: HOME` だが、
 * 検査に掛かっている機構は「**起動 cwd の slug しか見ない**」であって HOME 固有の話ではない。
 * 逆に HOME で撃つと、引き当てが外れた時の落とし先が **Tom の本物の転写 dir**
 * (`~/.claude/projects/-Users-<name>/`)になり、他人の作業場所に残骸を1本置く事になる。
 * 同じ機構を、消せる場所で測る。★残差は正直に書く: `$HOME` だけを特別扱いする枝が
 * `claude` 側に在れば此の測定は其れを見ない(読んだ限り無い。`gn()` は cwd をそのまま返す)。
 *
 * ── 安全側の約束(`live-fork-check.mjs` と同一) ──────────────────────
 *   - 作業場所は**自分で作る使い捨て**を2つ。既存の dir は受け取らない。
 *   - 転写 dir は撃つ前に**不在**を確かめ、不在だった物だけ後で消す。
 *   - `~/.claude.json`(信頼一覧)は**読まない・書かない**。
 *   - 生の出力は `redact()` を通す(起動系の文字列にアカウントのメールが載り得る)。
 *
 * (終了コードの凡例は頭に移した —— 読み手が最初に見る所に無い意味は無いのと同じ、
 *  という `test/live-exit-codes.test.mjs` の規律。40 行より下では見えない。)
 *
 * 使い方: node tools/live-resume-cwd-check.mjs [--bin claude] [--keep] [--verbose]
 * ★edith では `tools/edith-gui-run.sh` 越し(launchd gui/501)で走らせる事。
 *   素の ssh は login keychain が開かず `Not logged in` になる(製品ではなく測り方の値)。
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

const redact = (s) =>
  String(s).replace(/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g, "<mail>");

const looksLimited = (s) => /You['’]?ve hit your[^\n]{0,40}limit|weekly limit|usage limit/i.test(s);
const looksLoggedOut = (s) => /Not logged in|Please run \/login|\/login\b/i.test(s);

/** ★§3-V が予言している断り文句。`ZBy` が引き当てに失敗した時の唯一の出口。 */
const looksNotFound = (s) => /No conversation found with session ID/i.test(s);

/** cwd → 転写 dir 名。Claude Code は英数字以外を `-` に潰す。 */
const slugOf = (abs) => abs.replace(/[^A-Za-z0-9]/g, "-");

const fail = (code, why, extra) => {
  console.log("");
  console.log(code === 1 ? `判定: ★読みと違う — ${why}` : `判定: ★未測定 — ${why}`);
  // 版を必ず添える。0/1 の意味が版で入れ替わるので、版の無い判定は解釈できない。
  console.log(`  測った claude: ${VER}`);
  if (code === 1) console.log(VER_NOTE); // fail() は 0 で呼ばれない(緑の道は下で直に書く)
  if (extra) console.log(extra);
  process.exitCode = code;
};

// ── 0) 準備段 ────────────────────────────────────────────────────────────
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

/**
 * ★測った版。載せない判定は後から読めない —— 正常な終了コードが版で入れ替わるので
 *   (見出しの「版に依存する」を参照)、版の無い 0/1 は「予言どおり」なのか
 *   「経路が増えた」なのかを区別できない。取れなくても測定は続ける(判定材料ではない)。
 */
let VER = "";
try {
  VER = execFileSync(binPath, ["--version"], { encoding: "utf8" }).trim().split("\n")[0];
} catch { VER = "(--version が取れない)"; }
/** 版ごとの**実測済み**の対応。予言ではなく、撃って確かめた物だけを並べる。 */
const VER_NOTE =
  "  実測済みの対応: 2.1.223 = 横断あり(1 が正常) / 2.1.220-222 = 横断なし(0 が正常)";
console.log(`測った claude   : ${VER}`);

// ── 1) 使い捨ての作業場所を**2つ**自分で作る ────────────────────────────
const D1 = realpathSync(mkdtempSync("/tmp/rc-rcwd-a."));
const D2 = realpathSync(mkdtempSync("/tmp/rc-rcwd-b."));
const T1 = join(PROJECTS, slugOf(D1));
const T2 = join(PROJECTS, slugOf(D2));

console.log(`使い捨て cwd D1 : ${D1}`);
console.log(`使い捨て cwd D2 : ${D2}`);
console.log(`転写 dir  T1    : ${T1}`);
console.log(`転写 dir  T2    : ${T2}`);

const T1_PRE = existsSync(T1);
const T2_PRE = existsSync(T2);
if (T1_PRE || T2_PRE) {
  cleanupAll();
  console.log(`★準備段で中断: 転写 dir が既に在る(T1=${T1_PRE} T2=${T2_PRE}) = 自分が作った物と区別できない`);
  process.exit(2);
}

/** 転写 dir の中身を撮る。file 名 → 行数。 */
function snap(dir) {
  if (!existsSync(dir)) return {};
  const out = {};
  for (const f of readdirSync(dir)) {
    const p = join(dir, f);
    let st;
    try { st = statSync(p); } catch { continue; }
    if (!st.isFile()) { out[f + "/"] = "(dir)"; continue; }
    let lines = 0;
    try { lines = readFileSync(p, "utf8").split("\n").filter(Boolean).length; } catch { lines = -1; }
    out[f] = lines;
  }
  return out;
}

/** claude を1回撃つ。★`cwd` を引数で受ける —— 此の道具では cwd が唯一の独立変数。 */
function shoot(label, cwd, extraArgs, prompt) {
  const args = [...extraArgs, "-p", prompt, "--output-format", "json"];
  let raw = "", code = 0;
  try {
    raw = execFileSync(binPath, args, { cwd, encoding: "utf8", maxBuffer: 8 * 1024 * 1024 });
  } catch (e) {
    raw = `${e.stdout || ""}${e.stderr || ""}`;
    code = typeof e.status === "number" ? e.status : -1;
  }
  // 形が整っている事と、答えが返った事は別(`live-fork-check.mjs` が対照に落とされた所)。
  let j = null;
  try { j = JSON.parse(raw); } catch { j = null; }
  const errored = !!(j && j.is_error === true);
  const blob = raw + (j ? JSON.stringify(j.result ?? "") : "");
  const sid = j && (j.session_id || j.sessionId) ? (j.session_id || j.sessionId) : "";
  const rec = {
    label, cwd, ran: !!j && !errored, sid,
    limited: looksLimited(blob), loggedOut: looksLoggedOut(blob), notFound: looksNotFound(blob),
    code, raw,
  };
  console.log(
    `  ${label}: exit=${code} JSON=${j ? (errored ? "取れたが is_error=true" : "取れた") : "★取れない"}` +
    ` sid=${sid || "(なし)"}` +
    (rec.limited ? " ★上限の告知あり" : "") +
    (rec.loggedOut ? " ★未ログイン" : "") +
    (rec.notFound ? " ★No conversation found" : "")
  );
  if (VERBOSE || !j) console.log(`     抜粋: ${redact(raw).slice(0, 200).replace(/\n/g, " / ")}`);
  return rec;
}

/** 片付けは**どの出口でも同じ物**を畳む(出口ごとに書くと必ずどれかが忘れられる)。 */
function cleanupAll() {
  if (KEEP) return;
  rmTree(D1); rmTree(D2);
  if (!T1_PRE) rmTree(T1);
  if (!T2_PRE) rmTree(T2);
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

/** 未測定で降りる時の共通路。`ran` が false の理由を1つに決める。 */
function bailUnmeasured(rec, what) {
  cleanupAll();
  const why = rec.limited
    ? `利用上限で相手が答えられない(${what})`
    : rec.loggedOut
      ? `★鍵束が開いていない(Not logged in)= 素の ssh で撃っている。tools/edith-gui-run.sh 越し(launchd gui/501)で走らせる事`
      : `${what}が答えを返していない(JSON が無い / is_error=true)`;
  fail(rec.limited ? 3 : 2, why);
  process.exit(process.exitCode);
}

// ── 2) 撃つ ──────────────────────────────────────────────────────────────
console.log("");
console.log("--- ① D1 で会話を建てる ---");
const A = shoot("①建てる", D1, [], "ok");
if (!A.ran) bailUnmeasured(A, "①");
if (!A.sid) { cleanupAll(); fail(2, "①が session_id を返さなかった = 以降の resume が撃てない"); process.exit(2); }
const s1a = snap(T1);

console.log("--- ② 同じ D1 から --resume(★陽性の錨) ---");
const B = shoot("②同cwd", D1, ["--resume", A.sid], "ok2");
// ★錨が落ちたら③は解釈できない。「cwd のせい」と「resume 自体が効かない」を分けられない。
if (!B.ran) bailUnmeasured(B, "②(陽性の錨)");
const s1b = snap(T1);
const anchorGrew = Object.keys(s1a).some((f) => typeof s1b[f] === "number" && typeof s1a[f] === "number" && s1b[f] > s1a[f]);
const anchorOk = B.sid === A.sid && anchorGrew;
if (!anchorOk) {
  cleanupAll();
  fail(2, `★陽性の錨が立たない(sid ${B.sid === A.sid ? "同じ" : "★違う"} / 転写が伸びた ${anchorGrew}) = ③を解釈できない`);
  process.exit(2);
}

console.log("--- ③ 別の cwd D2 から --resume(★これが問い) ---");
const C = shoot("③別cwd", D2, ["--resume", A.sid], "ok3");
const s1c = snap(T1);
const s2c = snap(T2);

// ── 3) 判定 ─────────────────────────────────────────────────────────────
const n = (s) => Object.keys(s).sort();
console.log("");
console.log("観測:");
console.log(`  T1 ①の後 : ${JSON.stringify(s1a)}`);
console.log(`  T1 ②の後 : ${JSON.stringify(s1b)}   ← 錨。同じ file が伸びた`);
console.log(`  T1 ③の後 : ${JSON.stringify(s1c)}`);
console.log(`  T2 ③の後 : file ${n(s2c).length}件  ${JSON.stringify(s2c)}`);
console.log(`  session_id: ① ${A.sid} / ② ${B.sid || "(なし)"} / ③ ${C.sid || "(なし)"}`);

// ③が D1 の転写に書いたか = 別 cwd から本当に引き当てたかの直接の証拠。
const t1GrewOn3 = n(s1b).some((f) => typeof s1c[f] === "number" && typeof s1b[f] === "number" && s1c[f] > s1b[f]);

const resumedForeign = C.ran && C.sid === A.sid;          // 引き当てた = §3-V 崩壊
const silentNew      = C.ran && C.sid !== A.sid;          // 黙って別会話を建てた
const refusedForeign = !C.ran && C.notFound;              // 予言どおり断った

console.log("");
console.log(`  ③は D1 の転写に書いたか : ${t1GrewOn3 ? "★書いた" : "書いていない"}`);
console.log(`  ③は T2 に会話を作ったか : ${n(s2c).length > 0 ? "★作った" : "作っていない"}`);

cleanupAll();
console.log("");
console.log(`片付け: D1 ${existsSync(D1) ? "★残っている" : "不在 OK"} / D2 ${existsSync(D2) ? "★残っている" : "不在 OK"}` +
  ` / T1 ${existsSync(T1) ? "★残っている" : "不在 OK"} / T2 ${existsSync(T2) ? "★残っている" : "不在 OK"}`);

if (refusedForeign && !t1GrewOn3) {
  console.log("");
  console.log("判定: HANDOFF §3-V のとおり —— 引き当ては起動 cwd に固定されている");
  console.log(`  測った claude: ${VER}`);
  console.log(VER_NOTE);
  console.log("  ②(同じ cwd)は通り、③(別の cwd)だけが `No conversation found` で落ちた。");
  console.log("  = `cwd: HOME` のワーカーが `~` 以外の会話を resume できない、は実測で裏が取れた。");
  console.log("  ★これは `src/trust.mjs` の 409 の可否とは**別の話**。409 の3つの理由は");
  console.log("    どれも引き当て機構と独立している(見出しの訂正を参照)ので、緑でも赤でも");
  console.log("    409 の扱いは此の測定からは決まらない。");
  process.exit(0);
}

if (resumedForeign) {
  fail(1, "★③が別の cwd から会話を引き当てた = §3-V の記述が此の版では成り立たない",
    `  D1 の転写が③で伸びた: ${t1GrewOn3}\n` +
    "  → HANDOFF §3-V に**版の条件**を足す事(読み違いとは限らない。2.1.223 で\n" +
    "     横断の落とし先が増えたのを実測済み)。\n" +
    "  ★src/trust.mjs の 409 は此処からは動かさない —— 3つの理由はどれも引き当て\n" +
    "     機構と独立している。触るなら別の根拠を持って来る事(見出しの訂正を参照)。");
  process.exit(1);
}

if (silentNew) {
  fail(1, "★③が黙って別の会話を建てた(断らなかった)",
    `  ③の sid = ${C.sid}(①と違う) / T2 の file ${n(s2c).length}件\n` +
    "  → 引き当てには失敗しているので §3-V の結論(届かない)は生きるが、\n" +
    "     **断り方が違う**。電話にはエラーではなく空の会話が返る事になるので、\n" +
    "     `worker.mjs` の異常系(No conversation found を当てにしている所)を見直す事。");
  process.exit(1);
}

fail(2, `③の落ち方をどの型にも当てられない(ran=${C.ran} notFound=${C.notFound} exit=${C.code})`,
  "  ★0 にも 1 にも丸めない。断り文句が変わった可能性が在るので、生の抜粋を --verbose で撮り直す事。");
process.exit(2);
