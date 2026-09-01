import test from "node:test";
import assert from "node:assert/strict";
import { digestOf, digestLine, actionRequired, trimTail, DIGEST_MAX_RECORDS } from "../src/digest.mjs";

// ★この検査が守るのは正確さより**正直さ**。要約は読み飛ばす為の物なので、
//   抜けに気付けない要約は生の流れより危ない。だから検査の大半は
//   「読めなかった時に読めたふりをしないか」に割いてある。

const T0 = Date.parse("2026-08-26T00:00:00.000Z");
const at = (m) => new Date(T0 + m * 60000).toISOString();

const user = (m, text) => ({ type: "user", timestamp: at(m), message: { role: "user", content: text } });
const say  = (m, text) => ({ type: "assistant", timestamp: at(m), message: { role: "assistant", content: [{ type: "text", text }] } });
const tool = (m, name, input) => ({ type: "assistant", timestamp: at(m),
  message: { role: "assistant", content: [{ type: "tool_use", name, input: input || {} }] } });

const WIN = { sinceMs: T0, nowMs: T0 + 60 * 60000, reachedStart: true };

test("窓の中を数える", () => {
  const d = digestOf([user(1, "go"), say(2, "ok"), tool(3, "Bash", {}), tool(4, "Edit", { file_path: "/a.js" })], WIN);
  assert.equal(d.complete, true);
  assert.deepEqual(d.counts, { user: 1, assistant: 1, tool: 2 });
  assert.equal(d.fileTargetsTotal, 1);
});

test("窓の外は数えない", () => {
  const d = digestOf([say(-10, "before"), say(5, "inside"), say(999, "after")], WIN);
  assert.equal(d.counts.assistant, 1);
  assert.match(d.lastAssistant, /inside/);
});

test("★observedFromIso は実際に見えた最初の時刻(頼まれた時刻を書かない)", () => {
  // 1時間ぶんを頼んだが、実際に在るのは 50 分目から。
  // 「00:00 から」と名乗ったらその1行は嘘になる(Codex 2026-08-26)。
  const d = digestOf([say(50, "late"), say(55, "later")], WIN);
  assert.equal(d.window.requestedFromIso, new Date(T0).toISOString());
  assert.equal(d.window.observedFromIso, at(50));
  assert.notEqual(d.window.observedFromIso, d.window.requestedFromIso);
});

test("窓の中に1件も無ければ observedFromIso は null(0 分前と言わない)", () => {
  const d = digestOf([say(-5, "old")], WIN);
  assert.equal(d.complete, true);
  assert.equal(d.window.observedFromIso, null);
  assert.deepEqual(d.counts, { user: 0, assistant: 0, tool: 0 });
});

// ---- 不完全の扱い(この file の本題)----------------------------------------

test("★遡り切れなかったら数を返さない(0 に丸めない)", () => {
  const d = digestOf([say(30, "hi")], { ...WIN, reachedStart: false });
  assert.equal(d.complete, false);
  assert.equal(d.incompleteReason, "scan-budget");
  assert.equal(d.counts, null, "0 に丸めると『静かだった』として届く");
  assert.equal(d.tools, null);
  assert.equal(d.fileTargets, null);
});

test("★不完全でも最後の発言だけは返す(末尾は読めている)", () => {
  const d = digestOf([say(30, "the last thing I said")], { ...WIN, reachedStart: false });
  assert.equal(d.complete, false);
  assert.match(d.lastAssistant, /the last thing/);
});

test("★時刻の無いレコードが1件でも混ざったら不完全へ倒す", () => {
  const bad = { type: "assistant", message: { role: "assistant", content: [{ type: "text", text: "x" }] } };
  const d = digestOf([say(1, "a"), bad], WIN);
  assert.equal(d.complete, false);
  assert.equal(d.incompleteReason, "undated-records");
});

