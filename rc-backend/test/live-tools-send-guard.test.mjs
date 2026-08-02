// `tools/live-*.mjs` の**運用規約**を静的に測る(DESIGN §2.17「H1 の残り」/ §2.20-b)。
//
// 変異(`test/mutation-controls.py`)は `src/` の**中身**を測る物で、これは別の層 ——
// 「計器が Tom の実ペインへ送らない」という **`tools/` 側の約束**が破れた事を測る。
// §2.17 の結論(錠は注入器の中のまま、プロセスを跨ぐ錠は作らない)は
// 「**送る道具は自分で建てた使い捨てにしか送らない**」を前提にしていて、その前提が
// 崩れる形は1つ —— 既存のペインへ送る道具が1本増える事。ここが赤になる場所。
//
// ★述語は §2.20-b で広げてある。`.send(` だけを見ると、L4 で「この計器は安全だ」と
//   確定させた当の `live-http-check.mjs` が**対象から外れる**(`.send(` を呼ばず HTTP で送る)。
//   広げた事自体を測る陰性対照が N2。
//
// 要求は3つ。§2.17:1986 が名指しするのは前2つで、3つ目は今日 3 file 全部が既に
// 持っている物を要求へ格上げした(理由は下の COLLISION_GUARD の注釈)。
import { test } from "node:test";
import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const TOOLS = join(dirname(fileURLToPath(import.meta.url)), "..", "tools");

