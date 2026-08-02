// view.mjs の unit test — 電話の画面が「何と書くか」を決める層。
//
// ここが緑でも実機の見た目は保証しない(§2.13「検査の届かない所」)。
// 保証するのは**文面と継ぎ目の判断**だけ。それが本来ここに置いた理由。
import { test } from "node:test";
import assert from "node:assert/strict";
import { WIRE_REASONS } from "../src/blocked.mjs";
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
  // server.mjs:790 の `{accepted, route:"worker", seq}` には delivered が無い。
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

test("★割り込み: 200 + interrupted で「止めました」、interrupted:false は警告(失敗ではない)", () => {
  assert.deepEqual(interruptResult(200, { interrupted: true }), {
    kind: "ok",
    text: "止めました(Escape)。",
  });
  const none = interruptResult(200, { interrupted: false });
  assert.equal(none.kind, "warn", "止める対象が無いのは正常な結果。error に丸めない");
  assert.match(none.text, /対象がありません/);
});

// 2026-08-02: 同じ `|| {}` の病気。「止める対象が無かった」は**観測した結果**なので、
// 本文が読めていない時に既定値として出してはいけない。workPhrase の注記
// (「観測できなかった」を「静か」と書かない)と同じ誤りを1行でやっていた。
test("★割り込み: 200 で本文が読めなかったら「対象が無かった」と断定しない", () => {
  const r = interruptResult(200, null);
  assert.equal(r.kind, "warn");
  assert.match(r.text, /確認できません/);
  assert.doesNotMatch(r.text, /対象がありません/, "観測していない事を断定しない");
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
  // 出所 = 2026-08-02。`inject.mjs:246` / `server.mjs:229` / `server.mjs:500` が揃って
  // 「observed でない事は待機中を意味しない」と書いているのに、view だけが断定していた。
  // 実測: 生成中の1枚あたり検出率は 31%。一覧は1枚しか撮らないので 69% 外す。
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
  // 旧実装は `server.mjs:486` が `route:"gone"` を産み、使う側が**1つも無かった**。
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
