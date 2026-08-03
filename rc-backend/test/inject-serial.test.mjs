// ペインの鍵(H1) — 「同じ物理キーボードを2人で叩かない」を**測る**検査。
// DESIGN.md §2.18-1/2。`inject.mjs` 単体でも `mutex.mjs` 単体でもなく、**2つを繋いだ時の性質**を見る。
//
// ★この file の作法: **守りを外した版を同じ検査に通す**(`NO_LOCK`)。
//   緑だけでは「鍵が効いている」ではなく「鍵が邪魔をしていない」しか言えない。
//   鍵を抜いた注入器で**同じ検査が赤になる**事を並べて初めて、この検査が鍵を見ている証拠になる。
//   (= 陰性対照を検査の中に持たせた形。変異runner を回さなくても、この file 単体で成り立つ)
//
// 偽 tmux は**状態を持つ**。実機と同じで:
//   - `send-keys -l` は入力欄に**足す**(消さない = だから混ざると食い込む)
//   - `Enter` は入力欄を空にする(取り込まれた)
//   - `Escape` も入力欄を空にする —— ★ここが割り込みを同じ鍵に入れた理由。
//     送信側から見ると Enter で消えたのか Escape で消えたのか**画面では区別が付かない**。
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { TmuxInjector, composerBox } from "../src/inject.mjs";
import { makeKeyedMutex, MUTEX_BUSY, MUTEX_ABORTED } from "../src/mutex.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const screen = (name) => readFileSync(join(HERE, "fixtures", "screens", `${name}.txt`), "utf8");

/** 実機 fixture の入力欄の箱に本文を載せる(`inject.test.mjs` と同じ作り方)。 */
function withComposerBody(base, body) {
  const box = composerBox(base);
  assert.ok(box, "前提: 元の画面に入力欄の箱がある事");
  const lines = base.split("\n");
  const head = lines[box.head].replace(/(❯\s?).*$/, `$1${body}`);
  return [...lines.slice(0, box.head), head, ...lines.slice(box.head + 1)].join("\n");
}

/**
 * 入力欄の中身を**本当に持つ**偽 tmux。ペインごとに別の中身。
 * 実機の「打鍵は足し算 / Enter と Escape は空にする」だけを模す。
 */
function livePane(base) {
  const calls = [];
  const body = new Map(); // pane -> 入力欄の中身
  const get = (p) => body.get(p) || "";
  const run = (args) => {
    calls.push(args);
    const pane = args[2];
    if (args[0] === "capture-pane") {
      const b = get(pane);
      return b ? withComposerBody(base, b) : base;
    }
    if (args[0] === "send-keys") {
      if (args[3] === "-l") body.set(pane, get(pane) + args[5]);
      else if (args[3] === "Enter" || args[3] === "Escape") body.set(pane, "");
    }
    return "";
  };
  return { calls, run, runStrict: run, bodyOf: get };
}

/** そのペインへの打鍵だけを、読める形で並べる。 */
const keys = (t, pane) =>
  t.calls
    .filter((c) => c[0] === "send-keys" && c[2] === pane)
    .map((c) => (c[3] === "-l" ? `打:${c[5]}` : c[3]));

/** ★守りを外した注入(陰性対照)。鍵を取らずにそのまま走らせる。 */
const NO_LOCK = { run: (_key, fn) => fn() };

const base = screen("idle-boot");

test("★同じペインへの2本の送信は混ざらない(打鍵の順が A→A→B→B になる)", async () => {
  const t = livePane(base);
  const inj = new TmuxInjector({ tmux: t });

  const [ra, rb] = await Promise.all([inj.send("%1", "AAA"), inj.send("%1", "BBB")]);

  assert.equal(ra.sent, true, `1本目が送れていない(reason=${ra.reason})`);
  assert.equal(rb.sent, true, `2本目が送れていない(reason=${rb.reason})`);
  assert.deepEqual(
    keys(t, "%1"),
    ["打:AAA", "Enter", "打:BBB", "Enter"],
    "本文と Enter の間に他人の打鍵が入っている",
  );
  assert.equal(t.bodyOf("%1"), "", "入力欄に本文が残った(次の送信に混ざる)");
});

