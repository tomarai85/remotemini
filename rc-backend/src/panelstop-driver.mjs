// agent panel で「この subagent を止める」を**机側で打つ** driver(2026-09-06、対照表 #8 の後半 c2)。
//
// 計画は `panelstop.mjs`(純関数)が立て、此処は其の計画を tmux に流す。打つ前に毎回、今の描画を撮って
// 計画へ戻る —— 「送った」を「効いた」と読まない(`choice()` と同じ型)。
//
// ── 打鍵の規則 ─────────────────────────────────────────────────────────────
//   1. 入口は SENDABLE で**入力欄が空**の時か、既に開いている PANEL だけ。CHOICE / 許可確認 / 文字の残った入力欄には
//      何も打たない(入力欄に文字が在ると `/tasks` が其の続きになり、Enter で親へ送られる。Codex r5 #1)。
//   2. `/tasks` は入力欄が**丁度** `/tasks` になったのを見てから Enter。開かなければ猶予をもう一度待ち、残った文字は
//      Backspace で取り消してから断る(遅い描画で `/tasks` が入力欄に残る。Codex r5 #5)。
//   3. 印の移動は 1 打ごとに撮り直し、印が動いたのを見てから次を打つ。動かなければ断る。
//   4. Enter は `verifySelection` が通った描画の直後だけ。詳細が開かなければ断る。
//   5. `x` は `planStop` が `press-x-in-detail` と言った詳細画面でだけ。打つ直前にもう一度撮り、**同じ詳細**が
//      映っている時だけ打つ(撮った後に agent が終わってパネルへ戻り、印がシェル行に居る隙間を狭める。Codex r5 #3。
//      入力状態と描画の隙間は TUI の外からは閉じられないので、シェル行が在る時は既定で断る = `allowShells`)。
//      押した後は「同じ詳細が消えた」(overlay が閉じた / パネルに戻って其の行が running でない)を待つ。詳細に
//      留まったまま(数字が進んだだけ)は成功ではない = `unverified`(Codex r5 #4)。
//   6. **Escape は overlay(PANEL / DETAIL)が見えている時にしか打たない**。詳細の Escape 1 回で overlay 全体が閉じ、
//      2 回目は親の会話への割り込みになる(測定 2026-09-06)。しかも描画は遅れるので、1 回打った後に閉じたのを
//      **見ていない**限り 2 回目は打たない(古い描画を根拠にしない。Codex r5 #2)。見えなければ `escape-unverified`。
//   7. 全体をペインの鍵の中で行う(電話の送信・割り込み・選択と直列)。鍵に入る前に pane と予算を検める(Codex r5 #6/#7)。
import { classifyScreen, panelStateOf, composerText, composerIsEmpty, emptyPanelIn } from "./inject.mjs";
import { parsePanel, parseDetail } from "./panelmodel.mjs";
import { planStop, planDirectDetail, verifySelection, sameShape, hasMaterial, rowDescription, rowMatches, STOP_REFUSAL, DEFAULT_MAX_MOVES } from "./panelstop.mjs";
import { ESC_SETTLE_MS } from "./choice.mjs";
import { MUTEX_BUSY, MUTEX_ABORTED } from "./mutex.mjs";

/** driver が足す断りの語彙(計画の 7 語に足して閉じる)。文は電話にそのまま出せる形。 */
export const DRIVER_REFUSAL = {
  "no-pane": "This conversation has no open pane on the desk, so nothing can be pressed.",
  "pane-busy": "The desk is busy with another action on this conversation. Nothing was pressed.",
  // ★2026-09-07 裁定(Codex: DON'T SHIP on flipping): シェル行が在るパネルでは押さない。`x` は id ではなく**今の焦点**に効くので、
  //   詳細を撮った後に agent が終わってパネルへ戻れば、印はシェル行に乗り、x はシェルを殺す —— 直前の再撮影も確率を下げるだけで
  //   閉じない。実セッションの 5.4% の Bash が背景で走る(8/120 セッション)ので、断りは「何が起きたか・どうすれば通るか」を言う。
  "shells-present": "A background shell is running under this conversation, and the desk will not press stop while a shell row is on the panel (a late redraw could kill the shell instead). Wait for the shell to finish, or stop it from the desk, then try again. Nothing was pressed.",
  "not-sendable": "The desk is not at an empty prompt (a menu, a permission prompt, another overlay, or text already typed), so the agent panel was not opened. Nothing was pressed.",
  "panel-did-not-open": "The desk did not show the agent panel after /tasks. Nothing else was pressed.",
  "detail-did-not-open": "The desk did not open the agent's detail view. The stop key was not pressed.",
  "unverified": "The stop key was pressed but the desk did not visibly stop the agent within the time budget. The result is unknown; it was not pressed again.",
  "escape-unverified": "An Escape was sent to close the panel, but the desk did not visibly close it within the time budget. Nothing else was pressed; check the desk.",
  "too-many-rounds": "The panel had to be reopened too many times to identify the agent. Nothing was pressed.",
};
export const STOP_REASONS = Object.freeze({ ...STOP_REFUSAL, ...DRIVER_REFUSAL });

