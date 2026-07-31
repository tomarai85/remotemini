// tmux 注入層 — テスト先行。実 tmux は叩かず、コマンド実行を注入して検証する。
//
// 契約の出典:
//   DESIGN.md §2.9(Tom 裁定 = 動いている会話にいつでも干渉)
//   HANDOFF §1-B(Codex 確定の3規約)
//   WORKLOG 2026-07-31 19:4x(実機で注入成立 + 上限画面 = 送ってはいけない状態の実例)
import { test } from "node:test";
import assert from "node:assert/strict";
import { TmuxInjector, classifyPane } from "../src/inject.mjs";

// 実行されたコマンドを記録するだけの偽 tmux
function fakeTmux(paneText = "") {
  const calls = [];
  return {
    calls,
    run: (args) => {
      calls.push(args);
      if (args[0] === "capture-pane") return paneText;
      if (args[0] === "list-panes") return "sess:0.0 /Users/Shared/dev/roundtrip claude\n";
      return "";
    },
  };
}

// ---- 画面状態の判定(何を送ってよいか) ----

test("入力プロンプトが見えれば READY", () => {
  assert.equal(classifyPane("╰────╯\n❯ Try \"how does <filepath> work?\"\n  ⏸ manual mode on"), "READY");
});

test("生成中(Brewed/Thinking 等)は BUSY", () => {
  assert.equal(classifyPane("✻ Brewed for 3s\n  esc to interrupt"), "BUSY");
});

test("★上限到達の選択肢画面は CHOICE(実機で観測した実物)", () => {
  // 2026-07-31 実測: ここに Enter を送ると "2. Switch to usage credits" を選びかねない = 課金事故
  const real = [
    "  ⎿  You've hit your weekly limit · resets Aug 3 at 12am (Asia/Tokyo)",
    "   What do you want to do?",
    "   ❯ 1. Stop and wait for limit to reset",
    "     2. Switch to usage credits",
    "     3. Upgrade your plan",
    "   Enter to confirm · Esc to cancel",
  ].join("\n");
  assert.equal(classifyPane(real), "CHOICE");
});

test("ツール承認待ちも CHOICE(Enter が承認になる)", () => {
  const approval = ["Do you want to proceed?", "❯ 1. Yes", "  2. No, and tell Claude what to do differently"].join("\n");
  assert.equal(classifyPane(approval), "CHOICE");
});

test("判定できない画面は UNKNOWN(fail-closed の入口)", () => {
  assert.equal(classifyPane("なんだかよく分からない出力\n"), "UNKNOWN");
});

test("空・null でも落ちず UNKNOWN", () => {
  assert.equal(classifyPane(""), "UNKNOWN");
  assert.equal(classifyPane(null), "UNKNOWN");
});

// ---- 送信の規約(Codex §1-B) ----

test("READY なら本文をリテラル送信し、Enter は別コマンド", () => {
  const t = fakeTmux("❯ Try \"how does <filepath> work?\"");
  const inj = new TmuxInjector({ tmux: t });
  const r = inj.send("sess:0.0", "テスト本文");
  assert.equal(r.sent, true);
  const sends = t.calls.filter((c) => c[0] === "send-keys");
  assert.equal(sends.length, 2, "本文と Enter は必ず2回に分ける");
  assert.deepEqual(sends[0], ["send-keys", "-t", "sess:0.0", "-l", "--", "テスト本文"]);
  assert.deepEqual(sends[1], ["send-keys", "-t", "sess:0.0", "Enter"]);
});

test("★CHOICE 画面には絶対に送らない(本文も Enter も)", () => {
  const t = fakeTmux("What do you want to do?\n❯ 1. Stop and wait\n  2. Switch to usage credits");
  const inj = new TmuxInjector({ tmux: t });
  const r = inj.send("sess:0.0", "うっかり");
  assert.equal(r.sent, false);
  assert.equal(r.state, "CHOICE");
  assert.equal(t.calls.filter((c) => c[0] === "send-keys").length, 0, "1文字も送ってはいけない");
});

test("UNKNOWN にも送らない(状態不明なら fail-closed)", () => {
  const t = fakeTmux("???");
  const inj = new TmuxInjector({ tmux: t });
  assert.equal(inj.send("sess:0.0", "x").sent, false);
});

test("BUSY は送らずキューに積む(生成後の誤送信を防ぐ)", () => {
  const t = fakeTmux("✻ Brewed for 3s");
  const inj = new TmuxInjector({ tmux: t });
  const r = inj.send("sess:0.0", "あとで");
  assert.equal(r.sent, false);
  assert.equal(r.queued, true);
  assert.equal(t.calls.filter((c) => c[0] === "send-keys").length, 0);
  assert.equal(inj.pending("sess:0.0").length, 1);
});

test("READY に戻った時、キューの先頭が1件だけ流れる", () => {
  const busy = fakeTmux("✻ Brewed for 3s");
  const inj = new TmuxInjector({ tmux: busy });
  inj.send("sess:0.0", "A");
  inj.send("sess:0.0", "B");
  assert.equal(inj.pending("sess:0.0").length, 2);
  // 画面が READY に変わった状態で drain
  inj.tmux = fakeTmux("❯ Try \"how does <filepath> work?\"");
  const drained = inj.drain("sess:0.0");
  assert.equal(drained, 1, "一度に1件だけ(連続送信しない)");
  assert.equal(inj.pending("sess:0.0").length, 1);
});

// ---- 割り込み(Codex §1-B-3) ----

test("割り込みは Escape。C-c は使わない", () => {
  const t = fakeTmux("✻ Brewed for 3s");
  const inj = new TmuxInjector({ tmux: t });
  inj.interrupt("sess:0.0");
  const sends = t.calls.filter((c) => c[0] === "send-keys");
  assert.deepEqual(sends[0], ["send-keys", "-t", "sess:0.0", "Escape"]);
  assert.ok(!JSON.stringify(t.calls).includes("C-c"), "C-c は緊急専用で通常経路に出さない");
});

test("割り込み直後に本文を続けて送らない", () => {
  const t = fakeTmux("✻ Brewed for 3s");
  const inj = new TmuxInjector({ tmux: t });
  inj.interrupt("sess:0.0");
  const r = inj.send("sess:0.0", "すぐ本文");
  assert.equal(r.sent, false, "Escape 後は画面がまだ BUSY 表示なので送らない");
});

// ---- ペイン特定 ----

test("cwd からペインを引ける", () => {
  const t = fakeTmux();
  const inj = new TmuxInjector({ tmux: t });
  assert.equal(inj.findPaneByCwd("/Users/Shared/dev/roundtrip"), "sess:0.0");
  assert.equal(inj.findPaneByCwd("/nope"), null);
});
