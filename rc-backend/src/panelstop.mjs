// agent panel で「この subagent を止める」の**計画**を立てる純関数(2026-09-06、対照表 #8 の後半 c1)。
//
// ── 決める事、決めない事 ─────────────────────────────────────────────────────
// 決める: 目標の subagent(机の転写 `agent-<id>.jsonl` から分かる型・説明文・prompt・道具列と、机が知る生死)に
//   対して、今の panel(`parsePanel`)と、開いていれば詳細(`parseDetail`)と、既に見た詳細(`examined`)を見て、
//     ・次に何をするか(詳細を開く / 其の詳細で x を押す / 詳細を閉じて続ける)
//     ・印を何段動かすか(有界。超えたら断る)
//   を返す。断る理由は閉じた語彙(`STOP_REFUSAL`)。
// 決めない: 打鍵。1 打も打たない。打つのは driver(c2)で、driver は**打つ前に毎回**此処へ戻って来る。
//
// ── 規則の出典 ─────────────────────────────────────────────────────────────
// 設計文(2026-09-04): 押す直前の描画で印が目標の名前の行に乗っている時だけ / 断りは再試行ではない /
//   有界の移動 / 同名は曖昧 / 名前が消えたら reflow(終わった疑い)。
// 測定(2026-09-06): 行は `<説明文> (<状態>) · <model>` で id を描かない。同じ説明文の 2 本は byte 同一。
//   詳細画面(Enter)は型・説明・数・直近の道具・prompt の冒頭を出す = 説明文が同じでも prompt か道具が違えば
//   見分けられる。全部同じなら「曖昧」が正解。シェルの節の行に印が乗り得る(x はシェルを殺す)。
//   詳細画面の footer にも `x to stop` が在る = **押すのは常に詳細画面から**。
//   prompt は幅に関係なく **297 字 + `…`** で切られる(Jervis 120 桁と friday 80 桁の fixture が共に 298 字)。
// Codex 敵対レビュー 3 回(2026-09-06、計 20 所見、全部取り込み)。要点:
//   (1) 画面だけでは「完全に同一な双子の片方が先に終わった後」を見分けられない → 机が知る生死を入力に要求する
//       (`target.live` と `target.liveSameDescription`)。無ければ断る。
//   (2) 切れていない prompt は丸ごと一致。`…` で終わる prompt は、見えている長さが UI の切り所(`TRUNC_MIN`)より
//       短ければ**本物の `…`** と読み(丸ごと一致だけ)、長ければ UI の省略と読んで先頭一致。
//   (3) 空白は折り返し(改行)だけ畳む。行の中の連続空白、先頭・末尾の空白は意味を持つので残す。
//   (4) 目標が持つ材料は**全部**詳細側にも要る。片方が画面外なら比較できない(insufficient)。
//   (5) 直前確認は平らな位置 + 節 + 節内の位置 + 文字列の四つ、全部必須。印が 2 つ以上 / 無い描画は reflow。
//   (6) 説明文の境界は「最後の ` (<状態>)`」で切る(説明文自身が括弧を含み得る)。
import { duplicateRows } from "./panelmodel.mjs";

/** 断りの語彙(閉じている)。文は電話にそのまま出せる形。 */
export const STOP_REFUSAL = {
  "not-a-panel": "The agent panel is not open on the desk, so no agent can be selected. Nothing was pressed.",
  "shell-row": "The selection is on a background shell, not an agent. Nothing was pressed.",
  "no-such-row": "No running agent on the desk's panel matches that description. It may have finished. Nothing was pressed.",
  "ambiguous": "More than one running agent has this exact description and nothing on the desk tells them apart. Nothing was pressed.",
  "too-far": "The target is too many rows away to reach safely. Nothing was pressed.",
  "mismatch": "The agent shown on the desk does not match the one you chose. Nothing was pressed.",
  "reflow": "The panel changed while it was being read (an agent finished or the list moved). Nothing was pressed.",
};

