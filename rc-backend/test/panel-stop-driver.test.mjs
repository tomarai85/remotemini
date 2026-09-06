// 机側の停止 driver の検査(2026-09-06、対照表 #8 の後半 c2)。偽 tmux = 打鍵に応じて画面を描く小さな模型。
// ★模型は**入力状態と描画を分ける**(Codex r5 #8): 打鍵は入力状態を即座に変えるが、描画は `lag` 回の撮影ぶん遅れる。
//   詳細の数字(経過秒)は撮影ごとに進む(`tick`)。これが無いと「古い描画で二度目の Escape」「数字が進んだだけで
//   x が効いたと読む」「撮った後に終わってパネルへ戻る」を表せない。
// 規則の検査: Escape は overlay の時だけ、閉じたのを見るまで二度打たない / x は一致した詳細でだけ、直前にもう一度撮る /
// 印の移動は 1 打ごとに観測 / 入力欄に文字が在れば打たない / 断りは閉じた語彙。
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { TmuxInjector, classifyScreen, composerText } from "../src/inject.mjs";
import { makeKeyedMutex } from "../src/mutex.mjs";
import { stopSubagent, STOP_REASONS, DRIVER_REFUSAL } from "../src/panelstop-driver.mjs";
import { STOP_REFUSAL } from "../src/panelstop.mjs";

const FIX = join(dirname(fileURLToPath(import.meta.url)), "fixtures", "panel");
const fx = (n) => readFileSync(join(FIX, n), "utf8");
const COMPOSER = fx("jervis-panel-closed.txt");
const DETAIL_FIX = fx("jervis-detail-open.txt");
const PROMPT = "You have exactly one job. Run the shell command `sleep 12` using the Bash tool, ten times in a row, as ten separate sequential Bash tool calls. Wait for each call to return before issuing the next one. Never use run_in_background. Do not combine the sleeps into one command, a loop, or a chain. Do not read files.";
const OTHER = "Count to ten slowly, one number per Bash call, and stop when you reach ten. Do not read files and do not spawn anything.";
const ROW = "count slowly (running) · Sonnet 5";
const T = (over = {}) => ({ agentType: "general-purpose", description: "count slowly", promptPrefix: PROMPT, recentTools: ["Bash(sleep 12)", "Bash(sleep 12)"], live: true, liveSameDescription: 1, ...over });

/** 入力欄に文字が映った composer 画面(最後の `❯` 行 = 入力欄の頭)。 */
function typed(text, s) {
  const lines = text.split("\n");
  for (let i = lines.length - 1; i >= 0; i--) if (/^\s*❯/.test(lines[i])) { lines[i] = lines[i].replace(/^(\s*❯\s?).*$/, `$1${s}`); break; }
  return lines.join("\n");
}
/** パネル画面。rows = [{text, shell?}]、sel = 平らな位置。 */
function panelScreen(rows, sel) {
  const shells = rows.filter((r) => r.shell), agents = rows.filter((r) => !r.shell);
  const out = ["⏺ Launch two subagents", "", "▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔", "   Background", `   ${shells.length} active shells · ${agents.length} active agents`, ""];
  let flat = 0;
  const emit = (r) => { out.push((flat === sel ? "   ❯ " : "     ") + r.text); flat++; };
  if (shells.length) { out.push(`     Shells (${shells.length})`); shells.forEach(emit); }
  if (agents.length) { out.push(`     Local agents (${agents.length})`); agents.forEach(emit); }
  out.push("", "   ↑/↓ to select · Enter to view · f to foreground · x to stop · ctrl+x ctrl+k to stop all agents · Esc to close", "");
  return out.join("\n");
}
/** 詳細画面: fixture の Prompt を差し替える(297 字で `…`)。経過秒は `elapsed` で差し替える。 */
function detailScreen(prompt, elapsed = 30) {
  const lines = DETAIL_FIX.split("\n").map((l) => l.replace(/^(\s*)\d+s · /, `$1${elapsed}s · `));
  const qi = lines.findIndex((l) => l.trim() === "Prompt");
  const fi = lines.findIndex((l, i) => i > qi && /^\s*← to go back/.test(l));
  const shown = prompt.length > 297 ? prompt.slice(0, 297) + "…" : prompt;
  const wrapped = []; let cur = "";
  for (const w of shown.split(" ")) { if (cur && (cur + " " + w).length > 100) { wrapped.push("   " + cur); cur = w; } else cur = cur ? cur + " " + w : w; }
  if (cur) wrapped.push("   " + cur);
  return [...lines.slice(0, qi + 1), ...wrapped, "", ...lines.slice(fi)].join("\n");
}

