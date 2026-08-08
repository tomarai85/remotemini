// view.mjs の unit test — 電話の画面が「何と書くか」を決める層。
//
// ここが緑でも実機の見た目は保証しない(§2.13「検査の届かない所」)。
// 保証するのは**文面と継ぎ目の判断**だけ。それが本来ここに置いた理由。
import { test } from "node:test";
import assert from "node:assert/strict";
import { WIRE_REASONS } from "../src/blocked.mjs";
import {
  choiceResult, choiceView, clearQueueResult, freshness, gapNotice, interruptResult, mergeHistory,
  nextAttempt, nextHistoryLimit, queueView, readablePoll, relTime, routeLabel, scanLine, sendResult,
  subtitleOf, whoOf,
} from "../src/view.mjs";

const e = (role, text) => ({ role, text });

test("重なりが無ければそのまま繋がる", () => {
  const h = [e("user", "a"), e("assistant", "b")];
  const l = [e("user", "c")];
  assert.deepEqual(mergeHistory(h, l), [...h, ...l]);
});

test("★履歴の末尾とライブの先頭が重なったら剥がす(先に購読するので重複が出る)", () => {
  const h = [e("user", "a"), e("assistant", "b"), e("user", "c")];
  const l = [e("assistant", "b"), e("user", "c"), e("assistant", "d")];
  assert.deepEqual(mergeHistory(h, l), [
    e("user", "a"), e("assistant", "b"), e("user", "c"), e("assistant", "d"),
  ]);
});

test("ライブが丸ごと履歴に含まれていたら何も足さない", () => {
  const h = [e("user", "a"), e("assistant", "b")];
  assert.deepEqual(mergeHistory(h, [e("user", "a"), e("assistant", "b")]), h);
});

test("片方が空でも壊れない", () => {
  assert.deepEqual(mergeHistory([], [e("user", "a")]), [e("user", "a")]);
  assert.deepEqual(mergeHistory([e("user", "a")], []), [e("user", "a")]);
  assert.deepEqual(mergeHistory(null, null), []);
});

test("役割が違えば重なりと見なさない(本文だけの一致で剥がさない)", () => {
  const h = [e("user", "同じ文")];
  const l = [e("assistant", "同じ文"), e("user", "次")];
  assert.deepEqual(mergeHistory(h, l), [...h, ...l]);
});

test("★同じ発言を2回した時は剥がしすぎる(承知の上の代償)", () => {
  // 「はい」を2回続けて言うと、履歴の末尾とライブの先頭が偶然一致して1つに畳まれる。
  // 履歴側に id が無いので他に突き合わせる鍵が無い。**取りこぼしよりは軽い**、
  // という判断でここに居る。将来 /history が seq を返せる様になったら消せる欠陥。
  const h = [e("user", "はい"), e("user", "はい")];
  const l = [e("user", "はい")];
  assert.deepEqual(mergeHistory(h, l), h, "3回目が畳まれる = 既知の代償");
});

test("送信 202 verified は「送った」", () => {
  const r = sendResult(202, { accepted: true, route: "tmux", delivered: "verified" });
  assert.equal(r.kind, "ok");
  assert.equal(r.text, "送った");
});

test("★送信 202 unverified は警告 + サーバの note をそのまま出す(失敗に丸めない)", () => {
  const note = "Enter は送りましたが、本文が取り込まれた事を確認できませんでした(…)。";
  const r = sendResult(202, { accepted: true, delivered: "unverified", note });
  assert.equal(r.kind, "warn");
  assert.ok(r.text.startsWith(note), "サーバの note を先頭にそのまま置く(言い換えない)");
  assert.match(r.text, /二重/, "送り直すと二重に入りうる事を書く");
  assert.ok(!/送れませんでした|失敗/.test(r.text), "「届かなかった」と書かない");
});

test("★★送信 202 unverified で入力欄を空にしない(届いたか分からない本文を捨てない)", () => {
  // 2026-08-02 の修正。旧実装は warn でも欄を消していた = 「確認できませんでした」と
  // 書きながら成功時と同じ振る舞いをしていた。届いていなければ本文は復元不能になる。
  const r = sendResult(202, { accepted: true, delivered: "unverified", note: "…" });
  assert.equal(r.keepText, true);
});

test("送信 202 verified の時だけ入力欄を空にする", () => {
  assert.equal(sendResult(202, { delivered: "verified" }).keepText, false);
  assert.equal(sendResult(202, { route: "worker" }).keepText, false);
});

// 2026-08-02: `const b = body || {}` が「本文を読めなかった」を「鍵の無い読めた本文」に
// 潰していた。202 の本文にしか `delivered` は無いので、読めていないなら私は確認していない。
// 既存の 6 本の 202 検査は全部**整った本文**を渡していて、この入口だけが一度も測られて
// いなかった(枝ではなく入口が抜けていた)。
test("★送信 202 で本文が読めなかったら「送った」と名乗らない", () => {
  const r = sendResult(202, null);
  assert.equal(r.kind, "warn");
  assert.equal(r.keepText, true, "確認できていないのに打った本文を捨てない");
  assert.match(r.text, /読めません/);
  assert.doesNotMatch(r.text, /^送った/);
});

test("★読める本文に delivered が無いのは今まで通り ok(worker 経路は正当に持たない)", () => {
  // server.mjs の 202 `{accepted, route:"worker", seq}` には delivered が無い。
  // 変えるのは `null` だけ = 修正の範囲がここより広がっていない事の対照。
  assert.equal(sendResult(202, { route: "worker" }).kind, "ok");
  assert.equal(sendResult(202, {}).kind, "ok");
});

test("ワーカー経路の 202 も「送った」", () => {
  const r = sendResult(202, { accepted: true, route: "worker", seq: 3 });
  assert.equal(r.kind, "ok");
  assert.match(r.text, /ワーカー/);
});

test("★409 はサーバの文をそのまま出し、本文を消さない", () => {
  const msg = "画面が選択待ちです。Enter が承認や課金の選択になるため送信しません。";
  const r = sendResult(409, { error: msg });
  assert.equal(r.kind, "refused");
  assert.equal(r.text, msg);
  assert.equal(r.keepText, true, "断られた本文は消さない");
});

test("★500 は「応答しませんでした」と書かない(応答は来ている)", () => {
  const r = sendResult(500, {});
  assert.equal(r.kind, "error");
  assert.equal(r.keepText, true);
  assert.match(r.text, /HTTP 500/);
  assert.doesNotMatch(r.text, /応答しませんでした/, "状態番号を出しながら無応答と書くのは自己矛盾");
});