/** UI が prompt を切る長さ(実測 297 字 + `…`)より短い所で `…` が出たら、其れは本物の `…`(切られていない)。 */
export const TRUNC_MIN = 250;
/** `…` で切れた道具の行を証拠と認める最短の長さ(短い接頭辞は別物同士でも一致する)。 */
export const MIN_TOOL_PREFIX = 12;
export const DEFAULT_MAX_MOVES = 8;

/** panel の全行を表示順に平らにする(印は節を跨いで動くので、移動の数は平らな並びで数える)。壊れた入力は空。 */
export function flatRows(panel) {
  const out = [];
  for (const s of Array.isArray(panel?.sections) ? panel.sections : []) {
    if (!s || !Array.isArray(s.rows)) continue;
    s.rows.forEach((r, i) => out.push({ section: String(s.name ?? ""), index: i, text: String(r?.text ?? ""), selected: r?.selected === true }));
  }
  return out;
}

const isShell = (section) => /^Shells\b/.test(section);
/** 折り返し(改行 + 前後の空白)だけを 1 つの空白に畳む。先頭の空行と末尾の改行は落とす。行の中の空白は残す。 */
const foldLines = (s) => String(s).replace(/^\s*\n/, "").replace(/\n\s*$/, "").replace(/[ \t]*\n[ \t]*/g, " ");
const hasOverflow = (panel) => Array.isArray(panel?.hints) && panel.hints.some((h) => /↓ \d+ more/.test(String(h)));
/** 印(選択)の平らな位置。0 本でも 2 本以上でも -1(壊れた描画 = reflow として扱う)。 */
function selectedFlatOf(rows) {
  const sel = rows.map((r, i) => (r.selected ? i : -1)).filter((i) => i >= 0);
  return sel.length === 1 ? sel[0] : -1;
}

/**
 * 行の文字列から説明文を取り出す(`<説明文> (<状態>)` か `<説明文> (<状態>) · <model>`)。境界は**最後の** ` (<状態>)`
 * (説明文自身が `deploy (backup)` の様に括弧を含み得る。Codex 所見)。形が違えば null。
 */
export function rowDescription(text) {
  if (typeof text !== "string") return null;
  const m = /^(.*) \(([a-z][a-z -]*)\)(?: · ([^()]+))?$/.exec(text);
  return m ? m[1] : null;
}

/** 行の文字列が目標の説明文の行か。 */
export function rowMatches(text, description) {
  if (typeof description !== "string" || !description) return false;
  return rowDescription(text) === description;
}

/** 目標に、同名の行を見分ける材料(prompt か道具列)が在るか。無ければ何も照合できない。 */
export function hasMaterial(target) {
  return Boolean(target && ((typeof target.promptPrefix === "string" && target.promptPrefix.trim()) || (Array.isArray(target.recentTools) && target.recentTools.length > 0)));
}

/**
 * 詳細画面が目標と一致するか。**同じ説明文の 2 本を見分ける唯一の材料**なので、目標が持つ材料は全部照合する。
 *  - 説明文と型が違えば mismatch。
 *  - 目標が持つ材料(prompt / 道具列)が詳細側に無ければ比較できない = `insufficient`(mismatch ではない)。
 *  - prompt: `…` で終わっていなければ**丸ごと**一致。`…` で終わっていて、見えている長さが `TRUNC_MIN` 未満なら
 *    UI は切っていない = 本物の `…` なので丸ごと一致だけ(目標が其の先頭と同じなら `insufficient`)。`TRUNC_MIN`
 *    以上なら UI の省略なので、目標が其の長さに収まる筈なら丸ごと、収まらないなら先頭一致。
 *  - 道具: 詳細の直近の道具が目標の道具列の**末尾**と一致。行が `…` で切れていれば前方一致(`MIN_TOOL_PREFIX`)。
 */
