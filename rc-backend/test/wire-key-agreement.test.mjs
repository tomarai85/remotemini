// 電話の `Decodable` が名乗る鍵名を、サーバが**実際に吐いた**鍵名と突き合わせる。
//
// ★何故これが要るか(2026-08-08、S8-24)。電話の model は**わざと緩く**復号する ——
//   欠けた鍵は `nil` / `[]` / `.unrecognized` に落ちる。理由は書いてある通り正しい
//   (古い電話が新しいサーバに当たった日に、画面ごと白紙になる方が悪い)。但し緩さが
//   安全なのは「ズレに気付く者が別に居る」時だけで、その者が居なかった。
//   鍵名が片側で変わると、復号は通り、検査は全部緑のまま、**画面だけが痩せる**。
//
//   実害の形で言うと: `display.choice` の鍵名が変われば選択カードは二度と出ず
//   (S6 が直した「見えるが答えられない」に戻る)、`buttons`/`digest` が変われば
//   カードは出るのに何も押せない。どちらも例外は投げない。
//
// ★測り方の非対称を意図的に選んだ。側A(サーバ)は**実行**して出た鍵を拾う ——
//   `src/view.mjs` の builder は export されていて単体から呼べる。側B(電話)は
//   **原文を読む**。Swift は此処からは走らせられないので、`CodingKeys` が在れば
//   それを、無ければ格納プロパティを鍵とする(`CodingKeys` が property 名に勝つ:
//   `ScreenBody` は `case classification = "screen"` と改名している)。
//
// ★此の検査が**嘘の緑**を出しうる唯一の道は「側Aの入力が狭くて、或る枝の鍵が
//   一度も出ない」。だから builder の原文からも鍵位置の名前を拾い、実行で出た
//   葉名の部分集合である事を別に押さえる(下の②)。
//
// 測っていない事は末尾の `UNPAIRED` に**型の名前で**列挙する。0件を「全部一致」と
// 読ませない為に、走査が見付けた鍵付き型は `PAIRS` か `UNPAIRED` の**どちらかに
// 必ず居る**事も測る(③)。
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";
// ★`ROOT` = rc-backend、`REPO` = その親。**木の中を読む時に `REPO` を経由しない**
//   (2026-08-09、S8-29 で実際に踏んだ)。`join(REPO, "rc-backend", …)` は完全な木では
//   `join(ROOT, …)` と同じ物を指すので手元では永遠に緑だが、`mutation-controls.py` が
//   起こす **rc-backend だけの写し**には親が無く、同じ式が存在しない path になる。
//   その2本が写しで throw して対照1(無変異の木は緑)が落ち、197件の変異走行が
//   1件も起動しなくなっていた。木の外(`ios/**`)だけが `REPO` + `requireOutside` の領分。
import { ROOT, REPO, requireOutside } from "./subtree.mjs";
import { stripSwiftComments, swiftFiles } from "./swiftsrc.mjs";
import { stripComments, blockAfter } from "./jssrc.mjs";
import * as view from "../src/view.mjs";
import * as blocked from "../src/blocked.mjs";
import * as wire from "../src/wire.mjs";
import * as sessions from "../src/sessions.mjs";
import * as registry from "../src/registry.mjs";
import { parseFleetAccount } from "../src/account.mjs";
import { buildListing, unreadableRow } from "../src/sessions.mjs";
import { registryOnlySessions } from "../src/registry.mjs";
import { sessionRow } from "../src/wire.mjs";
import { looksLikeClaudePane } from "../src/inject.mjs";

const SWIFT_ROOT = join(REPO, "ios", "Sources");
const NEED = [
  "ios/Sources/Core/PollModels.swift",
  "ios/Sources/Core/SessionsModels.swift",
  "ios/Sources/Core/ResultDisplay.swift",
  // S8-26 で `HistoryResponse` / `HistoryEntry` / `EntryDisplay` を組に入れたので、
  // 此の file が無い木は「測れていない」と言わせる。書かないと、消えた時に
  // 「電話側に居ない = 改名か削除」という**別の理由**の赤に化ける。
  "ios/Sources/Core/HistoryModels.swift",
];
const gate = requireOutside(NEED);
const skip = gate.skip;

// --- 側A: サーバの builder を実際に呼ぶ ---------------------------------------

// 一覧の行に食わせる観測値。`registryOnlySessions` は**採否の判定を通った時だけ**行を出すので、
// 通る入力を作らないと ② が赤くなる(= 痩せた入力に気付く側の圧力が、そのまま効く)。
// 生きた登録の形は `test/registry.test.mjs` の通っている fixture をそのまま写した。
const S_CWD = "/Users/Shared/dev/roundtrip";
const LISTING_ENTRIES = [{
  sessionId: "1b5c9362-aaaa-bbbb-cccc-000000000001",
  projectSlug: "-Users-Shared-dev-roundtrip",
  mtimeMs: 1000,
  meta: { entrypoint: "cli", cwd: S_CWD, lastPrompt: "直近の一言", turns: 3, aiTitle: "題", metadataIncomplete: false },
}];
const REGISTRY_ARGS = {
  listing: [],
  entries: [{ sessionId: "1b5c9362-aaaa-bbbb-cccc-000000000002", pane: "%12", mtimeMs: 1000 }],
  panes: [{ pane: "%12", command: "2.1.220", tty: "/dev/ttys012", path: S_CWD }],
  isClaude: looksLikeClaudePane,
  now: 1000,
  ttlMs: 5000,
};
const UNREADABLE_ARGS = {
  id: "1b5c9362-aaaa-bbbb-cccc-000000000003",
  project: "-Users-Shared-dev-roundtrip",
  updatedAt: "2026-08-08T00:00:00.000Z",
  errorCode: "TRANSCRIPT_UNREADABLE",
};
/** 行の生産者は3本。**和を取らないと `fromRegistryOnly` / `errorCode` が測れない**。 */
const ROWS = [
  ...buildListing(LISTING_ENTRIES),
  ...registryOnlySessions(REGISTRY_ARGS),
  unreadableRow(UNREADABLE_ARGS),
];
const LIVES = [
  { route: "tmux", pane: "%12", screen: "SENDABLE" },
  { route: "worker", state: "busy", queued: 1 },
  { route: "blocked", reason: "no-pane" },
];
const SCAN = { scope: "all", limit: 20, files: 42, read: 7, cached: 35, examined: 42 };
// 選択待ちの画面。`choiceView` と `pollBodyTmux` の**両方**が要る ——
// ★写しを2つ置かない。`display.choice` は `pollBodyTmux` が `choiceView` を呼んで作るので、
//   入力が別物だと「同じ画面から同じカードが出る」という肝心の関係が測れない。
const CHOICE_SCREEN = {
  screen: "CHOICE",
  choice: { head: ["h"], options: [{ n: 1, label: "a" }], keys: ["digit", "enter", "escape"], digest: "d", cursor: 1, kind: "select-model" },
};
// 流れの1件・履歴の1件。★`{role, text}` **だけ**にするのは意図で、`sessions.mjs` が
// 実際に押し込む形をそのまま写した(`out.push({ role: "user", text })`)。ここに線に無い鍵を
// 足すと `withWho` の出力が増え、電話に無い鍵として④が赤くなる —— 製品ではなく入力の捏造で。
const ENTRIES = [
  { role: "user", text: "u" },
  { role: "assistant", text: "a" },
];