test("★陰性対照: 鍵を外すと同じ検査が赤になる(= 上の緑は鍵を見ている)", async () => {
  const t = livePane(base);
  // 待ちが実時間にならない様に上限を詰める(混線した側は composer-mismatch まで待つ)
  const inj = new TmuxInjector({ tmux: t, mutex: NO_LOCK, echoBudgetMs: 60 });

  const [ra, rb] = await Promise.all([inj.send("%1", "AAA"), inj.send("%1", "BBB")]);

  const order = keys(t, "%1");
  const clean =
    ra.sent && rb.sent && JSON.stringify(order) === JSON.stringify(["打:AAA", "Enter", "打:BBB", "Enter"]);
  assert.equal(
    clean,
    false,
    `鍵を外しても混線しなかった = この検査は鍵を見ていない。打鍵順=${JSON.stringify(order)}`,
  );
  // 実際に起きる壊れ方も固定しておく: 1本目が**2本の本文を繋いだ物**で Enter を押す。
  const firstEnterAt = t.calls.findIndex((c) => c[0] === "send-keys" && c[3] === "Enter");
  const typedBefore = t.calls
    .slice(0, firstEnterAt)
    .filter((c) => c[0] === "send-keys" && c[3] === "-l")
    .map((c) => c[5]);
  assert.deepEqual(typedBefore, ["AAA", "BBB"], "前提: Enter の前に2本分の本文が入力欄へ入る事");
});

// ★2026-08-03、この対の土台を `idle-boot` から**生成中の画面**へ変えた。
// 割り込みは押す前に「本当に動いているか」を枠を跨いで見る(`PRE_FRAMES`)ので、
// 止まっている画面を土台にすると、鍵を外しても Escape が 800ms 後ろに回る =
// **陰性対照が鍵ではなく待ち時間を見る**検査に化けていた(実際に化けていて、
// 鍵を外しても順序が変わらず落ちた)。動いている画面なら 1 枚目で抜けるので、
// 順序を決めるのは鍵だけになる。止める対象が在る = 割り込みの現実の形でもある。
const busy = screen("edith-generating-spinner-hidden");

test("★割り込みは送信の途中に入らない(Escape が Enter の前に落ちない)", async () => {
  const t = livePane(busy);
  const inj = new TmuxInjector({ tmux: t });

  // 送信を始めてから(= 最初の await で止まっている所へ)割り込む。
  const sending = inj.send("%1", "AAA");
  const stopping = inj.interrupt("%1");
  const [r, stopped] = await Promise.all([sending, stopping]);

  assert.equal(r.sent, true, `送信が割り込みに潰された(reason=${r.reason})`);
  // ここで見たいのは**打鍵の順**。止まったか自体の検査は `inject.test.mjs` の四値の組で行う。
  // (割り込みが走った事は、直下の打鍵列に Escape が在る事で見える)
  void stopped;
  assert.deepEqual(
    keys(t, "%1"),
    ["打:AAA", "Enter", "Escape"],
    "Escape が本文と Enter の間に落ちている(送信側が「入力欄が空 = 届いた」と誤読する窓)",
  );
});

test("★陰性対照: 鍵を外すと割り込みが送信の途中に落ちる", async () => {
  const t = livePane(busy);
  const inj = new TmuxInjector({ tmux: t, mutex: NO_LOCK, echoBudgetMs: 60 });

  const sending = inj.send("%1", "AAA");
  const stopping = inj.interrupt("%1");
  await Promise.all([sending, stopping]);

  const order = keys(t, "%1");
  assert.notDeepEqual(
    order,
    ["打:AAA", "Enter", "Escape"],
    `鍵を外しても割り込みが後ろに回った = この検査は鍵を見ていない。打鍵順=${JSON.stringify(order)}`,
  );
  assert.equal(order[1], "Escape", `Escape は本文の直後に落ちるはず。実際=${JSON.stringify(order)}`);
});