test("401 は鍵の問題として出し、本文を残す", () => {
  assert.deepEqual(sendResult(401, {}), {
    kind: "error",
    text: "鍵が通りませんでした。",
    keepText: true,
  });
});

// ★2026-08-08、ここに在った検査(「200 + interrupted で『止めました(Escape)。』」)は
//   **消したのではなく、下の「stopped を載せない古いサーバ」へ移して的を裏返した**。
//   旧版は `interrupted:true` を「止めました(Escape)。」に固定していたが、`interrupted`
//   は「止める対象が**居た**か」でしかなく、止まった事は誰も観測していない。つまり
//   この検査は**嘘を守っていた**。`interrupted:false` 側(警告であって失敗ではない)は
//   そのまま向こうで生きている。

// 2026-08-02: 同じ `|| {}` の病気。「止める対象が無かった」は**観測した結果**なので、
// 本文が読めていない時に既定値として出してはいけない。workPhrase の注記
// (「観測できなかった」を「静か」と書かない)と同じ誤りを1行でやっていた。
test("★割り込み: 200 で本文が読めなかったら「対象が無かった」と断定しない", () => {
  const r = interruptResult(200, null);
  assert.equal(r.kind, "warn");
  assert.match(r.text, /確認できません/);
  assert.doesNotMatch(r.text, /対象がありません/, "観測していない事を断定しない");
});

// 2026-08-03: 「押した」と「止まった」が別の値になったので、電話の文もそこで分かれる。
// ★分ける理由は表示の綺麗さではない。tmux 経路では **Escape を押しても止まらない事が
//   実際に起きる**(印が残る)。そこで「止めました」と書くと、Tom は止まったと思って
//   画面を見ない = 誤報が一番高くつく方向に倒れる。だから unverified は必ず**確かめて
//   くれ**と言う。3つの値が3つとも違う文になる事を、ここで固定する。
test("★割り込み: stopped の四値がそれぞれ別の文になる(verified/already-done/unverified/対象なし)", () => {
  const ok = interruptResult(200, { interrupted: true, stopped: "verified" });
  assert.equal(ok.kind, "ok");
  assert.match(ok.text, /止めました/);
  assert.match(ok.text, /確認/, "何をもって止まったと言っているかを書く");

  const un = interruptResult(200, { interrupted: false, stopped: "unverified", reason: "still-in-flight" });
  assert.equal(un.kind, "warn", "押せてはいるので error ではない");
  assert.match(un.text, /まだ止まって/, "止まったと読める文にしない");
  assert.match(un.text, /画面を見て/, "Tom に次の一手を示す");

  const none = interruptResult(200, { interrupted: false, stopped: null, reason: "not-in-flight" });
  assert.equal(none.kind, "warn");
  assert.match(none.text, /見当たりません/);

  // ★2026-08-03 追加。押した時には自力で終わっていた場合。画面の見え方は
  //   「止まった」と同じ(スピナーが消える)ので、`verified` と同じ文にすると
  //   **止めていないのに止めたと言う**事になる。
  const done = interruptResult(200, { interrupted: false, stopped: "already-done", reason: "finished-first" });
  assert.equal(done.kind, "ok", "止まっている事に変わりはないので警告にしない");
  assert.doesNotMatch(done.text, /止めました/, "止めていないのに「止めました」と書いている");
  assert.match(done.text, /終わって/, "何が起きたのかを書く");

  // 4つとも別の文である事(どれか2つが同じなら、電話は区別を捨てている)
  const texts = new Set([ok.text, un.text, none.text, done.text]);
  assert.equal(texts.size, 4, `四値が別の文になっていない: ${[...texts].join(" / ")}`);
});

// ★2026-08-08、この検査の前提が引っくり返ったので**的ごと**書き直した(§2.64)。
//   旧: 「ワーカー経路は tmux を持たないので画面を撮れない = `stopped` を名乗れない」
//   → 逆だった。ワーカーは**子プロセスの handle を握っている**ので、画素から推し量る
//   tmux より強い観測ができる。撮れないのは画面であって、死は撮るまでもなく分かる。
//   旧版はその誤った前提の上で「ワーカー経路 = `interrupted:true` は『止めました』でよい」
//   を**固定していた** —— 検査そのものが嘘を守っていた。
test("★割り込み: ワーカー経路も stopped を名乗る(撃った事を止まった事として書かない)", () => {
  const ok = interruptResult(200, { interrupted: true, stopped: "verified", route: "worker", waitedMs: 12 });
  assert.equal(ok.kind, "ok");
  assert.match(ok.text, /止めました/);
  assert.match(ok.text, /確認/, "何をもって止まったと言っているかを書く");

  const un = interruptResult(200, { interrupted: false, stopped: "unverified", reason: "still-alive", route: "worker" });
  assert.equal(un.kind, "warn");
  assert.match(un.text, /まだ止まって/);
  // ★ワーカー経路は Escape を**一度も押していない**(子への SIGTERM)。押していない
  //   操作を報告するのは、直そうとしている嘘の別の形。
  assert.doesNotMatch(un.text, /Escape/, "ワーカー経路で Escape を名乗ってはいけない");

  const none = interruptResult(200, { interrupted: false, stopped: null, reason: "not-running", route: "worker" });
  assert.equal(none.kind, "warn");
  assert.match(none.text, /見当たりません/);
  assert.doesNotMatch(none.text, /Escape/, "ワーカー経路で Escape を名乗ってはいけない");
});

// tmux 経路は実際に Escape を押している。ここで動作名を落とすと、今度は**やった事を
// 報告できなくなる**。経路ごとに動作名が違う事を、両側から留める。
test("★割り込み: 動作の名前は経路で分かれる(tmux = Escape / worker = 停止の信号)", () => {
  const t = interruptResult(200, { interrupted: false, stopped: "unverified", route: "tmux" });
  assert.match(t.text, /Escape/);
  const w = interruptResult(200, { interrupted: false, stopped: "unverified", route: "worker" });
  assert.match(w.text, /信号/);
  assert.notEqual(t.text, w.text, "経路が違うのに同じ文なら、どちらかが事実と違う");

  // 経路が読めない応答は、動作を**創作しない**で畳む。
  const u = interruptResult(200, { interrupted: false, stopped: "unverified" });
  assert.doesNotMatch(u.text, /Escape/);
  assert.doesNotMatch(u.text, /信号/);
});

