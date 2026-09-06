// 会話の下の subagent を、ディスクだけから正しく数え、**分からない事は分からないと言う**か。
//
// ── 何を守るか(2026-09-04)────────────────────────────────────────────────
// この口が返す `subagents: []` には意味が3つ在る —— 本当に1本も居ない / dir が読めない /
// 居るが親の転写が読めず生死が判らない。1つの空配列で3つを名乗ると、電話は必ず一番
// 都合の良い読み方(=「今 何も走っていない」)をする。走っている物を見落とす向きの嘘。
//
// ★生死の規則は、引き継ぎ文の記述を実測で**訂正した**上で測る。引き継ぎ文は
//   「親の tool_result が agentId を名乗っていたら終了」と書いていたが、実測(991 本)では
//   親が名乗る `toolUseResult` の `status` は2種類在って、`async_launched` は**起動**の
//   合図でしかない。名前だけを見る実装は、起動直後の agent を全部「終了」と報告する。
//   だから下の「★起動を名乗るだけの記録は終了ではない」が此の file の主柱で、
//   其処が緑のまま他が緑になっても意味が無い。
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, utimesSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { readSubagentsFromPath, subagentDirFor, SUBAGENT_STALE_MS } from "../src/subagents.mjs";

const NOW = Date.parse("2026-09-04T12:00:00.000Z");
const SID = "1b5c9362-aaaa-bbbb-cccc-000000000001";

/** 親 file と、その隣の `subagents/` を作る。`agents` は `{id, meta, mtimeMinAgo, model}`。 */
function world({ parentLines = [], agents = [], noDir = false } = {}) {
  const base = mkdtempSync(join(tmpdir(), "subagents-"));
  const parent = join(base, `${SID}.jsonl`);
  writeFileSync(parent, parentLines.map((l) => JSON.stringify(l)).join("\n") + "\n");
  if (!noDir) {
    const dir = join(base, SID, "subagents");
    mkdirSync(dir, { recursive: true });
    for (const a of agents) {
      const jl = join(dir, `agent-${a.id}.jsonl`);
      const line = { agentId: a.id, type: "assistant", message: { role: "assistant", model: a.model ?? "claude-opus-5" } };
      writeFileSync(jl, JSON.stringify(line) + "\n");
      // mtime を意図した過去へ。★`stalled` は此処でしか作れない。
      const t = (NOW - (a.mtimeMinAgo ?? 0) * 60_000) / 1000;
      utimesSync(jl, t, t);
      if (a.meta !== null) {
        writeFileSync(join(dir, `agent-${a.id}.meta.json`),
          a.meta === "broken" ? "{ this is not json" : JSON.stringify(a.meta));
      }
    }
  }
  return { base, parent };
}

/** 親の「終了」記録(同期の Agent 呼び出し)。 */
const completed = (id) => ({
  type: "user", timestamp: "2026-09-04T11:00:00.000Z",
  message: { role: "user", content: [{ type: "tool_result", tool_use_id: "toolu_x" }] },
  toolUseResult: { agentId: id, status: "completed", agentType: "general-purpose" },
});

/** 親の「起動した」記録。★終了ではない。 */
const launched = (id) => ({
  type: "user", timestamp: "2026-09-04T11:00:00.000Z",
  message: { role: "user", content: [{ type: "tool_result", tool_use_id: "toolu_y" }] },
  toolUseResult: { agentId: id, status: "async_launched", isAsync: true },
});

/** 背後起動の agent が終わる時の形(`<task-notification>`)。 */
const notified = (id, status) => ({
  type: "user", timestamp: "2026-09-04T11:30:00.000Z",
  message: { role: "user", content: `<task-notification>\n<task-id>${id}</task-id>\n<status>${status}</status>\n</task-notification>` },
});

const read = (w, opts = {}) => readSubagentsFromPath(w.parent, { nowMs: NOW, ...opts });
const byId = (r, id) => r.agents.find((a) => a.agentId === id);

// ── 幹の位置 ────────────────────────────────────────────────────────────────

test("★子の dir は親 file の拡張子を落とした幹の隣に生える", () => {
  assert.equal(subagentDirFor("/p/-slug/abc.jsonl"), join("/p/-slug/abc", "subagents"));
  // 拡張子が無い path を渡された時も幹の扱いを変えない(呼び手が付け忘れても壊れない)。
  assert.equal(subagentDirFor("/p/-slug/abc"), join("/p/-slug/abc", "subagents"));
});

// ── 3値 + unknown ──────────────────────────────────────────────────────────

test("★親が終了を記録した子は finished(mtime が古くても観測値が勝つ)", () => {
  const w = world({
    parentLines: [completed("adone1")],
    agents: [{ id: "adone1", meta: { agentType: "planner", description: "計画" }, mtimeMinAgo: 999 }],
  });
  const r = read(w);
  const a = byId(r, "adone1");
  assert.equal(a.state, "finished");
  assert.equal(a.reason, "parent-completed");
  // 999 分放置されていても stalled に落ちない = mtime より親の記録が上位、を名指しで押さえる。
  assert.equal(r.counts.stalled, 0);
  assert.deepEqual(r.counts, { finished: 1, running: 0, stalled: 0, unknown: 0 });
});

