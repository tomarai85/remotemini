// agent panel(`/tasks`)と其の詳細画面を**構造**に読む純関数(2026-09-06、対照表 #8 の後半 b)。
//
// ── 何を読むか、何を決めないか ───────────────────────────────────────────────
// 読む: 節(`Shells (N)` / `Local agents (N)` / `Team: … (N)`)ごとの行と、どの行に選択の印 `❯` が乗っているか、
//       繋いだ footer。詳細画面なら `<型> › <説明>`、数の行、Progress の道具呼び出し、Prompt の冒頭。
// 決めない: 断るか押すか。其れは次の段(設計文の c)の仕事で、此処は**画面の写しを表にする**だけ。
//
// ★行の同一性は文字列だけ(測定 2026-09-06: 同じ説明文の 2 本は byte 同一)。だから `rows` に id は無い。
//   同名の行が 2 本在る事を**そのまま返す** —— 畳んだり番号を付けたりすると、上の段が「区別できた」と誤読する。
// ★見る範囲は `inject.mjs` の `panelStateOf` と同じ「最後の `▔▔▔` の区切りより下」。区切りの判断を 2 箇所に
//   書かない為に `overlayRegionOf` を其処から借りる。
import { overlayRegionOf, panelStateOf } from "./inject.mjs";

const SECTION = /^\s*(Shells|Local agents|Team: .+?) \((\d+)\)\s*$/;
const TEAM_HEAD_OPEN = /^\s*Team: \S/;
const TEAM_HEAD_TAIL = /^\s*(\S.*?)\s*\((\d+)\)\s*$/;
/** 項目の行の終わり: ` (<状態>)` か ` (<状態>) · <model>`(説明文自身は括弧を含み得るので、終わりだけ見る)。 */
const ROW_TAIL = / \([a-z][a-z -]*\)(?: · [^()]+)?$/;
/** teammate の行は `@name: status` の形(状態の括弧が無い)。折り返しの続きとは読まない。 */
const TEAMMATE_ROW = /^@\S+: /;
const TEAM_HEAD_MAX_LINES = 4;

/**
 * `Team: …` の見出しが行 i から何行に折り返しているか。`{ name, count, lines }` か null(見出しではない)。
 * 続きの行 = 印が無く、` · ` を含まず、見出し・overflow・footer でもない行。`(N)` で終わる行で閉じる。
 */
function teamHeadSpan(lines, i, end) {
  const l = lines[i] ?? "";
  if (!TEAM_HEAD_OPEN.test(l) || SECTION.test(l)) return null;
  const parts = [l.trim()];
  for (let j = i + 1; j < end && j < i + TEAM_HEAD_MAX_LINES; j++) {
    const nx = lines[j] ?? "";
    if (!nx.trim() || SELECTED.test(nx) || nx.includes(" · ") || SECTION.test(nx) || OVERFLOW.test(nx) || FOOTER_START.test(nx)) return null;
    const t = TEAM_HEAD_TAIL.exec(nx);
    if (t) {
      parts.push(t[1]);
      const name = parts.reduce((acc, p) => acc + (acc.endsWith("-") ? "" : " ") + p);
      return { name, count: t[2], lines: j - i + 1 };
    }
    parts.push(nx.trim());
  }
  return null;
}
// ★footer は行頭(字下げの後)から始まる物だけ(Codex 2026-09-06: 本文に同じ語を含む行で一覧が途中で切れる)。
const FOOTER_START = /^\s*↑\/↓ to select/;
// ★選択の印は**3 桁目**の `❯ `(fixture: 選択行 `   ❯ …` / 非選択行は空白 5 つ)。字下げを無視すると、本文が
//   `❯ ` で始まる非選択行を選択と読む(Codex 2026-09-06)。
const SELECTED = /^ {3}❯ /;
const OVERFLOW = /^\s*↓ \d+ more\s*$/;

/** 折り返した footer を 1 文に繋ぐ(`stop` が出た行まで、最長 max 行)。 */
function joinFooter(lines, from, stop, max = 3) {
  const out = [];
  for (let i = from; i < lines.length && out.length < max; i++) {
    out.push(lines[i].trim());
    if (stop.test(lines[i])) break;
  }
  return out.join(" ");
}