// `stopped` を載せないのは**2026-08-08 より前のサーバ**だけ。そこでの `interrupted` は
// 「止める対象が居たか」でしかないので、居ても「止めました」とは書けない —— それが
// この節を書き直す原因になった嘘そのもの。★ここを緩めると、古い版が繋がった時にだけ
// 嘘が復活する(= 一番見つけにくい形で戻る)。
test("★割り込み: stopped を載せない古いサーバは「止まったか分からない」と書く", () => {
  const old = interruptResult(200, { interrupted: true });
  assert.equal(old.kind, "warn", "止まった確証が無いので ok にしない");
  assert.doesNotMatch(old.text, /止めました/, "対象が居た事を止まった事として書いている");
  assert.match(old.text, /分かりません/);
  assert.match(old.text, /画面を見て/, "Tom に次の一手を示す");

  const oldNone = interruptResult(200, { interrupted: false });
  assert.equal(oldNone.kind, "warn");
  assert.match(oldNone.text, /対象がありません/);
});

test("割り込み: 409 はサーバの文、401 は鍵、5xx はサーバ側の失敗", () => {
  assert.equal(interruptResult(409, { error: "宛先を確定できません。" }).text, "宛先を確定できません。");
  assert.equal(interruptResult(409, { error: "宛先を確定できません。" }).kind, "refused");
  assert.equal(interruptResult(401, {}).kind, "error");
  assert.match(interruptResult(503, {}).text, /HTTP 503/);
  assert.doesNotMatch(interruptResult(503, {}).text, /応答しませんでした/);
});

test("routeLabel: tmux は机で開いている + 動き", () => {
  assert.match(routeLabel({ route: "tmux", work: "observed" }).text, /机で開いている・動いている/);
  assert.match(routeLabel({ route: "tmux", activity: "observed" }).text, /机で開いている・動いている/);
});

test("★routeLabel: 観測できなかった事を「静か」と書かない(3箇所の規律を表示層だけが破っていた)", () => {
  // 出所 = 2026-08-02。`inject.mjs` の activity docstring と `server.mjs` の2箇所が揃って
  // 「observed でない事は待機中を意味しない」と書いているのに、view だけが断定していた。
  // 実測(2026-08-03 の測り直し): 1枚あたり **18-39%** 取りこぼす。一覧は1枚しか撮らない。
  // 害の向きが悪い: 「静か」は**打ち込んで良い**と読める。
  const noWindow = routeLabel({ route: "tmux", activity: "unknown" }).text;
  assert.doesNotMatch(noWindow, /静か/, "窓が無いのに待機中を主張しない");
  assert.match(noWindow, /状態不明/);

  // 窓が在る側(ストリーム)は**測った窓をそのまま出す**。結論ではなく観測を出す。
  const windowed = routeLabel({ route: "tmux", work: "quiet", windowMs: 5600 }).text;
  assert.doesNotMatch(windowed, /静か/);
  assert.match(windowed, /6秒 動く印なし/, "5.6 秒は四捨五入して 6 秒");

  // 陰性対照1 — 「全部 状態不明 と書く」実装との差。observed は今まで通り強く出る。
  assert.match(routeLabel({ route: "tmux", work: "observed" }).text, /動いている/);
  assert.doesNotMatch(routeLabel({ route: "tmux", work: "observed" }).text, /状態不明/);
  // 陰性対照2 — windowMs を落とした実装が「0秒 動く印なし」と嘘をつかない事。
  assert.equal(routeLabel({ route: "tmux", work: "quiet" }).text, "机で開いている・動く印なし");
});

test("★routeLabel: 選択待ちは**一覧の札から**見える(Enter が承認や課金になる)", () => {
  // 見つけ方(2026-08-02): `app.html` の `sessionRow` は `label.text` しか描かず
  // `label.screen` を捨てる。帯だけが screen を読む = 開くまで分からなかった。
  // 送信は `SEND_REFUSAL.choice` が既に拒むが、**拒む事と見える事は別**。
  const l = routeLabel({ route: "tmux", screen: "CHOICE", activity: "unknown" });
  assert.match(l.short, /選択待ち/, "★一覧に出る側(short)に入っている事");
  assert.match(l.text, /承認や課金/, "なぜ危ないかを画面で言う");
  assert.doesNotMatch(l.text, /状態不明/, "選択待ちが分かっているのに「状態不明」に埋もれさせない");
  // 上限と選択待ちが同時に立っても両方残す(片方を消す実装との差)。
  const both = routeLabel({ route: "tmux", screen: "CHOICE", limited: true }).text;
  assert.match(both, /選択待ち/);
  assert.match(both, /利用上限/);
  // 陰性対照 — 常に選択待ちと言う実装との差。
  assert.doesNotMatch(routeLabel({ route: "tmux", screen: "SENDABLE" }).short, /選択待ち/);
  assert.doesNotMatch(routeLabel({ route: "worker", state: "idle" }).short, /選択待ち/);
});

test("★routeLabel: worker 経路の上限が一覧の札に出る(§2.69、監査 R2-2)", () => {
  // 見つけ方(2026-08-08、実測): 上限で終わった会話と正常に答え終わった会話の札が
  // **バイト単位で同一**だった(どちらも `ワーカー・busy`)。tmux 側は 2026-08-02 に
  // 直っており、片方の経路にだけ古い形が残っていた —— R2-3 と同じ残り方。
  const busy = routeLabel({ route: "worker", state: "busy", limited: true });
  assert.match(busy.short, /上限/, "★一覧に出る側(short)に入っている事");
  assert.match(busy.text, /返っていません/, "何が起きたかを会話画面で言う");
  // ★過去形と現在形を混ぜない。`limited` は**直前の turn**、`state` は**今**。
  //   上限の直後に次の一件が走り始めるのは普通に起きる(行列を止めない裁定)。
  assert.match(busy.text, /答え待ち/, "今走っている事が消えている(過去形が現在形を上書きしている)");

  const idle = routeLabel({ route: "worker", state: "idle", limited: true });
  assert.match(idle.short, /利用上限/, "走っていない時は上限が見出しに立つ");

  // 上限と名指せない異常 —— **理由を創作しない**枝。文面が未知の形に変わった日に
  // 無音にならない事が此処の仕事。
  const errored = routeLabel({ route: "worker", state: "idle", errored: true });
  assert.match(errored.short, /答えなし/, "異常で終わったのに一覧が平常と同じ");
  assert.doesNotMatch(errored.text, /上限/, "上限でない失敗を上限と名乗っている(偽の診断)");
  assert.match(errored.text, /名指せません/, "分からない事を分かった風に書いている");

  // 陰性対照1 — 常に上限と書く実装との差。何も無い時は素の札に戻る。
  assert.equal(routeLabel({ route: "worker", state: "busy" }).short, "ワーカー・答え待ち");
  assert.equal(routeLabel({ route: "worker", state: "busy" }).text, "ワーカー・答え待ち");
  // 陰性対照2 — 一覧の札が説明文まで抱え込んでいない事(丸い札に入る長さ)。
  assert.ok(busy.short.length <= 12, `一覧の札は短い(実際 ${busy.short.length} 文字)`);
  assert.ok(idle.short.length <= 12, `一覧の札は短い(実際 ${idle.short.length} 文字)`);
});