test("★起動を名乗るだけの記録は終了ではない(async_launched を finished と読まない)", () => {
  // ★此の file の主柱。引き継ぎ文の「名乗られていたら終了」を実装すると、此処が
  //   finished になって赤くなる。走っている物を「終わった」と報告する向きの嘘。
  const w = world({
    parentLines: [launched("arun1")],
    agents: [{ id: "arun1", meta: { agentType: "general-purpose", description: "調査" }, mtimeMinAgo: 1 }],
  });
  const r = read(w);
  const a = byId(r, "arun1");
  assert.equal(a.state, "running", "async_launched を終了と読んでいる");
  assert.equal(a.reason, "no-result-active");
  assert.equal(a.display.state, "Working");
});

test("★親に何も無く、最近書いている子は running", () => {
  const w = world({
    parentLines: [],
    agents: [{ id: "amate1", meta: { agentType: "claude", description: "同僚" }, mtimeMinAgo: 2 }],
  });
  const r = read(w);
  assert.equal(byId(r, "amate1").state, "running");
});

test("★親に終了が無く、mtime が閾値より古い子は stalled(running に留めない)", () => {
  // 実測: 991 本中 485 本(49%)は親のどこにも出て来ない `in_process_teammate`。
  // 其の半分が「永遠に作業中」にならない事が、3値目が要る唯一の理由。
  const w = world({
    parentLines: [],
    agents: [{ id: "astale1", meta: { agentType: "claude", description: "落ちた同僚" }, mtimeMinAgo: 60 }],
  });
  const r = read(w);
  const a = byId(r, "astale1");
  assert.equal(a.state, "stalled");
  assert.equal(a.reason, "no-result-idle");
  // ★文面が「死んだ」と断定していない事(mtime は健康診断ではない)。
  assert.equal(a.display.state, "No sign of life recently");
});

test("★閾値の両側で答えが変わる(定数が本当に判定に効いている)", () => {
  const mk = (minAgo) => {
    const w = world({ agents: [{ id: "aedge", meta: { agentType: "x", description: "d" }, mtimeMinAgo: minAgo }] });
    return byId(read(w), "aedge").state;
  };
  const staleMin = SUBAGENT_STALE_MS / 60_000;
  assert.equal(mk(staleMin - 1), "running", "閾値の内側が running でない");
  assert.equal(mk(staleMin + 1), "stalled", "閾値の外側が stalled でない");
});

test("★`<task-notification>` の completed も終了として数える(背後起動の終わり方)", () => {
  const w = world({
    parentLines: [launched("aasync1"), notified("aasync1", "completed")],
    agents: [{ id: "aasync1", meta: { agentType: "planner", description: "背後" }, mtimeMinAgo: 5 }],
  });
  assert.equal(byId(read(w), "aasync1").state, "finished");
});

test("★completed 以外の task-notification は終了にしない", () => {
  const w = world({
    parentLines: [launched("aasync2"), notified("aasync2", "running")],
    agents: [{ id: "aasync2", meta: { agentType: "planner", description: "背後" }, mtimeMinAgo: 1 }],
  });
  assert.equal(byId(read(w), "aasync2").state, "running");
});

// ── 同時に2本(先頭だけ見る実装を落とす)────────────────────────────────────

test("★終了1本と作業中1本が同時に居る(先頭しか見ない判定なら落ちる)", () => {
  const w = world({
    parentLines: [completed("adone2")],
    agents: [
      // 並び順に依存しないよう、終了した方が**新しい** mtime を持つ配置にする。
      { id: "adone2", meta: { agentType: "planner", description: "終わった方" }, mtimeMinAgo: 1 },
      { id: "arun2", meta: { agentType: "claude", description: "走っている方" }, mtimeMinAgo: 3 },
    ],
  });
  const r = read(w);
  assert.equal(r.agents.length, 2);
  assert.equal(byId(r, "adone2").state, "finished");
  assert.equal(byId(r, "arun2").state, "running");
  // ★数で押さえる —— 片方の verdict を両方へ配る実装(全部 finished / 全部 running)は
  //   上の2行だけだと片方が緑のままになりうるが、此の1行では必ず落ちる。
  assert.deepEqual(r.counts, { finished: 1, running: 1, stalled: 0, unknown: 0 });
});

// ── 読めない物 ──────────────────────────────────────────────────────────────