/**
 * 模型: 入力状態 `st.mode` = composer | panel | detail。打鍵で即座に変わる。描画は `lag` 回の撮影ぶん遅れる。
 *  - agents: [{ text, prompt, shell? }] 表示順 / sel: 印の平らな位置 / composer: 入力欄の初期文字
 *  - xEffect: "close"(x で overlay が閉じる)| "panel"(パネルに戻り行が消える)| "none"(何も起きない。数字だけ進む)
 *  - lag: 打鍵の後、古い描画を返す撮影の回数 / tick: 詳細の経過秒を撮影ごとに進める
 *  - ignoreMoves / neverOpenPanel / neverOpenDetail / reflowOnReopen / noEcho / finishAfterDetailCaptures(N 回撮った後に
 *    agent が終わってパネル(印はシェル行)へ戻る)
 */
function sim({ agents, sel = 0, composer = "", xEffect = "close", lag = 0, tick = false, ignoreMoves = false, neverOpenPanel = false,
               neverOpenDetail = false, reflowOnReopen = false, noEcho = false, finishAfterDetailCaptures = 0 } = {}) {
  const st = { mode: "composer", typed: composer, sel, agents: agents.map((a) => ({ ...a })), opens: 0, log: [], xPressed: 0, stoppedFlat: null,
               staleLeft: 0, staleFrame: null, elapsed: 30, detailCaptures: 0, captures: 0 };
  const flatRows = () => [...st.agents.filter((a) => a.shell), ...st.agents.filter((a) => !a.shell)];
  const render = () => {
    if (st.mode === "composer") return st.typed ? typed(COMPOSER, st.typed) : COMPOSER;
    if (st.mode === "panel") return panelScreen(flatRows(), st.sel);
    return detailScreen(flatRows()[st.sel].prompt, tick ? st.elapsed++ : 30);
  };
  const calls = [];
  const run = (args) => {
    calls.push(args);
    if (args[0] === "capture-pane") {
      st.captures++;
      if (st.staleLeft > 0) { st.staleLeft--; return st.staleFrame; }
      if (st.mode === "detail" && finishAfterDetailCaptures > 0) {
        st.detailCaptures++;
        if (st.detailCaptures > finishAfterDetailCaptures) { st.mode = "panel"; st.sel = 0; st.agents = st.agents.filter((a) => a.shell); }
      }
      return render();
    }
    if (args[0] !== "send-keys") return "";
    const before = render();
    const literal = args.includes("-l");
    const key = args[args.length - 1];
    st.log.push({ key, literal, mode: st.mode });
    if (literal) {
      if (st.mode === "composer" && !noEcho) st.typed += key;
      else if (st.mode === "detail" && key === "x") {
        st.xPressed++; st.stoppedFlat = st.sel;
        if (xEffect === "close") st.mode = "composer";
        else if (xEffect === "panel") { st.agents.splice(st.agents.indexOf(flatRows()[st.sel]), 1); st.mode = "panel"; st.sel = 0; }
      } else if (st.mode === "panel" && key === "x") { st.log[st.log.length - 1].shellKilled = Boolean(flatRows()[st.sel]?.shell); st.xPressed++; }
    } else if (key === "Enter") {
      if (st.mode === "composer" && st.typed.trim() === "/tasks") { st.typed = ""; if (!neverOpenPanel) { st.mode = "panel"; st.opens++; if (reflowOnReopen && st.opens > 1) { st.sel = 0; st.agents.push({ text: "late (running) · Sonnet 5", prompt: "late" }); } } }
      else if (st.mode === "panel" && !neverOpenDetail) st.mode = "detail";
    } else if (key === "Down") { if (st.mode === "panel" && !ignoreMoves) st.sel = Math.min(st.sel + 1, flatRows().length - 1); }
    else if (key === "Up") { if (st.mode === "panel" && !ignoreMoves) st.sel = Math.max(st.sel - 1, 0); }
    else if (key === "BSpace") { if (st.mode === "composer") st.typed = st.typed.slice(0, -1); }
    else if (key === "Escape") { if (st.mode === "panel" || st.mode === "detail") { st.mode = "composer"; st.sel = 0; } else st.log[st.log.length - 1].intoComposer = true; }
    if (lag > 0) { st.staleLeft = lag; st.staleFrame = before; }
    return "";
  };
  return { st, calls, tmux: { run, runStrict: run } };
}
const inj = (s, extra = {}) => new TmuxInjector({ tmux: s.tmux, echoBudgetMs: 60, sleep: async () => {}, mutex: makeKeyedMutex(), ...extra });
const closedResult = (r) => { if (r.ok) assert.equal(r.reason, null); else assert.ok(Object.hasOwn(STOP_REASONS, r.reason), r.reason); assert.ok(Array.isArray(r.keys)); assert.equal(typeof r.escapes, "number"); return r; };
const noEscapeIntoComposer = (s) => assert.equal(s.st.log.filter((l) => l.key === "Escape" && l.intoComposer).length, 0, "Escape が入力欄へ落ちた");
const noShellKilled = (s) => assert.equal(s.st.log.filter((l) => l.shellKilled).length, 0, "x がシェルを殺した");
const A1 = [{ text: ROW, prompt: PROMPT }];