/** 画面が動くのを待つ既定(パネルの開閉・詳細の開閉は 1 秒台で描かれる。8 桁の会話でも 2.5 秒で余る)。 */
export const PANEL_BUDGET_MS = 2500;
export const MAX_ROUNDS = 4;
const TASKS = "/tasks";

/**
 * 節が 1 つも無いパネル(最後の agent を止めた後の `Background` + footer だけの画面)。`panelStateOf` は節を要求するので
 * PANEL と読まないが、overlay としては開いたまま = Escape で閉じる対象で、行数 0 は「減った」の証拠でもある。
 */
/** 空パネル(節の無い `/tasks`)。本体は inject.mjs の `emptyPanelIn`(割り込みも同じ判定を使う、2026-09-07)。 */
const emptyPanel = (text) => emptyPanelIn(text);
const overlayKind = (text) => panelStateOf(text) || (emptyPanel(text) ? "PANEL-EMPTY" : null);
const isOverlay = (text) => overlayKind(text) !== null;
const hasShellRows = (panel) => (panel?.sections ?? []).some((s) => /^Shells\b/.test(String(s?.name ?? "")) && Array.isArray(s.rows) && s.rows.length > 0);
const shellRowTexts = (panel) => (panel?.sections ?? []).filter((s) => /^Shells\b/.test(String(s?.name ?? ""))).flatMap((s) => (Array.isArray(s.rows) ? s.rows : []))
  .map((r) => String(r?.text ?? "").trim().slice(0, 160)).slice(0, 8);
/** 同じ詳細か: 型・説明文に加えて prompt の冒頭と道具列も(型と説明文だけでは同名の隣と見分けられない。Codex c3 #4)。 */
const sameDetail = (a, b) => Boolean(a && b && a.agentType === b.agentType && a.description === b.description
  && String(a.promptPrefix ?? "") === String(b.promptPrefix ?? "") && JSON.stringify(a.recentTools ?? []) === JSON.stringify(b.recentTools ?? []));

/**
 * 目標の subagent を止める。戻りは常に閉じた形:
 *   `{ ok:true,  stopped:"observed", reason:null, sent:true, keys, escapes, target, after }`   x を押し、同じ詳細が消えた
 *   `{ ok:false, stopped:false, reason:<STOP_REASONS の鍵>, message, sent:boolean, keys, escapes, why?, after? }`
 *   `sent:true` は `x` を打った後の断り(= `unverified`)。打っていない断りは `sent:false`。
 * `target` は `panelstop.mjs` の `planStop` と同じ形(description / promptPrefix / recentTools / agentType /
 * live / liveSameDescription)。`allowShells` = パネルにシェル行が在っても進む(既定は断る)。
 */
