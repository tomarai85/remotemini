import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { createIdemStore, validKey, IDEM_REFUSAL, IDEM_MAX } from "../src/idem.mjs";

// ★この検査が守る一線は2つ。どちらも「静かに間違える」形を潰す為に在る。
//   1. **打つ前に予約し、打った後に記録する**。位置を間違えると、落ちた時に永久に
//      打てなくなるか、同時の2本が両方通るかのどちらかになる。
//   2. **同じ鍵で違う本文を黙って通さない**。通すと1回目の結果が2回目の応答として
//      返り、一番診断しにくい嘘になる。

const S = (o) => createIdemStore(o);

test("初回は通る", () => {
  assert.deepEqual(S().begin("abcd1234", "hello"), { go: true });
});

test("★打っている最中の再送は通さない(結果も返さない)", () => {
  const s = S();
  s.begin("abcd1234", "hello");
  const r = s.begin("abcd1234", "hello");
  assert.equal(r.go, false);
  assert.equal(r.why, "in-flight");
  assert.equal(r.result, undefined, "まだ結果が無いのに結果を返した");
});

test("★打った後の再送は、打ち直さず1回目の結果を返す", () => {
  const s = S();
  s.begin("abcd1234", "hello");
  s.finish("abcd1234", { accepted: true, seq: 7 });
  const r = s.begin("abcd1234", "hello");
  assert.equal(r.go, false);
  assert.equal(r.why, "duplicate");
  assert.deepEqual(r.result, { accepted: true, seq: 7 });
});

test("★★同じ鍵で違う本文は断る(1回目の結果を2回目の答えにしない)", () => {
  const s = S();
  s.begin("abcd1234", "hello");
  s.finish("abcd1234", { accepted: true });
  const r = s.begin("abcd1234", "something else entirely");
  assert.equal(r.why, "key-reused");
  assert.equal(r.result, undefined, "違う本文に1回目の結果を返した");
});

test("別の鍵なら同じ本文でも通る(意図的な2回打ちを塞がない)", () => {
  const s = S();
  s.begin("abcd1234", "same text");
  s.finish("abcd1234", { ok: true });
  assert.deepEqual(s.begin("efgh5678", "same text"), { go: true });
});

test("★失敗して予約を外したら、同じ鍵で打ち直せる", () => {
  const s = S();
  s.begin("abcd1234", "hello");
  s.abandon("abcd1234");
  assert.deepEqual(s.begin("abcd1234", "hello"), { go: true },
    "外したのに打てない = 原因を直しても永久に打てないままになる");
});

test("★憶えている時間を過ぎたら忘れる(再送が届かないほど遅い時)", () => {
  let t = 1000;
  const s = S({ ttl: 100, now: () => t });
  s.begin("abcd1234", "hello");
  s.finish("abcd1234", { ok: true });
  t += 500;
  assert.deepEqual(s.begin("abcd1234", "hello"), { go: true });
});

test("★件数に上限が在る(長く動いている机で静かに太らない)", () => {
  const s = S({ max: 3 });
  for (let i = 0; i < 10; i++) { const k = `key${i}0000`; s.begin(k, "x"); s.finish(k, {}); }
  assert.ok(s.size() <= 3, `上限を超えた: ${s.size()}`);
});

test("既定の上限は現実的な大きさ", () => {
  assert.ok(IDEM_MAX >= 100 && IDEM_MAX <= 10000);
});

// ---- 鍵の形 --------------------------------------------------------------------

test("★鍵の形を検める(電話が作る物なので受け取る前に見る)", () => {
  assert.equal(validKey("abcd1234"), true);
  for (const bad of ["short", "", null, 42, "../etc/passwd", "has space", "a".repeat(65), "セッション"]) {
    assert.equal(validKey(bad), false, String(bad));
  }
});

// ---- 断りの文 ------------------------------------------------------------------

test("★断りの文に本文も指紋も出さない", () => {
  for (const [k, v] of Object.entries(IDEM_REFUSAL)) {
    assert.ok(v.length > 10, k);
    assert.doesNotMatch(v, /[0-9a-f]{16,}/, `${k} に指紋らしき物が出ている: ${v}`);
  }
});

// ---- 呼び手の側(位置を間違えていないか)-----------------------------------------

