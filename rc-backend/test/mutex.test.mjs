// 鍵で直列化する道具(DESIGN.md §2.18)。時計を持たない層なので**偽時計が要らない**。
//
// 押さえるのは3点(残りはその対照):
//   1. 同じ鍵の2本が**重ならない**
//   2. ★期限切れした待ち手は、後から鍵が回ってきても**打たない**(ghost send)
//   3. 違う鍵は**並ぶ**(直列化しすぎて全ペインが1本になっていない事の対照)
//
// 2 は「無い事」の検査なので変異(M91)で**落ちる事**を確かめてある。
// 2026-08-02 の教訓「もっともらしい既定は覆い漏れを検査不能にする」と同じ形。
//
// ★この file の作法(2つ。どちらも「計器を壊さない」ための規則):
//   1. **落ちた検査が後続を巻き込まない**(`withDeferreds` = 作った保持者を必ず降ろす)。
//   2. **変異で未解決になり得る約束を `await` しない**(`watch` + `assertRejected`)。
//      → これは**この file の末尾の検査が回す**(規則を散文にだけ置かない = 教義19)。
//      ★2026-08-04 の経緯を2段書く。同じ日に、同じ規則で**別々に**2回外している:
//        (a) 元は「`grep 'assert.rejects' this-file` が何も返さない事」。**緑になり得ない**
//            —— 規則を説明している此処の注釈自体が当たるから。回すと必ず2件出る
//            = 「回した人が毎回無視する」検査。赤にならない検査の裏返しで、同じく計器でない。
//        (b) 直した形(`| grep -v '://'`)は**偶然**通っていた。除いていたのは注釈ではなく、
//            `grep -n` が付ける `16:` と行頭の `//` が隣り合って出来る `://` の並び。
//            注釈を1文字字下げすれば静かに壊れる = 通る理由が意図と違う。
//        だから grep をやめて、**注釈行を綴りで落とす**検査に置き換えた(末尾)。
//
//   2 の実測(2026-08-02): 最初は素直に `await assert.rejects(p, …)` と書いていた。
//   断るのをやめる変異(M88)を当てると、その約束は**永久に未解決**になり、
//   event loop が空になって node ごと終了 → 後続が全部 **cancelled**。
//   結果 `# fail 0 / # cancelled 8` —— **どの検査も落ちていないのに**、
//   終了コードだけ見て「検出」と報告されていた。掴んだのは検査ではなく crash。
//   「待って確かめる」ではなく「**もう決着しているか**を見る」形に統一した。
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { makeKeyedMutex, MUTEX_BUSY, MUTEX_ABORTED } from "../src/mutex.mjs";