test("★routeLabel: worker の状態が Tom の言葉になっている(内部トークンを生で出さない)", () => {
  // 見つけ方(2026-08-08): R2-2 を測っている最中、一覧の札が `ワーカー・busy` だった。
  // tmux 枝は全部日本語なので、これも片方の経路にだけ残っていた古い形。
  // ★隠していた物 = 電話の fixture が `ワーカー・実行中` と**日本語**で、本番より
  //   綺麗な文字列を出していた。画面を何度見ても `busy` は一度も出て来ない。
  assert.equal(routeLabel({ route: "worker", state: "busy" }).short, "ワーカー・答え待ち");
  assert.equal(routeLabel({ route: "worker", state: "ready" }).short, "ワーカー・待機");
  assert.equal(routeLabel({ route: "worker", state: "idle" }).short, "ワーカー・未起動");

  // ★言葉は観測に留める。`busy` は「送ってから result がまだ」という事実であって、
  //   Claude の中で何が起きているかではない。tmux 側が窓の無い時に「静か」と書かない
  //   (= 打って良いと読める)のと同じ線引き。
  for (const s of ["busy", "ready", "idle"]) {
    assert.doesNotMatch(routeLabel({ route: "worker", state: s }).short, /考え|生成中/,
      `${s}: 観測していない事(Claude の内心)を書いている`);
  }

  // ★知らない state は**生のまま**返す。勝手に既存の言葉へ丸めると、state が増えた事が
  //   誰にも見えないまま別の状態に化ける。
  assert.equal(routeLabel({ route: "worker", state: "draining" }).short, "ワーカー・draining",
    "知らない state を既存の言葉へ丸めている(増えた事が見えなくなる)");

  // 陰性対照 — state 自体が無い時は従来どおり素の「ワーカー」。中黒だけ残さない。
  assert.equal(routeLabel({ route: "worker" }).short, "ワーカー");
});

test("★routeLabel: 一覧の札は短く、説明は会話画面(92文字の札を一覧に出さない)", () => {
  // 実測 2026-08-02: 本番14行のうち6行が blocked で、札が**全部同じ92文字**だった。
  // 他の札は 9-10 文字。丸い札(border-radius:999px / 12px)に入る長さではない。
  const server = "この会話はペイン登録をしていないため、宛先を確定できません(同じフォルダの画面に送ると別の会話に入る恐れがあります)。その画面を rc-claude で開き直すと送れるようになります。";
  const l = routeLabel({ route: "blocked", reason: "unregistered", message: server });
  assert.equal(l.text, server, "説明はサーバの文のまま(出所を1つに保つ)");
  assert.ok(l.short.length <= 12, `一覧の札は短い(実際 ${l.short.length} 文字)`);
  assert.match(l.short, /送れない/);
  assert.ok(!/unregistered/.test(l.short), "理由コードを生で出さない");
  // 陰性対照 — 全部「送れない」に潰す実装との差。理由ごとに違う札になる。
  assert.notEqual(routeLabel({ route: "blocked", reason: "ambiguous" }).short,
                  routeLabel({ route: "blocked", reason: "unregistered" }).short);
});

test("★routeLabel: 電話に流れる理由を**全部**覆う(表が2枚ある = 片方だけ欠ける)", () => {
  // 覆うべき集合は目分量ではなく `blocked.mjs` の `WIRE_REASONS`(サーバが出しうる値の全域)。
  // ★2026-08-02: 目で突き合わせて2つ足した後にこの検査を書いたら、`not-claude` が**まだ**
  //   残っていた。表を2枚とも人が読んで揃える方法は、実際に1つ取りこぼした。
  for (const reason of WIRE_REASONS) {
    const tag = routeLabel({ route: "blocked", reason });          // サーバの文が無い = 一覧の札
    assert.match(tag.short, /送れない/, `${reason}: 札が既定`);
    assert.notEqual(tag.short, "送れない", `${reason}: 札が既定に落ちている`);
    assert.ok(!new RegExp(reason).test(tag.short), `${reason}: 理由コードが生で出ている`);
    assert.notEqual(tag.text, "宛先を確定できません。", `${reason}: 会話画面の文が既定`);
  }
  // 陰性対照 — 覆っていない値はちゃんと既定に落ちる(上が常に緑ではない事)。
  const un = routeLabel({ route: "blocked", reason: "made-up-reason" });
  assert.equal(un.short, "送れない");
  assert.equal(un.text, "宛先を確定できません。");
});

test("★routeLabel: 古い購読が運んでくる gone も blocked と同じ扱い(死んだ経路名を残さない)", () => {
  // 旧実装は `server.mjs` が `route:"gone"` を産み、使う側が**1つも無かった**。
  // 既定に落ちて「状態不明」= 理由が画面から消えていた(2026-08-02 に実行して確認)。
  // サーバ側は `blockedBody()` に寄せたが、繋ぎっ放しの購読が古い本文を持つので受け続ける。
  const l = routeLabel({ route: "gone", reason: "pane-gone" });
  assert.notEqual(l.kind, "unknown", "既定に落とさない");
  assert.match(l.short, /送れない/);
});