/** 送る経路①: 自前の注入器でペインへ打つ。 */
const SEND_INJECTOR = /\.send\(/;
/** 送る経路②: サーバ経由(§2.20-b で足した方)。 */
const SEND_HTTP = /"POST"[^\n]*\/(messages|interrupt)/;

/** 使い捨てを**自分で建てる**事。既存のペインを掴む道具はここで落ちる。 */
const NEW_SESSION = /\btmux\w*\(\s*\[\s*"new-session"/;
/**
 * 名前の fail-closed 検査。`rc-live-` / `rc-e2e-` と接頭辞は違ってよいが、
 * **前後を留めた**(`^…$`)6桁以上の数字付きである事を要求する。
 * 接頭辞の一覧を持たないのは、一覧は増えた時に静かに古くなるから(今夜の型)。
 */
const NAME_GUARD = /if \(!\/\^rc-[A-Za-z0-9]+-\[0-9\]\{6,\}\$\/\.test\(\w+\)\)/;
/**
 * ★同名が既に在ったら**触らずに止める**事。
 * 名前の形だけ見ても、`rc-e2e-20260803…` が偶然 Tom の側に在れば掴んでしまう。
 * 「消す」経路(`kill-session`)を持つ道具が他人のセッションを掴む = 一番高い代償なので、
 * §2.17:1986 の2つに加えてここも要求する(2026-08-03 時点で3 file とも既に持っている)。
 */
const COLLISION_GUARD = /"has-session"/;

/**
 * 名前検査の `if` が**自分の本体だけ**を返す。
 * ★行数で窓を切ると、次の文(`if (has-session) process.exit(2)`)が窓に入り込んで
 *   「止まっている」と読めてしまう —— 陰性対照 N3 が通ってしまう形。だから括弧で閉じる。
 */
function guardBlock(src) {
  const m = NAME_GUARD.exec(src);
  if (!m) return null;
  const rest = src.slice(m.index + m[0].length);
  const open = rest.indexOf("{");
  const nl = rest.indexOf("\n");
  // `) process.exit(2);` の様に同じ行で終わる形。
  if (open === -1 || (nl !== -1 && nl < open)) return rest.slice(0, nl === -1 ? rest.length : nl);
  let depth = 0;
  for (let i = open; i < rest.length; i++) {
    if (rest[i] === "{") depth++;
    else if (rest[i] === "}" && --depth === 0) return rest.slice(open, i + 1);
  }
  return rest.slice(open);
}

/** 名前検査に落ちた時、**本当に止まっている**か。 */
function abortsAfterGuard(src) {
  const b = guardBlock(src);
  return b !== null && /process\.exit\(|\breturn\b|\bthrow\b/.test(b);
}

/** この一節が「送る」か。片方でも持てば対象。 */
function sendRoutes(src) {
  const r = [];
  if (SEND_INJECTOR.test(src)) r.push("injector");
  if (SEND_HTTP.test(src)) r.push("http");
  return r;
}

/** 対象の一節に足りない物を並べる。空 = 規約を満たす。 */
function missing(src) {
  const out = [];
  if (!NEW_SESSION.test(src)) out.push("使い捨てセッションの生成(tmux new-session)");
  if (!NAME_GUARD.test(src)) out.push("名前の fail-closed 検査(^rc-…-[0-9]{6,}$)");
  else if (!abortsAfterGuard(src)) out.push("名前検査に落ちた時の停止(exit/return/throw)");
  if (!COLLISION_GUARD.test(src)) out.push("同名セッションの検出(has-session)");
  return out;
}

const FILES = readdirSync(TOOLS)
  .filter((f) => /^live-.*\.mjs$/.test(f))
  .map((f) => [f, readFileSync(join(TOOLS, f), "utf8")]);

test("実物の tools/live-*.mjs が規約を守っている", () => {
  assert.ok(FILES.length >= 4, `live-*.mjs を読めていない: ${FILES.length} 件`);
  for (const [name, src] of FILES) {
    if (sendRoutes(src).length === 0) continue;
    assert.deepEqual(missing(src), [], `${name} に足りない: ${missing(src).join(" / ")}`);
  }
});

test("★対象の集合を留める(送る道具が1本増えた瞬間に赤 = §2.17 の (i) が崩れる合図)", () => {
  const subjects = FILES.filter(([, s]) => sendRoutes(s).length > 0).map(([n]) => n).sort();
  assert.deepEqual(
    subjects,
    ["live-choice-check.mjs", "live-http-check.mjs", "live-inject-check.mjs"],
    "送る道具の顔ぶれが変わった。増えた物が**自分で建てた使い捨てにしか送らない**事を" +
      "人が確かめてから、この一覧に足す事(§2.17 の表『増えた瞬間に赤』はこの行)",
  );
  // 送らない道具が紛れ込んでいない事も同時に言う(述語が『全部』に化けていない)。
  const nonSender = FILES.find(([n]) => n === "live-fork-check.mjs");
  assert.ok(nonSender, "live-fork-check.mjs が消えた(対照が無くなる)");
  assert.deepEqual(sendRoutes(nonSender[1]), [], "送らない筈の道具が送る側に入った");
});

// --- 陰性対照 -------------------------------------------------------------
// 検査が**落ちる事**を見る。これが無いと「通った」は「何も見ていない」と区別が付かない。
const GUARDS = `
  const session = \`rc-fake-\${stamp}\`;
  if (!/^rc-fake-[0-9]{6,}$/.test(session)) {
    console.error("使い捨てのセッション名ではない");
    process.exit(2);
  }
  if (tmuxOk(["has-session", "-t", \`=\${session}\`])) process.exit(2);
  tmux(["new-session", "-d", "-s", session]);
`;

const NEGATIVES = [
  ["N1 注入器で送るのに使い捨てを建てない", `injector.send(pane, "hi");`, true],
  [
    "N2 ★`.send(` を持たず HTTP だけで送る(広げた述語の対照。旧述語なら素通り)",
    `await api(port, key, "POST", \`/api/sessions/\${id}/messages\`, { text: p });`,
    true,
  ],
  [
    "N3 名前検査は在るが落ちても止まらない",
    `injector.send(pane, "hi");
  if (!/^rc-fake-[0-9]{6,}$/.test(session)) { console.error("だめ"); }
  if (tmuxOk(["has-session"])) process.exit(2);
  tmux(["new-session", "-d", "-s", session]);`,
    true,
  ],
  ["N4 同名の検出が無い", `injector.send(pane, "hi");
  const session = \`rc-fake-\${stamp}\`;
  if (!/^rc-fake-[0-9]{6,}$/.test(session)) process.exit(2);
  tmux(["new-session", "-d", "-s", session]);`, true],
  ["P1 HTTP で送るが全部持っている(通る側)", `${GUARDS}
  await api(port, key, "POST", \`/api/sessions/\${id}/messages\`, { text: p });`, false],
  ["P2 そもそも送らない(対象外。守っていなくても赤にしない)", `const t = injector.capture(pane);`, false],
];

for (const [name, src, shouldFail] of NEGATIVES) {
  test(`陰性対照: ${name}`, () => {
    const isSubject = sendRoutes(src).length > 0;
    const bad = isSubject && missing(src).length > 0;
    assert.equal(bad, shouldFail, `対象=${isSubject} 不足=${missing(src).join(",") || "なし"}`);
  });
}

// ★上の対照は**私が書いた偽の一節**で測っている。それだけだと「私の書き癖には当たる」しか
//   言えない —— 実物の書き方(`return (prepAbort = true)` / `opt.session ||` など)に
//   当たっている保証が無い。だから**実物から守りを1つずつ抜いた写し**でも落ちる事を見る。
//   実物は読むだけ、抜くのは記憶の中の写し(file は触らない)。
const STRIPS = [
  ["使い捨ての生成", (s) => s.replace(/"new-session"/g, '"attach-session"'), "使い捨てセッションの生成"],
  ["名前の検査", (s) => s.replace(NAME_GUARD, "if (false)"), "名前の fail-closed 検査"],
  ["同名の検出", (s) => s.replace(/"has-session"/g, '"list-sessions"'), "同名セッションの検出"],
];

for (const [name, src] of FILES) {
  if (sendRoutes(src).length === 0) continue;
  for (const [what, strip, expect] of STRIPS) {
    test(`★実物 ${name} から「${what}」を抜いた写しは落ちる`, () => {
      const broken = strip(src);
      assert.notEqual(broken, src, `抜けていない = 検査が実物の書き方に当たっていない`);
      const gaps = missing(broken);
      assert.ok(
        gaps.some((g) => g.startsWith(expect)),
        `抜いたのに気づかない: 不足=${gaps.join(",") || "なし"}`,
      );
    });
  }
}