test("★meta が壊れた JSON でも 1 本落とすだけで、一覧も生死も返る", () => {
  const w = world({
    parentLines: [],
    agents: [
      { id: "abroken", meta: "broken", mtimeMinAgo: 1 },
      { id: "aok", meta: { agentType: "planner", description: "無事" }, mtimeMinAgo: 1 },
    ],
  });
  const r = read(w);
  const bad = byId(r, "abroken");
  assert.equal(bad.meta, "malformed");
  assert.equal(bad.agentType, null, "壊れた meta から型を捏造している");
  assert.equal(bad.description, null);
  // ★肝: 壊れていても**居る事と生死は分かる**(dir と mtime は読めているので)。
  assert.equal(bad.state, "running");
  assert.equal(byId(r, "aok").agentType, "planner");
  assert.equal(r.agents.length, 2, "壊れた 1 本が一覧ごと落としている");
});

test("★meta が無いだけの子は absent(壊れているのとは別の答え)", () => {
  const w = world({ agents: [{ id: "anometa", meta: null, mtimeMinAgo: 1 }] });
  assert.equal(byId(read(w), "anometa").meta, "absent");
});

test("★subagents/ が無い = absent。空配列だが『読めなかった』とは名乗らない", () => {
  const w = world({ noDir: true });
  const r = read(w);
  assert.deepEqual(r.agents, []);
  assert.equal(r.directory, "absent");
  // ★`absent` の時だけ counts を出してよい —— 「本当に 0 本」を観測できているので。
  assert.deepEqual(r.counts, { finished: 0, running: 0, stalled: 0, unknown: 0 });
});

test("★親の転写が読めない時、生死は unknown(running にも finished にも倒さない)", () => {
  const w = world({
    parentLines: [completed("aorphan")],
    agents: [{ id: "aorphan", meta: { agentType: "planner", description: "親が読めない" }, mtimeMinAgo: 1 }],
  });
  // 親を消して「読めない」を作る。★子の dir はそのまま = 居る事は分かるが生死は分からない。
  rmSync(w.parent);
  const r = read(w);
  assert.equal(r.parent, "unreadable");
  assert.equal(r.agents.length, 1, "親が読めないと子まで消えている");
  const a = byId(r, "aorphan");
  assert.equal(a.state, "unknown", "親を読めていないのに生死を断定している");
  assert.equal(a.reason, "parent-unreadable");
  assert.equal(a.display.state, "Could not tell");
  // ★mtime が新しくても running と言わない。「終わったかどうかを知らない」が正しい答えで、
  //   `running` は「まだ終わっていない」という**知り得ない主張**になる。
  assert.deepEqual(r.counts, { finished: 0, running: 0, stalled: 0, unknown: 1 });
});

test("★親の走査予算の外に居る子は unknown(『見付からない』を『無い』と読まない)", () => {
  // 親の**先頭**に終了記録を置き、その後ろを新しい行で厚く埋める。末尾から予算ぶんだけ
  // 読むと終了記録に届かない = 「無い」と「読めていない」が見分けられない状態。
  const filler = [];
  for (let i = 0; i < 300; i += 1) {
    filler.push({ type: "assistant", timestamp: "2026-09-04T11:50:00.000Z", message: { role: "assistant", content: [{ type: "text", text: `padding-${i}` }] } });
  }
  const w = world({
    parentLines: [completed("afar"), ...filler],
    // 子の最終書き込み(11:30)は、読めた窓の一番古い行(11:50)より**古い** = 窓の外。
    agents: [{ id: "afar", meta: { agentType: "planner", description: "遠い" }, mtimeMinAgo: 30 }],
  });
  const r = read(w, { maxBytes: 4096, chunk: 1024 });
  const a = byId(r, "afar");
  // ★`stalled` になったら「終了記録は無い」と言い切った事になる —— 実際は在って、
  //   予算の外に居ただけ。見えなかった事を観測値として報告する形。
  assert.equal(a.state, "unknown", "読めていない範囲を『記録は無い』と読んでいる");
  assert.equal(a.reason, "scan-budget");

  // 対照: 同じ木を予算を絞らずに読めば、終了記録に届いて finished になる。
  // ★之が無いと、上の unknown が「予算に関係なく常に unknown」でも緑になる。
  assert.equal(byId(read(w), "afar").state, "finished");
});

test("★モデル名は子の転写から採る(meta には在ると限らない)", () => {
  const w = world({
    agents: [{ id: "amodel", meta: { agentType: "planner", description: "d" }, mtimeMinAgo: 1, model: "claude-sonnet-5" }],
  });
  assert.equal(byId(read(w), "amodel").model, "claude-sonnet-5");
});

test("★meta から読むのは agentType と description の2つだけ(他は当てにしない)", () => {
  // 実測 1082 本: 全件に在るのは此の2つだけ。`name` や `taskKind` は 402 本にしか無い。
  const w = world({
    agents: [{ id: "akeys", meta: { agentType: "planner", description: "説明", name: "n", taskKind: "k" }, mtimeMinAgo: 1 }],
  });
  const a = byId(read(w), "akeys");
  assert.equal(a.agentType, "planner");
  assert.equal(a.description, "説明");
  assert.equal(a.name, undefined, "在ると限らない鍵を線に載せている");
  assert.equal(a.taskKind, undefined);
});