test("★routeLabel: 利用上限は「静か」と区別して出す(待ち続けさせない)", () => {
  // 出所 = edith 実機 2026-08-02。4回送って4回とも上限だったが、画面は
  // 入力欄が空なだけで「静か」と全く同じに見えた。電話の側はこれを見分けられない。
  assert.match(routeLabel({ route: "tmux", work: "quiet", limited: true }).text, /利用上限/);
  // ★旧版はここで `/静か/` を否定していたが、「静か」自体を廃したので**空の対照**になった。
  //   守りたかったのは「上限の見出しが動きの語に埋もれない」事なので、そちらを直接測る。
  const lim = routeLabel({ route: "tmux", work: "quiet", windowMs: 5600, limited: true }).text;
  assert.doesNotMatch(lim, /動く印なし/, "上限の時は動きの語に場所を譲らない");
  assert.doesNotMatch(lim, /状態不明/);
  // 陰性対照 — 常に上限と言う実装でも上の2行は緑になる。
  assert.doesNotMatch(routeLabel({ route: "tmux", work: "quiet", limited: false }).text, /利用上限/);
  assert.doesNotMatch(routeLabel({ route: "tmux", work: "observed" }).text, /利用上限/);
});

test("★routeLabel: 上限の告知が残っていても**動いているなら**「返りません」と言わない", () => {
  // 見つけ方(2026-08-02): 上の検査は `work:"observed"` と `limited:true` を**同時に**
  // 与えていなかったので、この組み合わせが誰にも測られていなかった。
  // 実物2枚(`limit-reached-edith.txt` の告知行 + `generating-spinner-visible.txt`)を
  // 1枚に混ぜると分類器は `{activity:"observed", limited:true}` を返す = 実在し得る組。
  //
  // なぜ害か: 上限の告知は**過去形**、回転子は**現在形**。現に答えが流れている最中に
  // 「答えは返りません」と出すと、外出先の Tom は待つのをやめる。
  // 上限の検出を足した目的(待たせない)の**逆**を、同じ機能がやる事になる。
  const live = routeLabel({ route: "tmux", activity: "observed", limited: true }).text;
  assert.match(live, /動いている/);
  assert.doesNotMatch(live, /答えは返りません/);
  // ★ただし上限の事実を**消さない**。見出しを入れ替えるだけで、情報は両方残す。
  assert.match(live, /利用上限/);

  // 陰性対照1 — 「動いている時は限界を全部黙る」実装との差。
  //   その実装だと上の3行のうち最後が落ちる。
  // 陰性対照2 — 動きを観測できていない時は今まで通り強い文言のまま(弱めていない事の確認)。
  const quiet = routeLabel({ route: "tmux", activity: "unknown", limited: true }).text;
  assert.match(quiet, /答えは返りません/);
  // 陰性対照3 — `work` 経由でも同じに倒れる(activity だけ直して work を忘れる形を塞ぐ)。
  const viaWork = routeLabel({ route: "tmux", work: "observed", limited: true }).text;
  assert.doesNotMatch(viaWork, /答えは返りません/);
});

test("★routeLabel: blocked はサーバの文を優先し、無ければ言い換える。理由コードは生で出さない", () => {
  const server = "この会話はペイン登録をしていないため、宛先を確定できません(…)。";
  assert.equal(routeLabel({ route: "blocked", reason: "unregistered", message: server }).text, server);
  const fallback = routeLabel({ route: "blocked", reason: "unregistered" }).text;
  assert.match(fallback, /ペイン登録/);
  assert.ok(!/unregistered/.test(fallback), "コードをそのまま画面に出さない");
  assert.match(routeLabel({ route: "blocked", reason: "見た事のない理由" }).text, /宛先を確定できません/);
});

test("routeLabel: 知らない route でも文字列を返す", () => {
  assert.equal(routeLabel(undefined).kind, "unknown");
  assert.equal(routeLabel({ route: "???" }).kind, "unknown");
});

test("relTime は時計に依存せず、粒度ごとに変わる", () => {
  const now = Date.parse("2026-08-02T12:00:00Z");
  const at = (s) => relTime(new Date(now - s * 1000).toISOString(), now);
  assert.equal(at(5), "たった今");
  assert.equal(at(90), "1分前");
  assert.equal(at(3 * 3600), "3時間前");
  assert.equal(at(2 * 86400), "2日前");
  assert.match(at(30 * 86400), /^\d+\/\d+$/, "1週間より前は日付");
  assert.equal(relTime("こわれた", now), "");
  assert.equal(at(-30), "たった今", "時計のずれで未来になっても壊さない");
});

// ---- 2026-08-02 に `app.html` の中から出した5つの判断 ------------------------
// どれも HTML の中に書いてあった間は、単体検査にも変異検査にも掴めなかった。

test("★nextAttempt: 一度つながっただけでは数を戻さない(受けた直後に切るサーバで毎秒再接続になる)", () => {
  const t = 1_000_000;
  assert.equal(nextAttempt(4, t, t + 4999), 5, "5秒未満しか続かなかった = 進める");
  assert.equal(nextAttempt(4, t, t + 5001), 1, "5秒より長く続いた = 仕切り直し");
});

test("nextAttempt: 一度も開けなかった回(openedAt が無い)は必ず進める", () => {
  assert.equal(nextAttempt(2, 0, 9_999_999), 3);
  assert.equal(nextAttempt(2, null, 9_999_999), 3);
});

test("★gapNotice: tail-attached は黙る(本当の取りこぼしが同じ文面に埋もれる)", () => {
  assert.equal(gapNotice("tail-attached"), null);
  assert.equal(gapNotice(undefined), null, "why が無い時に空の括弧を出さない");
  const g = gapNotice("truncated");
  assert.match(g, /切れ目/);
  assert.match(g, /truncated/, "理由は隠さない");
});

test("★nextHistoryLimit: 押すたびに必ず増える(増えないと押しても何も起きない)", () => {
  assert.equal(nextHistoryLimit(0), 150, "まだ0件でも先へ進む");
  assert.equal(nextHistoryLimit(50), 150);
  assert.ok(nextHistoryLimit(120) > 120, "現在値より必ず大きい");
  assert.equal(nextHistoryLimit(480), 500, "上限 500 で止まる(電話が固まらない側の栓)");
  assert.equal(nextHistoryLimit(500), 500);
});

test("whoOf: 知らない role は道具に寄せる(空欄にしない)", () => {
  assert.equal(whoOf("user"), "Tom");
  assert.equal(whoOf("assistant"), "Claude");
  assert.equal(whoOf("tool_result"), "道具");
  assert.equal(whoOf(undefined), "道具");
});