test("★多すぎる時も不完全(黙って上位だけ数えない)", () => {
  const many = Array.from({ length: DIGEST_MAX_RECORDS + 1 }, (_, i) => say(1, `m${i}`));
  const d = digestOf(many, WIN);
  assert.equal(d.complete, false);
  assert.equal(d.incompleteReason, "too-many-records");
});

test("窓が壊れていたら不完全", () => {
  assert.equal(digestOf([say(1, "a")], { sinceMs: NaN, nowMs: T0 }).complete, false);
});

// ---- 対象パス ----------------------------------------------------------------

test("★fileTargets は上位だけ出し、総数は別に持つ(件数を落とさない)", () => {
  const recs = ["/a", "/b", "/c", "/d", "/e"].map((p, i) => tool(i + 1, "Edit", { file_path: p }));
  const d = digestOf(recs, WIN);
  assert.equal(d.fileTargets.length, 3);
  assert.equal(d.fileTargetsTotal, 5, "総数を落とすと『5件中3件』が『3件』に化ける");
});

test("同じパスは1回だけ数える", () => {
  const d = digestOf([tool(1, "Edit", { file_path: "/a" }), tool(2, "Edit", { file_path: "/a" })], WIN);
  assert.equal(d.fileTargetsTotal, 1);
  assert.equal(d.counts.tool, 2, "道具の回数は減らさない");
});

test("path が文字列でなければ拾わない(input はモデルが書いた欄)", () => {
  const d = digestOf([tool(1, "Edit", { file_path: 42 }), tool(2, "Edit", {})], WIN);
  assert.equal(d.fileTargetsTotal, 0);
  assert.equal(d.counts.tool, 2);
});

// ---- 「今すぐ開くか」-----------------------------------------------------------

test("★人が押すまで進まない画面だけが now", () => {
  assert.equal(actionRequired("permission", { complete: true }).level, "now");
  assert.equal(actionRequired("choice", { complete: true }).level, "now");
});

test("打てば進む画面は soon", () => {
  assert.equal(actionRequired("input", { complete: true }).level, "soon");
});

test("動いている時は none", () => {
  assert.equal(actionRequired("none", { complete: true }).level, "none");
});

test("★画面が読めない時は none に倒さない(待っているかもしれない)", () => {
  for (const s of ["unknown", "", null, undefined, "nonsense"]) {
    const a = actionRequired(s, { complete: true });
    assert.equal(a.level, "unknown", `${s} が unknown 以外になった`);
  }
});

test("★要約が不完全なら『大丈夫』と言わない", () => {
  const a = actionRequired("none", { complete: false });
  assert.equal(a.level, "unknown");
  assert.equal(a.reason, "partial-digest");
});

// ---- 人が読む1行 --------------------------------------------------------------

test("1行は判断を先に言う", () => {
  const d = digestOf([say(1, "x"), tool(2, "Bash", {})], WIN);
  assert.match(digestLine(d, actionRequired("choice", d)), /waiting for you now/);
  assert.match(digestLine(d, actionRequired("none", d)), /still working/);
});

test("★不完全な1行は、完全な1行と見分けが付く", () => {
  const d = digestOf([say(1, "x")], { ...WIN, reachedStart: false });
  const line = digestLine(d, actionRequired("none", d));
  assert.match(line, /withheld/);
  assert.doesNotMatch(line, /still working/, "不完全なのに『動いています』と言い切った");
});

test("★どの1行も『安全』『大丈夫』を名乗らない", () => {
  const d = digestOf([say(1, "x")], WIN);
  for (const s of ["none", "input", "choice", "permission", "unknown"]) {
    const line = digestLine(d, actionRequired(s, d));
    assert.doesNotMatch(line, /\bsafe\b|\ball good\b|問題ありません/i, `${s}: ${line}`);
  }
});

test("末尾を採る(結論は後ろに在る)", () => {
  const long = "start " + "x".repeat(500) + " CONCLUSION";
  assert.match(trimTail(long), /CONCLUSION$/);
  assert.match(trimTail(long), /^…/);
});