export async function stopSubagent(inj, pane, target, opts = {}) {
  const o = opts && typeof opts === "object" ? opts : {};
  const maxMoves = Number.isInteger(o.maxMoves) && o.maxMoves >= 0 ? o.maxMoves : DEFAULT_MAX_MOVES;
  const maxRounds = Number.isInteger(o.maxRounds) && o.maxRounds >= 1 ? o.maxRounds : MAX_ROUNDS;
  const budgetMs = Number.isFinite(o.budgetMs) && o.budgetMs >= 0 ? o.budgetMs : PANEL_BUDGET_MS;
  const allowShells = o.allowShells === true;
  if (typeof pane !== "string" || !pane.trim()) return refusal("no-pane", {});
  // 画面を触る前に断れる物は断る(机を乱さない)。
  if (!target || typeof target.description !== "string" || !target.description || target.live !== true) {
    return refusal("no-such-row", { why: "not-live" });
  }
  if (!hasMaterial(target) || !Number.isInteger(target.liveSameDescription) || target.liveSameDescription < 1) {
    return refusal("ambiguous", { why: "insufficient" });
  }
  if (!inj || typeof inj.capture !== "function" || !inj.mutex || typeof inj.mutex.run !== "function") return refusal("no-pane", { why: "no-injector" });
  try {
    return await inj.mutex.run(pane, () => drive(inj, pane, target, { maxMoves, maxRounds, budgetMs, allowShells }), { signal: o.signal });
  } catch (e) {
    if (e?.code === MUTEX_BUSY || e?.code === MUTEX_ABORTED) return refusal("pane-busy", {});
    if (typeof e?.code === "string" && /^MUTEX_/.test(e.code)) return refusal("pane-busy", { why: e.code });   // 鍵の他の失敗(鍵が空 等)
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
async function drive(inj, pane, target, { maxMoves, maxRounds, budgetMs, allowShells }) {
  const keys = [];
  let escapes = 0;
  let escapeUnobserved = false;   // 1 回打って、閉じたのをまだ見ていない
  const cap = () => inj.capture(pane);
  const press = (k) => { keys.push(k); inj.tmux.run(["send-keys", "-t", pane, k]); };
  const type = (t) => { keys.push(`-l ${t}`); inj.tmux.run(["send-keys", "-t", pane, "-l", "--", t]); };
  const poll = (decide) => inj.pollScreen(pane, decide, { budgetMs });
  const composerOf = (x) => String(composerText(x) ?? "");

  /** overlay が見えている時だけ Escape を 1 回。閉じたのを見ていない Escape が在れば、二度目は打たない。 */
  const closeOverlay = async () => {
    const t = cap();
    if (!isOverlay(t)) { escapeUnobserved = false; return { pressed: false, closed: true, state: classifyScreen(t).state }; }
    if (escapeUnobserved) return { pressed: false, closed: false, uncertain: true, state: classifyScreen(t).state };
    press("Escape");
    escapes += 1;
    escapeUnobserved = true;
    await inj.sleep(ESC_SETTLE_MS);
    const r = await poll((x) => (isOverlay(x) ? null : "closed"));
    if (r.tag) escapeUnobserved = false;
    return { pressed: true, closed: Boolean(r.tag), uncertain: !r.tag, state: classifyScreen(r.text).state };
  };
  /** 断る時は overlay を閉じてから返す。閉じたのを見ていなければ其れ自体を理由にする。 */
  const bail = async (reason, extra = {}) => {
    const c = await closeOverlay();
    if (c.uncertain) return refusal("escape-unverified", { why: reason, keys, escapes, sent: extra.sent === true, after: { screen: c.state, overlayClosed: false } });
    // ★`extra.after` は `after` に**畳む**(上書きしない)。断りの根拠(例: 見えたシェル行)を診断欄に残す為。
    const { after: more = {}, ...rest } = extra;
    return refusal(reason, { ...rest, keys, escapes, after: { screen: c.state, overlayClosed: c.closed, ...more } });
  };
  /** 一致した詳細で x を押し、**パネルで**目標の running 行が減ったのを見る。`before` = 押す前の本数、`isTarget` = 数える行の条件。 */
  const countRunning = (p, isTarget) => (p?.sections ?? []).filter((s) => !/^Shells\b/.test(s.name)).reduce((n, s) => n + s.rows.filter((r) => isTarget(r) && / \(running\)/.test(r.text)).length, 0);
  const pressX = async ({ detail, before, isTarget, planTarget }) => {
    {
      // 打つ直前にもう一度撮る。同じ詳細が映っていなければ打たない(撮った後に終わってパネルへ戻った隙間)。
      const fresh = cap();
      if (panelStateOf(fresh) !== "DETAIL" || !sameDetail(parseDetail(fresh), detail)) return bail("reflow", { why: "detail-changed-before-x" });
      type("x");
      // 成功 = **パネルで**目標と同じ文字列の running 行が 1 本減ったのを見た(同名の双子が居る時は「行が無い」では判れない
      // ので数で見る)。x でパネルに戻ればその場で数え、overlay が閉じたなら /tasks を開き直して数える(「閉じた」だけでは
      // 対象に結び付かない。Codex c3 #5)。同じ詳細に留まったまま(数字が進んだだけ)/ 入力欄以外の画面(許可確認 等)に
      // 落ちたなら `unverified`。
      const runningSame = (p) => countRunning(p, isTarget);
      const decreased = (x) => {
        if (emptyPanel(x)) return before > 0 ? "panel" : null;          // 行が 1 本も残らないパネル(最後の agent を止めた)
        const p = parsePanel(x); return p && runningSame(p) < before ? "panel" : null;
      };
      const moved = (x) => {
        const st = overlayKind(x);
        if (st === "PANEL" || st === "PANEL-EMPTY") return decreased(x);
        if (st === "DETAIL") return null;
        return classifyScreen(x).state === "SENDABLE" ? "closed" : null;
      };
      let after = await poll(moved);
      let stopObserved = after.tag === "panel" ? "panel" : null;
      if (after.tag === "closed") {
        // overlay が閉じた = 数えていない。開き直して数える(入力欄が空でなければ開かない = `not-sendable` ではなく unverified)。
        const t = cap();
        const sc = classifyScreen(t);
        // ★開き直す前も同じ veto: spinner が見えている入力欄には打たない(Codex 2026-09-07 direct-detail #3)。
        if (sc.state === "SENDABLE" && sc.activity !== "observed" && composerIsEmpty(t)) {
          type(TASKS);
          const echo = await poll((x) => (composerOf(x) === TASKS ? "echo" : null));
          if (echo.tag) {
            press("Enter");
            const r = await poll((x) => { const k = overlayKind(x); return k === "PANEL" || k === "PANEL-EMPTY" ? "panel" : null; });
            if (r.tag) {
              const conf = await poll(decreased);
              if (conf.tag) stopObserved = "reopened";
            } else {
              await retract();
            }
          } else {
            await retract();
          }
        }
      }
      if (!stopObserved) {
        const c = await closeOverlay();
        return refusal(c.uncertain ? "escape-unverified" : "unverified", { sent: true, why: c.uncertain ? "unverified" : (after.tag ?? "no-change"), keys, escapes, after: { screen: c.state, overlayClosed: c.closed } });
      }
      const c = await closeOverlay();
      if (c.uncertain) return refusal("escape-unverified", { sent: true, why: "after-x", keys, escapes, after: { screen: c.state, overlayClosed: false, stopObserved } });
      return { ok: true, stopped: "observed", reason: null, message: null, sent: true, keys, escapes, target: planTarget,
               after: { screen: c.state, overlayClosed: c.closed, stopObserved } };
    }
  };
  /** 入力欄に `/tasks` が残っていれば Backspace で消す(入力欄が丁度 `/tasks` の時だけ)。 */
  const retract = async () => {
    const t = cap();
    if (composerOf(t) !== TASKS) return { retracted: false, leftover: composerOf(t) };
    for (let i = 0; i < TASKS.length; i++) press("BSpace");
    const r = await poll((x) => (composerIsEmpty(x) ? "empty" : null));
    return { retracted: Boolean(r.tag), leftover: r.tag ? "" : composerOf(r.text) };
  };

  /** パネルを出す。既に開いていれば其れを使う。詳細が開いていれば(誰かが開いた)1 回閉じてから。 */
  const openPanel = async () => {
    let t = cap();
    let st = panelStateOf(t);
    if (st === "DETAIL") {
      const c = await closeOverlay();
      if (!c.closed) return { refusal: refusal(c.uncertain ? "escape-unverified" : "not-sendable", { why: "detail-stuck", keys, escapes, after: { screen: c.state } }) };
      t = cap(); st = panelStateOf(t);
    }
    if (st === "PANEL") return { panel: parsePanel(t), opened: false };
    const s = classifyScreen(t);
    if (s.state !== "SENDABLE") return { refusal: refusal("not-sendable", { why: s.state, keys, escapes, after: { screen: s.state } }) };
    // ★親が生成中(spinner が見えている)なら打たない。state は SENDABLE のままなので activity で見る。run3(2026-09-07 09:27)は
    //   親の手番の終わり際に /tasks を打ち、文字が消えて `panel-did-not-open` になった —— 生成中の入力欄に打った文字は
    //   TUI が queue として扱う(送信の経路と同じ判断: 生成中は打たない)。
    if (s.activity === "observed") return { refusal: refusal("not-sendable", { why: "in-flight", keys, escapes, after: { screen: s.state, activityFrom: s.activityFrom ?? null } }) };
    if (!composerIsEmpty(t)) return { refusal: refusal("not-sendable", { why: "composer-not-empty", keys, escapes, after: { screen: s.state, composer: composerOf(t).slice(0, 80) } }) };
    type(TASKS);
    let echo = await poll((x) => (composerOf(x) === TASKS ? "echo" : null));
    if (!echo.tag) echo = await poll((x) => (composerOf(x) === TASKS ? "echo" : null));   // 遅い描画の猶予をもう一度
    if (!echo.tag) {
      const r = await retract();
      return { refusal: refusal("panel-did-not-open", { why: "no-echo", keys, escapes, after: { screen: classifyScreen(cap()).state, retracted: r.retracted, leftover: r.leftover } }) };
    }
    press("Enter");
    const kindOf = (x) => { const k = overlayKind(x); return k === "PANEL" ? "panel" : k === "DETAIL" ? "detail" : k === "PANEL-EMPTY" ? "empty" : null; };
    let r = await poll(kindOf);
    if (!r.tag) r = await poll(kindOf);   // 猶予をもう一度
    if (!r.tag) {
      const rt = await retract();
      return { refusal: refusal("panel-did-not-open", { why: "no-panel", keys, escapes, after: { screen: classifyScreen(cap()).state, overlay: panelStateOf(cap()), retracted: rt.retracted, leftover: rt.leftover } }) };
    }
    // ★task が 1 本だけの時、/tasks は一覧を**飛ばして其の詳細に直行する**(実機 friday 2.1.263、2026-09-07 に 3/3 再現。
    //   `.harness/evidence-2026-09-07/repro-shell-kill-screens.log`、fixture `friday-detail-direct.txt`)。一覧は無いが詳細は
    //   在るので、照合して押す道へ(planDirectDetail)。★task が 0 本なら「No tasks currently running」の空パネル = 目標は
    //   もう居ない。どちらも**開いた overlay は閉じてから**返す(以前は `panel-did-not-open` で断り、開けた詳細を残していた)。
    if (r.tag === "detail") return { detail: parseDetail(r.text), opened: true };
    if (r.tag === "empty") return { refusal: await bail("no-such-row", { why: "panel-empty" }) };
    return { panel: parsePanel(r.text), opened: true };
  };

  const examined = [];
  let shape = null;
  for (let round = 0; round < maxRounds; round++) {
    const op = await openPanel();
    if (op.refusal) return op.refusal;
    if (op.detail) {
      // 一覧を飛ばして詳細に直行した = パネルの task は此の 1 本。計画は planDirectDetail、押す条件は同じ(厳密な一致だけ)。
      // 数える相手は「説明文が目標で running の行」(一覧を見ていないので行の本文全体は知らない)。
      const plan1 = planDirectDetail({ detail: op.detail, target });
      if (!plan1.ok) return bail(plan1.reason, { why: plan1.why ?? null });
      const isTarget = (r) => rowMatches(r.text, target.description) && / \(running\)/.test(r.text);
      return pressX({ detail: op.detail, before: 1, isTarget, planTarget: plan1.target });
    }
    let panel = op.panel;
    if (shape && !sameShape(shape, panel)) return bail("reflow", { why: "reopened-panel-differs" });
    shape = panel;
    // ★断りの根拠をそのまま載せる: パネルに見えたシェル行の本文(最大 8 行・各 160 字)。live 計器は此処に自分の nonce を探し、
    //   「TUI が**此の**シェルの行を出していた」を机の言葉でなく行の本文で確かめる(Codex 2026-09-07 #3/#5)。
    if (!allowShells && hasShellRows(panel)) return bail("shells-present", { after: { shells: shellRowTexts(panel) } });
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
      const targetText = plan2.target?.text ?? null;
      const isTarget = (r) => r.text === targetText;
      return pressX({ detail, before: countRunning(panel, isTarget), isTarget, planTarget: plan2.target });
    }
    if (plan2.action === "close-detail") {
      examined.push({ flat: plan2.target.flat, detail });
      const c = await closeOverlay();
      if (!c.closed) return refusal(c.uncertain ? "escape-unverified" : "reflow", { why: "overlay-stuck", keys, escapes, after: { screen: c.state } });
      continue;
    }
    return bail("reflow", { why: `unexpected-plan:${plan2.action}` });
  }
  return bail("too-many-rounds", {});
}

export { rowDescription, emptyPanel };