test("語彙: driver の断りは計画の 7 語と重ならず、合わせて閉じている", () => {
  for (const k of Object.keys(DRIVER_REFUSAL)) assert.equal(Object.hasOwn(STOP_REFUSAL, k), false, k);
  assert.deepEqual(Object.keys(STOP_REASONS).sort(), [...Object.keys(STOP_REFUSAL), ...Object.keys(DRIVER_REFUSAL)].sort());
  for (const v of Object.values(DRIVER_REFUSAL)) assert.match(v, /pressed/);
});

test("★単独候補: /tasks → Enter → 詳細 → 一致 → x → 閉じる(x の後に overlay が無ければ Escape は打たない)", async () => {
  const s = sim({ agents: A1 });
  const r = closedResult(await stopSubagent(inj(s), "%1", T()));
  assert.equal(r.ok, true);
  assert.equal(r.stopped, "observed");
  assert.deepEqual(r.keys, ["-l /tasks", "Enter", "Enter", "-l x"]);
  assert.equal(r.escapes, 0);
  assert.equal(s.st.xPressed, 1);
  assert.equal(classifyScreen(s.tmux.run(["capture-pane"])).state, "SENDABLE");
  noEscapeIntoComposer(s);
});

test("★描画が 2 回遅れても同じ経路で止まる(打鍵ごとに『動いた』を待つ)", async () => {
  const s = sim({ agents: A1, lag: 2, tick: true });
  const r = closedResult(await stopSubagent(inj(s), "%1", T()));
  assert.equal(r.ok, true);
  assert.deepEqual(r.keys, ["-l /tasks", "Enter", "Enter", "-l x"]);
  noEscapeIntoComposer(s);
});

