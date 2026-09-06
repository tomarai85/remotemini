// agent panel で「この subagent を止める」を**机側で打つ** driver(2026-09-06、対照表 #8 の後半 c2)。
//
// 計画は `panelstop.mjs`(純関数)が立て、此処は其の計画を tmux に流す。打つ前に毎回、今の描画を撮って
// 計画へ戻る —— 「送った」を「効いた」と読まない(`choice()` と同じ型)。
//
// ── 打鍵の規則 ─────────────────────────────────────────────────────────────
//   1. 入口は SENDABLE(入力欄が見えている)か、既に開いている PANEL だけ。CHOICE / 許可確認 / 不明な画面には何も打たない。
//   2. `/tasks` は入力欄に文字が映ったのを見てから Enter。パネルが開かなければ其処で断る(Enter を二度打たない)。
//   3. 印の移動は 1 打ごとに撮り直し、印が動いたのを見てから次を打つ。動かなければ断る。
//   4. Enter は `verifySelection` が通った描画の直後だけ。詳細が開かなければ断る。
//   5. `x` は `planStop` が `press-x-in-detail` と言った詳細画面でだけ。押した後は画面が動くのを待ち、動かなければ
//      `unverified`(結果不明。届いていないではない。撃ち直さない)。
//   6. **Escape は overlay(PANEL / DETAIL)が見えている時にしか打たない**。詳細の Escape 1 回で overlay 全体が閉じ、
//      2 回目は親の会話への割り込みになる(測定 2026-09-06)。打つ前に必ず撮って overlay を確かめ、回数を数えて返す。
//   7. 全体をペインの鍵の中で行う(電話の送信・割り込み・選択と直列)。
import { classifyScreen, panelStateOf, composerText } from "./inject.mjs";
import { parsePanel, parseDetail } from "./panelmodel.mjs";
import { planStop, verifySelection, sameShape, hasMaterial, STOP_REFUSAL, DEFAULT_MAX_MOVES } from "./panelstop.mjs";
import { ESC_SETTLE_MS } from "./choice.mjs";
import { MUTEX_BUSY, MUTEX_ABORTED } from "./mutex.mjs";

/** driver が足す断りの語彙(計画の 7 語に足して閉じる)。文は電話にそのまま出せる形。 */
export const DRIVER_REFUSAL = {
  "pane-busy": "The desk is busy with another action on this conversation. Nothing was pressed.",
  "not-sendable": "The desk is not at its prompt (a menu, a permission prompt, or another overlay is up), so the agent panel was not opened. Nothing was pressed.",
  "panel-did-not-open": "The desk did not show the agent panel after /tasks. Nothing else was pressed.",
  "detail-did-not-open": "The desk did not open the agent's detail view. The stop key was not pressed.",
  "unverified": "The stop key was pressed but the desk did not visibly change within the time budget. The result is unknown; it was not pressed again.",
  "too-many-rounds": "The panel had to be reopened too many times to identify the agent. Nothing was pressed.",
};
export const STOP_REASONS = Object.freeze({ ...STOP_REFUSAL, ...DRIVER_REFUSAL });

/** 画面が動くのを待つ既定(パネルの開閉・詳細の開閉は 1 秒台で描かれる。8 桁の会話でも 2.5 秒で余る)。 */
export const PANEL_BUDGET_MS = 2500;
export const MAX_ROUNDS = 4;

const isOverlay = (text) => { const s = panelStateOf(text); return s === "PANEL" || s === "DETAIL"; };

/**
 * 目標の subagent を止める。戻りは常に閉じた形:
 *   `{ ok:true,  stopped:"observed", reason:null, keys, escapes, after }`   x を押し、画面が動いた
 *   `{ ok:false, stopped:false, reason:<STOP_REASONS の鍵>, message, sent:boolean, keys, escapes, why?, after? }`
 *   `sent:true` は `x` を打った後の断り(= `unverified`)。打っていない断りは `sent:false`。
 * `target` は `panelstop.mjs` の `planStop` と同じ形(description / promptPrefix / recentTools / agentType /
 * live / liveSameDescription)。
 */
export async function stopSubagent(inj, pane, target, { signal, maxMoves = DEFAULT_MAX_MOVES, maxRounds = MAX_ROUNDS, budgetMs = PANEL_BUDGET_MS } = {}) {
  // 画面を触る前に断れる物は断る(机を乱さない)。
  if (!target || typeof target.description !== "string" || !target.description || target.live !== true) {
    return refusal("no-such-row", { why: "not-live", keys: [], escapes: 0 });
  }
  if (!hasMaterial(target) || !Number.isInteger(target.liveSameDescription) || target.liveSameDescription < 1) {
    return refusal("ambiguous", { why: "insufficient", keys: [], escapes: 0 });
  }
  try {
    return await inj.mutex.run(pane, () => drive(inj, pane, target, { maxMoves, maxRounds, budgetMs }), { signal });
  } catch (e) {
    if (e?.code === MUTEX_BUSY || e?.code === MUTEX_ABORTED) return refusal("pane-busy", { keys: [], escapes: 0 });
    throw e;
  }
}

function refusal(reason, { why = null, keys = [], escapes = 0, sent = false, after = null } = {}) {
  const out = { ok: false, stopped: false, reason, message: STOP_REASONS[reason], sent, keys, escapes };
  if (why) out.why = why;
  if (after) out.after = after;
  return out;
}