test("★scanLine: 欠けた値を 0 で埋めない(「読めなかった」と「0本だった」は違う)", () => {
  assert.equal(scanLine(null), "");
  assert.equal(scanLine({ files: 192, read: 30, cached: 162 }),
    "192本のうち 30本を読み、162本は前の結果を使いました。");
  assert.match(scanLine({ cached: 0 }), /\?本のうち \?本/, "files/read が無ければ ? と書く");
  assert.match(scanLine({ files: 5, read: 5 }), /0本は前の結果/, "cached だけは 0 が既定でよい");
});

test("★subtitleOf: 読み切れていない時に「発言がありません」と書かない(§2.12)", () => {
  assert.equal(subtitleOf({ lastPrompt: "直近の発言" }), "直近の発言");
  assert.match(subtitleOf({ lastPrompt: null, metadataIncomplete: true }), /読み取り範囲の外/);
  assert.match(subtitleOf({ lastPrompt: null, metadataIncomplete: false }), /まだ発言がありません/);
});

// ---- 一覧の古さ(§2.19 U1)---------------------------------------------------

test("★一覧の古さ — 測った時刻が分からない時は「新しい」側へ倒さない", () => {
  // ★これが本題。ここを `{text:"", stale:false}` にすると、時刻を取り損ねた画面は
  //   **警告が消えるだけ**で、出している値は古いまま = 一番静かな嘘になる。
  for (const bad of [0, null, undefined, NaN, Infinity]) {
    const f = freshness(bad, 1_000_000);
    assert.equal(f.stale, true, `${String(bad)} を新しい側へ倒した`);
    assert.match(f.text, /不明/, "分からない事を文でも言っていない");
  }
});

test("★一覧の古さ — 60秒で「今」を名乗るのをやめる(画面自身の目盛りに合わせる)", () => {
  const t0 = 1_000_000;
  // 59秒までは relTime が「たった今」に潰す領域 = より細かい古さは画面上で区別できない
  assert.equal(freshness(t0, t0).stale, false);
  assert.equal(freshness(t0, t0 + 59_000).stale, false, "59秒で古いと言い出した");
  assert.equal(freshness(t0, t0 + 60_000).stale, true, "60秒を過ぎても「今」を名乗っている");
  // ★陽性対照 — 文面が実際に切り替わる事(stale の旗だけ立てて文が同じでは読めない)
  assert.match(freshness(t0, t0 + 30_000).text, /30秒前/);
  assert.match(freshness(t0, t0 + 120_000).text, /2分前/);
  assert.match(freshness(t0, t0 + 7_200_000).text, /2時間前/);
  assert.match(freshness(t0, t0 + 172_800_000).text, /2日前/);
  // 古い時は「どうすれば直るか」まで出す(見せるだけでは手が無い)
  assert.match(freshness(t0, t0 + 120_000).text, /更新/);
});

test("一覧の古さ — 時計がずれて未来を指しても壊れない(relTime と同じ扱い)", () => {
  const f = freshness(1_000_000, 900_000); // now が過去
  assert.equal(f.stale, false);
  assert.match(f.text, /たった今/);
});

// ---- 長待ち受けの応答の形 (DESIGN §2.36) --------------------------------------
// ★この検査群が在る理由そのものが、初版の取り違えを掴んだ事: 判断を app.html に
//   書いていた時は `entries` しか見ておらず、**ワーカー経路の poll が毎回投げる**形
//   だったのに、静的検査(app-html.test.mjs)も e2e も緑のままだった。

test("★tmux 経路の形を読める(entries を持つ)", () => {
  assert.equal(readablePoll({ items: [{ kind: "message", entries: [e("user", "a")] }] }), true);
  assert.equal(readablePoll({ items: [] }), true);
  assert.equal(readablePoll({ items: [{ kind: "gap", why: "ring-overflow" }] }), true);
});

test("★★ワーカー経路の形も読める(entries でなく event を運ぶ)", () => {
  // これが偽になると、ワーカー経路の電話は poll のたびに例外へ落ちて
  // 「切れました」を出し続ける = 経路まるごと使えない。初版はここで落ちた。
  assert.equal(readablePoll({ items: [{ kind: "message", event: { type: "user_sent", text: "x" }, seq: 3 }] }), true);
});

test("★読めない形は真にしない(空へ化かさない)", () => {
  assert.equal(readablePoll({ items: [{ kind: "message" }] }), false);       // どちらの欄も無い
  assert.equal(readablePoll({ items: [{ kind: "message", entries: "abc" }] }), false); // 配列でない
  assert.equal(readablePoll({ items: [{ kind: "message", event: [] }] }), false);      // 配列は event でない
  assert.equal(readablePoll({ items: [null] }), false);
  assert.equal(readablePoll({ items: "nope" }), false);
  assert.equal(readablePoll({}), false);
  assert.equal(readablePoll(null), false);
});

test("知らない kind は拒まない(古い電話が新しいサーバで固まらない)", () => {
  assert.equal(readablePoll({ items: [{ kind: "future-thing", whatever: 1 }] }), true);
});

test("★陰性対照: 何でも真を返す形なら上の検査は落ちる", () => {
  // `readablePoll` を `() => true` に潰したら「読めない形は真にしない」が落ちる事の確認。
  // 対照が無いと、この関数を骨抜きにしても全部緑のままになりうる。
  const alwaysTrue = () => true;
  assert.equal(alwaysTrue({ items: [{ kind: "message" }] }), true); // = 検査が掴む差
  assert.notEqual(readablePoll({ items: [{ kind: "message" }] }), alwaysTrue());
});

// ---- 選択待ちの操作面(2026-08-04)-------------------------------------------
//
// この層だけは間違いの向きが**安全確認を押す側**へ倒れうるので、
// 「押せる」と「押せない」の両方を、それぞれ落とし方付きで固定する。
const menu = (over = {}) => ({
  screen: "CHOICE",
  choice: {
    kind: "benign",
    matcher: "select-model@2",
    head: ["Select model"],
    options: [
      { n: 1, label: "Opus 5", cursor: false },
      { n: 2, label: "Sonnet 5", cursor: true },
      { n: 3, label: "Haiku 4.5", cursor: false },
    ],
    cursor: 2,
    footer: "",
    keys: ["digit", "enter", "escape"],
    digest: "abc123def4567890",
    ...over,
  },
});

