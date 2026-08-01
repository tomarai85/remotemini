// view.mjs の unit test — 電話の画面が「何と書くか」を決める層。
//
// ここが緑でも実機の見た目は保証しない(§2.13「検査の届かない所」)。
// 保証するのは**文面と継ぎ目の判断**だけ。それが本来ここに置いた理由。
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  gapNotice, interruptResult, mergeHistory, nextAttempt, nextHistoryLimit,
  relTime, routeLabel, scanLine, sendResult, subtitleOf, whoOf,
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

test("★割り込み: 200 + interrupted で「止めました」、interrupted:false は警告(失敗ではない)", () => {
  assert.deepEqual(interruptResult(200, { interrupted: true }), {
    kind: "ok",
    text: "止めました(Escape)。",
  });
  const none = interruptResult(200, { interrupted: false });
  assert.equal(none.kind, "warn", "止める対象が無いのは正常な結果。error に丸めない");
  assert.match(none.text, /対象がありません/);
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
  assert.match(routeLabel({ route: "tmux", work: "quiet" }).text, /静か/);
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
