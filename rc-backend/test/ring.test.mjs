// SSE 再接続の追いつき用リングバッファ — テスト先行(tdd-gate の型)。
//
// 契約(spec §In-4): ストリーム切断→再接続で取りこぼした分を seq 番号で追いつく。
// 本家 RC の「再構築中の更新はキューして回復後に配送」(teardown §4, v2.1.207 の修正)を
// 最初から入れるための部品。
import { test } from "node:test";
import assert from "node:assert/strict";
import { EventRing } from "../src/ring.mjs";

test("push は連番 seq を振る(1始まり)", () => {
  const r = new EventRing(4);
  assert.equal(r.push({ a: 1 }), 1);
  assert.equal(r.push({ a: 2 }), 2);
});

test("since(n) は n より後の全イベントを順に返す", () => {
  const r = new EventRing(8);
  for (let i = 1; i <= 5; i++) r.push({ i });
  const got = r.since(2);
  assert.deepEqual(got.map((e) => e.seq), [3, 4, 5]);
  assert.deepEqual(got.map((e) => e.data.i), [3, 4, 5]);
});

test("容量超過で古い物から落ち、落ちた範囲の since は gap を申告する", () => {
  const r = new EventRing(3);
  for (let i = 1; i <= 6; i++) r.push({ i });
  // 保持は 4,5,6。seq=1 からの追いつきは不可能 = gap。
  const res = r.since(1);
  assert.equal(res.gap, true); // 呼び手は「履歴を読み直せ」へ倒す
  assert.deepEqual(res.map((e) => e.seq), [4, 5, 6]);
});

test("gap なしの場合 gap フラグは falsy", () => {
  const r = new EventRing(8);
  r.push({});
  r.push({});
  // ★先に「差分が出ている」事を言う。`since` が空配列を返す実装でも `[].gap` は undefined =
  //   falsy なので、下の1行だけでは**何も返さない壊れ方**を緑で通す(2026-08-04、§2.35)。
  assert.equal(r.since(1).length, 1, "差分が出ていない = gap を測れる状態ですらない");
  assert.ok(!r.since(1).gap);
});

test("since(最新) は空配列", () => {
  const r = new EventRing(4);
  r.push({});
  // ★積めた事を先に確かめる。push が効いていない木でも「空配列」は満たされる。
  assert.equal(r.since(0).length, 1, "積んだ物が入っていない = 空配列の意味が変わる");
  assert.deepEqual(r.since(1), []);
});

test("空リングの since(0) は空・gap なし", () => {
  const r = new EventRing(4);
  const res = r.since(0);
  assert.equal(res.length, 0);
  assert.ok(!res.gap);
});

// ── 以下は変異 R5 の素通りで見つけた穴(2026-08-02)──────────────────────────
// `src/ring.mjs` に的を置くまで、この部品の単体は**一度も強さを測られていなかった**。
// R5 = 構築時の capacity 検査を丸ごと外す変異。**6件の検査が全部緑のまま通った**。
// なぜ重いか: capacity=0 で構築できると、push の度に `buf.length(1) > 0` で即座に
// shift されるので**リングが常に空**になる。例外も出ず、gap も立たない(空リングは
// gap を立てない仕様)。電話から見ると「再接続したが差分は無い」= **取りこぼしが
// 黙って消える**。この部品が防ぐ筈だった当の事故が、静かに起きる。
test("capacity が正の整数でなければ構築時に throw する(fail-closed)", () => {
  // ★`undefined` は入れない: 既定引数 `capacity = 512` が効くので throw しないのが正。
  //   (下の「既定で構築できる」検査がその挙動を固定している)
  for (const bad of [0, -1, 1.5, NaN, Infinity, "8", null]) {
    assert.throws(
      () => new EventRing(bad),
      /capacity must be a positive integer/,
      `capacity=${String(bad)} は撥ねられねばならない`,
    );
  }
});

test("既定(引数なし)は 512 で構築できる", () => {
  // 上の検査を「常に throw する」形で満たしてしまわない為の対。
  const r = new EventRing();
  assert.equal(r.capacity, 512);
  assert.equal(r.push({}), 1);
});

test("★capacity=0 を許すと追いつきが恒久的に死ぬ(R5 が防いでいる事故の実演)", () => {
  // 検査を外した世界を手で作り、何が起きるかを固定する。
  // この検査は「throw する事」でなく「throw しないと何が壊れるか」を記録している。
  //
  // ★2026-08-02、ここを最初「取りこぼしが黙って消える(gap も立たない)」と書いて
  //   **検査に否定された**。実際は buf が空でも nextSeq は進んでいるので
  //   oldestHeld = nextSeq となり gap は**立つ**。壊れ方は「黙って消える」ではなく
  //   「**永久に gap**」= 電話は再接続の度に /history 全体の読み直しへ倒され、
  //   この部品が存在する意味(差分で追いつく)が恒久的に失われる。安全側ではあるが死んでいる。
  const broken = Object.create(EventRing.prototype);
  broken.capacity = 0;
  broken.buf = [];
  broken.nextSeq = 1;
  for (let i = 1; i <= 3; i++) EventRing.prototype.push.call(broken, { i });
  const res = EventRing.prototype.since.call(broken, 0);
  assert.equal(res.length, 0, "3件積んだのに0件 = 全部落ちている");
  assert.equal(res.gap, true, "gap は立つ = 壊れ方は『恒久 gap』であって『黙って消える』ではない");
});