// 口座の入力は **`parseFleetAccount` に実際に食わせて作る**。手で `{current, accounts, …}` を
// 書くと、台本の出力形式が変わって parser の返り値の形が変われば入力だけが古いまま残り、
// 「実行して出た鍵」という側Aの前提が静かに崩れる(此の file の冒頭の主張そのもの)。
// 綴りの正本は `src/account.mjs` の定数(`現用:` / `優先順 (.order):` / `トークン:有|欠`)。
const ACCOUNT_STDOUT = {
  // 選べる行と**選べない行**(トークン欠け)が両方要る = `display.blocked` が出る枝。
  ok: "現用: team\n優先順 (.order):\n->  1. team     トークン:有\n    2. biz      トークン:有\n    3. sdgs     トークン:欠\n",
  // 現用の印が1つも無い = `anomalies: ["active-count-0"]` が出る枝(`display.anomalies` の中身)。
  anomaly: "現用: team\n優先順 (.order):\n    1. team     トークン:有\n    2. biz      トークン:有\n",
  // 1行目が「現用:」でない = `parseStatus !== "ok"` で **`raw` が生える枝**。
  // 此処を通さないと `raw` が「誰も吐かない鍵」として静かに落ちる。
  unreadable: "garbage line\nmore\n",
};
const ACCOUNT_PARSED = {
  ok: parseFleetAccount(ACCOUNT_STDOUT.ok),
  anomaly: parseFleetAccount(ACCOUNT_STDOUT.anomaly),
  unreadable: parseFleetAccount(ACCOUNT_STDOUT.unreadable),
};

/** 枝を割る為の入力。**返り値ではなく枝の数で選ぶ** —— 1本しか通さない表は側Aを痩せさせる。 */
const CASES = {
  routeLabel: [
    [{ route: "tmux", screen: "CHOICE", limited: true }],
    [{ route: "tmux", screen: "SENDABLE", activity: "observed" }],
    [{ route: "tmux", screen: "BUSY" }],
    [{ route: "worker", state: "busy" }],
    [{ route: "worker", state: "ready" }],
    [{ route: "blocked", reason: "no-pane" }],
    [null],
    [{}],
  ],
  choiceView: [
    [CHOICE_SCREEN],
    [{ screen: "CHOICE", choice: { head: [], options: [], keys: [], digest: "d", kind: "hard-stop" } }],
    [{ screen: "CHOICE", choice: null }],
    [{ screen: "SENDABLE" }],
    [null],
  ],
  // 202 は「受け取った」までしか言わない枝で、`keepText` を出すのは主に此処。
  sendResult: [
    [202, null], [202, {}], [202, { delivered: "unverified" }], [202, { delivered: true }],
    [200, { accepted: true }], [409, { code: "X" }], [400, {}], [500, {}],
  ],
  interruptResult: [[200, { interrupted: true, stopped: true }], [409, {}], [400, {}]],
  choiceResult: [[200, { accepted: true, applied: true }], [400, {}], [409, {}], [404, {}]],
  clearQueueResult: [[200, { dropped: 2 }], [400, {}]],
  paneFaultView: [["panes-unreadable"], ["tmux-unavailable"], ["名乗れない理由"]],
  buildListing: [[LISTING_ENTRIES], [[]]],
  registryOnlySessions: [[REGISTRY_ARGS], [{ ...REGISTRY_ARGS, panes: [] }]],
  unreadableRow: [[UNREADABLE_ARGS]],
  sessionRow: ROWS.flatMap((r) => LIVES.map((l) => [r, l])),
  sessionsBody: [
    [{ sessions: ROWS.map((r) => sessionRow(r, LIVES[0])), scan: SCAN, paneFault: null }],
    [{ sessions: [], scan: SCAN, paneFault: { reason: "tmux-unavailable", detail: "spawn tmux ENOENT" } }],
  ],
  // ★`seq` 有り/無しの**両方**を通す。`gapItem` は無い時に鍵ごと生やさないので、
  //   片方しか通さないと「線に出る鍵」を測り損ねる(有り側が抜ければ電話は番号を失い、
  //   無し側が抜ければ `seq: undefined` の混入に気付けない)。
  gapItem: [
    ["ring-overflow"], ["tail-attached"], ["cursor-too-long", 12], ["epoch-mismatch"],
  ],
  withWho: [[ENTRIES[0]], [ENTRIES[1]], [{ role: "tool", text: "⚙ Bash" }], [null]],
  messageItem: [
    [{ entries: ENTRIES.map((e) => wire.withWho(e)), seq: 7 }],
    [{ event: { type: "assistant", text: "a" }, seq: 8 }],
  ],
  pollBodyTmux: [
    [{ items: [], screen: CHOICE_SCREEN, cursor: "tmux:1:2:3", more: false }],
    [{ items: [], screen: null, cursor: "tmux:1:2:3", more: true }],
  ],
  pollBodyWorker: [[{ items: [], queued: 2, cursor: "worker:1:2", more: false }]],
  historyBody: [
    [{ entries: ENTRIES, truncated: true }],
    [{ entries: [], truncated: false }],
  ],
  // 枝が1本しか無い唯一の builder。分岐が無い(`ok` は定数、残り3つは受けた値をそのまま)
  // ので、枝を増やしても出る鍵は1組しか無い —— ②が「原文に在るのに出ない鍵」で裏を取る。
  healthzBody: [[{ pid: 4242, uptime: 61, version: "abc1234" }]],
  // 口座(2026-08-15)。3枝の**和**が要る:
  //   ok        -> `accounts[]` と `display.blocked`(選べない行)
  //   anomaly   -> `display.anomalies` の中身
  //   unreadable-> `raw`(`ok` でない時だけ生える鍵)
  // `raw` を第2引数で渡すのは本番と同じ形(`server.mjs` は台本の生出力を其処へ入れる)。
  accountBody: [
    [ACCOUNT_PARSED.ok, { raw: ACCOUNT_STDOUT.ok }],
    [ACCOUNT_PARSED.anomaly, { raw: ACCOUNT_STDOUT.anomaly }],
    [ACCOUNT_PARSED.unreadable, { raw: ACCOUNT_STDOUT.unreadable }],
  ],
  // 行は**行の生産者を直に呼ぶ**。`accountBody` の返り値の `accounts[].display` を辿る道を
  // 選ばなかったのは、`pluck` の `at` が1段しか降りられないから —— 2段の道を足すのは
  // 「測る為に測る道具を太らせる」側で、`sessionRow` が既に「行の生産者を直に呼ぶ」形を
  // 取っている(`src/wire.mjs` の `accountBody` は `accounts` に此の関数の返り値をそのまま入れる)。
  accountRow: ACCOUNT_PARSED.ok.accounts.map((a) => [ACCOUNT_PARSED.ok, a]),
};

