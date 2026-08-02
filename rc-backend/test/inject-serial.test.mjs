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

test("★割り込みは送信の途中に入らない(Escape が Enter の前に落ちない)", async () => {
  const t = livePane(base);
  const inj = new TmuxInjector({ tmux: t });

  // 送信を始めてから(= 最初の await で止まっている所へ)割り込む。
  const sending = inj.send("%1", "AAA");
  const stopping = inj.interrupt("%1");
  const [r, stopped] = await Promise.all([sending, stopping]);

  assert.equal(r.sent, true, `送信が割り込みに潰された(reason=${r.reason})`);
  assert.equal(stopped, true, "割り込みが実行されていない");
  assert.deepEqual(
    keys(t, "%1"),
    ["打:AAA", "Enter", "Escape"],
    "Escape が本文と Enter の間に落ちている(送信側が「入力欄が空 = 届いた」と誤読する窓)",
  );
});

test("★陰性対照: 鍵を外すと割り込みが送信の途中に落ちる", async () => {
  const t = livePane(base);
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

test("送信中の割り込みが断られたら false(「止めた」と言わない)", async () => {
  const t = livePane(base);
  const inj = new TmuxInjector({ tmux: t });

  // 鍵を埋めて待ちも上限まで塞ぐ
  const sends = Array.from({ length: 5 }, (_, i) => inj.send("%1", `本文${i}`));
  const stopped = await inj.interrupt("%1");
  await Promise.all(sends);

  assert.equal(stopped, false, "止めていないのに true を返した");
  assert.ok(
    !t.calls.some((c) => c[0] === "send-keys" && c[3] === "Escape"),
    "断ったのに Escape を送っている",
  );
});
