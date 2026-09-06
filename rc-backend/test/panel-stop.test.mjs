// 「この subagent を止める」の計画(純関数)の検査(2026-09-06、対照表 #8 の後半 c1)。
// 断りの語彙は閉じている。打鍵は 1 つも無い(此の file は tmux を知らない)。
// 規則: 押すのは常に `detailMatches` が通った詳細画面から。行の文字列だけで押す経路は無い。
// Codex 敵対レビュー 3 回(計 20 所見)の反例は此処に固定してある(★ 印、`Codex r<回>#<番号>`)。
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { parsePanel, parseDetail } from "../src/panelmodel.mjs";
import { planStop, verifySelection, detailMatches, rowMatches, rowDescription, flatRows, sameShape, hasMaterial, STOP_REFUSAL, TRUNC_MIN } from "../src/panelstop.mjs";

const FIX = join(dirname(fileURLToPath(import.meta.url)), "fixtures", "panel");
const fx = (n) => readFileSync(join(FIX, n), "utf8");
const PROMPT = "You have exactly one job. Run the shell command `sleep 12` using the Bash tool, ten times in a row, as ten separate sequential Bash tool calls. Wait for each call to return before issuing the next one. Never use run_in_background. Do not combine the sleeps into one command, a loop, or a chain. Do not read files.";
// 目標 = 机が転写から知る事 + 机が判定した生死(live)+ 同じ説明文で今も動いている数(目標を含む)。
const TARGET = { agentId: "a6276d12cef2e19e3", agentType: "general-purpose", description: "count slowly", promptPrefix: PROMPT,
  recentTools: ["Bash(sleep 12)", "Bash(sleep 12)"], live: true, liveSameDescription: 2 };
const SOLO = { ...TARGET, liveSameDescription: 1 };
const ROW = "count slowly (running) · Sonnet 5";
const LA = "Local agents";
const screen = (lines) => parsePanel(["⏺ x", "▔▔▔▔▔▔▔▔▔▔", "   Background", ...lines, "   ↑/↓ to select · Enter to view · x to stop · Esc to close", ""].join("\n"));
const ACTIONS = new Set(["open-detail", "press-x-in-detail", "close-detail"]);
const closed = (r) => { if (r.ok) { assert.ok(ACTIONS.has(r.action), r.action); assert.equal("reason" in r, false, "ok に reason は無い"); } else assert.ok(Object.hasOwn(STOP_REFUSAL, r.reason), r.reason); return r; };
const one = () => screen(["   1 active agent", "     Local agents (1)", `   ❯ ${ROW}`]);
const D = (over = {}) => ({ kind: "detail", agentType: "general-purpose", description: "count slowly", promptPrefix: "", promptTruncated: false, recentTools: [], ...over });

test("語彙は閉じていて、全部が『押していない』と言う", () => {
  for (const [k, v] of Object.entries(STOP_REFUSAL)) assert.match(v, /Nothing was pressed/, k);
  assert.deepEqual(Object.keys(STOP_REFUSAL).sort(), ["ambiguous", "mismatch", "no-such-row", "not-a-panel", "reflow", "shell-row", "too-far"]);
});

test("★rowDescription: 境界は最後の ` (<状態>)`。説明文自身が括弧を含んでも取り違えない(Codex r3#2)", () => {
  assert.equal(rowDescription(ROW), "count slowly");
  assert.equal(rowDescription("deploy (backup) (running) · Sonnet 5"), "deploy (backup)");
  assert.equal(rowDescription("deploy (running) · Sonnet 5"), "deploy");
  assert.equal(rowDescription("sleep 300 (running)"), "sleep 300");
  assert.equal(rowDescription("count slowly"), null);
  assert.equal(rowMatches("deploy (backup) (running) · Sonnet 5", "deploy"), false);
  assert.equal(rowMatches("count slowly faster (running) · Sonnet 5", "count slowly"), false);
  const panel = screen(["   2 active agents", "     Local agents (2)", "     deploy (backup) (running) · Sonnet 5", "   ❯ deploy (running) · Sonnet 5"]);
  const p = closed(planStop({ panel, target: { description: "deploy", promptPrefix: "A sufficiently identifying prompt", live: true, liveSameDescription: 1 }, maxMoves: 0 }));
  assert.deepEqual(p, { ok: true, action: "open-detail", moves: 0, direction: "down", target: { flat: 1, section: LA, index: 1, text: "deploy (running) · Sonnet 5" }, candidates: [1] });
});