// ── 量の門(2026-08-04)────────────────────────────────────────────────────
// 件数の門は**1件の大きさを問わない**。tool 結果が数 MB になる 1 行が 256 件 x 数 MB で
// 常駐し、会話は `feeds` / `WorkerManager.rings` に溜まり続ける(掃除する口が無い)ので、
// 上限が件数だけだと常駐量は**会話数 x 1件の大きさ**で伸びる。
// 落とす向きは件数の門と**同じ「古い方から」**にしてある = 溢れは既存の gap 判定に
// そのまま乗る。ここが逆向き(新しい方から)だと、gap が立たないまま列が欠ける。
const big = (n) => ({ blob: "x".repeat(n) });

test("量の上限を超えたら古い方から落ちる(件数にはまだ余裕が在っても)", () => {
  const r = new EventRing(100, { maxBytes: 400 });
  for (let i = 1; i <= 6; i++) r.push(big(100)); // 1件 ≒ 113 byte
  assert.ok(r.buf.length < 6, "件数に余裕が在っても量で落ちねばならない");
  assert.ok(r.bytes <= 400, `合計が上限を超えたまま: ${r.bytes}`);
});

test("★量で落ちた分も gap を申告する(件数で落ちた時と同じ意味論)", () => {
  const r = new EventRing(100, { maxBytes: 400 });
  for (let i = 1; i <= 6; i++) r.push(big(100));
  const res = r.since(1);
  assert.equal(res.gap, true, "量で消えた列を『連続』として渡すと電話に嘘の履歴が出る");
});

test("合計の帳簿が実際の中身と一致する(増減で持っているので狂うと静かに壊れる)", () => {
  const r = new EventRing(100, { maxBytes: 100_000 });
  for (let i = 1; i <= 20; i++) r.push({ i, pad: "あ".repeat(i) }); // 多バイト文字を混ぜる
  const recomputed = r.buf.reduce((a, e) => a + e.bytes, 0);
  assert.equal(r.bytes, recomputed, "帳簿と中身がずれている = 以後の判定が全部ずれる");
});

test("計測は UTF-8 のバイト数(UTF-16 の文字数ではない)", () => {
  // 日本語は UTF-8 で 3 byte / UTF-16 の length では 1。ここを length で測ると
  // Tom の会話(日本語)で**3 倍過小評価**し、量の門が実質効かなくなる。
  const r = new EventRing(10, { maxBytes: 100_000 });
  r.push("あ"); // JSON は `"あ"` = 3 + 引用符 2 = 5 byte
  assert.equal(r.buf[0].bytes, 5, "UTF-8 で測っていない");
});

test("maxBytes が正の整数でなければ構築時に throw する(capacity と同じ形の門)", () => {
  for (const bad of [0, -1, 1.5, NaN, Infinity, "8", null]) {
    assert.throws(
      () => new EventRing(8, { maxBytes: bad }),
      /maxBytes must be a positive integer/,
      `maxBytes=${String(bad)} は撥ねられねばならない`,
    );
  }
  // 既定(未指定)は構築できる — 上を「常に throw」で満たしてしまわない為の対。
  assert.ok(new EventRing(8).maxBytes > 0);
});

test("JSON にできない物は**採番の前に**撥ねる(seq に穴を空けない)", () => {
  const r = new EventRing(8, { maxBytes: 100_000 });
  assert.equal(r.push({ ok: 1 }), 1);
  const cyc = {};
  cyc.self = cyc;
  assert.throws(() => r.push(cyc), /circular|Converting circular/i);
  assert.throws(() => r.push(undefined), /JSON-serializable/);
  // ★ここが本題: 撥ねた後も次の seq は 2。飛んでいると、電話の栞が存在しない番号を
  //   指し、`since()` は「その番号より後」を返すので**欠落が gap にならない**。
  assert.equal(r.push({ ok: 2 }), 2, "撥ねた分で seq が飛んだ = 静かな取りこぼしの穴");
  assert.equal(r.buf.length, 2);
});

test("★残る穴を名指しで固定: 1件で上限を超えるイベントは次の push まで残る", () => {
  // 「最新1件は落とさない」の代償。ここが緑である事が仕様であって、事故ではない。
  // 落とす設計にしない理由は src/ring.mjs の push の注記(Codex 2026-08-04 の反論と撤回条件)。
  const r = new EventRing(100, { maxBytes: 200 });
  r.push(big(50));
  r.push(big(5000)); // 単体で上限超え
  assert.equal(r.buf.length, 1, "巨大な1件だけが残る");
  assert.ok(r.bytes > r.maxBytes, "= 常駐量の天井は maxBytes ではなく max(maxBytes, 最大の1件)");
  // 次の push で追い出される事まで見る(= 恒久的に居座りはしない)。
  r.push(big(10));
  assert.ok(r.bytes <= r.maxBytes, "次の push で追い出されていない = 本当に居座る");
  // そして buf は空にならない = 「buf が空 ⟹ nextSeq === 1」が保たれる。
  assert.ok(r.buf.length >= 1);
});

test("★capacity>=1 が『buf が空 ⟹ nextSeq===1』を成り立たせている(R3 の等価性の土台)", () => {
  // 変異 R3(空リングの起点を nextSeq でなく 0 と読む)は素通りした。調べると、
  // 差が出る入力は `since(-1)` の1点だけで、負の seq は `tail.mjs` の `^\d+$` で
  // 撥ねられるので**到達しない** = 等価変異(検査の穴ではない)。
  // ただしその議論は「buf が空なら nextSeq は必ず 1」に依存していて、それを保証して
  // いるのは R5 の capacity>=1 検査。**片方の等価性がもう片方の守りに乗っている**ので、
  // 土台の方を検査として固定しておく(R5 を消すと R3 の等価性も静かに崩れる)。
  const r = new EventRing(1);
  assert.equal(r.buf.length, 0);
  assert.equal(r.nextSeq, 1);
  r.push({});
  assert.ok(r.buf.length >= 1, "capacity>=1 なら push 後に buf が空になる事は無い");
});