export function detailMatches(detail, target) {
  if (!detail || !target) return { ok: false, why: "no-detail" };
  if (target.agentType && detail.agentType && detail.agentType !== target.agentType) return { ok: false, why: "agentType" };
  if (target.description && detail.description !== target.description) return { ok: false, why: "description" };
  const wantP = typeof target.promptPrefix === "string" && target.promptPrefix.trim().length > 0;
  const wantT = Array.isArray(target.recentTools) && target.recentTools.length > 0;
  if (!wantP && !wantT) return { ok: false, why: "insufficient" };
  const haveP = typeof detail.promptPrefix === "string" && detail.promptPrefix.trim().length > 0;
  const haveT = Array.isArray(detail.recentTools) && detail.recentTools.length > 0;
  if ((wantP && !haveP) || (wantT && !haveT)) return { ok: false, why: "insufficient" };
  if (wantP) {
    const shownRaw = foldLines(detail.promptPrefix);
    const want = foldLines(target.promptPrefix);
    if (want !== shownRaw) {
      if (!shownRaw.endsWith("…")) return { ok: false, why: "prompt" };
      const shown = shownRaw.slice(0, -1);
      if (shown.length < TRUNC_MIN) return { ok: false, why: want.startsWith(shown) ? "insufficient" : "prompt" };  // 本物の `…`
      if (want.length <= shown.length) return { ok: false, why: "prompt" };          // 収まる筈なのに違う
      if (!want.startsWith(shown)) return { ok: false, why: "prompt" };
    }
  }
  if (wantT) {
    const tail = target.recentTools.slice(-detail.recentTools.length);
    if (tail.length !== detail.recentTools.length) return { ok: false, why: "tools" };
    for (let i = 0; i < tail.length; i++) {
      const shown = detail.recentTools[i], want = tail[i];
      if (typeof shown !== "string" || typeof want !== "string") return { ok: false, why: "tools" };
      if (shown === want) continue;
      if (!shown.endsWith("…")) return { ok: false, why: "tools" };
      const head = shown.slice(0, -1);
      if (head.length < MIN_TOOL_PREFIX) return { ok: false, why: "insufficient" };
      if (!want.startsWith(head)) return { ok: false, why: "tools" };
    }
  }
  return { ok: true, why: null };
}

const at = (rows, flat) => (Number.isInteger(flat) && flat >= 0 && flat < rows.length ? { flat, section: rows[flat].section, index: rows[flat].index, text: rows[flat].text } : null);

function moveTo(rows, selectedFlat, flat, maxMoves) {
  const max = Number.isInteger(maxMoves) && maxMoves >= 0 ? maxMoves : DEFAULT_MAX_MOVES;
  const delta = selectedFlat >= 0 ? flat - selectedFlat : flat;
  if (Math.abs(delta) > max) return { ok: false, reason: "too-far", moves: delta };
  return { ok: true, moves: Math.abs(delta), direction: delta >= 0 ? "down" : "up" };
}

/**
 * 計画。戻りは `{ ok:true, action, moves, direction, target:{flat,section,index,text}, ... }` か `{ ok:false, reason }`。
 *  action = "open-detail"       印を `target` へ動かし(Enter の前に `verifySelection`)、Enter で詳細を開いて、
 *                               `detail` 付きで戻って来る。
 *           "press-x-in-detail" 今開いている詳細が目標。此処で x。
 *           "close-detail"      今の詳細では決められない(同名の別の行をまだ見ていない)。Escape 1 回で overlay
 *                               全体が閉じるので、`/tasks` を開き直し(`sameShape` で形を確かめ)、`examined` に
 *                               今の分を足して戻って来る。
 * 目標(`target`)に要る物:
 *   description / promptPrefix(全文)/ recentTools(全列)/ agentType /
 *   `live:true`(机が転写から「今も動いている」と判定した)/ `liveSameDescription`(机が知る、同じ説明文で今も
 *   動いている agent の数。目標を含む)。生死が分からなければ押さない —— 画面は id を出さないので、完全に同一な
 *   双子の片方が先に終わった後を画面だけでは見分けられない(Codex 所見)。
 * ★行の文字列だけで押す経路は無い。押すのは常に、`detailMatches` が通った詳細画面から。
 * ★同名が複数なら**全部の詳細を見てから**決める。一致が丁度 1 本の時だけ其処へ戻って押す。0 本 = 目標は一覧に居ない、
 *   2 本以上 = 見分けられない(曖昧)。消去法は使わない。
 * `examined` = `[{ flat, detail }]`(driver が見た詳細。flat は其の時の平らな位置)。`exclude` = 平らな位置の配列
 * (詳細を持たない除外。見た事にはなるが一致にはならない)。
 */