test("★行の文字列だけで押す経路は無い: 説明文が 1 本しか描かれていなくても open-detail", () => {
  const panel = screen(["   2 active shells · 1 active agent", "     Shells (2)", "     sleep 300 (running)", "   ❯ sleep 300 (running)", "     Local agents (1)", "     sleep then done (running) · Sonnet 5"]);
  const p = closed(planStop({ panel, target: { description: "sleep then done", promptPrefix: "sleep 200 then say done", live: true, liveSameDescription: 1 } }));
  assert.deepEqual(p, { ok: true, action: "open-detail", moves: 1, direction: "down", target: { flat: 2, section: LA, index: 0, text: "sleep then done (running) · Sonnet 5" }, candidates: [2] });
});

test("★机が生死を知らなければ押さない: live でなければ no-such-row、同名の生存数が無ければ ambiguous", () => {
  const detail = parseDetail(fx("jervis-detail-open.txt"));
  assert.equal(closed(planStop({ panel: one(), detail, target: { ...SOLO, live: false } })).reason, "no-such-row");
  assert.equal(closed(planStop({ panel: one(), detail, target: { ...SOLO, live: undefined } })).reason, "no-such-row");
  const noCount = closed(planStop({ panel: one(), detail, target: { ...SOLO, liveSameDescription: undefined } }));
  assert.equal(noCount.reason, "ambiguous");
  assert.equal(noCount.why, "unknown-siblings");
});

test("★完全に同一な双子の片方が先に終わった後(机は 2 本生きていると言い、画面は 1 本)→ ambiguous(Codex r2#1)", () => {
  const detail = parseDetail(fx("jervis-detail-open.txt"));
  const p = closed(planStop({ panel: one(), detail, target: TARGET }));   // liveSameDescription 2 > 描かれた 1
  assert.equal(p.reason, "ambiguous");
  assert.equal(p.why, "twin-may-have-finished");
  assert.equal(closed(planStop({ panel: one(), target: TARGET })).reason, "ambiguous");
});

test("★目標に見分ける材料が無ければ、行が 1 本でも ambiguous(何も照合できないのに押さない)", () => {
  assert.equal(hasMaterial({ description: "count slowly" }), false);
  assert.equal(closed(planStop({ panel: one(), target: { description: "count slowly", live: true, liveSameDescription: 1 } })).reason, "ambiguous");
});

test("★実 fixture: 同じ説明文の 2 本 + 材料あり → 1 本目の詳細を開く(印は 1 本目に乗っているので moves 0)", () => {
  const p = closed(planStop({ panel: parsePanel(fx("friday-panel-open.txt")), target: TARGET }));
  assert.equal(p.action, "open-detail");
  assert.equal(p.moves, 0);
  assert.deepEqual(p.candidates, [0, 1]);
  assert.deepEqual(p.remaining, [0, 1]);
  assert.deepEqual(p.target, { flat: 0, section: LA, index: 0, text: ROW });
});

test("★実 fixture: 同名 2 本で 2 本目の詳細が一致しても、1 本目を見ていなければ close-detail(消去法でも先着でも押さない)", () => {
  const panel = parsePanel(fx("jervis-panel-down1.txt"));   // 印は 2 本目(flat 1)
  const detail = parseDetail(fx("jervis-detail-open.txt"));
  const p = closed(planStop({ panel, detail, target: TARGET }));
  assert.equal(p.action, "close-detail");
  assert.deepEqual(p.remaining, [0]);
  assert.equal(p.matched, true);
});

test("★同名 2 本: 他方を見て外れていれば press-x-in-detail、他方も一致するなら ambiguous(双子は見分けられない)", () => {
  const panel = parsePanel(fx("jervis-panel-down1.txt"));
  const detail = parseDetail(fx("jervis-detail-open.txt"));
  const otherDetail = { ...detail, promptPrefix: "Count to ten slowly and then stop.", promptTruncated: false };
  const a = closed(planStop({ panel, detail, target: TARGET, examined: [{ flat: 0, detail: otherDetail }] }));
  assert.equal(a.action, "press-x-in-detail");
  assert.equal(a.target.flat, 1);
  const b = closed(planStop({ panel, detail, target: TARGET, examined: [{ flat: 0, detail }] }));
  assert.equal(b.reason, "ambiguous");
  assert.equal(b.why, "duplicate");
});