test("別のペインは互いに待たない(鍵はペイン単位 = 並列性を殺していない)", async () => {
  const t = livePane(base);
  const inj = new TmuxInjector({ tmux: t });

  const [ra, rb] = await Promise.all([inj.send("%1", "AAA"), inj.send("%2", "BBB")]);

  assert.equal(ra.sent, true);
  assert.equal(rb.sent, true);
  assert.deepEqual(keys(t, "%1"), ["打:AAA", "Enter"]);
  assert.deepEqual(keys(t, "%2"), ["打:BBB", "Enter"]);
  // ★別ペインが**重なった**事まで見る。片方を終えてから他方を始めたのなら、
  //   鍵はペイン単位でなくても(全体1本でも)この検査は緑になってしまう。
  //   重なりの証拠 = 打鍵が %1 %2 %1 %2 と交互に現れる事。
  const paneOrder = t.calls
    .filter((c) => c[0] === "send-keys")
    .map((c) => c[2])
    .join("");
  assert.equal(paneOrder, "%1%2%1%2", `別ペインが直列化されている(重なっていない): ${paneOrder}`);
});

test("★待ちが上限に達したら**1文字も送らずに**断る", async () => {
  const t = livePane(base);
  const inj = new TmuxInjector({ tmux: t });

  // 既定の待ち上限は 4。持ち主1 + 待ち4 = 5本目から断られる。
  const rs = await Promise.all(
    Array.from({ length: 7 }, (_, i) => inj.send("%1", `本文${i}`)),
  );

  const refused = rs.filter((r) => !r.sent);
  assert.ok(refused.length >= 2, `断りが出ていない(送れた本数=${rs.filter((r) => r.sent).length})`);
  for (const r of refused) {
    assert.equal(r.reason, "pane-busy", `断りの理由が違う: ${r.reason}`);
    assert.equal(r.delivered, null, "断ったのに delivered を名乗っている");
  }
  // 断られた本文が**打鍵として現れていない**事(= 積まずに断る、が本当か)
  const typed = t.calls.filter((c) => c[0] === "send-keys" && c[3] === "-l").map((c) => c[5]);
  assert.equal(typed.length, rs.filter((r) => r.sent).length, "送っていないはずの本文が打たれている");
  assert.equal(new Set(typed).size, typed.length, "同じ本文が2回打たれている");
});

// ═══════════════════════════════════════════════════════════════════════════
// §2.18-11 割り込みの行列優先(priority + 上限に数えない + 束ねる)
//
// ★此処に在った検査「送信中の割り込みが断られたら false」は 2026-08-04 に**捨てた**。
//   捨てたのは効かなくなったからではなく、**測っていた振る舞いを設計が覆したから**:
//   §2.18-11 は「送信の混雑が割り込みを断つ」事そのものを欠陥と裁定した。旧検査は
//   その欠陥を**固定する**側に立っていたので、残すと直したのに赤くなる。
//   代わりに (2) が「上限でも断られない」を測り、「断られたら押したと言わない」の方は
//   下の「断る鍵」= 差し込んだ協力者が断ってきた場合、として別に測る。
// ═══════════════════════════════════════════════════════════════════════════

/** 待ちを実時間にしない(1枚ごとにマクロタスクを1つ挟むだけ)。 */
const tick = () => new Promise((r) => setTimeout(r, 0));

/**
 * 鍵を**外から**占有する。「送信が持っている最中」を時計でなく**構造**で作る為の seam。
 * `run` は最初の `await` の前に `held` へ入れるので、戻った時点で既に占有されている。
 */
function holdKey(mutex, key) {
  let release;
  const gate = new Promise((r) => { release = r; });
  const held = mutex.run(key, () => gate);
  return { release, held };
}

/** ★陰性対照: 繋ぎ目は同じで **`priority` だけ捨てる**鍵。 */
const stripPriority = (m) => ({
  run: (key, fn, opts = {}) => m.run(key, fn, { ...opts, priority: false }),
});

