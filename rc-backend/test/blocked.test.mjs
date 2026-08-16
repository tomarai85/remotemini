// 「送れない」の文面層。★この検査が存在しなかったから今日の欠陥が実行するまで残った
// (`blockedMessage` は `server.mjs` に在り、`server.mjs` は import すると listen する)。
//
// 押さえるのは1点だけ: **入り得る理由の全域を、文面が覆っているか**。
// 覆えていない値は既定に落ち、以前の既定は「cwd 不一致」という**具体的な嘘**だった。
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  RESOLVE_REASONS, WIRE_REASONS, UNDECIDABLE,
  blockedMessage, blockedBody, unknownBlockedMessage, paneFaultReason,
  PANE_FAULT_VIEW, paneFaultView,
} from "../src/blocked.mjs";

const ctx = { candidates: 2, panePath: "/Users/edith/Projects", source: "registry" };

test("★電話に流れる理由は全部、既定でない文を持つ(覆い漏れ = 嘘の文)", () => {
  for (const reason of WIRE_REASONS) {
    const msg = blockedMessage({ ...ctx, reason });
    assert.equal(typeof msg, "string");
    assert.ok(msg.length >= 10, `${reason}: 文が短すぎる`);
    assert.notEqual(msg, unknownBlockedMessage(reason), `${reason} が既定に落ちている`);
  }
});

test("覆っていない理由は既定に落ちる(上の検査が常に緑にならない事の対照)", () => {
  const msg = blockedMessage({ ...ctx, reason: "made-up-reason" });
  assert.equal(msg, unknownBlockedMessage("made-up-reason"));
  // ★既定は**原因を名乗らない**。以前はここが cwd 不一致の文で、知らない値が来ると
  //   もっともらしい嘘が出た(2026-08-02 に `none` で実際に出た)。
  assert.ok(!msg.includes("現在地"), "既定が原因を作っている");
  assert.ok(!msg.includes("一致しません"), "既定が原因を作っている");
});

test("★resolveSessionPane の全域を通しても、電話に出る理由は WIRE_REASONS の中に収まる", () => {
  // これが今日の欠陥を直接掴む検査。`feedTick` だけが**絞らずに**全域を渡していて、
  // `none` / `not-claude` が `blockedMessage` の想定外だった。
  for (const reason of RESOLVE_REASONS) {
    const body = blockedBody({ pane: null, reason, ...ctx });
    assert.equal(body.route, "blocked");
    assert.ok(WIRE_REASONS.includes(body.reason), `${reason} -> ${body.reason} は電話の語彙に無い`);
    assert.notEqual(body.message, unknownBlockedMessage(body.reason), `${reason} が既定に落ちている`);
  }
});

test("★none は画面消失として出る(cwd 不一致の文にすり替わらない)", () => {
  const body = blockedBody({ pane: null, reason: "none", candidates: 0, source: "registry" });
  assert.equal(body.reason, "pane-gone");
  assert.ok(body.message.includes("found (closed"), body.message);
  // 嘘の対照: 「現在地がずれている」と読めると「開き直せば直る」と誤解する。
  assert.ok(!body.message.includes("folder ("), body.message);
  assert.ok(!body.message.includes("doesn't match"), body.message);
});

test("reason が無い時も既定(cwd 不一致)に落ちない", () => {
  const body = blockedBody({ pane: null, candidates: 0, source: "registry" });
  assert.equal(body.reason, "pane-gone");
  assert.ok(!body.message.includes("folder ("), body.message);
});

test("not-claude は「消えた」でも「ずれた」でもなく中身が変わったと言う", () => {
  const msg = blockedMessage({ ...ctx, reason: "not-claude" });
  assert.ok(msg.includes("no longer Claude"), msg);
  assert.ok(!msg.includes("found (closed"), msg);
});

test("UNDECIDABLE は resolveSessionPane の理由の部分集合(綴り違いを弾く)", () => {
  for (const r of UNDECIDABLE) {
    assert.ok(RESOLVE_REASONS.includes(r), `${r} は resolve 側に無い綴り`);
  }
  // ワーカーに落としてよい2つは入っていない事(入れると送れる会話が送れなくなる)。
  assert.ok(!UNDECIDABLE.has("none"));
  assert.ok(!UNDECIDABLE.has("not-claude"));
});

test("tmux の故障は2種を区別する(直し方が違う)", () => {
  assert.equal(paneFaultReason({ code: "TMUX_UNAVAILABLE" }), "tmux-unavailable");
  assert.equal(paneFaultReason(new Error("bad format")), "panes-unreadable");
  assert.equal(paneFaultReason(undefined), "panes-unreadable");
});

