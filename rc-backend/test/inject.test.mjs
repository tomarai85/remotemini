// tmux 注入層 — テスト先行。実 tmux は叩かず、コマンド実行を注入して検証する。
//
// 契約の出典:
//   DESIGN.md §2.9(Tom 裁定 = 動いている会話にいつでも干渉)
//   HANDOFF §1-B(Codex 確定の3規約)
//   WORKLOG 2026-07-31 19:4x(実機で注入成立 + 上限画面 = 送ってはいけない状態の実例)
import { test } from "node:test";
import assert from "node:assert/strict";
import { TmuxInjector, classifyPane, parsePaneList, looksLikeClaudePane } from "../src/inject.mjs";

// 実行されたコマンドを記録するだけの偽 tmux
// paneList は実物と同じタブ区切り(#{pane_id}\t#{pane_current_command}\t#{pane_current_path})
function fakeTmux(paneText = "", paneList = "%1\t2.1.220\t/Users/Shared/dev/roundtrip\n") {
  const calls = [];
  return {
    calls,
    run: (args) => {
      calls.push(args);
      if (args[0] === "capture-pane") return paneText;
      if (args[0] === "list-panes") return paneList;
      return "";
    },
  };
}

// 生成中の画面(実物の形)。過去形の完了行と**別物**であることがこの層の要。
const IN_FLIGHT = "✻ Baking… (12s · ↓ 1.2k tokens · esc to interrupt)";
// 完了後に scrollback へ残り続ける行(2026-07-31 edith 実測)。BUSY ではない。
const FINISHED = "✻ Baked for 0s";

// ---- 画面状態の判定(何を送ってよいか) ----

test("入力プロンプトが見えれば READY", () => {
  assert.equal(classifyPane("╰────╯\n❯ Try \"how does <filepath> work?\"\n  ⏸ manual mode on"), "READY");
});

test("生成中(esc to interrupt が出ている)は BUSY", () => {
  assert.equal(classifyPane(IN_FLIGHT), "BUSY");
});

test("★完了行が残っているだけの入力待ち画面は READY(BUSY と読むとキューが永久に滞留する)", () => {
  // 2026-07-31 edith 実測の再現。週次上限に当たると turn が即終わり、この過去形の行が
  // scrollback に残る。かつてこれを BUSY と判定していたため、そのペインは二度と
  // READY にならず、電話から送った本文が永久に届かなかった(実測 0 件到達)。
  const real = [
    "❯ reply with exactly: MARK_ALPHA",
    "  ⎿ You've hit your weekly limit · resets Aug 3 at 12am (Asia/Tokyo)",
    "     /usage-credits to finish what you're working on.",
    FINISHED,
    "────────",
    "❯ ",
    "────────",
    "  Sonnet 5 | /private/tmp/rc-smoke [rc %18]",
  ].join("\n");
  assert.equal(classifyPane(real), "READY");
});

test("★完了行だけでは BUSY にしない(過去形は進行中の証拠ではない)", () => {
  // 入力欄が見えない状態でも、過去形の行を根拠に BUSY を名乗ってはいけない。
  assert.notEqual(classifyPane(FINISHED), "BUSY");
});

test("★「esc to interrupt」が**文章として**画面に残っているだけなら BUSY にしない", () => {
  // この案件そのものが Claude Code の割り込みを扱っているので、応答本文にこの語が出るのは
  // 仮定ではなく通常運転。state() は scrollback を30行読むので、過去の応答文が判定に混ざる。
  const prose = [
    "❯ esc to interrupt って何を止めるの?", "",
    "  生成中に esc to interrupt と表示されている間だけ、Escape で生成を止められます。", "",
    "────────", "❯ ", "────────",
    "  Opus 5 | /Users/Shared/dev/roundtrip [rc %18]",
  ].join("\n");
  assert.equal(classifyPane(prose), "READY");
});

