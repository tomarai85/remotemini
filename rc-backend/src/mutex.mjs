// 鍵で直列化する道具 — DESIGN.md §2.18。**I/O も時計も持たない**(全部 unit で測れる層)。
//
// なぜ1つで足りるか: H1(同じペインへの打鍵が混ざる)と H2(同じ転写ファイルに書き手が2人)は
// 守る物が違うが、要るのは同じ「鍵で直列化する」だけで、違うのは**鍵の値**
// (H1 = ペイン ID `%34` / H2 = 論理会話 ID)。だから道具は1本。
//
// **この層に置く理由**(2026-08-02 の教訓): `server.mjs` は import すると `listen` するので、
// そこに置いた判断は `node --test` から触れない。判断は**読み込んでも何も起きない層**に置く。
//
// 時計を持たない理由: 期限は呼ぶ側の `AbortSignal`(= `AbortSignal.timeout(ms)`)で渡す。
// この層に `setTimeout` が無ければ、検査は偽時計を要らずに**決定的**に書ける。
//
// ---
// 先に決めた3つ。どれも「安全側はどちらか」の話で、逆に倒すと鍵が防ぐ物が起きる:
//
//   1. **取ってからは止めない**。中止は**待っている間だけ**効く。
//      取った後に途中で降りると、本文を打って Enter を押さないまま抜ける事になり、
//      `inject.mjs` が書いている壊れ方(入力欄に本文が残り、**次の送信に混ざる**)そのもの。
//      = 途中で止める方が、待たせるより悪い。
//
//   2. **保持側を横から解放しない**。詰まった保持者を強制的に外すと次の待ち手が打ち込む
//      = 混線そのもの。詰まった時は待ち手が自分の期限で「送っていない」と返して降りる。
//      その結果は「このペインへ送れない」であって「変な物を送る」ではない(fail-closed)。
//
//   3. **積んだ待ちを、後から来た誰かの為に捨てない**(2026-08-04 に決着。DESIGN §2.18-2 の
//      表に「『送信待ちを割り込みで捨てるか』は Tom の裁定が要る。未決として残す」と
//      2026-08-02 から書いてあった一行が、これ)。
//      決めた形 = **捨てない**。電話が「止める」を押しても、既に積まれた送信は走る。
//      - 素の TUI がそうだから(Escape は生成を止めるだけで、`Press up to edit queued
//        messages` に積まれた本文は残る)。この企画は素の Remote control を真似すると
//        決めてある。
//      - 捨てる = **受理したと出した後で黙って消す**。この企画が繰り返し潰してきた
//        「電話に出した事と tmux に届いた事が食い違う」の、もう半分。向きが逆なだけで
//        同じ欠陥(§2-D、`delivered:"verified"` の誤り)。
//        ★根拠に HTTP 202 を使わない(Codex `gpt-5.6-sol` xhigh 2026-08-04 の指摘)。
//        202 はそもそも配送保証ではないので、それを根拠にすると論拠が空になる。
//        効いているのは「**この企画が電話に「受理した」と出す時に約束している事**」の方 =
//        「tmux に届く。届かないなら理由が出る」(§2-D)。黙って消すのはその約束の違反。
//      ★**採らなかった論拠**(2026-08-04、Codex に潰された): 「待ちは最大4本 = 1秒未満なので、
//        1秒前の送信を別のボタンで取り消す意図は持てない」。**偽**。保持者は横から外さない
//        (規則2)し、保持者に期限も無いので、詰まった保持者の後ろで待ちは**いくらでも
//        長く滞留し得る**。時間の短さを根拠にすると、一番壊れている時に根拠が消える。
//      ★**覆る条件**: 「止める」を押した人が、自分が積んだ本文を消す意図で押していたと
//        分かった時。その時直すのは此処ではなく、電話に「積んだ分を消す」を**別に置く**事
//        (`interrupt` に意味を2つ持たせない)。
//      ★この規則は**上限の断り方にも掛かる**: 上限超過は `MUTEX_BUSY` で**新しい方を断る**
//        のであって、古い待ちを外して席を空ける事ではない。優先挿入(§2.18-11、未実装)が
//        入ると「先頭へ入れる」が「席を空ける」に化ける道が出来るので、先に検査で固定して
//        ある(`test/mutex.test.mjs` の2本 + 変異 M110)。
//
// ---
// ★呼ぶ側の契約(これを破ると ghost send が復活する):
//   **結果を知る口は `run()` が返す約束だけ**。呼ぶ側が別に時計を持って
//   「時間が来たから失敗」と自分で決めてはいけない。期限は signal で**この層に渡す**。
//   理由: 電話に「送っていません」と出した後で本文が入るのが、この企画が繰り返し潰してきた
//   fail-open の形(§2-D、`delivered:"verified"` の誤り、`blockedBody` の既定)。

/** 送信中で、待ちも上限に達している。**積まずに**断る。 */
export const MUTEX_BUSY = "MUTEX_BUSY";
/** 順番待ちの間に期限が切れた / 呼ばれた時点で既に中止されていた。**走らせていない**。 */
export const MUTEX_ABORTED = "MUTEX_ABORTED";

function mutexError(code, message) {
  const e = new Error(message);
  e.code = code;
  return e;
}