test("★同名 2 本: 1 本目の詳細が外れ → Escape 1 回 → /tasks を開き直し → Down → 2 本目の詳細が一致 → x", async () => {
  const s = sim({ agents: [{ text: ROW, prompt: OTHER }, { text: ROW, prompt: PROMPT }], xEffect: "panel" });
  const r = closedResult(await stopSubagent(inj(s), "%1", T({ liveSameDescription: 2 })));
  assert.equal(r.ok, true);
  assert.deepEqual(r.keys, ["-l /tasks", "Enter", "Enter", "Escape", "-l /tasks", "Enter", "Down", "Enter", "-l x", "Escape"]);
  assert.equal(r.escapes, 2);                                   // 1 回目 = 詳細を閉じる(閉じたのを見た)、2 回目 = x の後のパネル
  assert.equal(s.st.stoppedFlat, 1);
  assert.equal(r.target.flat, 1);
  noEscapeIntoComposer(s);
});

test("★双子(prompt も同じ): 両方の詳細を見て ambiguous。x は打たない、Escape は overlay の時だけ", async () => {
  const s = sim({ agents: [{ text: ROW, prompt: PROMPT }, { text: ROW, prompt: PROMPT }] });
  const r = closedResult(await stopSubagent(inj(s), "%1", T({ liveSameDescription: 2 })));
  assert.equal(r.reason, "ambiguous");
  assert.equal(r.sent, false);
  assert.equal(s.st.xPressed, 0);
  assert.equal(s.st.mode, "composer");
  noEscapeIntoComposer(s);
});

test("★入力欄に文字が残っていれば /tasks を打たない(親へ送ってしまう。Codex r5 #1)", async () => {
  const s = sim({ agents: A1, composer: "explain the quoted /tasks command" });
  const r = closedResult(await stopSubagent(inj(s), "%1", T()));
  assert.equal(r.reason, "not-sendable");
  assert.equal(r.why, "composer-not-empty");
  assert.deepEqual(r.keys, []);
  assert.equal(s.st.typed, "explain the quoted /tasks command");
});

test("★Escape の後、閉じたのを見るまで二度目は打たない。見えなければ escape-unverified(Codex r5 #2)", async () => {
  // 詳細が開いた状態で始まり、描画が 6 回遅れる = 期限内に閉じたのが見えない。
  const s = sim({ agents: [{ text: ROW, prompt: OTHER }], lag: 6 });
  s.st.mode = "detail";
  const r = closedResult(await stopSubagent(inj(s, { echoBudgetMs: 0 }), "%1", T(), { budgetMs: 0 }));
  assert.equal(r.reason, "escape-unverified");
  assert.equal(r.keys.filter((k) => k === "Escape").length, 1, "Escape は 1 回だけ");
  assert.equal(r.escapes, 1);
  noEscapeIntoComposer(s);
});

test("★撮った後に agent が終わってパネル(印はシェル行)へ戻る隙間: x の直前にもう一度撮って断る(Codex r5 #3)", async () => {
  const s = sim({ agents: [{ text: "sleep 300 (running)", prompt: "", shell: true }, { text: ROW, prompt: PROMPT }], finishAfterDetailCaptures: 1 });
  const r = closedResult(await stopSubagent(inj(s), "%1", T(), { allowShells: true }));
  assert.equal(r.reason, "reflow");
  assert.equal(r.why, "detail-changed-before-x");
  assert.equal(s.st.xPressed, 0);
  noShellKilled(s);
  noEscapeIntoComposer(s);
});

test("★シェル行が在るパネルは既定で断る(shell-row / shells-present)。allowShells で進める", async () => {
  const s = sim({ agents: [{ text: "sleep 300 (running)", prompt: "", shell: true }, { text: ROW, prompt: PROMPT }] });
  const r = closedResult(await stopSubagent(inj(s), "%1", T()));
  assert.equal(r.reason, "shell-row");
  assert.equal(r.why, "shells-present");
  assert.equal(s.st.xPressed, 0);
  const s2 = sim({ agents: [{ text: "sleep 300 (running)", prompt: "", shell: true }, { text: "sleep 301 (running)", prompt: "", shell: true }, { text: ROW, prompt: PROMPT }] });
  const r2 = closedResult(await stopSubagent(inj(s2), "%1", T(), { allowShells: true }));
  assert.equal(r2.ok, true);
  assert.deepEqual(r2.keys, ["-l /tasks", "Enter", "Down", "Down", "Enter", "-l x"]);
  assert.equal(s2.st.stoppedFlat, 2);
  noShellKilled(s2);
});