test("良性メニュー: 実在する選択肢の数だけ数字が出る(1-9 を並べない)", () => {
  const v = choiceView(menu());
  assert.equal(v.show, true);
  assert.equal(v.reason, "");
  assert.deepEqual(v.buttons.map((b) => b.key), ["1", "2", "3", "enter", "escape"]);
  // ★数字の**個数**を先に言う。3択に 9 個出す実装でも「1 が在る」だけなら通ってしまう。
  assert.equal(v.buttons.filter((b) => /^\d$/.test(b.key)).length, 3);
  assert.equal(v.digest, "abc123def4567890");
});

test("ボタンの語に選択肢の本文が入る(押す物が読める)", () => {
  const v = choiceView(menu());
  assert.equal(v.buttons[0].label, "1. Opus 5");
  // Enter はカーソルの載っている選択肢を名乗る = 人の目でも「見た物と押す物が同じ」
  assert.equal(v.buttons[3].label, "Enter(2. Sonnet 5 で決定)");
  // Escape はカーソルに依らないので、括弧の中は固定の語。★鍵名だけで出してはいけない
  //   —— 同じカードに `1. Opus 5` と `Enter(…)` が並ぶ中で其処だけ英語になる(監査 S8-20)。
  assert.equal(v.buttons[4].label, "Escape(中止)");
});

test("カーソルが読めない時、Enter は何を決めるか名乗らない(断定しない)", () => {
  const v = choiceView(menu({ cursor: -1 }));
  assert.equal(v.buttons.find((b) => b.key === "enter").label, "Enter");
});

test("★keys が空なら押す物を出さない —— 許可の出所はサーバの keys ただ1つ", () => {
  for (const kind of ["hard-stop", "unrecognized"]) {
    const v = choiceView(menu({ kind, keys: [] }));
    assert.equal(v.show, true, "押せなくても『選択待ちである事』は見える");
    assert.equal(v.buttons.length, 0, `${kind} に操作を出した`);
    assert.ok(v.reason.length > 0, `${kind} の理由が無い`);
  }
  // ★kind が benign のままでも keys が空なら出さない = 電話が kind で自前に判断していない事
  //   (ここが `kind === "benign"` を見る実装だと、この検査だけが落ちる)
  assert.equal(choiceView(menu({ keys: [] })).buttons.length, 0);
});

test("★hard-stop の文面は『机で確認』へ倒す(自動化に安全確認を押させない)", () => {
  const v = choiceView(menu({ kind: "hard-stop", keys: [] }));
  assert.match(v.reason, /許可・信頼の確認/);
  assert.match(v.reason, /机/);
});

test("★指紋が無ければ押す物を出さない(サーバは digest 必須 = 出せば必ず失敗する)", () => {
  for (const bad of ["", null, undefined, 123]) {
    const v = choiceView(menu({ digest: bad }));
    assert.equal(v.buttons.length, 0, `digest=${String(bad)} で操作を出した`);
    assert.equal(v.digest, "", "読めない指紋を値として通した");
    assert.ok(v.reason.length > 0);
  }
});

test("keys に digit が無ければ数字は出ない(Enter/Escape だけ)", () => {
  const v = choiceView(menu({ keys: ["enter", "escape"] }));
  assert.deepEqual(v.buttons.map((b) => b.key), ["enter", "escape"]);
});

test("keys に enter が無ければ Enter は出ない", () => {
  const v = choiceView(menu({ keys: ["digit", "escape"] }));
  assert.deepEqual(v.buttons.map((b) => b.key), ["1", "2", "3", "escape"]);
});

test("選択肢の番号が 1-9 の外なら、その1個だけ落ちる", () => {
  const v = choiceView(menu({
    options: [{ n: 0, label: "零" }, { n: 2, label: "二" }, { n: 10, label: "十" }, { n: 1.5, label: "半" }],
  }));
  assert.deepEqual(v.buttons.map((b) => b.key), ["2", "enter", "escape"]);
});

test("CHOICE でなければ操作面ごと出さない", () => {
  for (const s of [null, undefined, "CHOICE", {}, { screen: "IDLE" }, { screen: "BUSY", choice: menu().choice }]) {
    assert.equal(choiceView(s).show, false, `${JSON.stringify(s)} で操作面を出した`);
  }
});

test("CHOICE だが choice が無い(強い文言 + 番号行の経路)= 出すが押せない", () => {
  const v = choiceView({ screen: "CHOICE" });
  assert.equal(v.show, true);
  assert.equal(v.buttons.length, 0);
  assert.ok(v.reason.length > 0);
});

test("形の壊れた choice を投げずに受け止める(古い電話 x 新しいサーバ)", () => {
  const v = choiceView({ screen: "CHOICE", choice: { kind: "benign", keys: "digit", options: "x", head: 1, digest: "d" } });
  assert.equal(v.show, true);
  assert.deepEqual(v.head, []);
  assert.deepEqual(v.options, []);
  assert.equal(v.buttons.length, 0, "keys が配列でない時に押せる物を出した");
});

test("★applied は文字列の値域。verified だけが『押しました』", () => {
  // 初版は `applied === false` を見ていて、`"unverified"` が全部「押しました」に落ちていた。
  // 値域は inject.mjs の choice docstring が正本。
  assert.equal(choiceResult(200, { accepted: true, applied: "verified" }).kind, "ok");
  assert.equal(choiceResult(200, { accepted: true, applied: "unverified", note: "動いていません" }).kind, "warn");
  assert.equal(choiceResult(200, { accepted: true, applied: "moved-to-hard-stop", note: "★確認画面" }).kind, "warn");
  assert.equal(choiceResult(200, { accepted: true, applied: null }).kind, "warn");
  assert.equal(choiceResult(200, { accepted: true }).kind, "warn");
});

test("★『押した』と『効いた』を混ぜない —— 動いていない時に成功の語を出さない", () => {
  const v = choiceResult(200, { accepted: true, applied: "unverified", note: "画面が変わっていません。" });
  assert.equal(v.text, "画面が変わっていません。");
  assert.doesNotMatch(v.text, /押しました|決定しました/);
  // 許可確認へ着地した時も同じ。ここを ok にすると**一番知らせたい着地**が成功として出る。
  const h = choiceResult(200, { accepted: true, applied: "moved-to-hard-stop", note: "★許可の確認が出ました。" });
  assert.notEqual(h.kind, "ok");
  assert.match(h.text, /許可/);
});

test("読めない 200 を『押せた』と名乗らない", () => {
  const v = choiceResult(200, null);
  assert.equal(v.kind, "warn");
  assert.match(v.text, /読めませんでした/);
});