test("★同名 2 本を全部見た後(詳細は閉じている): 一致 1 本なら其処へ open-detail(final)、0 本なら no-such-row、2 本なら ambiguous", () => {
  const panel = parsePanel(fx("friday-panel-open.txt"));   // 印は flat 0
  const detail = parseDetail(fx("jervis-detail-open.txt"));
  const other = { ...detail, promptPrefix: "Count to ten slowly and then stop.", promptTruncated: false };
  const p = closed(planStop({ panel, target: TARGET, examined: [{ flat: 0, detail: other }, { flat: 1, detail }] }));
  assert.equal(p.action, "open-detail");
  assert.equal(p.final, true);
  assert.equal(p.target.flat, 1);
  assert.equal(p.moves, 1);
  assert.equal(closed(planStop({ panel, target: TARGET, examined: [{ flat: 0, detail: other }, { flat: 1, detail: other }] })).reason, "no-such-row");
  assert.equal(closed(planStop({ panel, target: TARGET, examined: [{ flat: 0, detail }, { flat: 1, detail }] })).reason, "ambiguous");
});

test("★exclude(詳細の無い除外)は『見たが一致しない』として効く(Codex r2#6)", () => {
  const panel = parsePanel(fx("friday-panel-open.txt"));
  const p = closed(planStop({ panel, target: TARGET, exclude: [0] }));
  assert.equal(p.action, "open-detail");
  assert.equal(p.target.flat, 1);
  assert.equal(p.moves, 1);
  assert.deepEqual(p.remaining, [1]);
  assert.equal(closed(planStop({ panel, target: TARGET, exclude: [0, 1] })).reason, "no-such-row");
});

test("★詳細が開いている時、印がシェル行 / 目標と違う行の上なら詳細を見る前に断る", () => {
  const detail = parseDetail(fx("jervis-detail-open.txt"));
  const shellSel = screen(["   1 active shell · 1 active agent", "     Shells (1)", "   ❯ sleep 300 (running)", "     Local agents (1)", `     ${ROW}`]);
  assert.equal(closed(planStop({ panel: shellSel, detail, target: SOLO })).reason, "shell-row");
  const otherSel = screen(["   2 active agents", "     Local agents (2)", "   ❯ other (running) · Sonnet 5", `     ${ROW}`]);
  assert.equal(closed(planStop({ panel: otherSel, detail, target: SOLO })).reason, "mismatch");
});

test("★印が 2 つ以上 / 無い描画は reflow(壊れた取得を『最初の印』で読まない。Codex r3#3)", () => {
  const two = screen(["   2 active agents", "     Local agents (2)", `   ❯ ${ROW}`, "   ❯ other (running) · Sonnet 5"]);
  assert.equal(verifySelection(two, { flat: 0, section: LA, index: 0, text: ROW }).reason, "reflow");
  assert.equal(closed(planStop({ panel: two, target: SOLO })).reason, "reflow");
  const none = screen(["   1 active agent", "     Local agents (1)", `     ${ROW}`]);
  assert.equal(verifySelection(none, { flat: 0, section: LA, index: 0, text: ROW }).reason, "reflow");
  assert.equal(closed(planStop({ panel: none, target: SOLO })).reason, "reflow");
});

test("単独候補(机も 1 本と言う)+ 詳細一致 → press-x-in-detail、prompt が違えば mismatch(why prompt)", () => {
  const detail = parseDetail(fx("jervis-detail-open.txt"));
  const p = closed(planStop({ panel: one(), detail, target: SOLO }));
  assert.equal(p.action, "press-x-in-detail");
  assert.deepEqual(p.target, { flat: 0, section: LA, index: 0, text: ROW });
  const q = closed(planStop({ panel: one(), detail, target: { ...SOLO, promptPrefix: "Count to ten slowly and then stop." } }));
  assert.equal(q.reason, "mismatch");
  assert.equal(q.why, "prompt");
});