// ---- 実物で踏んだ2件(2026-08-26)。どちらも「正直だが常に役立たず」へ落ちる形 ----

test("★時刻の無い**メタ行**は抜けではない(全部を不完全の証拠にすると常に数を伏せる)", () => {
  // 実測: 実際の転写には mode / permission-mode / ai-title / last-prompt 等、
  // 時刻を持たない行が数百本混ざる。これを抜けと読むと digest は永久に complete:false。
  const meta = [
    { type: "ai-title", title: "x" },
    { type: "last-prompt", content: "y" },
    { type: "file-history-snapshot" },
  ];
  const d = digestOf([say(1, "hello"), ...meta], WIN);
  assert.equal(d.complete, true, "メタ行で不完全に倒れた");
  assert.equal(d.counts.assistant, 1);
});

test("★数える筈の行に時刻が無ければ、やはり不完全(上の緩和が緩め過ぎでない事)", () => {
  const bad = { type: "assistant", message: { role: "assistant", content: [{ type: "text", text: "x" }] } };
  const d = digestOf([say(1, "a"), bad], WIN);
  assert.equal(d.complete, false);
  assert.equal(d.incompleteReason, "undated-records");
});

// ── 読んだ file と書き換えた file を分ける(2026-08-31)────────────────────────
// 直す前は `Read` と `Edit` が同じ箱に入っていて、区別できなかった。
// 此の 1 行が答える問いは「今ノートを開くべきか」で、其の判断に効くのは
// **読んだ 20 件ではなく、書き換えた 3 件**の方。

test("★読んだだけの file を「変えた」と数えない", () => {
  const now = Date.parse("2026-08-31T12:00:00Z");
  const since = now - 3600_000;
  const rec = (name, path) => ({
    type: "assistant", timestamp: new Date(now - 60_000).toISOString(),
    message: { content: [{ type: "tool_use", name, input: { file_path: path } }] },
  });
  const d = digestOf([rec("Read", "/a.txt"), rec("Read", "/b.txt")], { sinceMs: since, nowMs: now, reachedStart: true });
  assert.equal(d.fileTargetsTotal, 2, "読んだ側は従来通り数える");
  assert.equal(d.writeTargetsTotal, 0, "★読んだだけを「変えた」に数えてはいけない");
});

test("★書き換えた file だけを数える", () => {
  const now = Date.parse("2026-08-31T12:00:00Z");
  const since = now - 3600_000;
  const rec = (name, path) => ({
    type: "assistant", timestamp: new Date(now - 60_000).toISOString(),
    message: { content: [{ type: "tool_use", name, input: { file_path: path } }] },
  });
  const d = digestOf([rec("Read", "/a.txt"), rec("Edit", "/b.txt"), rec("Write", "/c.txt")],
                     { sinceMs: since, nowMs: now, reachedStart: true });
  assert.equal(d.fileTargetsTotal, 3);
  assert.equal(d.writeTargetsTotal, 2, "Edit と Write だけ");
});

test("★1 行は書き換えが無い時に黙る(読んだ数を出さない)", () => {
  const base = { complete: true, window: { minutes: 60 }, counts: { assistant: 3, tool: 20 } };
  const noWrite = digestLine({ ...base, writeTargetsTotal: 0 }, { level: "soon" });
  assert.ok(!/file/.test(noWrite), `読んだだけなのに file を出している: ${noWrite}`);
  const withWrite = digestLine({ ...base, writeTargetsTotal: 3 }, { level: "soon" });
  assert.ok(/3 files changed/.test(withWrite), withWrite);
});

test("読み切れなかった時は書き換えの数も伏せる(0 に丸めない)", () => {
  const now = Date.parse("2026-08-31T12:00:00Z");
  const d = digestOf([], { sinceMs: now - 3600_000, nowMs: now, reachedStart: false });
  assert.equal(d.complete, false);
  assert.equal(d.writeTargetsTotal, null, "★null であって 0 ではない(0 は「変えなかった」)");
});