test("★x の後に数字が進んだだけ(同じ詳細に留まる)は成功ではない = unverified、sent:true(Codex r5 #4)", async () => {
  const s = sim({ agents: A1, xEffect: "none", tick: true });
  const r = closedResult(await stopSubagent(inj(s), "%1", T()));
  assert.equal(r.reason, "unverified");
  assert.equal(r.sent, true);
  assert.equal(s.st.xPressed, 1);
  assert.equal(r.escapes, 1);                                   // 残った詳細は閉じる(閉じたのを見る)
  assert.equal(s.st.mode, "composer");
});

test("★遅い描画: echo は猶予でもう一度待ち、来れば進む。来なければ残った /tasks を Backspace で消す(Codex r5 #5)", async () => {
  const s = sim({ agents: A1, lag: 1 });
  const r = closedResult(await stopSubagent(inj(s), "%1", T()));
  assert.equal(r.ok, true);
  const s2 = sim({ agents: A1, noEcho: true });
  s2.st.typed = "";
  const orig = s2.tmux.run;
  // 打った後に echo が一度も来ない(入力欄は空のまま)= 残る物が無い
  const r2 = closedResult(await stopSubagent(inj(s2), "%1", T()));
  assert.equal(r2.reason, "panel-did-not-open");
  assert.equal(r2.why, "no-echo");
  assert.equal(r2.after.retracted, false);
  // echo が期限(撮影 2 回)の後に来る = /tasks が残る → Backspace × 6 で消してから断る
  const s3 = sim({ agents: A1, lag: 2 });
  const r3 = closedResult(await stopSubagent(inj(s3, { echoBudgetMs: 0 }), "%1", T(), { budgetMs: 0 }));
  assert.equal(r3.reason, "panel-did-not-open");
  assert.equal(r3.why, "no-echo");
  assert.equal(r3.keys.filter((k) => k === "BSpace").length, 6, "残った /tasks は取り消す");
  assert.equal(s3.st.typed, "", "入力欄は空に戻る");
  assert.equal(r3.keys.filter((k) => k === "Enter").length, 0, "Enter は打っていない");
  void orig;
});

test("★/tasks でパネルが開かなければ panel-did-not-open(Enter は 1 回だけ、x は無し)", async () => {
  const s = sim({ agents: A1, neverOpenPanel: true });
  const r = closedResult(await stopSubagent(inj(s), "%1", T()));
  assert.equal(r.reason, "panel-did-not-open");
  assert.equal(r.keys.filter((k) => k === "Enter").length, 1);
  assert.equal(s.st.xPressed, 0);
  assert.equal(r.escapes, 0);
});

test("★印が動かなければ reflow で断る(Down は 1 回だけ、Escape でパネルを閉じる)", async () => {
  const s = sim({ agents: [{ text: "other (running) · Sonnet 5", prompt: "x" }, { text: ROW, prompt: PROMPT }], ignoreMoves: true });
  const r = closedResult(await stopSubagent(inj(s), "%1", T()));
  assert.equal(r.reason, "reflow");
  assert.equal(r.why, "move-not-observed");
  assert.deepEqual(r.keys, ["-l /tasks", "Enter", "Down", "Escape"]);
  assert.equal(s.st.xPressed, 0);
  assert.equal(s.st.mode, "composer");
});

test("★詳細が開かなければ x は打たない(detail-did-not-open)", async () => {
  const s = sim({ agents: A1, neverOpenDetail: true });
  const r = closedResult(await stopSubagent(inj(s), "%1", T()));
  assert.equal(r.reason, "detail-did-not-open");
  assert.equal(s.st.xPressed, 0);
  assert.equal(s.st.mode, "composer");
});