/**
 * 鍵ごとの直列化。
 *
 * @param {object} [opts]
 * @param {number} [opts.defaultMaxWaiters] 1つの鍵に積める待ちの上限(既定 4)。
 *   上限を置く理由: 電話の連打で待ちが無限に伸びると、**押した順に全部が後から入る**。
 *   人が「効かない」と思って押した分まで送るのは、押した本人の意図と違う。
 * @returns {{run: Function, isHeld: Function, waiting: Function, inspect: Function}}
 */
export function makeKeyedMutex({ defaultMaxWaiters = 4 } = {}) {
  const held = new Set(); // 今この鍵を誰かが持っている
  const queues = new Map(); // key -> 待ち行列(FIFO)

  function queueOf(key) {
    let q = queues.get(key);
    if (!q) {
      q = [];
      queues.set(key, q);
    }
    return q;
  }

  /**
   * 持ち主が降りた。次の持ち主へ**渡す**(`held` は保ったまま)。
   *
   * ★ここに中止済みの待ち手が現れる事は**無い**。中止は listener の中で
   *   「行列から外す」まで同期でやり切るので(下の `enqueue`)、この関数から見えない。
   *
   *   2026-08-02、最初はここに `if (w.aborted) continue;` を書き、コメントで
   *   「これが ghost send を塞ぐ1行」と名乗らせていた。**嘘だった**。
   *   その行を `throw` に変えて全検査を回しても **9/9 緑** = **一度も通らない**。
   *   塞いでいたのは splice の方で、その事は M91(splice を外す変異)が掴む。
   *   到達しない守りは、守っている様に見えるだけで**測れない** —— 今日の
   *   「もっともらしい既定は覆い漏れを検査不能にする」と同じ形なので、消した。
   */
  function releaseAndPump(key) {
    const q = queues.get(key) || [];
    if (q.length) {
      const w = q.shift();
      w.detach();
      w.grant(); // この待ち手が鍵を持つ。held はそのまま = 持ち主が変わっただけ
      return;
    }
    held.delete(key);
    queues.delete(key);
  }

  function enqueue(key, signal) {
    const q = queueOf(key);
    return new Promise((grant, reject) => {
      const w = { grant, detach: () => {} };
      if (signal) {
        const onAbort = () => {
          // ★**ここが ghost send を塞ぐ唯一の場所**(実測でそう確かめた。上の releaseAndPump 参照)。
          //   行列から外してから reject する。Node は単線で、この関数の中に await が
          //   1つも無いので「外している途中」という状態は存在しない
          //   (worker.mjs の二重 spawn が起きない理由と同じ論法)。
          //   外さないと、持ち主が降りた時に**既に「送っていません」と返した待ち手へ鍵が渡る**。
          const i = q.indexOf(w);
          if (i >= 0) q.splice(i, 1);
          reject(mutexError(MUTEX_ABORTED, `${key}: 順番待ちの間に期限切れ。**送っていない**`));
        };
        signal.addEventListener("abort", onAbort, { once: true });
        // detach は**正しさの守りではない**(鍵を渡した後の abort は、既に解決済みの
        // 約束に対する no-op なので何も起きない)。長生きする signal に listener が
        // 溜まるのを防ぐだけ。だから検査も置いていない。
        w.detach = () => signal.removeEventListener("abort", onAbort);
      }
      q.push(w);
    });
  }

  /**
   * 鍵を取って `fn` を走らせる。取れなければ**走らせずに**投げる。
   *
   * @template T
   * @param {string} key 直列化の単位(ペイン ID / 論理会話 ID)
   * @param {() => (T|Promise<T>)} fn 鍵の中で走らせる手続き
   * @param {object} [opts]
   * @param {AbortSignal} [opts.signal] **待っている間だけ**効く期限
   * @param {number} [opts.maxWaiters]
   * @returns {Promise<T>} `fn` の戻り。取れなかった時は code 付きで throw
   *
   * ★同じ鍵の入れ子は取れない(自分を待って固まる)。呼ぶ側で入れ子にしない。
   */
  async function run(key, fn, { signal, maxWaiters = defaultMaxWaiters } = {}) {
    if (typeof key !== "string" || key === "") {
      throw mutexError("MUTEX_KEY", "鍵が空。鍵の値が空になる経路は直列化されない");
    }
    if (typeof fn !== "function") throw mutexError("MUTEX_FN", "fn が関数でない");
    // 呼ばれた時点で既に中止されている物は、鍵が空いていても走らせない。
    if (signal?.aborted) {
      throw mutexError(MUTEX_ABORTED, `${key}: 呼ばれた時点で中止済み。**走らせていない**`);
    }

    if (held.has(key)) {
      const q = queueOf(key);
      if (q.length >= maxWaiters) {
        throw mutexError(MUTEX_BUSY, `${key}: 送信中で、待ちも上限(${maxWaiters})。**積まない**`);
      }
      await enqueue(key, signal); // ここを抜けた = 自分が持ち主
    } else {
      held.add(key);
    }

    try {
      return await fn();
    } finally {
      // fn が投げても必ず渡す。ここを条件付きにすると、1回の失敗で鍵が永久に埋まる。
      releaseAndPump(key);
    }
  }

  const isHeld = (key) => held.has(key);
  const waiting = (key) => (queues.get(key) || []).length;
  /** 観測用。今どの鍵が埋まっていて、何本待っているか。 */
  const inspect = () => [...held].map((key) => ({ key, waiting: waiting(key) }));

  return { run, isHeld, waiting, inspect };
}