/**
 * ★鍵を**手放す直前**でだけ `hook` を走らせる seam(本体は終わっている / 解放はまだ)。
 * 束ねの地図を「臨界区間の中で消す」形にすると、**此処が地図の空いた隙**になる。
 * 時計で狙うと当たらないので、隙そのものを鍵の差し替えで**構造として**作る。
 */
const gapMutex = (m, hook) => ({
  run: (key, fn, opts = {}) =>
    m.run(key, async () => { const r = await fn(); hook(); return r; }, opts),
});

test("★§2.18-11 (1) 鍵が空くと、後から来た割り込みが待っている送信より先に走る", async () => {
  const t = livePane(base);
  const mutex = makeKeyedMutex();
  const inj = new TmuxInjector({ tmux: t, mutex, sleep: tick });

  const { release, held } = holdKey(mutex, "%1");
  const sends = [inj.send("%1", "AAA"), inj.send("%1", "BBB"), inj.send("%1", "CCC")];
  const stopping = inj.interrupt("%1"); // ★**後から**来る。FIFO なら最後に走る
  release();
  await Promise.all([held, stopping, ...sends]);

  const order = keys(t, "%1");
  assert.equal(
    order[0],
    "Escape",
    `割り込みが送信の後ろに回った(FIFO のまま): ${JSON.stringify(order)}`,
  );
});

test("★陰性対照(1): priority を捨てる鍵にすると、同じ検査で送信が先になる", async () => {
  const t = livePane(base);
  const mutex = makeKeyedMutex();
  const inj = new TmuxInjector({ tmux: t, mutex: stripPriority(mutex), sleep: tick });

  const { release, held } = holdKey(mutex, "%1");
  const sends = [inj.send("%1", "AAA"), inj.send("%1", "BBB"), inj.send("%1", "CCC")];
  const stopping = inj.interrupt("%1");
  release();
  await Promise.all([held, stopping, ...sends]);

  const order = keys(t, "%1");
  assert.equal(
    order[0],
    "打:AAA",
    `優先を捨てても割り込みが先に走った = 上の緑は優先を見ていない(行列が元から順不同)。` +
      `打鍵順=${JSON.stringify(order)}`,
  );
});

test("★§2.18-11 (2) 待ちが上限でも割り込みは断られない(陽性対照: 送信は断られる)", async () => {
  const t = livePane(base);
  const mutex = makeKeyedMutex();
  const inj = new TmuxInjector({ tmux: t, mutex, sleep: tick });

  const { release, held } = holdKey(mutex, "%1");
  const waiting = Array.from({ length: 4 }, (_, i) => inj.send("%1", `待${i}`)); // 既定の上限ちょうど

  // ★陽性対照: **同じ混雑で送信は断られる**。これが無いと「上限自体が効いていない」
  //   実装でも下の緑が出る(= 何も見分けていない検査になる)。
  const overflow = await inj.send("%1", "溢れ");
  assert.equal(overflow.sent, false, "上限が効いていない = この検査は混雑を作れていない");
  assert.equal(overflow.reason, "pane-busy");

  const stopping = inj.interrupt("%1");
  release();
  const stopped = await stopping;
  await Promise.all([held, ...waiting]);

  // ★「断られない」= **await が通る**事。断る鍵なら注入器が投げるので此処まで来ない
  //   (2026-08-04 以前は `pressed:false` / `reason:"pane-busy"` という値で見ていた)。
  assert.ok(stopped, "割り込みが値を返していない");
  assert.equal(keys(t, "%1")[0], "Escape", "断られはしなかったが順番は後ろのまま");
});

test("★§2.18-11 (3) 同時に来た割り込み2本は束ねられる(Escape は1回だけ)", async () => {
  const t = livePane(base);
  const inj = new TmuxInjector({ tmux: t, sleep: tick });

  const [a, b] = await Promise.all([inj.interrupt("%1"), inj.interrupt("%1")]);

  assert.deepEqual(b, a, "2本目が1本目と違う答えを受け取っている(束ねていない)");
  const escs = keys(t, "%1").filter((k) => k === "Escape").length;
  assert.equal(escs, 1, `Escape が ${escs} 回飛んだ = 次の番に当たりうる`);
});