/**
 * PANEL 画面 → `{ counts, sections:[{ name, count, rows:[{ text, selected }] }], footer, selected }`。
 * PANEL でなければ null。`selected` = `{ section, index, text }`(印の行が無ければ null)。
 *
 * 行の読み方(fixture 10 枚から): 節の見出しの下に 1 行 1 項目。選択の印は行頭の空白の後の `❯ `。
 * 印の無い行は空白 5 つで始まる。`↓ N more` の様な overflow の行は項目ではないので `rows` に入れず `hints` へ。
 */
export function parsePanel(text) {
  if (panelStateOf(text) !== "PANEL") return null;
  const lines = overlayRegionOf(text);
  const bg = lines.findIndex((l) => l.trim() === "Background");
  const fi = lines.findIndex((l, i) => i > bg && FOOTER_START.test(l));
  const end = fi >= 0 ? fi : lines.length;
  const footer = fi >= 0 ? joinFooter(lines, fi, /Esc to close/) : "";
  // 数の行 = Background の下から最初の節の見出しまで(80 桁で折り返し得るので 1 行に限らない — Codex)。
  const wrappedHead = (i) => teamHeadSpan(lines, i, end) !== null;
  let firstSection = lines.findIndex((l, i) => i > bg && i < end && (SECTION.test(l) || wrappedHead(i)));
  if (firstSection < 0) firstSection = end;
  const counts = lines.slice(bg + 1, firstSection).map((l) => l.trim()).filter(Boolean).join(" ") || null;
  const sections = [];
  const hints = [];
  let selected = null;
  let cur = null;
  for (let i = firstSection; i < end; i++) {
    const l = lines[i];
    if (!l.trim()) continue;
    let m = SECTION.exec(l);
    // 80 桁では長い `Team: <name> (N)` の見出しが複数行に折り返す(Codex 所見 2026-09-06、2 行と 3 行以上)。
    // `Team:` で始まって `(N)` で終わらない行から、`(N)` で終わる行までを 1 つの見出しとして繋ぐ。
    if (!m) {
      const span = teamHeadSpan(lines, i, end);
      if (span) { m = [null, span.name, span.count]; i += span.lines - 1; }
    }
    if (m) { cur = { name: m[1], count: Number(m[2]), rows: [] }; sections.push(cur); continue; }
    if (OVERFLOW.test(l)) { hints.push(l.trim()); continue; }
    if (!cur) continue;
    const sel = SELECTED.test(l);
    let text = (sel ? l.replace(SELECTED, "") : l).replace(/^\s+/, "");
    // 長い説明文の行も折り返す(Codex 所見 2026-09-06)。`(<状態>)` で終わらない行に、続きの行(印無し・見出しでも
    // overflow でもない)を繋いで `(<状態>)` の形になるなら 1 行と読む(最大 3 行)。
    for (let k = 0; k < 2 && !ROW_TAIL.test(text) && !TEAMMATE_ROW.test(text) && i + 1 < end; k++) {
      const nx = lines[i + 1] ?? "";
      if (!nx.trim() || SELECTED.test(nx) || SECTION.test(nx) || OVERFLOW.test(nx) || FOOTER_START.test(nx) || TEAMMATE_ROW.test(nx.trim()) || teamHeadSpan(lines, i + 1, end)) break;
      text = `${text} ${nx.trim()}`;
      i += 1;
    }
    const row = { text, selected: sel };
    cur.rows.push(row);
    if (sel) selected = { section: cur.name, index: cur.rows.length - 1, text: row.text };
  }
  return { kind: "panel", counts, sections, hints, footer, selected };
}

/**
 * DETAIL 画面 → `{ agentType, description, counters:{ elapsed, tokens, tools, model }, recentTools:[…],
 *                  promptPrefix, footer }`。DETAIL でなければ null。
 *
 * `recentTools` は Progress の下の行(`Bash(sleep 12)` 等)を**上から順に**。進行中の印 `›` は落とす。
 * `promptPrefix` は Prompt の下の行を繋いだ物(画面が `…` で切った所まで = 全文ではない)。
 */
