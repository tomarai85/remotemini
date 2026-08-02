// 生存信号の判定(DESIGN §7-P)。**鳴らない壊れ方**を掴む事が主眼。
//
// 監視の欠陥は「鳴りすぎ」より「鳴らない」の方が致命的で、しかも放置すると
// 一生気付けない(yoda: watchdog は設計どおり動いたのに Tom には 46 時間届かなかった)。
// なので「鳴る」だけでなく「**鳴らないべき時に鳴らない**」も同じ数だけ固定する。
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  initialHealthState,
  healthTransition,
  healthMessage,
  humanSeconds,
  markDelivered,
} from "../src/health.mjs";

const OK = { ok: true };
const NG = (reason = "curl exit 7") => ({ ok: false, reason });

// 観測の並びを畳む小道具(now は 600 秒 = 10 分刻み、実際の間隔と同じ)。
//
// ★`deliver` = 出し先が受け取れたか。既定 true(= 出し先が正常)。false にすると
//   「文面は出来たが届かなかった」を再現できる —— これは机上の想定ではなく、
//   実際に台本を壊して測った形(`src/health.mjs` の `markDelivered` の注記)。
function run(probes, opts = {}) {
  const { deliver = true, ...tOpts } = opts;
  let st = initialHealthState();
  const notes = [];
  probes.forEach((p, i) => {
    const r = healthTransition(st, p, 1000 + i * 600, tOpts);
    st = r.state;
    if (r.notify) {
      notes.push({ at: 1000 + i * 600, ...r.notify });
      if (deliver) st = markDelivered(st);   // 台本は出し先が 0 で終わった時だけこれを呼ぶ
    }
  });
  return { state: st, notes };
}

test("既定は3回連続で落ちたと言う(2回では言わない)", () => {
  assert.equal(run([NG(), NG()]).notes.length, 0);
  const r = run([NG(), NG(), NG()]);
  assert.equal(r.notes.length, 1);
  assert.equal(r.notes[0].kind, "down");
  assert.equal(r.state.status, "down");
});

test("★落ちたと言って**届いた**後は、失敗が続いても鳴らさない", () => {
  const r = run([NG(), NG(), NG(), NG(), NG(), NG()]);
  assert.equal(r.notes.length, 1); // 10分ごとに鳴る監視は黙らされる = 気付けなくなる
  assert.equal(r.state.owed, null, "借りは返済済み");
});

test("★★届かなかったら、閾値を越えている限り毎回鳴らし直す(沈黙する監視を作らない)", () => {
  // 元の欠陥: 出し先が壊れている間に status が down に確定し、**出し先が直っても
  // 二度と鳴らなかった**。実際に台本で再現させてからこの検査を書いた。
  const r = run([NG(), NG(), NG(), NG(), NG()], { deliver: false });
  assert.equal(r.notes.length, 3);                  // 3・4・5回目 = 閾値を越えた全部
  assert.equal(r.state.owed.kind, "down");          // 借りが残っている = 知らせ終えていない
  assert.equal(r.state.status, "down");             // 観測した事実の側は変わらない
});

test("★届かない回を挟んでも、届いた時点で止まる(直った瞬間に1通だけ)", () => {
  let st = initialHealthState();
  const notes = [];
  // 3回失敗して鳴るが届かない → 4回目でまた鳴り、今度は届く → 5回目は静か
  [NG(), NG(), NG(), NG(), NG()].forEach((p, i) => {
    const r = healthTransition(st, p, 1000 + i * 600);
    st = r.state;
    if (r.notify) {
      notes.push(i);
      if (i === 3) st = markDelivered(st);   // 4回目だけ配達成功
    }
  });
  assert.deepEqual(notes, [2, 3]);           // 5回目(i=4)は鳴らない
  assert.equal(st.owed, null);
});

test("★★届いた印を次の落下へ持ち越さない(持ち越すとその回は一度も鳴らない)", () => {
  // 借りが status と独立に生き残ると、復帰後の**次の**障害で沈黙する。
  // `status` が二役を持っていた元の欠陥と同じ罠なので、境界を検査で固定する。
  const r = run([NG(), NG(), NG(), OK, NG(), NG(), NG()]);
  assert.deepEqual(r.notes.map((n) => n.kind), ["down", "recovered", "down"]);
});