/** 外から解ける約束。「保持者をいつ降ろすか」を検査側が決められる様にする。 */
function deferred() {
  let resolve, reject;
  const promise = new Promise((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

/** マイクロタスクを何回か回す(タイマーを使わずに「先へ進ませる」)。 */
const settle = async (n = 4) => {
  for (let i = 0; i < n; i++) await Promise.resolve();
};

/**
 * 約束の**決着**を記録する。呼んだ瞬間に handler が付くので、
 * 検査が途中で投げて誰も待たなくなっても unhandled rejection にならない。
 * 約束そのものは**どこでも await しない** = 未解決になる変異で固まらない。
 */
function watch(promise) {
  const w = { state: "pending", code: undefined, message: "" };
  promise.then(
    () => {
      w.state = "resolved";
    },
    (e) => {
      w.state = "rejected";
      w.code = e?.code;
      w.message = String(e?.message ?? e);
    },
  );
  return w;
}

/** 「もう断られていて、断り方がこれ」を見る。待たない。 */
async function assertRejected(w, expect, why) {
  await settle();
  assert.equal(w.state, "rejected", `${why}(state=${w.state} = 断っていない/待たせている)`);
  if (expect instanceof RegExp) assert.match(w.message, expect, why);
  else assert.equal(w.code, expect, why);
}

/**
 * 検査が途中で落ちても、作った保持者を必ず降ろす。
 * 降ろさないと鍵が埋まったままの約束が残り、runner が後続をまとめて赤にする。
 */
async function withDeferreds(body) {
  const made = [];
  const mk = () => {
    const d = deferred();
    made.push(d);
    return d;
  };
  try {
    await body(mk);
  } finally {
    for (const d of made) d.resolve();
    await settle();
  }
}

test("同じ鍵の2本は重ならない(入った順・出た順で見る。速さでは見ない)", async () => {
  await withDeferreds(async (mk) => {
    const m = makeKeyedMutex();
    const log = [];
    const a = mk();
    const b = mk();

    const p1 = m.run("%1", async () => {
      log.push("a:in");
      await a.promise;
      log.push("a:out");
    });
    const p2 = m.run("%1", async () => {
      log.push("b:in");
      await b.promise;
      log.push("b:out");
    });

    await settle();
    // A が保持している間、B は**まだ入っていない**
    assert.deepEqual(log, ["a:in"]);
    assert.equal(m.isHeld("%1"), true);
    assert.equal(m.waiting("%1"), 1);

    a.resolve();
    await settle();
    assert.deepEqual(log, ["a:in", "a:out", "b:in"]);

    b.resolve();
    await Promise.all([p1, p2]);
    assert.deepEqual(log, ["a:in", "a:out", "b:in", "b:out"]);
    assert.equal(m.isHeld("%1"), false);
  });
});

test("★期限切れした待ち手は、鍵が回ってきても打たない(ghost send)", async () => {
  await withDeferreds(async (mk) => {
    const m = makeKeyedMutex();
    const a = mk();
    let bRan = false;

    const p1 = m.run("%1", async () => {
      await a.promise;
    });
    const ac = new AbortController();
    const p2 = watch(m.run("%1", async () => {
      bRan = true;
    }, { signal: ac.signal }));

    await settle();
    assert.equal(m.waiting("%1"), 1);

    // 待っている間に期限が切れる = 呼ぶ側は「送っていません」を受け取る
    ac.abort();
    await assertRejected(p2, MUTEX_ABORTED, "中止しても呼ぶ側に返していない");
    assert.equal(m.waiting("%1"), 0, "中止した待ち手が行列に残っている");

    // 保持者が降りる。ここで B が走ったら**言った事と違う事をした**事になる。
    a.resolve();
    await p1;
    await settle();
    assert.equal(bRan, false, "中止済みの待ち手が後から走った(= ghost send)");
    assert.equal(m.isHeld("%1"), false, "全員降りたのに鍵が埋まったまま");
  });
});

test("違う鍵は並ぶ(直列化しすぎていない事の対照)", async () => {
  await withDeferreds(async (mk) => {
    const m = makeKeyedMutex();
    const a = mk();
    let bIn = false;

    const p1 = m.run("%1", async () => {
      await a.promise;
    });
    const p2 = m.run("%2", async () => {
      bIn = true;
    });

    await settle();
    assert.equal(bIn, true, "別の鍵まで待たされている");
    await p2;
    a.resolve();
    await p1;
  });
});

test("待ちの上限を超えたら積まずに断る(連打を全部後から流し込まない)", async () => {
  await withDeferreds(async (mk) => {
    const m = makeKeyedMutex({ defaultMaxWaiters: 2 });
    const a = mk();
    const ran = [];

    const p1 = m.run("%1", async () => {
      await a.promise;
    });
    const p2 = m.run("%1", () => ran.push(2));
    const p3 = m.run("%1", () => ran.push(3));
    await settle();
    assert.equal(m.waiting("%1"), 2);

    // 3本目の待ち = 上限超え。**即**断る(待たせてから断るのではない)。
    const p4 = watch(m.run("%1", () => ran.push(4)));
    await assertRejected(p4, MUTEX_BUSY, "上限超えを**即**断っていない(待たせている / 積んだ)");
    assert.equal(m.waiting("%1"), 2, "断った待ち手を行列に積んでいる");

    a.resolve();
    await Promise.all([p1, p2, p3]);
    assert.deepEqual(ran, [2, 3], "FIFO で走っていない / 断ったはずの4が走った");
  });
});

test("fn が投げても鍵は次へ渡る(1回の失敗で永久に埋まらない)", async () => {
  const m = makeKeyedMutex();
  let second = false;
  const p1 = watch(
    m.run("%1", async () => {
      throw new Error("送信に失敗");
    }),
  );
  await assertRejected(p1, /送信に失敗/, "fn の失敗が呼ぶ側に届いていない");
  assert.equal(m.isHeld("%1"), false);
  await m.run("%1", () => {
    second = true;
  });
  assert.equal(second, true);
});

test("★取った後の中止は効かない(途中で降りる方が混線より悪い)", async () => {
  await withDeferreds(async (mk) => {
    const m = makeKeyedMutex();
    const ac = new AbortController();
    const gate = mk();
    let finished = false;

    const p = m.run("%1", async () => {
      ac.abort(); // 本文を打った直後に期限が切れた、という状況
      await gate.promise;
      finished = true; // Enter まで打ち切る
    }, { signal: ac.signal });

    await settle();
    gate.resolve();
    await p;
    assert.equal(finished, true, "取った後に中止で降りた(入力欄に本文が残る壊れ方)");
  });
});

test("最初から中止済みの signal では、鍵が空いていても走らせない", async () => {
  const m = makeKeyedMutex();
  const ac = new AbortController();
  ac.abort();
  let ran = false;
  const p = watch(
    m.run("%1", () => {
      ran = true;
    }, { signal: ac.signal }),
  );
  await assertRejected(p, MUTEX_ABORTED, "中止済みの signal を見ずに受けた");
  assert.equal(ran, false);
  assert.equal(m.isHeld("%1"), false);
});

test("待ちが全部中止されたら鍵は空く(次が即取れる)", async () => {
  await withDeferreds(async (mk) => {
    const m = makeKeyedMutex();
    const a = mk();
    const ac1 = new AbortController();
    const ac2 = new AbortController();

    const p1 = m.run("%1", async () => {
      await a.promise;
    });
    const p2 = watch(m.run("%1", () => {}, { signal: ac1.signal }));
    const p3 = watch(m.run("%1", () => {}, { signal: ac2.signal }));
    await settle();
    assert.equal(m.waiting("%1"), 2);

    ac1.abort();
    ac2.abort();
    await assertRejected(p2, MUTEX_ABORTED, "1本目の待ちを中止で返していない");
    await assertRejected(p3, MUTEX_ABORTED, "2本目の待ちを中止で返していない");

    a.resolve();
    await p1;
    await settle();
    assert.equal(m.isHeld("%1"), false);
    assert.deepEqual(m.inspect(), []);
  });
});

// ================== 「捨てない」(§2.18-2 の未決を 2026-08-04 に決着) ==================
//
// 決めた形 = **積んだ待ちを、後から来た誰かの為に捨てない**(`src/mutex.mjs` 冒頭の規則3)。
// 割り込みは送信と同じ鍵に入るので(§2.18-2)、「電話が『止める』を押したら、既に積んだ
// 送信が消えるか」はこの層の性質になる。
//
// ★**順序を見ない**のは意図的。§2.18-11(優先挿入、未実装)が入ると割り込みが**先頭**へ
//   回る = 順序は**正しく**変わる。ここで順序を固定すると、その日に此処が赤くなり、
//   「捨てない」の主張ごと緩めて直される道が出来る。守る性質(顔ぶれが欠けない)と
//   変わってよい性質(順序)を、別の検査に分けて書く。順序・排他・優先はそれぞれ別の的。
//
// ★下の2本目(上限ちょうど)が要る理由(Codex `gpt-5.6-sol` xhigh 2026-08-04 の指摘):
//   1本目の「2本待ち → 3本待ち」だけだと、**満杯の時にだけ現れる**捨て方
//   (`q.unshift(割り込み); if (q.length > maxWaiters) q.pop();`)を見逃す。境界は別に撃つ。

test("★割り込みが来ても、先に待っている送信を捨てない(顔ぶれだけ見る。順序は見ない)", async () => {
  await withDeferreds(async (mk) => {
    const m = makeKeyedMutex();
    const hold = mk();
    const ran = [];

    const p0 = m.run("%1", async () => {
      ran.push("s0");
      await hold.promise;
    });
    await settle();

    const w1 = watch(m.run("%1", () => ran.push("s1")));
    const w2 = watch(m.run("%1", () => ran.push("s2")));
    await settle();
    assert.equal(m.waiting("%1"), 2, "前提が崩れている(2本積めていない)");

    // ここで電話が「止める」を押した。割り込みも同じ鍵に入る。
    const wi = watch(m.run("%1", () => ran.push("INT")));
    await settle();
    assert.equal(m.waiting("%1"), 3, "割り込みが席を空ける為に先の待ちを外した(= 捨てた)");

    hold.resolve();
    await settle(40);

    // ★`resolved` を要求する(「決着した」ではなく)。断って捨てる実装は `rejected` に
    //   なるので、settled で見ると素通りする。
    assert.equal(w1.state, "resolved", "s1 が走っていない(捨てられた / 孤児になった)");
    assert.equal(w2.state, "resolved", "s2 が走っていない(捨てられた / 孤児になった)");
    assert.equal(wi.state, "resolved", "割り込み自身が決着していない");
    assert.deepEqual([...ran].sort(), ["INT", "s0", "s1", "s2"], "走った顔ぶれが欠けている");
    await p0;
  });
});

test("★待ちが上限ちょうどの時、後から来た1本は**断られる**。席を空けるのではない", async () => {
  await withDeferreds(async (mk) => {
    const m = makeKeyedMutex(); // 既定の上限そのもので測る(本番と同じ境界)
    const hold = mk();
    const ran = [];
    const CAP = 4; // makeKeyedMutex の defaultMaxWaiters

    const p0 = m.run("%1", async () => {
      ran.push("s0");
      await hold.promise;
    });
    await settle();

    const ws = [];
    for (let i = 1; i <= CAP; i++) ws.push(watch(m.run("%1", () => ran.push(`s${i}`))));
    await settle();
    assert.equal(m.waiting("%1"), CAP, "前提が崩れている(上限ちょうどまで積めていない)");

    const wx = watch(m.run("%1", () => ran.push("X")));
    await assertRejected(wx, MUTEX_BUSY, "上限超えを断っていない");
    assert.equal(m.waiting("%1"), CAP, "断る代わりに古い待ちを外して席を空けた(= 捨てた)");

    hold.resolve();
    await settle(60);

    for (let i = 0; i < CAP; i++) {
      assert.equal(ws[i].state, "resolved", `s${i + 1} が走っていない(捨てられた / 孤児になった)`);
    }
    assert.deepEqual(
      [...ran].sort(),
      ["s0", "s1", "s2", "s3", "s4"],
      "走った顔ぶれが欠けている / 断ったはずの X が走った",
    );
    await p0;
  });
});

test("鍵が空文字の経路は直列化されないので、取れない", async () => {
  const m = makeKeyedMutex();
  let ran = false;
  const p = watch(
    m.run("", () => {
      ran = true;
    }),
  );
  await assertRejected(p, "MUTEX_KEY", "空の鍵を受け付けた");
  assert.equal(ran, false);
});

// ── 作法2を**機械に回させる**(DESIGN 教義19: 規則は、それを回す物が無いと効かない)──
//
// 綴りは連結で組み立てる。この検査は**自分の file を走査する**ので、生の literal を
// 置くと自分に当たる(`test/no-linerefs.test.mjs` と同じ理由・同じ作法)。
const FORBIDDEN = "assert" + "." + "rejects";

/** 注釈行を落として本文だけ返す。行番号は**元の file の番号**を保つ。 */
function codeLines(text) {
  return text
    .split("\n")
    .map((line, i) => [i + 1, line])
    .filter(([, line]) => !line.trimStart().startsWith("//"));
}

test("★作法2: 未解決になり得る約束を await しない(禁じ手が本文に1件も無い)", () => {
  const self = readFileSync(fileURLToPath(import.meta.url), "utf8");
  const body = codeLines(self);
  // ★空を走査して緑を名乗らない。道が壊れて 0 行になった時、上の陰性対照は
  //   合成文字列を見ているので**気付かない**(死んだ計器は下流の欠陥も隠す = §2.33)。
  assert.ok(body.length > 100, `自分の file を読めていない(本文 ${body.length} 行)`);
  const hits = body
    .filter(([, line]) => line.includes(FORBIDDEN))
    .map(([n, line]) => `${n}: ${line.trim()}`);
  assert.deepEqual(
    hits, [],
    "断るのをやめる変異を当てると、その約束は永久に未解決になり、event loop が空になって" +
      " node ごと終了 → 後続が全部 cancelled になる(2026-08-02 の実測: fail 0 / cancelled 8)。" +
      " `watch()` + `assertRejected()` で「もう決着しているか」を見る形に直す事",
  );
});

test("陰性対照: 本文に混ぜれば見つかる / 注釈に在る分は見つけない", () => {
  const inCode = `  await ${FORBIDDEN}(p, { code: "X" });`;
  assert.equal(codeLines(inCode).filter(([, l]) => l.includes(FORBIDDEN)).length, 1,
    "本文の禁じ手を見逃した = この検査は空振りしている");
  assert.equal(codeLines(`  // ${FORBIDDEN} は使わない`).filter(([, l]) => l.includes(FORBIDDEN)).length, 0,
    "注釈に当たっている = 8/04 (a) の『緑になり得ない検査』へ戻っている");
  // ★字下げした注釈でも落ちる事(= 8/04 (b) の grep が静かに壊れた形を、ここでは踏まない)
  assert.equal(codeLines(`      // 例: ${FORBIDDEN}`).filter(([, l]) => l.includes(FORBIDDEN)).length, 0,
    "字下げした注釈を本文と誤認している");
});