/** 鍵の中でだけ走る本体。**直接呼ばない**。 */
async function drive(inj, pane, target, { maxMoves, maxRounds, budgetMs }) {
  const keys = [];
  let escapes = 0;
  const cap = () => inj.capture(pane);
  const press = (k) => { keys.push(k); inj.tmux.run(["send-keys", "-t", pane, k]); };
  const type = (t) => { keys.push(`-l ${t}`); inj.tmux.run(["send-keys", "-t", pane, "-l", "--", t]); };
  const poll = (decide) => inj.pollScreen(pane, decide, { budgetMs });

  /** overlay が見えている時だけ Escape を 1 回。閉じたかを撮って返す。 */
  const closeOverlay = async () => {
    const t = cap();
    if (!isOverlay(t)) return { pressed: false, closed: true, state: classifyScreen(t).state };
    press("Escape");
    escapes += 1;
    await inj.sleep(ESC_SETTLE_MS);
    const r = await poll((x) => (isOverlay(x) ? null : "closed"));
    return { pressed: true, closed: Boolean(r.tag), state: classifyScreen(r.text).state };
  };
  const bail = async (reason, extra = {}) => {
    const c = await closeOverlay();
    return refusal(reason, { ...extra, keys, escapes, after: { screen: c.state, overlayClosed: c.closed } });
  };

  /** パネルを出す。既に開いていれば其れを使う。詳細が開いていれば(誰かが開いた)1 回閉じてから。 */
  const openPanel = async () => {
    let t = cap();
    let st = panelStateOf(t);
    if (st === "DETAIL") { const c = await closeOverlay(); if (!c.closed) return { refusal: await bail("not-sendable", { why: "detail-stuck" }) }; t = cap(); st = panelStateOf(t); }
    if (st === "PANEL") return { panel: parsePanel(t), opened: false };
    const s = classifyScreen(t);
    if (s.state !== "SENDABLE") return { refusal: refusal("not-sendable", { why: s.state, keys, escapes, after: { screen: s.state } }) };
    type("/tasks");
    const echo = await poll((x) => (String(composerText(x) ?? "").includes("/tasks") ? "echo" : null));
    if (!echo.tag) return { refusal: refusal("panel-did-not-open", { why: "no-echo", keys, escapes, after: { screen: classifyScreen(echo.text).state } }) };
    press("Enter");
    const r = await poll((x) => (panelStateOf(x) === "PANEL" ? "panel" : null));
    if (!r.tag) return { refusal: refusal("panel-did-not-open", { why: "no-panel", keys, escapes, after: { screen: classifyScreen(r.text).state, overlay: panelStateOf(r.text) } }) };
    return { panel: parsePanel(r.text), opened: true };
  };

  const examined = [];
  let shape = null;
  for (let round = 0; round < maxRounds; round++) {
    const op = await openPanel();
    if (op.refusal) return op.refusal;
    let panel = op.panel;
    if (shape && !sameShape(shape, panel)) return bail("reflow", { why: "reopened-panel-differs" });
    shape = panel;
    const plan = planStop({ panel, target, maxMoves, examined });
    if (!plan.ok) return bail(plan.reason, { why: plan.why ?? null });
    if (plan.action !== "open-detail") return bail("reflow", { why: `unexpected-plan:${plan.action}` });

    // 印を動かす。1 打ごとに「印が動いた」を見る。
    for (let i = 0; i < plan.moves; i++) {
      const before = parsePanel(cap());
      const from = before?.selected ? `${before.selected.section}#${before.selected.index}` : null;
      press(plan.direction === "up" ? "Up" : "Down");
      const r = await poll((x) => { const p = parsePanel(x); const now = p?.selected ? `${p.selected.section}#${p.selected.index}` : null; return p && now && now !== from ? "moved" : null; });
      if (!r.tag) return bail("reflow", { why: "move-not-observed" });
    }
    panel = parsePanel(cap());
    if (!panel) return bail("reflow", { why: "panel-gone" });
    const v = verifySelection(panel, plan.target);
    if (!v.ok) return bail(v.reason, { why: "before-enter" });

    press("Enter");
    const d = await poll((x) => (panelStateOf(x) === "DETAIL" ? "detail" : null));
    if (!d.tag) return bail("detail-did-not-open", {});
    const detail = parseDetail(d.text);
    const plan2 = planStop({ panel, detail, target, maxMoves, examined });
    if (!plan2.ok) return bail(plan2.reason, { why: plan2.why ?? null });

    if (plan2.action === "press-x-in-detail") {
      type("x");
      const after = await poll((x) => (x !== d.text ? "changed" : null));
      if (!after.tag) {
        const c = await closeOverlay();
        return refusal("unverified", { sent: true, keys, escapes, after: { screen: c.state, overlayClosed: c.closed } });
      }
      const c = await closeOverlay();
      return { ok: true, stopped: "observed", reason: null, message: null, sent: true, keys, escapes, target: plan2.target,
               after: { screen: c.state, overlayClosed: c.closed, overlayAfterX: panelStateOf(after.text) } };
    }
    if (plan2.action === "close-detail") {
      examined.push({ flat: plan2.target.flat, detail });
      const c = await closeOverlay();
      if (!c.closed) return refusal("reflow", { why: "overlay-stuck", keys, escapes, after: { screen: c.state } });
      continue;
    }
    return bail("reflow", { why: `unexpected-plan:${plan2.action}` });
  }
  return bail("too-many-rounds", {});
}
