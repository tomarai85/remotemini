// 本番の実データを**表示層にそのまま通す**常設の検査。
//
// なぜ在るか(2026-08-02): この日の表示層の欠陥4件は、全部「読む」では出なかった。
// `view.mjs` を読んで気付いたのは1件だけ。残り3件は edith の `/api/sessions` を
// そのまま `routeLabel()` に通して**印字して**初めて出た:
//   1. blocked の札が **92文字**(他の札は9-10文字。丸い札に入らない)。しかも6行が同じ文
//   2. `activity:"unknown"` を「静か」と断定していた(観測できなかっただけ)
//   3. `screen:"CHOICE"` が一覧から見えない(`sessionRow` が `label.screen` を捨てる)
//   4. `route:"gone"` に分岐が無く「様子を読めていません」に落ちる
// だから**通す物自体を常設**にする。手で書いた入力では、この4件は1件も出なかった。
//
// fixture = edith 実機 2026-08-02 09:56 の `/api/sessions` の payload そのまま。
// PII 走査済(メール0・トークン様0。陽性対照付きで走査器が生きている事も確認)。
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { routeLabel, scanLine, subtitleOf } from "../src/view.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const RAW = JSON.parse(readFileSync(join(HERE, "fixtures", "api-sessions-live-20260802.json"), "utf8"));
const PL = RAW.payload;

const KINDS = new Set(["tmux", "worker", "blocked", "choice", "unknown"]);
const CODES = /(unregistered|ambiguous|cwd-mismatch|pane-gone|tmux-unavailable|panes-unreadable|stale)/;

test("実データ: 14行すべてが既知の kind に落ちる(例外も「様子を読めていません」も出さない)", () => {
  assert.equal(PL.sessions.length, 14, "fixture が差し替わったら期待も測り直す");
  for (const s of PL.sessions) {
    const l = routeLabel(s.live);
    assert.ok(KINDS.has(l.kind), `未知の kind: ${l.kind} (${s.id})`);
    assert.notEqual(l.kind, "unknown", `既定に落ちた行が在る: ${s.id} ${JSON.stringify(s.live)}`);
  }
});

test("★実データ: 一覧の札が短い(92文字の札を現物で塞ぐ)", () => {
  // 実測 2026-08-02: blocked 6行の札が**全部同じ92文字**だった。
  // 他の札は9-10文字。`border-radius:999px / font-size:12px` の丸い札に入る長さではない。
  const long = PL.sessions
    .map((s) => ({ id: s.id.slice(0, 8), short: routeLabel(s.live).short }))
    .filter((r) => r.short.length > 30); // 英語化(2026-08-17)で 12→30 字
  assert.deepEqual(long, [], `一覧の札が長い行: ${JSON.stringify(long)}`);
  // 陰性対照 — 「札を全部空にする」実装ならこの検査は緑になるので、中身も測る。
  for (const s of PL.sessions) {
    const l = routeLabel(s.live);
    assert.ok(l.short.length >= 2, `札が空: ${s.id}`);
    assert.ok(!CODES.test(l.short), `理由コードが札に生で出た: ${l.short}`);
  }
});

test("★実データ: 説明はサーバの文のまま(出所を1つに保つ)", () => {
  const blocked = PL.sessions.filter((s) => (s.live || {}).route === "blocked");
  assert.equal(blocked.length, 6, "この日の実データは blocked 6行");
  for (const s of blocked) {
    const l = routeLabel(s.live);
    assert.equal(typeof l.short, "string", "★札が無い実装で notEqual が素通りしない為");
    assert.equal(l.text, s.live.message, "サーバの文を書き換えない");
    assert.ok(l.text.length > 40, "説明の方は短くしない(短くするのは札だけ)");
    assert.notEqual(l.short, l.text, "★札と説明は別物 = 置き場所が違う");
  }
});

test("★実データ: 観測できなかった事を「静か」と書かない", () => {
  // `activity` の値域は observed|unknown の2値。**どちらも「待機中」を意味しない**
  // (inject.mjs の M3' と server.mjs の2箇所が揃ってそう書いている)。
  // 実測(2026-08-03 の測り直し): 1枚あたり **18-39%** 取りこぼす。一覧は1枚しか撮らない。
  for (const s of PL.sessions) {
    const l = routeLabel(s.live);
    assert.doesNotMatch(l.short, /静か/, `${s.id}: 札が待機中を主張した`);
    assert.doesNotMatch(l.text, /静か/, `${s.id}: 説明が待機中を主張した`);
  }
  // この日の実データに tmux は1行。その行が「観測できていない」と言えている事。
  const t = PL.sessions.filter((s) => (s.live || {}).route === "tmux");
  assert.equal(t.length, 1);
  assert.match(routeLabel(t[0].live).text, /Status unknown|No activity|Active|input|limit/);
});

test("実データ: 走査の数字を埋めない(668/668 をそのまま出す)", () => {
  assert.equal(scanLine(PL.scan), "Read 668 of 668 files; 0 reused cached results.");
});

test("実データ: 副題は読み残しを「発言なし」と言い換えない", () => {
  for (const s of PL.sessions) {
    const sub = subtitleOf(s);
    if (s.metadataIncomplete && !s.lastPrompt) assert.match(sub, /beyond the read range/);
    if (!s.metadataIncomplete && !s.lastPrompt) assert.match(sub, /No messages yet/);
  }
});