test("★届かなかった落下の後でも、復帰は**必ず**知らせる(ここを黙らせない)", () => {
  // 「落ちた」が一度も届いていない時、復帰の知らせまで抑えるのは筋が通って見える
  // (Tom は落ちた事を知らないのだから)。が、それをやると **出し先が壊れている間の
  // 障害が丸ごと無かった事になる**。復帰の文面は「いつから何秒落ちていたか」を含むので、
  // これが Tom の耳に入る最初の一報になる = 沈黙より遥かに良い。
  // 将来「未通知の落下に対する復帰は抑える」と直したくなる人へ向けた杭。
  const r = run([NG(), NG(), NG(), OK], { deliver: false });
  assert.deepEqual(r.notes.map((n) => n.kind), ["down", "recovered"]);
  assert.ok(r.notes[1].seconds >= 0, "落ちていた長さが復帰の知らせに載っている");
});

test("★★届かなかった『戻りました』も、届くまで鳴らし直す(落下と同じ扱い)", () => {
  // 実測して見つけた非対称(2026-08-02): 落下は鳴り直すのに復帰は0回だった。
  // 起きる条件 = 落下は届いた後で出し先が壊れる。すると Tom は**復旧済みの物を
  // 落ちたままだと思い続ける**。監視が「異常なし」と黙るのと同じ質の嘘。
  let st = initialHealthState();
  const kinds = [];
  [NG(), NG(), NG(), OK, OK, OK].forEach((p, i) => {
    const r = healthTransition(st, p, 1000 + i * 600);
    st = r.state;
    if (!r.notify) return;
    kinds.push(r.notify.kind);
    if (r.notify.kind === "down") st = markDelivered(st);   // 落下だけ届く
  });
  assert.deepEqual(kinds, ["down", "recovered", "recovered", "recovered"]);
});

test("★鳴らし直す『戻りました』の文面は凍結する(落ちていた長さが伸びない)", () => {
  // 復旧は**もう起きた**出来事。再送のたびに now から測り直すと
  // 「30分落ちていました」が10分ごとに伸びる = 遅れて届く嘘になる。
  const r = run([NG(), NG(), NG(), OK, OK, OK], { deliver: false });
  const recs = r.notes.filter((n) => n.kind === "recovered");
  assert.ok(recs.length >= 2, "鳴らし直している");
  assert.equal(recs[0].seconds, recs[recs.length - 1].seconds);
  assert.equal(recs[0].since, 1000);
});

test("★届いた『戻りました』は鳴り直さない(借りを返したら黙る)", () => {
  const r = run([NG(), NG(), NG(), OK, OK, OK]);   // deliver=true
  assert.equal(r.notes.filter((n) => n.kind === "recovered").length, 1);
  assert.equal(r.state.owed, null);
});

test("★未配達の『戻りました』は、次に落ちた時点で捨てる(嘘を遅れて届けない)", () => {
  // 借りは「今の状態」を指す物であって履歴の箱ではない。今落ちているのに
  // 『戻りました』を後から配達するのは、間違った現在を伝える事。
  const r = run([NG(), NG(), NG(), OK, NG(), NG(), NG()], { deliver: false });
  assert.equal(r.state.owed.kind, "down");
  assert.equal(r.notes[r.notes.length - 1].kind, "down");
});

test("★★項が無い状態は『伝え済み』ではなく『分からない』(= 鳴らし直す側へ倒す)", () => {
  // 項の名前を変えた時に一度ここを踏んだ(2026-08-02、台本の対照が先に捕まえた):
  // `owed` の欠落を null(返済済み)に丸めたら、旧版の状態ファイルを読んだ瞬間に
  // **落下が一度も鳴らなくなった**。JSON は undefined を書き出さないので、
  // 「項が無い」は上げ直しのたびに必ず通る道 —— 沈黙側に倒すと全部の警報を失う。
  const legacy = { status: "down", fails: 9, firstFailAt: 1000 };   // owed が無い
  const r = healthTransition(legacy, NG(), 5000);
  assert.equal(r.notify.kind, "down", "分からない = まだ伝えていない と読む");
  const settled = healthTransition({ ...legacy, owed: null }, NG(), 5000);
  assert.equal(settled.notify, null, "明示的な null(返済済み)は黙る");
});