test("★詳細が目標と違えば mismatch。x は打たない", async () => {
  const s = sim({ agents: [{ text: ROW, prompt: OTHER }] });
  const r = closedResult(await stopSubagent(inj(s), "%1", T()));
  assert.equal(r.reason, "mismatch");
  assert.equal(r.why, "prompt");
  assert.equal(s.st.xPressed, 0);
  assert.equal(r.escapes, 1);
  assert.equal(s.st.mode, "composer");
});

test("★開き直したパネルの形が違えば reflow(候補の位置を信じない)", async () => {
  const s = sim({ agents: [{ text: ROW, prompt: OTHER }, { text: ROW, prompt: PROMPT }], reflowOnReopen: true });
  const r = closedResult(await stopSubagent(inj(s), "%1", T({ liveSameDescription: 2 })));
  assert.equal(r.reason, "reflow");
  assert.equal(r.why, "reopened-panel-differs");
  assert.equal(s.st.xPressed, 0);
  assert.equal(s.st.mode, "composer");
});

test("★既にパネルが開いていれば /tasks を打たずに其れを使う", async () => {
  const s = sim({ agents: A1 });
  s.st.mode = "panel";
  const r = closedResult(await stopSubagent(inj(s), "%1", T()));
  assert.equal(r.ok, true);
  assert.deepEqual(r.keys, ["Enter", "-l x"]);
});

test("★画面を触る前に断れる物は 1 打も打たない(live でない / 材料が無い / 生存数が無い / pane が空 / 予算が NaN でも走る)", async () => {
  const s = sim({ agents: A1 });
  for (const t of [T({ live: false }), T({ promptPrefix: "", recentTools: [] }), T({ liveSameDescription: undefined })]) {
    const r = closedResult(await stopSubagent(inj(s), "%1", t));
    assert.equal(r.ok, false);
    assert.deepEqual(r.keys, []);
  }
  assert.equal(closedResult(await stopSubagent(inj(s), "", T())).reason, "no-pane");           // Codex r5 #7
  assert.equal(closedResult(await stopSubagent(inj(s), "   ", T())).reason, "no-pane");
  assert.equal(s.calls.length, 0);
  const r = closedResult(await stopSubagent(inj(s), "%1", T(), { budgetMs: NaN }));           // Codex r5 #6: 既定に落ちて走り切る
  assert.equal(r.ok, true);
});

test("★入口が SENDABLE でなければ何も打たない(選択メニューが出ている)", async () => {
  const s = sim({ agents: A1 });
  const choice = ["  Do you want to proceed?", "  ❯ 1. Yes", "    2. No", "", "  Esc to cancel", ""].join("\n");
  const orig = s.tmux.run;
  s.tmux.run = (a) => (a[0] === "capture-pane" ? choice : orig(a));
  s.tmux.runStrict = s.tmux.run;
  const r = closedResult(await stopSubagent(inj(s), "%1", T()));
  assert.equal(r.reason, "not-sendable");
  assert.deepEqual(r.keys, []);
});

test("★ペインの鍵が塞がっていれば pane-busy(何も打たない)", async () => {
  const s = sim({ agents: A1 });
  const i = inj(s);
  let release;
  const held = i.mutex.run("%1", () => new Promise((r) => { release = r; }));
  const ac = new AbortController();
  const p = stopSubagent(i, "%1", T(), { signal: ac.signal });
  ac.abort();
  const r = closedResult(await p);
  assert.equal(r.reason, "pane-busy");
  assert.deepEqual(r.keys, []);
  release(); await held;
});

test("composerText の対照: 模型の入力欄は本物の読み手で読める", () => {
  assert.equal(composerText(typed(COMPOSER, "/tasks")), "/tasks");
  assert.equal(composerText(COMPOSER), "");
});