export function parseDetail(text) {
  if (panelStateOf(text) !== "DETAIL") return null;
  const lines = overlayRegionOf(text);
  let ti = lines.findIndex((l) => /^\s*\S[^›\n]* › .+$/.test(l));
  let [, agentType, description] = /^\s*(\S[^›]*?)\s*›\s*(.+?)\s*$/.exec(lines[ti]) ?? [null, null, null];
  // 長い説明文は題名が次の行へ折り返す(Codex 所見 2026-09-06)。題名と数の行(` · ` と `tokens` を含む)の間の行は
  // 題名の続き(最大 2 行)。数の行が無ければ繋がない。
  const isCounters = (l) => l.includes("·") && /tokens/.test(l);
  for (let j = ti + 1; j < Math.min(ti + 3, lines.length) && description; j++) {
    const nx = lines[j] ?? "";
    if (!nx.trim() || isCounters(nx) || nx.trim() === "Progress" || nx.trim() === "Prompt" || /^\s*›?\s*[A-Za-z_][\w.]*\(/.test(nx) || /^\s*← to go back/.test(nx)) break;
    const hasCounters = lines.slice(j + 1, j + 3).some(isCounters);
    if (!hasCounters) break;
    description = `${description} ${nx.trim()}`;
    ti = j;
  }
  const pi = lines.findIndex((l, i) => i > ti && l.trim() === "Progress");
  const qi = lines.findIndex((l, i) => i > ti && l.trim() === "Prompt");
  const fi = lines.findIndex((l, i) => i > ti && /^\s*← to go back/.test(l));
  const end = fi >= 0 ? fi : lines.length;
  // 数の行 = 題の下から、Progress / Prompt の見出しか**最初の道具の行**まで(折り返し得るので繋ぐ — Codex)。
  //   道具の行を数に混ぜない: Progress の見出しが無い画面では道具の行が数の直後に来る。
  const firstHead = [pi, qi].filter((i) => i >= 0).reduce((a, b) => Math.min(a, b), end);
  const toolish = (l) => /^\s*›?\s*[A-Za-z_][\w.]*\(/.test(l);
  let cEnd = firstHead;
  for (let i = ti + 1; i < firstHead; i++) if (toolish(lines[i])) { cEnd = i; break; }
  const cLine = lines.slice(ti + 1, cEnd).map((l) => l.trim()).filter(Boolean).join(" ");
  const parts = cLine.split(" · ").map((p) => p.trim()).filter(Boolean);
  const isElapsed = (p) => /^\d+(\.\d+)?(s|m|h)\b/.test(p);
  const isTokens = (p) => /tokens$/.test(p);
  const isTools = (p) => /tools?$/.test(p);
  const counters = {
    elapsed: parts.find(isElapsed) ?? null,
    tokens: parts.find(isTokens) ?? null,
    tools: parts.find(isTools) ?? null,
    // model = 残り全部を ` · ` で繋ぐ(model 名が ` · ` を含んでも切らない — Codex)。
    model: parts.filter((p) => !isElapsed(p) && !isTokens(p) && !isTools(p)).join(" · ") || null,
  };
  const recentTools = (pi >= 0
    ? lines.slice(pi + 1, qi >= 0 ? qi : end)
    // Progress の見出しが無くても道具の行が見えていれば拾う(黙って [] にしない — Codex)。
    : lines.slice(cEnd, qi >= 0 ? qi : end).filter(toolish))
    .map((l) => l.replace(/^\s*›\s?/, "").trim()).filter(Boolean);
  // 行頭は overlay の字下げ(空白 3 つ)だけを落とす。prompt 自身の先頭の空白は意味を持つので残す(Codex 所見 2026-09-06)。
  const promptPrefix = qi >= 0 ? lines.slice(qi + 1, end).filter((l) => l.trim()).map((l) => l.replace(/^ {3}/, "").replace(/\s+$/, "")).join(" ") : "";
  const footer = fi >= 0 ? joinFooter(lines, fi, /to close|stop all agents/) : "";
  // 画面が `…` で切った prompt か、本文の末尾が `…` かは区別できない —— 旗として出し、上の段に判断を残す。
  const promptTruncated = promptPrefix.endsWith("…");
  return { kind: "detail", agentType, description, counters, recentTools, promptPrefix, promptTruncated, footer };
}

/** 同じ文字列の行が節の中に 2 本以上在る名前の一覧(上の段が「曖昧」と断る材料。此処では断らない)。 */
export function duplicateRows(panel) {
  const seen = new Map();
  for (const s of panel?.sections ?? []) for (const r of s.rows) seen.set(r.text, (seen.get(r.text) ?? 0) + 1);
  return [...seen.entries()].filter(([, n]) => n > 1).map(([text, n]) => ({ text, count: n }));
}