test("★帯の文は paneFaultReason の全域を覆う(覆い漏れ = 電話に既定が出る)", () => {
  // `paneFaultReason` が作りうる値を**呼んで**作る。2語を書き写すと語彙の写しが増える。
  const produced = [paneFaultReason({ code: "TMUX_UNAVAILABLE" }), paneFaultReason(new Error("x"))];
  assert.equal(new Set(produced).size, 2, "paneFaultReason の枝が2つで無くなっている");

  for (const reason of produced) {
    const v = paneFaultView(reason);
    assert.equal(v, PANE_FAULT_VIEW[reason], `${reason} が既定に落ちている(表に無い)`);
    assert.ok(v.headline.length > 0 && v.body.length > 0, `${reason} の文が空`);
    // ★帯は**一覧全体**の話をする。行ごとの拒否文(blockedMessage)は「この会話には」と
    //   1つの会話を主語にするので、そのまま貼ると帯として嘘になる。
    assert.ok(!v.body.includes("this session"), `${reason} の帯が1つの会話を主語にしている: ${v.body}`);
    assert.ok(v.body.includes("Nothing can be sent"), `${reason} の帯が全体を主語にしていない: ${v.body}`);
    // ★下に会話が1件も無い事が在る(走査が0件で帯だけが出る)ので「下の会話は」と数えない。
    assert.ok(!v.body.includes("下の"), `${reason} の帯が下に並ぶ物を数えている: ${v.body}`);
  }

  // 2つの故障は**直し方が違う**ので、文まで別でなければ区別を出した意味が無い。
  assert.notEqual(paneFaultView(produced[0]).headline, paneFaultView(produced[1]).headline);
});

test("知らない reason に原因を作らない(名乗れないと言い、理由コードは出す)", () => {
  const v = paneFaultView("some-future-reason");
  assert.ok(v.body.includes("some-future-reason"), `理由コードを落としている: ${v.body}`);
  assert.ok(v.headline.length > 0, "見出しが空");
  // 覆っている2つのどちらの文にも化けない = もっともらしい嘘を出さない。
  for (const known of Object.values(PANE_FAULT_VIEW)) {
    assert.notEqual(v.body, known.body);
  }
  // reason 自体が無い時も、原因の無い文ではなく「不明」と名乗る。
  assert.ok(paneFaultView(undefined).body.includes("unknown"));
});

// ★2026-08-09。poll の `screen` 欄には**産む所が2つ**ある —— `screenBody()` と、この
// `blockedBody()`。`feedTick` は `r.pane ? screenBody(f, r.pane) : blockedBody(r)` を
// 同じ1つのセルに書き、poll はそのセルをそのまま `screen` に載せる。セルは tick を
// 跨いで残る一方、poll のハンドラは要求ごとにペインを引き直すので、**前の tick では
// 消えていて poll の時には解決するペイン**が tmux 経路を通り、古い「送れない」本文を
// `screen` に載せる。
//
// 電話の `ScreenBody` はこの欄の `screen` 鍵を読む。そこを必須にしていた為、この本文が
// 届くと `PollResponse` の複合が丸ごと落ち、`PollClient` は `.unreadable`、`PollLoop` は
// 20 秒待ちと劣化帯 —— ペインが1回瞬いただけで電話が 20 秒死んだ(2026-08-09 に実測、
// `DecodingError.keyNotFound: Key 'screen' not found`)。電話側は塞いだ。
//
// ここで押さえるのは**サーバ側の半分**: この本文が分類語を持たない事実を固定する。
// 誰かが後で `screen` 鍵を足すなら、電話の `.unrecognized` への落ち方も一緒に見直す事。
test("★送れない本文は分類語(screen 鍵)を持たない —— poll の screen 欄の2人目の産み手", () => {
  const ctx = { pane: null, candidates: ["%1", "%2"], source: "registry" };
  const seen = new Set();
  for (const reason of WIRE_REASONS) {
    const body = blockedBody({ ...ctx, reason });
    seen.add(reason);
    assert.ok(body.route === "blocked", `${reason}: route が blocked でない(${body.route})`);
    assert.ok(
      !Object.prototype.hasOwnProperty.call(body, "screen"),
      `${reason}: screen 鍵が生えた。電話の ScreenBody の落ち方を見直すまで足さない`,
    );
    // 分類語の代わりに**理由と文**を持つ。ここが空なら電話は何も言えない。
    assert.ok(body.reason.length > 0 && body.message.length > 0, `${reason}: 理由か文が空`);
  }
  assert.equal(seen.size, WIRE_REASONS.length, "全域を回っていない");
});

// 上が常に緑にならない事の対照。tmux 側の産み手が持つ形(`screen` 鍵あり)は、この検査を
// 通らない —— 通ってしまうなら「鍵が無い事」を測れていない。
test("分類語を持つ本文(tmux 側の形)は上の検査に通らない(対照)", () => {
  const tmuxShaped = { route: "tmux", pane: "%3", screen: "SENDABLE", work: "quiet", windowMs: 5600 };
  assert.ok(Object.prototype.hasOwnProperty.call(tmuxShaped, "screen"));
  assert.ok(!Object.prototype.hasOwnProperty.call(blockedBody({ reason: "pane-gone" }), "screen"));
});