export function planStop({ panel, detail = null, target, maxMoves = DEFAULT_MAX_MOVES, examined = [], exclude = [] } = {}) {
  if (!panel || panel.kind !== "panel") return { ok: false, reason: "not-a-panel" };
  if (!target || typeof target.description !== "string" || !target.description) return { ok: false, reason: "no-such-row" };
  if (target.live !== true) return { ok: false, reason: "no-such-row", why: "not-live" };
  const rows = flatRows(panel);
  const sameName = rows.map((r, i) => ({ ...r, flat: i })).filter((r) => !isShell(r.section) && rowMatches(r.text, target.description));
  if (sameName.length === 0) return { ok: false, reason: hasOverflow(panel) ? "too-far" : "no-such-row" };
  if (!hasMaterial(target)) return { ok: false, reason: "ambiguous", why: "insufficient" };
  const known = target.liveSameDescription;
  if (!Number.isInteger(known) || known < 1) return { ok: false, reason: "ambiguous", why: "unknown-siblings" };
  if (known > sameName.length) return { ok: false, reason: "ambiguous", why: "twin-may-have-finished" };
  const selectedFlat = selectedFlatOf(rows);
  if (rows.length > 0 && selectedFlat < 0) return { ok: false, reason: "reflow", why: "selection" };   // 印が無い / 2 つ以上
  const seen = new Map();
  for (const f of Array.isArray(exclude) ? exclude : []) if (Number.isInteger(f)) seen.set(f, null);
  for (const e of Array.isArray(examined) ? examined : []) if (e && Number.isInteger(e.flat)) seen.set(e.flat, e.detail ?? null);

  if (detail) {
    // 詳細が開いている = 印の行の詳細。
    const sel = at(rows, selectedFlat);
    if (isShell(sel.section)) return { ok: false, reason: "shell-row" };
    if (!rowMatches(sel.text, target.description)) return { ok: false, reason: "mismatch", why: "row" };
    const m = detailMatches(detail, target);
    if (m.why === "insufficient") return { ok: false, reason: "ambiguous", why: m.why };
    if (sameName.length === 1) {
      return m.ok ? { ok: true, action: "press-x-in-detail", moves: 0, direction: null, target: sel } : { ok: false, reason: "mismatch", why: m.why };
    }
    // 同名が複数: 他の候補を全部見終わっていて、一致が此の 1 本だけの時に限って押す。
    const others = sameName.filter((c) => c.flat !== selectedFlat);
    const unseen = others.filter((c) => !seen.has(c.flat));
    if (unseen.length > 0) return { ok: true, action: "close-detail", moves: 0, direction: null, target: sel, remaining: unseen.map((c) => c.flat), matched: m.ok };
    const otherMatches = others.filter((c) => detailMatches(seen.get(c.flat), target).ok).length;
    if (m.ok && otherMatches === 0) return { ok: true, action: "press-x-in-detail", moves: 0, direction: null, target: sel };
    if (m.ok || otherMatches > 0) return { ok: false, reason: otherMatches + (m.ok ? 1 : 0) >= 2 ? "ambiguous" : "mismatch", why: m.ok ? "duplicate" : m.why };
    return { ok: false, reason: "no-such-row", why: "none-matched" };
  }

  // 詳細が開いていない: 次に開く候補を選ぶ。
  if (sameName.length === 1) {
    const only = sameName[0];
    const mv = moveTo(rows, selectedFlat, only.flat, maxMoves);
    return mv.ok ? { ok: true, action: "open-detail", moves: mv.moves, direction: mv.direction, target: at(rows, only.flat), candidates: [only.flat] } : mv;
  }
  const unseen = sameName.filter((c) => !seen.has(c.flat));
  if (unseen.length > 0) {
    const nextC = unseen[0];
    const mv = moveTo(rows, selectedFlat, nextC.flat, maxMoves);
    return mv.ok ? { ok: true, action: "open-detail", moves: mv.moves, direction: mv.direction, target: at(rows, nextC.flat), candidates: sameName.map((c) => c.flat), remaining: unseen.map((c) => c.flat) } : mv;
  }
  const matches = sameName.filter((c) => detailMatches(seen.get(c.flat), target).ok);
  if (matches.length === 0) return { ok: false, reason: "no-such-row", why: "none-matched" };
  if (matches.length > 1) return { ok: false, reason: "ambiguous", why: "duplicate" };
  const mv = moveTo(rows, selectedFlat, matches[0].flat, maxMoves);
  return mv.ok ? { ok: true, action: "open-detail", moves: mv.moves, direction: mv.direction, target: at(rows, matches[0].flat), candidates: sameName.map((c) => c.flat), final: true } : mv;
}

