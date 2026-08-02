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
//      → `grep 'assert.rejects' this-file` が**何も返さない**事がこの規則の検査。
//
//   2 の実測(2026-08-02): 最初は素直に `await assert.rejects(p, …)` と書いていた。
//   断るのをやめる変異(M88)を当てると、その約束は**永久に未解決**になり、
//   event loop が空になって node ごと終了 → 後続が全部 **cancelled**。
//   結果 `# fail 0 / # cancelled 8` —— **どの検査も落ちていないのに**、
//   終了コードだけ見て「検出」と報告されていた。掴んだのは検査ではなく crash。
//   「待って確かめる」ではなく「**もう決着しているか**を見る」形に統一した。
import { test } from "node:test";
import assert from "node:assert/strict";
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