test("★prompt が切れていなければ丸ごと一致。行の中の連続空白、先頭・末尾の空白も意味を持つ(Codex r2#4, r3#5)", () => {
  const whole = D({ promptPrefix: "Count to ten" });
  assert.equal(detailMatches(whole, { description: "count slowly", promptPrefix: "Count to ten and then stop" }).why, "prompt");
  assert.equal(detailMatches(whole, { description: "count slowly", promptPrefix: "Count to ten" }).ok, true);
  assert.equal(detailMatches(whole, { description: "count slowly", promptPrefix: "Count  to ten" }).why, "prompt");
  assert.equal(detailMatches(whole, { description: "count slowly", promptPrefix: "  Count to ten" }).why, "prompt");
  assert.equal(detailMatches(whole, { description: "count slowly", promptPrefix: "Count to ten  " }).why, "prompt");
  const code = D({ promptPrefix: "Run `printf 'a b'`" });
  assert.equal(detailMatches(code, { description: "count slowly", promptPrefix: "Run `printf 'a  b'`" }).why, "prompt");
  assert.equal(detailMatches(code, { description: "count slowly", promptPrefix: "Run `printf 'a b'`" }).ok, true);
  // 折り返し(改行 + 前後の空白)だけは畳む。先頭の空行と末尾の改行は落とす(prompt は其の形で来る事が普通)
  assert.equal(detailMatches(code, { description: "count slowly", promptPrefix: "Run\n   `printf 'a b'`" }).ok, true);
  assert.equal(detailMatches(code, { description: "count slowly", promptPrefix: "\nRun `printf 'a b'`\n" }).ok, true);
});

test("★`…` で終わる prompt: 見えている長さが UI の切り所より短ければ本物の `…`(丸ごと一致だけ)、長ければ UI の省略で先頭一致(Codex r2#3, r3#6)", () => {
  const long = "A".repeat(TRUNC_MIN) + " and then the rest of a much longer prompt that did not fit on the screen";
  const cut = D({ promptPrefix: "A".repeat(TRUNC_MIN) + "…", promptTruncated: true });
  assert.equal(detailMatches(cut, { description: "count slowly", promptPrefix: long }).ok, true);
  assert.equal(detailMatches(cut, { description: "count slowly", promptPrefix: "B" + long }).why, "prompt");
  assert.equal(detailMatches(cut, { description: "count slowly", promptPrefix: "short" }).why, "prompt");        // 収まる筈なのに違う
  // 本物の `…`(40 字 + `…` = UI は切っていない)を接頭辞に持つ別の目標: 通さない
  const literal = D({ promptPrefix: "A".repeat(40) + "…", promptTruncated: true });
  assert.equal(detailMatches(literal, { description: "count slowly", promptPrefix: "A".repeat(40) + " completely different continuation" }).why, "insufficient");
  assert.equal(detailMatches(literal, { description: "count slowly", promptPrefix: "A".repeat(40) + "…" }).ok, true);   // 文字通り同じなら通る
  assert.equal(detailMatches(literal, { description: "count slowly", promptPrefix: "B".repeat(60) }).why, "prompt");
  const shortCut = D({ promptPrefix: "Do A…", promptTruncated: true });
  assert.equal(closed(planStop({ panel: one(), detail: shortCut, target: { ...SOLO, promptPrefix: "Do A completely different", recentTools: [] } })).reason, "ambiguous");
  // 実 fixture は 297 字 + `…`(Jervis 120 桁も friday 80 桁も同じ)= UI の省略
  for (const f of ["jervis-detail-open.txt", "friday-detail-open.txt"]) assert.ok(parseDetail(fx(f)).promptPrefix.length - 1 >= TRUNC_MIN, f);
  assert.equal(detailMatches(parseDetail(fx("jervis-detail-open.txt")), { description: "count slowly", promptPrefix: PROMPT }).ok, true);
  // friday の fixture は別の prompt の agent(先頭から違う)= 同じ説明文でも見分けられる事の実例
  assert.equal(detailMatches(parseDetail(fx("friday-detail-open.txt")), { description: "count slowly", promptPrefix: PROMPT }).why, "prompt");
});

