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
  assert.ok(body.message.includes("見つかりません"), body.message);
  // 嘘の対照: 「現在地がずれている」と読めると「開き直せば直る」と誤解する。
  assert.ok(!body.message.includes("現在地"), body.message);
  assert.ok(!body.message.includes("一致しません"), body.message);
});

test("reason が無い時も既定(cwd 不一致)に落ちない", () => {
  const body = blockedBody({ pane: null, candidates: 0, source: "registry" });
  assert.equal(body.reason, "pane-gone");
  assert.ok(!body.message.includes("現在地"), body.message);
});

test("not-claude は「消えた」でも「ずれた」でもなく中身が変わったと言う", () => {
  const msg = blockedMessage({ ...ctx, reason: "not-claude" });
  assert.ok(msg.includes("Claude ではありません"), msg);
  assert.ok(!msg.includes("見つかりません"), msg);
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