/**
 * どの module に居るか。原文を読む側(②)も同じ表を使う。
 *
 * 3つ目は**吐く literal の直前の目印**(省略時は `export function <名前>(` の直後)。
 * 引数を分解する書き方(`function f({ a, b })`)だと、既定の目印の直後に来る `{` は
 * **引数の分解**であって吐く物ではない。そこを読むと鍵が0件になり、②は静かに緑になる。
 * だから目印を明示し、加えて②で「0件は赤」を測る(目印がズレたら null で赤になる)。
 */
const MODULE_OF = {
  routeLabel: ["view", "src/view.mjs"],
  choiceView: ["view", "src/view.mjs"],
  sendResult: ["view", "src/view.mjs"],
  interruptResult: ["view", "src/view.mjs"],
  choiceResult: ["view", "src/view.mjs"],
  clearQueueResult: ["view", "src/view.mjs"],
  paneFaultView: ["blocked", "src/blocked.mjs"],
  buildListing: ["sessions", "src/sessions.mjs", ".map((e) => ("],
  unreadableRow: ["sessions", "src/sessions.mjs", "export function unreadableRow({ id, project, updatedAt, errorCode }) {"],
  registryOnlySessions: ["registry", "src/registry.mjs", "out.push("],
  sessionRow: ["wire", "src/wire.mjs"],
  sessionsBody: ["wire", "src/wire.mjs", "export function sessionsBody({ sessions, scan, paneFault }) {"],
  // 引数を分解しない2本は既定の目印で本文に届く(`gapItem(why, seq)` / `withWho(entry)`)。
  gapItem: ["wire", "src/wire.mjs"],
  withWho: ["wire", "src/wire.mjs"],
  // 残る4本は分解するので目印を明示する —— 既定だと**引数の分解**を本文と読んで0件になる。
  messageItem: ["wire", "src/wire.mjs", "export function messageItem({ entries, event, seq }) {"],
  pollBodyTmux: ["wire", "src/wire.mjs", "export function pollBodyTmux({ items, screen, cursor, more }) {"],
  pollBodyWorker: ["wire", "src/wire.mjs", "export function pollBodyWorker({ items, queued, cursor, more }) {"],
  historyBody: ["wire", "src/wire.mjs", "export function historyBody({ entries, truncated }) {"],
  healthzBody: ["wire", "src/wire.mjs", "export function healthzBody({ pid, uptime, version }) {"],
  // 第2引数を分解するので目印を明示する(既定の目印だと `{ raw = "" }` = **引数の分解**を
  // 本文と読んで、鍵が0件になる。②が其れを赤で捕まえるが、先に正しく書く)。
  accountBody: ["wire", "src/wire.mjs", "export function accountBody(parsed, { raw = \"\" } = {}) {"],
  // 行の方は分解しないので既定の目印で本文に届く(`accountRow(parsed, a)`)。
  accountRow: ["wire", "src/wire.mjs"],
};
const MODULES = { view, blocked, wire, sessions, registry };

/** 入れ子を含めた鍵の道を集める(`options[].n` の形)。 */
function keyPaths(value, prefix, out) {
  if (value === null || typeof value !== "object") return out;
  if (Array.isArray(value)) {
    for (const v of value) keyPaths(v, `${prefix}[]`, out);
    return out;
  }
  for (const [k, v] of Object.entries(value)) {
    const p = prefix ? `${prefix}.${k}` : k;
    out.add(p);
    keyPaths(v, p, out);
  }
  return out;
}

/** 物か、物の配列かを、鍵を持つ物の並びに均す。返り値が「行の並び」の builder が居るので要る。 */
function objects(value) {
  if (Array.isArray(value)) return value.filter((v) => v && typeof v === "object" && !Array.isArray(v));
  return value && typeof value === "object" ? [value] : [];
}

/**
 * `at` が指す入れ子を取り出す。
 *   `""`          返り値そのもの(配列なら要素を均す)
 *   `options[]`   その鍵の配列の要素
 *   `paneFault`   その鍵の入れ子1つ(null なら0件 = 枝を通っていないだけ)
 */