test("★目標が持つ材料は全部詳細側にも要る: prompt が画面外なら道具だけでは押さない(Codex r2#5)", () => {
  const noPrompt = D({ recentTools: ["Read(x)"] });
  assert.equal(detailMatches(noPrompt, { description: "count slowly", promptPrefix: "unique prompt for A", recentTools: ["Read(x)"] }).why, "insufficient");
  assert.equal(closed(planStop({ panel: one(), detail: noPrompt, target: { ...SOLO, promptPrefix: "unique prompt for A", recentTools: ["Read(x)"] } })).reason, "ambiguous");
  const noTools = D({ promptPrefix: "unique prompt for A" });
  assert.equal(detailMatches(noTools, { description: "count slowly", promptPrefix: "unique prompt for A", recentTools: ["Read(x)"] }).why, "insufficient");
});

test("道具: 末尾一致。行が `…` で切れていれば前方一致(短い接頭辞は証拠にしない)、切れていなければ丸ごと一致", () => {
  const base = D({ recentTools: ["Bash(sleep 12 && echo very-long-arg…"] });
  const t = { description: "count slowly", recentTools: ["Read(x)", "Bash(sleep 12 && echo very-long-argument-that-was-cut)"] };
  const loose = { strict: false };                                             // 単独候補の時だけ切れた行を認める
  assert.equal(detailMatches(base, t, loose).ok, true);
  assert.equal(detailMatches(base, t).why, "insufficient");                    // 既定(同名あり)は証拠にしない
  assert.equal(detailMatches({ ...base, recentTools: ["Bash(sleep 12 && echo very-long-arg"] }, t, loose).why, "tools");
  assert.equal(detailMatches({ ...base, recentTools: ["Bash(sleep 99)…"] }, t, loose).why, "tools");
  assert.equal(detailMatches({ ...base, recentTools: ["Bash(sl…"] }, t, loose).why, "insufficient");
  assert.equal(detailMatches({ ...base, recentTools: ["Read(x)", "Bash(sleep 12 && echo very-long-argument-that-was-cut)"] }, { ...t, recentTools: ["Bash(sleep 12 && echo very-long-argument-that-was-cut)"] }).why, "tools");
  assert.deepEqual(detailMatches(parseDetail(fx("jervis-detail-open.txt")), { description: "count slowly" }), { ok: false, why: "insufficient" });
});

test("★シェルの節の行は候補にしない(説明文が偶然一致しても no-such-row)", () => {
  const panel = screen(["   1 active shell", "     Shells (1)", "   ❯ sleep 300 (running)"]);
  assert.equal(closed(planStop({ panel, target: { description: "sleep 300", promptPrefix: "x", live: true, liveSameDescription: 1 } })).reason, "no-such-row");
});

test("遠すぎれば too-far(既定 8 段)、maxMoves を広げれば届く。overflow の印が在って目標が見えなければ too-far。壊れた maxMoves は既定に落ちる(Codex r3#7)", () => {
  const rows = Array.from({ length: 12 }, (_, i) => `     agent ${i} (running) · Sonnet 5`);
  rows[0] = "   ❯ agent 0 (running) · Sonnet 5";
  const panel = screen(["   12 active agents", "     Local agents (12)", ...rows]);
  const t = { description: "agent 11", promptPrefix: "x", live: true, liveSameDescription: 1 };
  assert.equal(closed(planStop({ panel, target: t })).reason, "too-far");
  assert.equal(closed(planStop({ panel, target: t, maxMoves: 12 })).action, "open-detail");
  assert.equal(closed(planStop({ panel, target: t, maxMoves: Symbol("bad") })).reason, "too-far");
  assert.equal(closed(planStop({ panel, target: { ...t, description: "agent 3" }, maxMoves: "9" })).action, "open-detail");
  const cutPanel = screen(["   14 active agents", "     Local agents (14)", ...rows, "     ↓ 2 more"]);
  assert.equal(closed(planStop({ panel: cutPanel, target: { ...t, description: "agent 13" } })).reason, "too-far");
});