test("★★送らずに帰る枝は全部 予約を外している(原文で数える)", () => {
  // 位置の間違いは動かして測りにくい(落ちた時の枝はそう簡単に踏めない)ので、
  // **原文の形**で見る。この検査が守るのは「1本だけ外し忘れる」型。
  const src = readFileSync(join(process.cwd(), "src", "server.mjs"), "utf8");
  const start = src.indexOf('if (action === "messages"');
  const end = src.indexOf('if (action === "interrupt"', start);
  assert.ok(start > 0 && end > start, "messages の道が見つからない(形が変わったら此処も直す)");
  const block = src.slice(start, end);

  const lines = block.split("\n");
  const missing = [];
  for (let i = 0; i < lines.length; i++) {
    if (!/return json\(res, (400|409|500)/.test(lines[i])) continue;
    // 予約を取る前(begin より上)の脱出は外す物が無い = 対象外
    const upto = lines.slice(0, i).join("\n");
    if (!upto.includes("idem.begin")) continue;
    // ★`begin` が「通さない」と答えた枝は、予約を**取っていない**ので外す物が無い。
    //   `idemHeld` が立つのは `go === true` の時だけ、という形がそれを保証している。
    if (/IDEM_REFUSAL/.test(lines[i])) continue;
    const near = lines.slice(Math.max(0, i - 3), i + 1).join("\n");
    if (!near.includes("idem.abandon")) missing.push(lines[i].trim().slice(0, 60));
  }
  assert.deepEqual(missing, [],
    "送らずに帰るのに予約を外していない枝が在る = その鍵で二度と打てなくなる");
});

test("★★打てた枝は 予約を外さずに『済んだ』を書いている", () => {
  const src = readFileSync(join(process.cwd(), "src", "server.mjs"), "utf8");
  const start = src.indexOf('if (action === "messages"');
  const end = src.indexOf('if (action === "interrupt"', start);
  const block = src.slice(start, end);
  const finishes = (block.match(/idem\.finish\(/g) || []).length;
  // ★重複の枝は数えない。あれは**1回目の記録をそのまま返す**枝で、
  //   もう一度書く物が無い(書くと `at` が動いて TTL の起点がずれる)。
  const lines = block.split("\n");
  const accepted = lines.filter((l, i) => {
    if (!/return json\(res, 202/.test(l)) return false;
    const near = lines.slice(Math.max(0, i - 6), i + 1).join("\n");
    return !/g\.why === "duplicate"/.test(near);
  }).length;
  assert.equal(finishes, accepted,
    `打てた枝 ${accepted} 本に対して finish が ${finishes} 本(どちらかを数え漏らしている)`);
});

test("★★重複は1回目と同じ status で返す(届いている物を失敗の顔で見せない)", () => {
  // 2026-08-26 に本番で実測して直した: 200 で返していて、`sendResult` が
  // 「知らない形」と読み、電話に error として出た。実際には届いているので、
  // Tom はもう一度押す = 重複を防ぐ機能が重複を誘発していた。
  const src = readFileSync(join(process.cwd(), "src", "server.mjs"), "utf8");
  const i = src.indexOf('g.why === "duplicate"');
  assert.ok(i > 0, "重複の枝が見つからない");
  const near = src.slice(i, i + 500);
  assert.match(near, /json\(res, 202/, "重複を 202 以外で返している");
  assert.doesNotMatch(near, /json\(res, 200/, "200 で返す枝が残っている");
});


// ============================================================================================
// 再起動で忘れるのは **意図的な設計**であって、直すべき穴ではない(2026-08-27 に固定)
//
// ★経緯を残す価値が在るので書く: このセッションは `const m = new Map()` という機構だけを
//   読んで「机の再起動を跨いだ再送が二重注入する欠陥」と報告し、DESIGN.md にも「守りの穴」
//   として書いた。**その6行上に理由が在った**。読まなかったのはこちらの落ち度。
//
//   `server.mjs` の `const idem = createIdemStore()` の直上:
//     「file に落とさないのは、落とせば『何をいつ送ったか』の跡が机に残るから ——
//       この repo が明示的に選んでいる『打った物を残さない』線を越える。
//       再起動で忘れるが、忘れて困るのは『再起動を跨いだ再送』だけで、
//       それは電話から見て別の送信として扱われる方が正しい。」
//
//   つまり永続化しないのは privacy 側の裁定で、再起動跨ぎの扱いも裁定済み。
//   ★固定しないと、次に読む者が同じ順序で誤読して persist を足しかねない ——
//   この線引きを**再検討せずに**越える形で。検査を赤にすれば、越えるなら意図的になる。
// ============================================================================================

test("★再起動を跨いだ再送は意図的に新しい送信として通す(忘却は設計であって穴ではない)", () => {
  const before = S();
  assert.deepEqual(before.begin("restart01", "同じ本文"), { go: true });
  before.done?.("restart01", { ok: true });

  // 新しい store = 机を落として上げた後。**前の記憶を引き継がない**のが正しい。
  const after = S();
  assert.deepEqual(after.begin("restart01", "同じ本文"), { go: true },
    "再起動後の store が前の送信を覚えている —— 永続化が入った。" +
    "それは『打った物を残さない』線を越える変更なので、越えるなら意図的にやり、" +
    "server.mjs の裁定コメントごと書き換える事");
});

test("記憶は file へ出ない(打った物の跡を机に残さない線)", () => {
  const src = readFileSync(join(process.cwd(), "src", "idem.mjs"), "utf8");
  assert.doesNotMatch(src, /writeFileSync|appendFileSync|createWriteStream|renameSync/,
    "idem.mjs が file を書いている —— 指紋と時刻が机に残る");
});

test("永続化しない理由が呼び出し口に残っている(裁定が消えたら気づく)", () => {
  const src = readFileSync(join(process.cwd(), "src", "server.mjs"), "utf8");
  const i = src.indexOf("createIdemStore()");
  assert.ok(i > 0, "createIdemStore の呼び出しが見つからない");
  // 呼び出しの**直前**に理由が在る事を測る。離れた場所の一致では意味が無い。
  const before = src.slice(Math.max(0, i - 700), i);
  assert.match(before, /打った物を残さない/,
    "永続化しない理由が呼び出し口から消えた —— 機構だけ読む者が穴と誤読する" +
    "(2026-08-27 に実際に起きた)");
});