test("★陽性対照(3): 1本だけの時も同じ4値が返る(束ねが定型文を返しているのではない)", async () => {
  const t = livePane(base);
  const inj = new TmuxInjector({ tmux: t, sleep: tick });

  const only = await inj.interrupt("%1");
  assert.equal(only.reason, "not-in-flight", "土台の画面が変わった(上の (3) の前提が崩れる)");
  assert.equal(keys(t, "%1").filter((k) => k === "Escape").length, 1);
});

test("★§2.18-11 (4) **実行中**に来た割り込みも合流する(束ねの寿命は解放まで)", async () => {
  const t = livePane(base);
  let second = null;
  // ★「I1 が走っている最中」を**構造**で指定する seam。`pollScreen` の待ちは
  //   臨界区間の中でしか起きないので、此処で撃てば必ず実行中に当たる(時計を使わない)。
  const inj = new TmuxInjector({
    tmux: t,
    sleep: () => {
      if (!second) second = inj.interrupt("%1");
      return tick();
    },
  });

  const first = await inj.interrupt("%1");
  assert.ok(second, "前提: 実行中に2本目を撃てていない(seam が効いていない)");
  const joined = await second;

  assert.deepEqual(joined, first, "実行中に来た2本目が別に走った(束ねが待ちの間しか覆っていない)");
  const escs = keys(t, "%1").filter((k) => k === "Escape").length;
  assert.equal(escs, 1, `Escape が ${escs} 回飛んだ`);
});

test("★§2.18-11 (5) 実行中に割り込みを撃ち続けても、待っている送信は走る(飢餓の直接測定)", async () => {
  const t = livePane(base);
  const mutex = makeKeyedMutex();
  let sendDone = false;
  let rounds = 0;
  // ★鍵を**持っている間**に次を撃つ。時計で撃つと「たまたま空いている時」に当たって
  //   何も測れない。上限(40)は、飢餓した時に検査が固まらない為だけの物。
  const inj = new TmuxInjector({
    tmux: t,
    mutex,
    sleep: () => {
      if (!sendDone && rounds < 40) { rounds++; inj.interrupt("%1"); }
      return tick();
    },
  });

  const { release, held } = holdKey(mutex, "%1");
  const sending = inj.send("%1", "AAA").then((r) => { sendDone = true; return r; });
  const first = inj.interrupt("%1");
  release();
  await Promise.all([held, first, sending]);

  const order = keys(t, "%1");
  const firstType = order.findIndex((k) => k.startsWith("打:"));
  assert.ok(firstType >= 0, `送信が一度も走らなかった: ${JSON.stringify(order)}`);
  assert.ok(rounds >= 2, `前提: 実行中の連打が起きていない(rounds=${rounds})`);
  const escBefore = order.slice(0, firstType).filter((k) => k === "Escape").length;
  assert.equal(
    escBefore,
    1,
    `送信の前に Escape が ${escBefore} 回飛んだ = 割り込みに追い越され続けた(飢餓)`,
  );
});