test("途中で1回成功すると連続が切れ、落ちたと言わない", () => {
  const r = run([NG(), NG(), OK, NG(), NG()]);
  assert.equal(r.notes.length, 0);
  assert.equal(r.state.fails, 2);
});

test("落ちた後の1回成功で戻ったと言う", () => {
  const r = run([NG(), NG(), NG(), OK]);
  assert.deepEqual(r.notes.map((n) => n.kind), ["down", "recovered"]);
  assert.equal(r.state.status, "up");
});

test("★unknown からの初回成功では「戻った」と言わない(何も起きていないのに鳴らない)", () => {
  const r = run([OK, OK]);
  assert.equal(r.notes.length, 0);
  assert.equal(r.state.status, "up");
});

test("★戻ったと一度言った後、成功が続いても鳴り続けない", () => {
  const r = run([NG(), NG(), NG(), OK, OK, OK]);
  assert.equal(r.notes.filter((n) => n.kind === "recovered").length, 1);
});

test("since は連続の**1回目**の時刻(閾値に達した時刻ではない)", () => {
  const r = run([NG(), NG(), NG()]);
  assert.equal(r.notes[0].since, 1000);        // 1回目の失敗
  assert.equal(r.notes[0].seconds, 1200);      // そこから 20 分
});

test("成功を挟むと since も測り直す", () => {
  const r = run([NG(), OK, NG(), NG(), NG()]);
  assert.equal(r.notes[0].since, 1000 + 2 * 600); // 3件目(成功の次)から数える
});

test("戻った通知は落ちていた時間を持つ", () => {
  const r = run([NG(), NG(), NG(), OK]);
  const rec = r.notes.find((n) => n.kind === "recovered");
  assert.equal(rec.since, 1000);
  assert.equal(rec.seconds, 1800);
});

test("閾値1なら初回の失敗で言う", () => {
  const r = run([NG()], { threshold: 1 });
  assert.equal(r.notes.length, 1);
  assert.equal(r.notes[0].kind, "down");
});

test("★閾値が0以下や小数なら投げる(黙って鳴らない監視を作らせない)", () => {
  const st = initialHealthState();
  for (const bad of [0, -1, 2.5, "3", null, NaN, Infinity]) {
    assert.throws(() => healthTransition(st, NG(), 0, { threshold: bad }), /threshold/);
  }
  // undefined だけは「既定(3)を使う」の合図なので投げない
  assert.doesNotThrow(() => healthTransition(st, NG(), 0, { threshold: undefined }));
});

test("now が数でないなら投げる(時計を渡し忘れて全部同じ時刻になるのを防ぐ)", () => {
  const st = initialHealthState();
  assert.throws(() => healthTransition(st, OK, NaN), /now/);
  assert.throws(() => healthTransition(st, OK, "0"), /now/);
});

test("理由は落ちた通知に載る(観測側の生の文言をそのまま運ぶ)", () => {
  const r = run([NG("connect timeout"), NG("connect timeout"), NG("connect timeout")]);
  assert.equal(r.notes[0].reason, "connect timeout");
});

test("★文面に会話の中身が入らない(通知経路に秘密を流さない)", () => {
  const r = run([NG("curl exit 7"), NG("curl exit 7"), NG("curl exit 7")]);
  const msg = healthMessage(r.notes[0], "desk.tailnet.example", (t) => `T${t}`);
  assert.match(msg, /rc-backend が応答しません/);
  assert.match(msg, /desk\.tailnet\.example/);
  // 負の対照: 判定は probe しか見ていないので、載せようが無い事を形で固定する
  assert.equal(/session|cwd|pane|tmux|api\.key/i.test(msg), false);
});

test("通知が無い時は文面も無い", () => {
  assert.equal(healthMessage(null, "h", (t) => String(t)), null);
});

test("humanSeconds: 分未満は秒で言う(「0分」と言わない)", () => {
  assert.equal(humanSeconds(0), "0秒");
  assert.equal(humanSeconds(59), "59秒");
  assert.equal(humanSeconds(60), "1分");
  assert.equal(humanSeconds(3600), "1時間");
  assert.equal(humanSeconds(3660), "1時間1分");
  assert.equal(humanSeconds(-1), "不明な時間");
});