function pluck(value, at) {
  if (at === "") return objects(value);
  const arr = /^([A-Za-z_]\w*)\[\]$/.exec(at);
  if (arr) return Array.isArray(value?.[arr[1]]) ? objects(value[arr[1]]) : [];
  const one = /^([A-Za-z_]\w*)$/.exec(at);
  assert.ok(one, `at の書き方を知らない: ${at}`);
  const v = value?.[one[1]];
  return Array.isArray(v) ? [] : objects(v);
}

function callAll(name) {
  const [mod] = MODULE_OF[name];
  const fn = MODULES[mod][name];
  assert.equal(typeof fn, "function", `${mod}.${name} が関数でない(export が消えた)`);
  return CASES[name].map((args) => fn(...args));
}

/** builder 群を `at` の位置で呼んで、出た鍵名の和を返す。 */
function emittedKeys(names, at) {
  const keys = new Set();
  for (const n of names) for (const r of callAll(n)) for (const o of pluck(r, at)) for (const k of Object.keys(o)) keys.add(k);
  return keys;
}

/** builder 1本が出す**葉名**の全部(入れ子の中も含む)。②で使う。 */
function emittedLeafNames(name) {
  const leaves = new Set();
  for (const r of callAll(name)) for (const p of keyPaths(r, "", new Set())) leaves.add(p.split(".").pop().replace(/\[\]$/, ""));
  return leaves;
}

// --- 側B: 電話の Swift を読む -------------------------------------------------

/** 文字列 literal の中身だけを潰す(長さは変えない)。brace の数え間違いを防ぐ為。 */
function blankStrings(src) {
  let out = "";
  let i = 0;
  let inStr = false;
  while (i < src.length) {
    const ch = src[i];
    if (inStr) {
      if (ch === "\\") { out += "  "; i += 2; continue; }
      if (ch === '"') { inStr = false; out += ch; i++; continue; }
      out += ch === "\n" ? "\n" : " ";
      i++;
      continue;
    }
    if (ch === '"') { inStr = true; out += ch; i++; continue; }
    out += ch;
    i++;
  }
  return out;
}

function matchBrace(src, open) {
  let d = 0;
  for (let i = open; i < src.length; i++) {
    if (src[i] === "{") d++;
    else if (src[i] === "}") { d--; if (d === 0) return i; }
  }
  return -1;
}

const TYPE_RE = /(?:^|[\n;])[ \t]*(?:(?:public|private|internal|fileprivate|open)[ \t]+)*(?:final[ \t]+)?(struct|class|enum|actor)[ \t]+([A-Za-z_]\w*)[ \t]*(:[^{\n]*)?\{/g;

/** 型宣言を brace で切り出す。入れ子は `親.子` の名前で別項目にする。 */
function scanTypes(blank, raw, prefix, file, out) {
  const re = new RegExp(TYPE_RE.source, "g");
  let m;
  while ((m = re.exec(blank))) {
    const [whole, kind, name, conf] = m;
    const open = m.index + whole.length - 1;
    const close = matchBrace(blank, open);
    assert.notEqual(close, -1, `${file} の ${name} で brace が閉じない`);
    const qname = prefix + name;
    out.push({
      name: qname,
      kind,
      codable: /\b(Decodable|Codable)\b/.test(conf || ""),
      body: blank.slice(open + 1, close),
      rawBody: raw.slice(open + 1, close),
      file,
    });
    scanTypes(blank.slice(open + 1, close), raw.slice(open + 1, close), `${qname}.`, file, out);
    re.lastIndex = close;
  }
  return out;
}

/** 入れ子を `{}` に畳んだ、型の直下だけの文面。計算プロパティを格納と混ぜない為。 */
function shallow(body) {
  let out = "";
  let d = 0;
  for (const ch of body) {
    if (ch === "{") { if (d === 0) out += "{}"; d++; continue; }
    if (ch === "}") { d--; continue; }
    if (d === 0) out += ch;
  }
  return out;
}

const PROP_RE = /^[ \t]*(?:(?:public|private|internal|fileprivate)[ \t]+)?(?:let|var)[ \t]+([A-Za-z_]\w*)[ \t]*:[ \t]*([^\n]*)$/;

function storedKeys(body) {
  const keys = [];
  for (const line of shallow(body).replace(/;/g, "\n").split("\n")) {
    if (/^\s*static\b/.test(line)) continue;
    const m = PROP_RE.exec(line);
    if (!m) continue;
    if (m[2].includes("{")) continue; // 計算プロパティ
    keys.push(m[1]);
  }
  return keys;
}

/** `CodingKeys` が在れば**そちらが正**(`case classification = "screen"` の改名を拾う)。 */
function codingKeys(all, qname) {
  const ck = all.find((e) => e.name === `${qname}.CodingKeys`);
  if (!ck) return null;
  const keys = [];
  for (const m of ck.rawBody.matchAll(/\bcase[ \t]+([^\n]+)/g)) {
    for (const part of m[1].split(",")) {
      const t = part.trim();
      if (!t) continue;
      const renamed = /^[A-Za-z_]\w*[ \t]*=[ \t]*"([^"]*)"/.exec(t);
      if (renamed) { keys.push(renamed[1]); continue; }
      const bare = /^([A-Za-z_]\w*)$/.exec(t);
      if (bare) keys.push(bare[1]);
    }
  }
  return keys;
}