/**
 * Enter を打つ直前の確認。**今の描画**で印が `expected` の行(平らな位置 + 節 + 節内の位置 + 文字列、**全部必須**)に
 * 乗っているか。
 *  - `expected` に四つが揃っていない → `mismatch`(欠けた要素を「何でもよい」とは読まない)
 *  - 目標の文字列の行が 1 本も無い → `reflow`(終わった疑い)
 *  - 印が無い / 印が 2 つ以上 / `expected.flat` の行が無い / 其の行の文字列・節・節内の位置が変わった → `reflow`
 *  - 印がシェルの節 → `shell-row`
 *  - 印が別の位置 → `mismatch`
 * 同名が複数在っても、位置が一致して初めて ok(文字列だけでは通さない)。成功の戻りに `reason` は無い。
 */
export function verifySelection(panel, expected) {
  if (!panel || panel.kind !== "panel") return { ok: false, reason: "not-a-panel" };
  if (!expected || typeof expected.text !== "string" || !Number.isInteger(expected.flat)
      || typeof expected.section !== "string" || !Number.isInteger(expected.index)) return { ok: false, reason: "mismatch" };
  const rows = flatRows(panel);
  if (!rows.some((r) => !isShell(r.section) && r.text === expected.text)) return { ok: false, reason: "reflow" };
  const selectedFlat = selectedFlatOf(rows);
  if (selectedFlat < 0) return { ok: false, reason: "reflow" };
  const sel = at(rows, selectedFlat);
  if (isShell(sel.section)) return { ok: false, reason: "shell-row" };
  const want = at(rows, expected.flat);
  if (!want || want.text !== expected.text || want.section !== expected.section || want.index !== expected.index) return { ok: false, reason: "reflow" };
  if (selectedFlat !== expected.flat) return { ok: false, reason: "mismatch" };
  return { ok: true, selected: sel };
}

/**
 * 2 枚の描画が同じ形か(開き直した後に候補の位置を信じてよいかの前提)。行の並びと文字列、節の数字、
 * 上の集計文、overflow の印が全部同じ時だけ true(印の位置は形に入れない)。
 */
export function sameShape(a, b) {
  if (!a || !b || a.kind !== "panel" || b.kind !== "panel") return false;
  const ra = flatRows(a), rb = flatRows(b);
  if (ra.length !== rb.length || !ra.every((r, i) => r.section === rb[i].section && r.index === rb[i].index && r.text === rb[i].text)) return false;
  const sa = Array.isArray(a.sections) ? a.sections : [], sb = Array.isArray(b.sections) ? b.sections : [];
  if (sa.length !== sb.length || !sa.every((s, i) => s?.name === sb[i]?.name && (s?.count ?? null) === (sb[i]?.count ?? null))) return false;
  if ((a.counts ?? null) !== (b.counts ?? null)) return false;
  const ha = (Array.isArray(a.hints) ? a.hints : []).join("\n"), hb = (Array.isArray(b.hints) ? b.hints : []).join("\n");
  return ha === hb;
}

export { duplicateRows };