test("panel でなければ not-a-panel、目標の行が無ければ no-such-row、壊れた入力は例外でなく断り(Codex r2#8)", () => {
  assert.equal(closed(planStop({ panel: null, target: TARGET })).reason, "not-a-panel");
  assert.equal(closed(planStop({ panel: parsePanel(fx("friday-panel-open.txt")), target: { ...SOLO, description: "does not exist" } })).reason, "no-such-row");
  assert.equal(closed(planStop({ panel: parsePanel(fx("friday-panel-open.txt")) })).reason, "no-such-row");
  const broken = { kind: "panel", sections: [{ name: "Local agents" }] };
  assert.equal(closed(planStop({ panel: broken, target: SOLO })).reason, "no-such-row");
  assert.equal(verifySelection(broken, { flat: 0, section: LA, index: 0, text: ROW }).reason, "reflow");
  assert.equal(sameShape(broken, broken), true);
});

test("★verifySelection: 平らな位置 + 節 + 節内の位置 + 文字列の四つが全部必須で、揃って初めて ok(Codex r1#3, r2#2, r3#4)", () => {
  const open = parsePanel(fx("friday-panel-open.txt"));   // 印は flat 0
  const ok = verifySelection(open, { flat: 0, section: LA, index: 0, text: ROW });
  assert.equal(ok.ok, true);
  assert.equal("reason" in ok, false);
  assert.equal(verifySelection(open, { flat: 1, section: LA, index: 1, text: ROW }).reason, "mismatch");
  assert.equal(verifySelection(open, { text: ROW }).reason, "mismatch");                                   // 位置無し
  assert.equal(verifySelection(open, { flat: 0, text: ROW }).reason, "mismatch");                          // 節・index 無し
  assert.equal(verifySelection(open, { flat: 0, section: null, index: null, text: ROW }).reason, "mismatch"); // null は wildcard ではない
  assert.equal(verifySelection(open, { flat: 0, section: LA, index: 0, text: "gone (running) · Sonnet 5" }).reason, "reflow");
  assert.equal(verifySelection(open, { flat: 5, section: LA, index: 5, text: ROW }).reason, "reflow");     // 其の位置に行が無い
  assert.equal(verifySelection(open, { flat: 0, section: "Team: x", index: 0, text: ROW }).reason, "reflow");
  // Codex r2#2: 節内の index 1 を期待していたが、上の 1 本が終わって shell が先頭に足され、flat は偶然 1 のまま
  const fresh = screen(["   1 active shell · 1 active agent", "     Shells (1)", "     job (running)", "     Local agents (1)", `   ❯ ${ROW}`]);
  assert.equal(verifySelection(fresh, { flat: 1, section: LA, index: 1, text: ROW }).reason, "reflow");
  const shellSel = screen(["   1 active shell · 1 active agent", "     Shells (1)", "   ❯ sleep 300 (running)", "     Local agents (1)", `     ${ROW}`]);
  assert.equal(verifySelection(shellSel, { flat: 1, section: LA, index: 0, text: ROW }).reason, "shell-row");
  const other = screen(["   2 active agents", "     Local agents (2)", "   ❯ other (running) · Sonnet 5", `     ${ROW}`]);
  assert.equal(verifySelection(other, { flat: 1, section: LA, index: 1, text: ROW }).reason, "mismatch");
  assert.equal(verifySelection(null, { flat: 0, section: LA, index: 0, text: ROW }).reason, "not-a-panel");
});

test("★sameShape: 行の並びと文字列に加えて、節の数字・集計文・overflow の印も同じ時だけ true(Codex r2#10)", () => {
  const a = parsePanel(fx("friday-panel-open.txt")), b = parsePanel(fx("jervis-panel-down1.txt"));
  assert.equal(sameShape(a, b), true);                       // 印の位置は形に入れない
  assert.equal(sameShape(a, one()), false);
  const before = { kind: "panel", counts: "3 active agents", hints: ["↓ 1 more"], sections: [{ name: LA, count: 3, rows: [{ text: ROW, selected: true }, { text: ROW, selected: false }] }] };
  const after = { kind: "panel", counts: "2 active agents", hints: [], sections: [{ name: LA, count: 2, rows: [{ text: ROW, selected: true }, { text: ROW, selected: false }] }] };
  assert.equal(sameShape(before, after), false);
  assert.equal(sameShape(before, { ...before, sections: [{ ...before.sections[0], rows: before.sections[0].rows.map((r) => ({ ...r, selected: !r.selected })) }] }), true);
});