let CACHE = null;
function phoneTypes() {
  if (CACHE) return CACHE;
  const files = swiftFiles(SWIFT_ROOT);
  const all = [];
  let crudeLines = 0;
  const extensions = [];
  for (const f of files) {
    const rel = f.slice(SWIFT_ROOT.length + 1);
    const raw = stripSwiftComments(readFileSync(f, "utf8"));
    scanTypes(blankStrings(raw), raw, "", rel, all);
    for (const line of raw.split("\n")) {
      if (/\b(struct|class|enum|actor)[ \t]+\w+[ \t]*:[^{\n]*\b(Decodable|Codable)\b/.test(line)) crudeLines++;
      const ext = /^[ \t]*extension[ \t]+([A-Za-z_][\w.]*)[ \t]*:[^{\n]*\b(Decodable|Codable)\b/.exec(line);
      if (ext) extensions.push(ext[1]);
    }
  }
  const keyed = new Map();
  for (const e of all) {
    if (!e.codable || e.kind === "enum") continue;
    keyed.set(e.name, { keys: new Set(codingKeys(all, e.name) ?? storedKeys(e.body)), file: e.file });
  }
  CACHE = { files, all, keyed, crudeLines, extensions };
  return CACHE;
}

// --- 突き合わせる組 -----------------------------------------------------------

/**
 * `swift` の鍵名 = `builders` を `at` の位置で呼んで出た鍵名。
 *
 * `mode` は既定が `equal`(**完全一致**)。一覧の行と封筒だけは電話が**わざと部分集合**しか
 * 読まない(行は12鍵吐いて電話は5鍵しか要らない)ので `phone-subset` を許すが、
 * その差は `serverOnly` に**1つ残らず名前で**書く —— 「電話が読まない鍵が在ってもよい」に
 * すると、電話が読むべき鍵を1本落とした日も同じ緑になる。増えても減っても赤にする。
 *
 * 片側にしか無い鍵を許す為の `IGNORED` は**空**のまま置く —— 例外を1つ作った瞬間、
 * 次の1つが「前例が在る」で入る。要るようになったら理由と一緒に此処へ書く。
 */
const PAIRS = [
  { swift: "RouteLabel", builders: ["routeLabel"], at: "" },
  { swift: "ChoiceView", builders: ["choiceView"], at: "" },
  { swift: "ChoiceOption", builders: ["choiceView"], at: "options[]" },
  { swift: "ChoiceButton", builders: ["choiceView"], at: "buttons[]" },
  { swift: "SessionsResponse.PaneFault.Display", builders: ["paneFaultView"], at: "" },
  { swift: "ResultDisplay", builders: ["sendResult", "interruptResult", "choiceResult", "clearQueueResult"], at: "" },
  // ---- 一覧(2026-08-08 / 監査 S8-25 で封筒を `src/wire.mjs` へ切り出して測れるようにした)
  {
    swift: "SessionsResponse", builders: ["sessionsBody"], at: "",
    mode: "phone-subset",
    // `scan` は診断の観測値。電話は `display.scan` の1行しか描かない(web は生を使う)。
    serverOnly: ["scan"],
  },
  { swift: "SessionsResponse.OuterDisplay", builders: ["sessionsBody"], at: "display" },
  { swift: "SessionsResponse.PaneFault", builders: ["sessionsBody"], at: "paneFault" },
  {
    // 行の生産者は3本(jsonl から / 登録簿だけ / 読めなかった)+ 居場所を足す `sessionRow`。
    // **和を取る**。1本でも欠かすと、その経路にしか無い鍵(`fromRegistryOnly` / `errorCode`)が
    // 「電話に無い鍵」ではなく「誰も吐かない鍵」として静かに消える。
    swift: "SessionRow",
    builders: ["buildListing", "registryOnlySessions", "unreadableRow", "sessionRow"], at: "",
    mode: "phone-subset",
    // 電話が読まないと決めた観測値。描くのは `display` 側(§2.75)。
    serverOnly: ["project", "cwd", "lastPrompt", "turns", "metadataIncomplete", "readable", "errorCode", "live"],
  },
  { swift: "SessionRow.RowDisplay", builders: ["sessionRow"], at: "display" },
  // ---- poll と履歴(2026-08-09 / 監査 S8-26。同じ手を封筒の残りへ広げた)
  {
    // **経路2本の和**を取る。tmux だけを通すと `queued: null` の側しか出ず、
    // ワーカーだけだと `display` が消える —— どちらも「電話に無い鍵」ではなく
    // 「誰も吐かない鍵」として静かに落ちる、S8-25 で行の生産者3本を和にしたのと同じ形。
    swift: "PollResponse", builders: ["pollBodyTmux", "pollBodyWorker"], at: "",
    mode: "phone-subset",
    // 電話は経路を `cursor` の中身で判る(`PollCursor` は不透明な文字列)ので `route` を読まない。
    serverOnly: ["route"],
  },
  { swift: "PollDisplay", builders: ["pollBodyTmux"], at: "display" },
  {
    // tmux は `entries`、ワーカーは `event`。**片方ずつしか出ない鍵**なので和が要る。
    swift: "MessageItem", builders: ["messageItem"], at: "",
    mode: "phone-subset",
    // `kind` は項目の振り分け語で、電話は `PollItem` の側(enum)で読む。
    // `event` はワーカーの生の NDJSON 1行 —— v1 では描かないと決めた(brief §1-a/§1-b)。
    serverOnly: ["event", "kind"],
  },
  {
    swift: "GapItem", builders: ["gapItem"], at: "",
    mode: "phone-subset",
    // 同上・`kind` は振り分け語。`GapItem` の `CodingKeys` は `why, display, seq` で、
    // `notice` は `display` を1段剥がして取る(下の DisplayBox が受け持つ)。
    serverOnly: ["kind"],
  },
  { swift: "GapItem.DisplayBox", builders: ["gapItem"], at: "display" },
  { swift: "HistoryResponse", builders: ["historyBody"], at: "" },
  { swift: "HistoryEntry", builders: ["withWho"], at: "" },
  { swift: "HistoryEntry.EntryDisplay", builders: ["withWho"], at: "display" },
  // ---- 生存信号(2026-08-09 / 監査 S8-26 の続き)
  // **完全一致**(`mode` 無し)。認証の外へ出る唯一の応答なので、電話が読まない鍵が
  // サーバ側に生える事を許さない —— `serverOnly` を1つでも認めた瞬間、
  // 「電話は読まないから」で秘密を足せる形になる。増えたら赤、が此処では正しい既定。
  { swift: "HealthzClient.Wire", builders: ["healthzBody"], at: "" },
  // ---- 口座(2026-08-15。§9-3 で応答を文字列1本から構造へ変えた分)
  {
    // ★此の4本は**入る前に1つ直す事が在った**: 電話側の `AccountClient` は
    //   `decodeAccount` と `decodeError` の中に `struct Wire` を1つずつ持っていて、
    //   走査は修飾名で Map へ入れる = 後勝ちで潰れ、`AccountClient.Wire` は
    //   `{ error }` の1鍵の型を指していた。誤りの側を `Envelope` に改名して分けてある。
    //   同じ名前の型が同じ親の下に2つ在ると、此の検査は**片方しか測らないのに緑**になる。
    swift: "AccountClient.Wire", builders: ["accountBody"], at: "",
    mode: "phone-subset",
    // `account` = 現用名だけを入れた**出荷済みの版**(#56)向けの1鍵。新しい電話は
    //   `current` を読むので二重に読まない(`src/wire.mjs` の accountBody の註が経緯)。
    // `parseStatus` / `anomalies` = 内部の英語トークン。電話は `display` に畳まれた
    //   日本語しか読まない —— 型から外してあるのは、読める形にすると
    //   「英語のまま画面に出す」道が生えるから(`AccountClient.decodeAccount` の註)。
    serverOnly: ["account", "anomalies", "parseStatus"],
  },
  { swift: "AccountClient.Wire.Row", builders: ["accountRow"], at: "" },
  { swift: "AccountClient.Wire.Row.RowDisplay", builders: ["accountRow"], at: "display" },
  { swift: "AccountClient.Wire.Display", builders: ["accountBody"], at: "display" },
];

const IGNORED = {};

/**
 * 突き合わせていない鍵付き型と、その理由。**「見付からなかった」を書かない**。
 *
 * ★理由は1件ずつ自足させる(「同上」を使わない)。並び替えた瞬間に意味が消える
 *   書き方は、次に読む人には理由が無いのと同じになる。
 *
 * ★此処に残る理由は**全部同じ1つ**に収斂した: 鍵名を決める場所が `src/server.mjs` の中に在り、
 *   その file は import した瞬間 listen するので単体から呼べない。静的に読めば触れるが、
 *   それは「実行して出た鍵」ではなく別種の測定なので、混ぜずに空けてある。
 *
 * ★塞ぎ方は3度実演済み —— 封筒を `src/wire.mjs` の純関数へ切り出して上の組へ移す。
 *   一覧の5本(SessionsResponse / OuterDisplay / PaneFault / SessionRow / RowDisplay)が
 *   2026-08-08(S8-25)、poll と履歴の8本(PollResponse / PollDisplay / MessageItem /
 *   GapItem + DisplayBox / HistoryResponse / HistoryEntry + EntryDisplay)と
 *   生存信号の1本(HealthzClient.Wire)が 2026-08-09(S8-26)。
 *
 * ★★但し**誤り応答の4本には効かない**(2026-08-09、S8-26 phase 3 で測った)。
 *   「残りも同じ手が効く」と書きかけて、書かずに `DESIGN.md §2.81` へ
 *   「言い切れない、phase 3 で測る」と残した所。測った結果は下の4項に個別に書いた ——
 *   要点は、あの4本が読む鍵は `display` / `code`(/ `digest`)の3つだけで、
 *   **どちらも既に別の検査が測っている**事。切り出しても組が1つ増えるだけで、
 *   その上に新しい主張は1つも乗らない。効かない場所で同じ手を繰り返さない。
 *   本当に測れていなかったのは鍵名ではなく**値**で、其方は
 *   `test/wire-vocabulary-agreement.test.mjs` が持つ(負の対照 =
 *   `.harness/wire-vocabulary-agreement-controls.sh`)。
 */
const UNPAIRED = {
  ScreenBody: "poll の `screen` の**中身**。封筒(`pollBodyTmux`)は受け取った物をそのまま載せるだけで、"
    + "鍵名を決めるのは `screenBody()`(`src/server.mjs` に居て単体から呼べない)と `blockedBody()` の2本",
  "SendClient.Envelope": "送信の誤り応答の封筒(`code` + `display`)。`json()`(`src/server.mjs`)が組む。"
    + "★切り出しても得が無い事を測った(2026-08-09): `display` の**中身**は `test/e2e-local.mjs` 13-D が"
    + "生きたサーバの応答と `sendResult()` の再計算で突き合わせ済(status 違い / 本文違い / 別の口の関数の3対照付き)、"
    + "`code` は `test/recovery-codes.test.mjs` がサーバ側で守り、両側の**値**の一致は"
    + "`test/wire-vocabulary-agreement.test.mjs` が持つ。鍵名の組を足しても其の上に何も乗らない",
  "InterruptClient.Envelope": "割り込みの誤り応答の封筒。`json()` が組む。読む鍵は上と同じ2つで、"
    + "測っている者も同じ3本(e2e 13-D の `interruptResult` / recovery-codes / wire-vocabulary-agreement)",
  "ChoiceClient.Envelope": "打鍵の誤り応答の封筒。上の2つに `digest` を足した形で、やはり `json()` が組む。"
    + "`digest` は誤り応答では使われず(電話が読むのは成功側の `choiceView`)、其方は `PollDisplay` の組で測っている",
  RecoveryCode: "誤り本文の `code` だけを読む小さな型。builder が作る物ではない。"
    + "★鍵名(`code` の1つ)ではなく**焼いている値**が此の型の中身なので、測る場所は"
    + "`test/wire-vocabulary-agreement.test.mjs`(サーバの値 == 電話の値。片側だけ動けば赤)",
  "KeychainCredentialStore.Wire": "電話の中の保存形式(keychain)。線には出ない",
  "UserDefaultsDraftStore.StoredDraft": "電話の中の保存形式(打ちかけ)。線には出ない",
  SignOutNotice: "鍵切れの報せを画面間で渡す入れ物。電話の中で完結し、線には出ない",
  "ClearQueueClient.Wire": "取り消しの応答(`{dropped}` / 409 の `{error}`)。`dropped` を組むのは "
    + "`src/server.mjs` の DELETE queue 分岐(`json(res, 200, { dropped: ... })` を直に書く)で、"
    + "系統Bの builder ではない。★片側が動いた時に赤を出すのは `test/view.test.mjs` の "
    + "`clearQueueResult` の的(200 に `dropped` が必ず載る事)と、Swift 側の "
    + "`QueueViewStateTests`(載っていない 200 を『0件』でなく『不明』と読む事)の対",
  "AccountClient.Envelope": "口座の**誤り応答**の封筒(`error` の1鍵)。3つの口の 400/500 が "
    + "`json(res, N, { error: ... })` を `src/server.mjs` の中で直に組む(builder では無い)。"
    + "★400 の側は `reason`(`no-token` 等の機械語)も載せるが、電話は**わざと読まない** —— "
    + "文面を電話で組み立てない為で、`AccountRow.blocked` の註と同じ判断。"
    + "★2026-08-15 に `Wire` から改名した。同じ親の下に `Wire` が2つ在った間、上の走査は "
    + "修飾名 `AccountClient.Wire` を後勝ちで潰し、**200 の応答の型を1つも測らないまま緑**だった。"
    + "★測っているのは `test/account-routes.test.mjs` の A5(3つの口の 500 が `error` 鍵で理由を載せる)と "
    + "A9(選ぶ道の 400 が `error` で、`code` では**ない**)。どちらも原文を書き換える負の対照付き。"
    + "文面の**値**を両側で突き合わせる者は此処には居ないが要らない —— 電話は文面をサーバから"
    + "受け取ってそのまま描き、自前の語彙を1つも持たないので、ズレる2つ目の写しが存在しない",
};

/**
 * 単値で復号する `extension` の相手。鍵を持たないので分割の対象外。
 * ★増減したら赤くする —— `extension` で準拠を足す書き方は型宣言の行に何も残さないので、
 *   此処で名前を並べておかないと**鍵を持つ型が1つだけ走査から消える**道になる。
 */
const SINGLE_VALUE_EXTENSIONS = [
  "PollCursor",              // 不透明な文字列そのもの
  "RouteLabel.Kind",         // 知らない route 名は .unknown へ
  "ScreenBody.Classification", // 同・画面の分類語
  "GapWhy",                  // 同・欠落の理由
  "EntryRole",               // 同・履歴の発言者
];

// --- ① 側Aは実際に呼んで測る ---------------------------------------------------

test("側A: builder は全部呼べて、どれも鍵を1つ以上出す(空の和を一致と読ませない)", () => {
  for (const name of Object.keys(CASES)) {
    const leaves = emittedLeafNames(name);
    assert.ok(leaves.size > 0, `${name} が鍵を1つも出していない`);
  }
  for (const p of PAIRS) {
    const keys = emittedKeys(p.builders, p.at);
    assert.ok(keys.size > 0, `${p.swift} に当たる ${p.builders.join("/")}(${p.at || "直下"})が空`);
  }
});

// --- ② 入力の広さを原文で裏取りする -------------------------------------------

test("側A: builder の原文に在る鍵位置の名前は、実行で全部出ている(狭い入力で緑にしない)", () => {
  const short = {};
  for (const [name, [mod, path, anchor]] of Object.entries(MODULE_OF)) {
    const src = readFileSync(join(ROOT, path), "utf8");
    const marker = anchor ?? `export function ${name}(`;
    const body = blockAfter(src, marker);
    assert.ok(body, `${path} に ${marker} が無い(書き方が変わったら目印も直す)`);
    const code = stripComments(body);
    const written = new Set();
    for (const m of code.matchAll(/[{,]\s*([A-Za-z_$][\w$]*)\s*:/g)) written.add(m[1]);
    for (const m of code.matchAll(/[{,]\s*"([^"]+)"\s*:/g)) written.add(m[1]);
    // ★0件を「原文に鍵が無い」と読まない。引数の分解を本文と取り違えた時に此処が静かに緑になる。
    assert.ok(written.size > 0, `${name} の原文から鍵を1つも読めていない(目印 ${marker} が本文を指していない)`);
    const leaves = emittedLeafNames(name);
    const missing = [...written].filter((k) => !leaves.has(k)).sort();
    if (missing.length) short[name] = missing;
  }
  assert.deepEqual(short, {}, "原文に在るのに実行で出ない鍵 = CASES の枝が足りない(か、その鍵は誰にも届かない)");
});

// --- ③ 側Bの読み取りが型を取りこぼしていない ----------------------------------

test("側B: Swift の走査が Decodable 型を取りこぼしていない", { skip }, () => {
  const t = phoneTypes();
  assert.ok(t.files.length > 0, "Swift を1本も読めていない");
  const structured = t.all.filter((e) => e.codable).length;
  assert.equal(
    structured,
    t.crudeLines,
    `構造で拾った Decodable 型 ${structured} 件と、行で数えた ${t.crudeLines} 件が合わない ` +
      "(総称型や複数行の準拠並びなど、brace の走査が読めない書き方が入った合図)",
  );
  assert.deepEqual([...t.extensions].sort(), [...SINGLE_VALUE_EXTENSIONS].sort(),
    "extension で Decodable を足した型が増減した。単値でなく鍵を持つなら PAIRS/UNPAIRED に入れる");
});

// --- ④ 本体: 鍵名が一致する ---------------------------------------------------

test("24組の鍵名が、サーバの実出力と一字一句一致する", { skip }, () => {
  const t = phoneTypes();
  const drift = {};
  for (const p of PAIRS) {
    const phone = t.keyed.get(p.swift);
    assert.ok(phone, `電話側に ${p.swift} が居ない(改名か削除)`);
    const server = emittedKeys(p.builders, p.at);
    // 電話が名乗る鍵をサーバが吐いていない = **どの mode でもズレ**。画面が黙って痩せる側。
    const onlyPhone = [...phone.keys].filter((k) => !server.has(k)).sort();
    // サーバにしか無い鍵は、`equal` なら全部ズレ。`phone-subset` なら**宣言と完全一致**を要求する
    // (増えた = 電話が読み落とした候補。減った = 宣言が古い。どちらも人が見るべき差)。
    const extra = [...server].filter((k) => !phone.keys.has(k)).sort();
    const allowed = p.mode === "phone-subset" ? [...p.serverOnly].sort() : [];
    const onlyServer = p.mode === "phone-subset"
      ? { got: extra, declared: allowed }
      : extra;
    const serverDrift = p.mode === "phone-subset"
      ? extra.join("\u0000") !== allowed.join("\u0000")
      : extra.length > 0;
    if (onlyPhone.length || serverDrift) drift[p.swift] = { onlyPhone, onlyServer };
  }
  assert.deepEqual(drift, {}, "電話の Decodable とサーバの出力で鍵名がズレた(復号は通るので、画面が痩せるだけで気付けない)");
});

// --- ⑤ 0件を「全部一致」と読ませない ------------------------------------------

test("走査が見付けた鍵付き型は、突き合わせたか理由を書いたかのどちらか(全域・排他)", { skip }, () => {
  const t = phoneTypes();
  const paired = PAIRS.map((p) => p.swift);
  const unpaired = Object.keys(UNPAIRED);
  const declared = new Set([...paired, ...unpaired]);
  assert.equal(declared.size, paired.length + unpaired.length, "PAIRS と UNPAIRED に同じ型が両方居る");

  const found = [...t.keyed.keys()];
  const undeclared = found.filter((n) => !declared.has(n)).sort();
  const phantom = [...declared].filter((n) => !t.keyed.has(n)).sort();
  assert.deepEqual(undeclared, [], "新しい Decodable 型がどちらの箱にも入っていない");
  assert.deepEqual(phantom, [], "宣言に在る型が Swift から消えた(改名なら宣言も直す)");
  assert.equal(found.length, declared.size);
  assert.ok(paired.length >= 20 && unpaired.length > 0);
  for (const [k, v] of Object.entries(UNPAIRED)) assert.ok(v.length >= 10, `${k} の理由が短すぎる`);
});

test("例外表は空のまま(片側にしか無い鍵を1つも許していない)", () => {
  assert.deepEqual(IGNORED, {});
  const used = new Set(PAIRS.flatMap((p) => p.builders));
  const idle = Object.keys(CASES).filter((n) => !used.has(n)).sort();
  assert.deepEqual(idle, [], "CASES に在るのにどの組でも使われていない builder(測ったつもりの死に枝)");
});

// --- ⑦ 切り出した builder を、本番のハンドラが本当に通っている --------------------

/**
 * 封筒を純関数へ出しても、`src/server.mjs` がハンドラの中で literal を組み直せば
 * 上の照合は**全部飾りになる**(検査は builder を測り、線に出るのは別物)。
 * 実行では捕まえられない —— server.mjs は import した瞬間 listen するので。だから原文に錨を打つ。
 */
test("ハンドラは切り出した builder を通って封筒を組んでいる(直書きへ戻っていない)", () => {
  const src = stripComments(readFileSync(join(ROOT, "src", "server.mjs"), "utf8"));
  for (const call of [
    "sessionsBody({", "sessionRow(", "unreadableRow({",
    // S8-26 で切り出した6本。`.map(withWho)` だけ呼び方が違うのは、これがハンドラ側で
    // **束に対して**掛かる為(封筒の引数として渡る形が本番の姿)。
    "historyBody({", "messageItem({", "pollBodyTmux({", "pollBodyWorker({", "gapItem(", ".map(withWho)",
    "healthzBody({",
    // 口座(2026-08-15)。3つの口が同じ封筒を通る —— `GET /api/account` / `POST …/select` /
    // `POST …/next`。此処が直書きへ戻ると、電話が読む鍵の照合が丸ごと飾りになる。
    "accountBody(",
  ]) {
    assert.ok(src.includes(call), `src/server.mjs が ${call} を通っていない = 封筒が直書きへ戻り、上の照合が飾りになった`);
  }
  assert.match(src, /json\(res,\s*200,\s*sessionsBody\(/, "`/api/sessions` の 200 が `sessionsBody` を通っていない");
  assert.match(src, /json\(res,\s*200,\s*historyBody\(/, "`/history` の 200 が `historyBody` を通っていない");
  // ★`/healthz` は認証の**外**。ここが直書きへ戻ると、鍵を1本足す改修が
  //   電話側の照合を1つも通らずに認証の外へ出る道になる。
  assert.match(src, /json\(res,\s*200,\s*healthzBody\(/, "`/healthz` の 200 が `healthzBody` を通っていない");
  // ★口座は**3つ数える**。`assert.match` は1本でも在れば緑になるので、3つの口のうち
  //   2つが直書きへ戻っても気付けない —— 実際、線に出る形が口ごとに違えば
  //   「読めた時だけ切替が出る」という電話側の判断が口によって効かなくなる。
  //   4つ目の口を足す時は此処が赤くなる = その口も封筒を通すか、通さない理由を書く手が要る。
  assert.equal((src.match(/json\(res,\s*200,\s*accountBody\(/g) ?? []).length, 3,
    "`/api/account` `/api/account/select` `/api/account/next` の 200 が3本とも `accountBody` を通っていない");
});

test("`phone-subset` の宣言が、緩める言い訳になっていない", () => {
  for (const p of PAIRS) {
    if (p.mode === undefined) {
      assert.equal(p.serverOnly, undefined, `${p.swift}: mode を書かずに serverOnly だけ在る(既定は完全一致)`);
      continue;
    }
    assert.equal(p.mode, "phone-subset", `${p.swift}: 知らない mode`);
    // 空の `serverOnly` は「完全一致」を回りくどく書いただけ。読む人に mode を疑わせる。
    assert.ok(Array.isArray(p.serverOnly) && p.serverOnly.length > 0,
      `${p.swift}: phone-subset なのに serverOnly が空(なら mode を消す)`);
    assert.equal(new Set(p.serverOnly).size, p.serverOnly.length, `${p.swift}: serverOnly に重複`);
  }
  // 部分集合を許した組を**並び順ごと**に固定する。増える時は此処が赤くなり、理由を書く手が要る。
  assert.deepEqual(PAIRS.filter((p) => p.mode === "phone-subset").map((p) => p.swift),
    ["SessionsResponse", "SessionRow", "PollResponse", "MessageItem", "GapItem", "AccountClient.Wire"]);
});