// ★(5b) は 2026-08-04 に**測って**足した。それまで、束ねの地図を消す位置は
//   「臨界区間の中の最後の同期文」と設計書に書いてあったのに、前後どちらへ動かしても
//   検査は緑のままだった(変異 M107 が素通り = **一度も見分けていなかった**)。
//   見分ける物を作ったら、書いてあった側が**悪い方**だと分かった:
//   中で消すと「消してから解放するまで」に地図が空き、その隙に来た割り込みは合流できず
//   新しい優先待ちとして先頭へ積まれる = 送信を追い越し続けられる。
//   実測(同じ仕掛け): 中で消す版 = `[Escape, Escape, 打:AAA]` / 決着後に消す版 = `[Escape, 打:AAA]`。
//   ★(5) との違い: (5) は**実行中**に撃つ(地図は埋まっている)。此処は**解放の直前**に撃つ。
//   同じ「飢餓」でも入口が別なので、(5) が緑でも此処は赤になり得る。
test("★§2.18-11 (5b) 鍵を手放す直前の隙で割り込みが来ても、送信は追い越されない", async () => {
  const t = livePane(base);
  const real = makeKeyedMutex();
  let fired = 0;
  let inj;
  const mutex = gapMutex(real, () => { if (fired === 0) { fired++; inj.interrupt("%1"); } });
  inj = new TmuxInjector({ tmux: t, mutex, sleep: () => tick() });

  const { release, held } = holdKey(real, "%1");
  const sending = inj.send("%1", "AAA");
  const first = inj.interrupt("%1"); // 先頭へ入る1本目
  release();
  await Promise.all([held, first, sending]);

  const order = keys(t, "%1");
  assert.equal(fired, 1, "前提: 隙で1本も撃てていない(seam が効いていない)");
  const firstType = order.findIndex((k) => k.startsWith("打:"));
  assert.ok(firstType >= 0, `送信が一度も走らなかった: ${JSON.stringify(order)}`);
  const escBefore = order.slice(0, firstType).filter((k) => k === "Escape").length;
  assert.equal(
    escBefore,
    1,
    `送信の前に Escape が ${escBefore} 回 = 隙で来た割り込みが合流せず先頭へ積まれた: ${JSON.stringify(order)}`,
  );
});

test("★§2.18-11 (6) 合流した2本目が、**他人の期限**で倒れない", async () => {
  const t = livePane(base);
  const mutex = makeKeyedMutex();
  const inj = new TmuxInjector({ tmux: t, mutex, sleep: tick });

  const { release, held } = holdKey(mutex, "%1");
  const ac = new AbortController();
  const i1 = inj.interrupt("%1", { signal: ac.signal }); // 期限付き
  const i2 = inj.interrupt("%1"); // 期限なし。1本目に合流する
  ac.abort(); // ★待っている間に切れる
  release();

  // ★**例外にならない事そのものが本体**。期限を転送すると `mutex.run` が
  //   `MUTEX_ABORTED` で reject し、此処が投げて赤くなる(M109 の死に方)。
  //   2026-08-04 まではこれを `pressed:false` で見ていたが、断りを値に化かす catch を
  //   落としたので、今は**この await が通る事**が判定そのもの。
  const [r1, r2] = await Promise.all([i1, i2]);
  await held;

  assert.deepEqual(r2, r1, "頼んでいない期限で2本目まで倒れた");
  assert.equal(keys(t, "%1").filter((k) => k === "Escape").length, 1);
});

// ★2026-08-04 に**裏返した**検査。旧題は「断る鍵を差し込んだら『押していない』と名乗る」で、
//   注入器が `MUTEX_BUSY`/`MUTEX_ABORTED` を捕まえて `pressed:false` に化かすのを固定していた。
//   §2.18-11 で優先の取得が上限に数えられなくなり、出荷している鍵では**どちらも起こせない**。
//   到達しない枝を「協力者との境界だから生きている」と読んだのが誤りで、継ぎ目を撃つ変異 W6 は
//   実際に**素通り**した(2026-08-04 の走行)。だから枝ごと落とし、契約違反は**投げる**。
//   此処が測るのは「握り潰さない事」= 静かな 409 で「まだ止めていません」と名乗らない事。
test("★断る鍵を差し込んだら、割り込みは値に化かさず**投げる**(協力者の契約違反)", async () => {
  const refusing = (code) => ({
    run: () => {
      const e = new Error(code);
      e.code = code;
      throw e;
    },
  });

  for (const code of [MUTEX_BUSY, MUTEX_ABORTED]) {
    const t = livePane(base);
    const inj = new TmuxInjector({ tmux: t, mutex: refusing(code) });

    await assert.rejects(
      () => inj.interrupt("%1"),
      (e) => e?.code === code,
      `${code}: 断りを値に化かして飲み込んでいる(電話には「止めた/止めていません」が出てしまう)`,
    );
    assert.ok(
      !t.calls.some((c) => c[0] === "send-keys" && c[3] === "Escape"),
      `${code}: 鍵を取れていないのに Escape を送っている`,
    );
  }
});