test("★見た候補が『決められない』(材料が画面外)なら、他が一致しても押さない(Codex r4#1)", () => {
  const panel = parsePanel(fx("jervis-panel-down1.txt"));   // 印は flat 1
  const t = { agentType: "general-purpose", description: "count slowly", promptPrefix: "shared prompt", recentTools: ["Read(/same)"], live: true, liveSameDescription: 2 };
  const shown = D({ promptPrefix: "shared prompt", recentTools: ["Read(/same)"] });
  const undecided = D({ promptPrefix: "", recentTools: ["Read(/same)"] });      // prompt が画面外
  const a = closed(planStop({ panel, detail: shown, target: t, examined: [{ flat: 0, detail: undecided }] }));
  assert.equal(a.reason, "ambiguous");
  assert.equal(a.why, "insufficient");
  // 詳細を閉じた後の集計でも同じ
  const b = closed(planStop({ panel: parsePanel(fx("friday-panel-open.txt")), target: t, examined: [{ flat: 0, detail: undecided }, { flat: 1, detail: shown }] }));
  assert.equal(b.reason, "ambiguous");
  // 外れ(prompt が違う)なら押せる
  const miss = D({ promptPrefix: "another prompt", recentTools: ["Read(/same)"] });
  assert.equal(closed(planStop({ panel, detail: shown, target: t, examined: [{ flat: 0, detail: miss }] })).action, "press-x-in-detail");
});

test("★詳細に型が無ければ wildcard ではなく insufficient(Codex r4#2)", () => {
  assert.equal(detailMatches(D({ agentType: null, promptPrefix: "unique prompt" }), { agentType: "general-purpose", description: "count slowly", promptPrefix: "unique prompt" }).why, "insufficient");
  assert.equal(closed(planStop({ panel: one(), detail: D({ agentType: null, promptPrefix: PROMPT }), target: { ...SOLO, recentTools: [] } })).reason, "ambiguous");
});

test("★planStop(null) / planStop() は例外でなく not-a-panel(Codex r4#3)", () => {
  assert.equal(closed(planStop(null)).reason, "not-a-panel");
  assert.equal(closed(planStop()).reason, "not-a-panel");
  assert.equal(closed(planStop("x")).reason, "not-a-panel");
});

test("★切れた道具の行は『矛盾しない』止まり: 同名が複数なら証拠にしない、単独候補なら足りる(Codex r4#8)", () => {
  const common = "Bash(process --config /a/very/long/common/prefix/that-is-identical/up-to-the-terminal-cut/";
  const d = D({ promptPrefix: "same prompt", recentTools: [common + "…"] });
  const t = { agentType: "general-purpose", description: "count slowly", promptPrefix: "same prompt", recentTools: [common + "TARGET.json)"] };
  assert.equal(detailMatches(d, t).why, "insufficient");                       // 既定 = strict
  assert.equal(detailMatches(d, t, { strict: false }).ok, true);
  assert.equal(detailMatches(d, { ...t, recentTools: ["Read(x)"] }, { strict: false }).why, "tools");
  // 同名 2 本: 一方の詳細が切れた道具でしか一致しない → ambiguous
  const panel = parsePanel(fx("jervis-panel-down1.txt"));
  const p = closed(planStop({ panel, detail: d, target: { ...t, live: true, liveSameDescription: 2 }, examined: [{ flat: 0, detail: D({ promptPrefix: "other", recentTools: ["Read(x)"] }) }] }));
  assert.equal(p.reason, "ambiguous");
  // 単独候補(机も 1 本): 矛盾しないので押せる
  assert.equal(closed(planStop({ panel: one(), detail: d, target: { ...t, live: true, liveSameDescription: 1 } })).action, "press-x-in-detail");
});

test("flatRows は節を跨いだ表示順(移動の数は此の並びで数える)", () => {
  assert.deepEqual(flatRows(parsePanel(fx("friday-panel-open.txt"))).map((r) => [r.section, r.index, r.selected]), [[LA, 0, true], [LA, 1, false]]);
});