test("断りと失敗の文面はサーバの物を出す(電話が言い換えない)", () => {
  assert.deepEqual(choiceResult(409, { error: "そのメニューはもう在りません。" }),
    { kind: "refused", text: "そのメニューはもう在りません。" });
  assert.deepEqual(choiceResult(400, { error: "打てない鍵です。" }),
    { kind: "error", text: "打てない鍵です。" });
  assert.equal(choiceResult(401, {}).kind, "error");
  assert.equal(choiceResult(503, null).kind, "error");
  assert.match(choiceResult(418, null).text, /418/);
});

// ---- 送信待ち(2026-08-04)----------------------------------------------------

test("送信待ちが1件以上なら、数と取り消しの札を出す", () => {
  const v = queueView({ route: "worker", queued: 2 }, 1000, 1000);
  assert.equal(v.show, true);
  assert.equal(v.known, true);
  assert.equal(v.count, 2);
  assert.match(v.text, /2 件/);
  assert.equal(v.clearLabel, "2 件を取り消す");
});

test("送信待ち0件は何も出さない(空の面を置かない)", () => {
  const v = queueView({ route: "worker", queued: 0 }, 1000, 1000);
  assert.equal(v.show, false);
  assert.equal(v.known, true, "0 は**観測した結果**なので known は true");
});

// ---- 送信待ちの数の**古さ**(2026-08-04)--------------------------------------
//
// この面は poll が返った時にしか描き直されない。返らなくなった時に「送信待ち 2 件」を
// 現在形で出し続けるのが、直したかった穴。判定は一覧と**同じ** `freshness` から取る。

test("★取れたばかりの数には古さの警告を付けない", () => {
  const T = 1_700_000_000_000;
  const v = queueView({ route: "worker", queued: 2 }, T, T + 5_000);
  assert.equal(v.stale, false);
  assert.equal(v.ageText, "5秒前の値");
});

test("★60秒を跨いだ数は古いと言う ―― 面が描き直されていない事が見える", () => {
  const T = 1_700_000_000_000;
  const v = queueView({ route: "worker", queued: 2 }, T, T + 60_000);
  assert.equal(v.stale, true, "1分前の数を現在形で出している");
  assert.match(v.ageText, /1分前の値/);
  // 数そのものは動かさない。古いのは**いつ測ったか**であって、値の書き換えではない。
  assert.equal(v.count, 2);
  assert.match(v.text, /2 件/);
});

test("★測った時刻が分からない数を『新しい』側へ倒さない(fail-closed)", () => {
  const T = 1_700_000_000_000;
  for (const bad of [0, undefined, null, NaN, "1700000000000"]) {
    const v = queueView({ route: "worker", queued: 2 }, bad, T);
    assert.equal(v.stale, true, `${String(bad)} を新しい側へ倒している`);
    assert.equal(v.ageText, "いつ測った値か不明");
  }
});

test("★古さの境目を一覧と共有する ―― 画面ごとの二つ目の 60 秒を作らない", () => {
  // 此処が `freshness` と1文字でもずれたら、同じ「古い」が画面ごとに違う時刻で起きる。
  const T = 1_700_000_000_000;
  for (const d of [0, 59_000, 60_000, 3_600_000, 86_400_000]) {
    const f = freshness(T, T + d);
    const v = queueView({ queued: 1 }, T, T + d);
    assert.equal(v.ageText, f.text, `${d}ms で文面が一覧とずれている`);
    assert.equal(v.stale, f.stale, `${d}ms で古さの判定が一覧とずれている`);
  }
});

test("★面を出さない枝は古さを名乗らない(数の消えた『2分前の値』を残さない)", () => {
  const T = 1_700_000_000_000;
  for (const d of [{ queued: 0 }, { queued: null }, {}, null]) {
    const v = queueView(d, T - 600_000, T); // 10分前 = 出していれば必ず stale になる古さ
    assert.equal(v.show, false);
    assert.equal(v.ageText, "", `${JSON.stringify(d)} で古さの行だけ生き残っている`);
    assert.equal(v.stale, false);
  }
});

test("★`queued:null`(tmux 経路)は『0件』と同じ枝に落ちない ―― 観測していない", () => {
  // 机の会話の行列は Claude Code の TUI が持っていて、数は観測できない。
  // 表示はどちらも「出さない」で同じだが、**判定の意味が違う**。畳むと、後から
  // 「机の会話でも 0 件と出しては?」という直し方が正しく見えてしまう。
  const unknown = queueView({ route: "tmux", queued: null });
  assert.equal(unknown.show, false);
  assert.equal(unknown.known, false, "観測していない事が known に出ていない");
  // 欄そのものが無い応答(古いサーバ / 読めなかった本文)も同じ扱い。
  assert.equal(queueView({ route: "worker" }).known, false);
  assert.equal(queueView(null).known, false);
  // 数でない物を数として飲まない。
  for (const bad of ["2", NaN, Infinity, true, {}, []]) {
    assert.equal(queueView({ queued: bad }).known, false, `${String(bad)} を数として飲んでいる`);
  }
});

test("取り消しの応答: 件数はサーバの物、走っている番は止まらないと必ず書く", () => {
  const v = clearQueueResult(200, { dropped: 3, route: "worker" });
  assert.equal(v.kind, "ok");
  assert.match(v.text, /3 件/);
  assert.match(v.text, /止まりません/, "『取り消した = 全部止まった』と読める文になっている");
  assert.equal(clearQueueResult(200, { dropped: 0 }).kind, "ok");
  assert.match(clearQueueResult(200, { dropped: 0 }).text, /残っていません/);
});

test("★読めない 200 / `dropped` の無い 200 を『0件だった』に丸めない", () => {
  // interruptResult と同じ誤り。「無かった」は観測した結果であって既定値ではない。
  assert.equal(clearQueueResult(200, null).kind, "warn");
  assert.equal(clearQueueResult(200, {}).kind, "warn");
  assert.equal(clearQueueResult(200, { dropped: "3" }).kind, "warn", "文字列を件数として飲んでいる");
});

test("断りと失敗の文面はサーバの物を出す(取り消し)", () => {
  assert.deepEqual(
    clearQueueResult(409, { error: "この会話は机で開かれています。", reason: "queue-not-ours" }),
    { kind: "refused", text: "この会話は机で開かれています。" },
  );
  assert.equal(clearQueueResult(401, {}).kind, "error");
  assert.equal(clearQueueResult(503, null).kind, "error");
  assert.match(clearQueueResult(418, null).text, /418/);
});