test("★スピナー記号が折り返しで消えても、中黒区切りが残っていれば BUSY と読む", () => {
  // 判定は**行単位**。狭い端末で記号と語が別行に割れると BUSY を取り逃す(= READY 側に倒れる)。
  // その代償は Claude Code 自身が入力をキューするだけなので許容し、締める側を優先する。
  assert.equal(classifyPane("(12s · ↓ 1.2k tokens ·\n esc to interrupt)"), "UNKNOWN");
  assert.equal(classifyPane("(12s · ↓ 1.2k tokens · esc to interrupt)"), "BUSY");
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
  const t = fakeTmux(IN_FLIGHT);
  const inj = new TmuxInjector({ tmux: t });
  const r = inj.send("sess:0.0", "あとで");
  assert.equal(r.sent, false);
  assert.equal(r.queued, true);
  assert.equal(t.calls.filter((c) => c[0] === "send-keys").length, 0);
  assert.equal(inj.pending("sess:0.0").length, 1);
});

test("READY に戻った時、キューの先頭が1件だけ流れる", () => {
  const busy = fakeTmux(IN_FLIGHT);
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
  const t = fakeTmux(IN_FLIGHT);
  const inj = new TmuxInjector({ tmux: t });
  inj.interrupt("sess:0.0");
  const sends = t.calls.filter((c) => c[0] === "send-keys");
  assert.deepEqual(sends[0], ["send-keys", "-t", "sess:0.0", "Escape"]);
  assert.ok(!JSON.stringify(t.calls).includes("C-c"), "C-c は緊急専用で通常経路に出さない");
});

test("割り込み直後に本文を続けて送らない", () => {
  const t = fakeTmux(IN_FLIGHT);
  const inj = new TmuxInjector({ tmux: t });
  inj.interrupt("sess:0.0");
  const r = inj.send("sess:0.0", "すぐ本文");
  assert.equal(r.sent, false, "Escape 後は画面がまだ BUSY 表示なので送らない");
});

// ---- ペイン特定 ----
// 出典: 2026-07-31 edith 実測 `tmux list-panes -a`
//   work:0.0 | cmd=2.1.220 | path=/Users/Shared/dev/roundtrip   ← 対話 claude
//   rc-inject-test-99017:0.0 | cmd=zsh | path=/private/tmp      ← 素のシェル

test("cwd からペインを引ける(実物の cmd は claude でなくバージョン文字列)", () => {
  const t = fakeTmux();
  const inj = new TmuxInjector({ tmux: t });
  assert.equal(inj.findPaneByCwd("/Users/Shared/dev/roundtrip"), "%1");
  assert.equal(inj.findPaneByCwd("/nope"), null);
});

test("パスに空白があっても壊れない(空白分割していない)", () => {
  const panes = parsePaneList("%3\t2.1.220\t/Users/tom/My Docs/proj\n");
  assert.deepEqual(panes, [{ pane: "%3", command: "2.1.220", path: "/Users/tom/My Docs/proj" }]);
});

test("★cwd は一致するが claude でないペインには送らない(素の zsh に打ち込む事故)", () => {
  const t = fakeTmux("❯ ", "%9\tzsh\t/private/tmp\n");
  const inj = new TmuxInjector({ tmux: t });
  const r = inj.resolvePane("/private/tmp");
  assert.equal(r.pane, null);
  assert.equal(r.reason, "not-claude");
});

test("★同じ cwd に claude が2つある時は決めない(別の会話へ届く事故)", () => {
  const list = "%1\t2.1.220\t/Users/Shared/dev/roundtrip\n%2\t2.1.220\t/Users/Shared/dev/roundtrip\n";
  const inj = new TmuxInjector({ tmux: fakeTmux("", list) });
  const r = inj.resolvePane("/Users/Shared/dev/roundtrip");
  assert.equal(r.pane, null);
  assert.equal(r.reason, "ambiguous");
  assert.equal(r.candidates, 2);
});

test("cwd に何も無ければ none(ワーカー経路へ落として良い唯一の理由)", () => {
  const inj = new TmuxInjector({ tmux: fakeTmux() });
  assert.equal(inj.resolvePane("/nowhere").reason, "none");
});

test("claude 判定は許可制(未知のコマンド名は通さない)", () => {
  assert.equal(looksLikeClaudePane("2.1.220"), true, "実測の形");
  assert.equal(looksLikeClaudePane("claude"), true);
  assert.equal(looksLikeClaudePane("node"), true);
  assert.equal(looksLikeClaudePane("zsh"), false);
  assert.equal(looksLikeClaudePane("vim"), false);
  assert.equal(looksLikeClaudePane("ssh"), false);
  assert.equal(looksLikeClaudePane(""), false);
  assert.equal(looksLikeClaudePane(undefined), false);
});
