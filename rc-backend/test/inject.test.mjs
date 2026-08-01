// tmux 注入層 — 実機で撮った画面を一次資料にして検証する。
//
// ★2026-08-01 全面改訂。前の版は **存在しない状態(BUSY)を 100 行かけて検証していた**。
// `esc to interrupt` はこのビルドの画面に無く(240 枚中 0)、その文字列を手で書いた
// 固定文字列を「実測の形」と称して assert していたのが原因。だからこの版では
// 判定の材料を手書きしない。`test/fixtures/screens/*.txt` は使い捨てセッションから
// 撮った生の capture-pane 出力で、DESIGN.md §2.9(2026-08-01)の実測表と 1:1 で対応する。
//
// 契約の出典:
//   DESIGN.md §2.9 ★2026-08-01(実測で覆った現行設計)
//   WORKLOG 2026-08-01(M1..M5)
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import {
  TmuxInjector,
  classifyScreen,
  findComposer,
  menuAt,
  composerText,
  parsePaneList,
  looksLikeClaudePane,
} from "../src/inject.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
/** 実機の画面(生の capture-pane 出力)。手で書き足さない。 */
const screen = (name) => readFileSync(join(HERE, "fixtures", "screens", `${name}.txt`), "utf8");

/** 送信してよい実物の画面 7 枚(起動直後・生成中・入力途中・キュー中・完了後)。 */
const SENDABLE_FIXTURES = [
  "idle-boot",
  "generating",
  "generating-spinner-visible",
  "generating-spinner-hidden",
  "composer-holds-text",
  "queued-during-generation",
  "idle-after-two-turns",
];

// 実行されたコマンドを記録するだけの偽 tmux。
// paneText に配列を渡すと capture-pane の**呼び出し順**に消費する(最後の1枚は使い回す)。
// send() は撮る→本文→撮る→Enter→撮る の3相なので、相の間で画面が変わる状況を再現できる。
function fakeTmux(paneText = "", paneList = "%1\t2.1.220\t/Users/Shared/dev/roundtrip\n") {
  const calls = [];
  const frames = Array.isArray(paneText) ? [...paneText] : [paneText];
  let n = 0;
  return {
    calls,
    captures: () => n,
    run: (args) => {
      calls.push(args);
      if (args[0] === "capture-pane") {
        const f = frames[Math.min(n, frames.length - 1)];
        n++;
        return f;
      }
      if (args[0] === "list-panes") return paneList;
      return "";
    },
  };
}
const sends = (t) => t.calls.filter((c) => c[0] === "send-keys");

// ---- 画面状態の判定 ----

test("★実機で撮った 7 枚は全部 SENDABLE(生成中も含む)", () => {
  for (const name of SENDABLE_FIXTURES) {
    const s = classifyScreen(screen(name));
    assert.equal(s.state, "SENDABLE", `${name} が SENDABLE でない`);
    assert.ok(s.composer >= 0, `${name} の composer 行が取れていない`);
  }
});

test("★スピナーが見えない生成中の画面も SENDABLE(これを塞いだのが前の版の欠陥)", () => {
  // M3: 6.5 秒の生成中にスピナーが見えたのは 26 サンプル中 8 枚(31%)。
  // 残り 18 枚は同じ行を tmux のヒント文が占拠する。
  const hidden = classifyScreen(screen("generating-spinner-hidden"));
  assert.equal(hidden.activity, "unknown", "この画面にスピナーは写っていない");
  assert.equal(hidden.state, "SENDABLE", "見えないことを理由に送信を止めてはいけない");

  const visible = classifyScreen(screen("generating-spinner-visible"));
  assert.equal(visible.activity, "observed");
  assert.equal(visible.state, "SENDABLE", "生成中でも入力欄はあるので送れる");
});

test("activity は表示専用 — state を一切動かさない", () => {
  // 同じ画面の 2 枚(同一セッション・6 秒差)で activity だけが違い state は同じ。
  const a = classifyScreen(screen("generating-spinner-visible"));
  const b = classifyScreen(screen("generating-spinner-hidden"));
  assert.notEqual(a.activity, b.activity);
  assert.equal(a.state, b.state);
});

test("★選択メニューは CHOICE(実機の /model 画面)", () => {
  const s = classifyScreen(screen("choice-model-menu"));
  assert.equal(s.state, "CHOICE");
  assert.equal(s.composer, -1, "メニュー中は入力欄を持たない");
});

test("完了行(過去形)は生成中と見なさない", () => {
  // 実機の完了行は `✻ Cogitated for 10s` — `…` が無く、scrollback に残り続ける。
  assert.equal(classifyScreen("✻ Cogitated for 10s").activity, "unknown");
  assert.equal(classifyScreen("✻ Churned for 7s").activity, "unknown");
  // 進行中は `…` を伴う。
  assert.equal(classifyScreen("✳ Fluttering… (3s · thinking)").activity, "observed");
});

test("空・null は UNKNOWN(fail-closed)", () => {
  assert.equal(classifyScreen("").state, "UNKNOWN");
  assert.equal(classifyScreen(null).state, "UNKNOWN");
  assert.equal(classifyScreen("なんだかよく分からない出力\n").state, "UNKNOWN");
});

// ---- 入力欄の実在(SENDABLE の積極的定義) ----

test("★裸の `❯` は入力欄と認めない(応答本文に画面が引用された場合)", () => {
  // この案件の設計文書がまさに Claude Code の画面を引用している。表示された本文の中の
  // `❯` を入力欄と読むと、応答を表示しているだけのペインに送ってしまう。
  const quoted = "説明: 入力欄は次のように出ます\n  ❯ Try \"how does <filepath> work?\"\n以上。";
  assert.equal(findComposer(quoted), -1);
  assert.equal(classifyScreen(quoted).state, "UNKNOWN");
});

test("★画面の上の方にある入力欄は採らない(下部8行限定)", () => {
  const real = screen("idle-boot");
  const pushedUp = real + "\n" + Array.from({ length: 12 }, (_, i) => `本文の続き ${i}`).join("\n");
  assert.equal(findComposer(pushedUp), -1, "下から離れた `❯` は今の入力欄ではない");
});

test("入力欄は上下を罫線で挟まれている必要がある", () => {
  const rule = "─".repeat(40);
  assert.ok(findComposer(`${rule}\n❯ \n${rule}`) >= 0);
  assert.equal(findComposer(`${rule}\n❯ \nただの行`), -1);
});

test("composerText は入力途中の本文を返す(実機)", () => {
  const t = composerText(screen("composer-holds-text"));
  assert.ok(t !== null && t.trim().length > 0, "入力途中の本文が取れない");
});

// ---- CHOICE 誤検知の2つの発生源(どちらも実際に起きうる) ----

test("★電話から `1. …` で始まる本文を送ってもロックしない", () => {
  // 送った本文は `❯ 1. まずテストを直して` として入力欄に出る。番号行1つで CHOICE に
  // すると、**自分の送信でそのペインが送信不能になる**(自己ロック)。
  const rule = "─".repeat(40);
  const pane = `前の応答の末尾\n${rule}\n❯ 1. まずテストを直して\n${rule}`;
  assert.equal(menuAt(pane), false);
  assert.equal(classifyScreen(pane).state, "SENDABLE");
});

test("★応答本文の番号付きリストは CHOICE にしない(カーソルが載らない)", () => {
  const rule = "─".repeat(40);
  const pane = [
    "やることは3つです:",
    "  1. テストを直す",
    "  2. サーバを直す",
    "  3. コミットする",
    rule,
    "❯ ",
    rule,
  ].join("\n");
  assert.equal(menuAt(pane), false);
  assert.equal(classifyScreen(pane).state, "SENDABLE");
});

test("カーソルの字体が違ってもメニューを取り逃さない", () => {
  for (const cur of ["❯", ">", "›", "→", "▶"]) {
    const pane = `${cur} 1. Stop and wait\n  2. Switch to usage credits`;
    assert.equal(menuAt(pane), true, `カーソル ${cur} を取り逃した`);
  }
});

test("強い文言 + 番号行はカーソル無しでも CHOICE(字体想定外の保険)", () => {
  const pane = "Do you trust the files in this folder?\n  1. Yes, proceed\n  2. No, exit";
  assert.equal(classifyScreen(pane).state, "CHOICE");
});

test("強い文言だけでは CHOICE にしない(応答本文で遮断されない)", () => {
  const rule = "─".repeat(40);
  const pane = `assistant: Do you want to proceed という確認が出ます。\n${rule}\n❯ \n${rule}`;
  assert.equal(classifyScreen(pane).state, "SENDABLE");
});

// ---- 送信の規約 ----

test("SENDABLE なら本文をリテラル送信し、Enter は別コマンド", async () => {
  const base = screen("idle-boot");
  const t = fakeTmux([base, base + "\nテスト本文", base]);
  const inj = new TmuxInjector({ tmux: t });
  const r = await inj.send("%1", "テスト本文");
  assert.equal(r.sent, true);
  const s = sends(t);
  assert.equal(s.length, 2, "本文と Enter は必ず2回に分ける");
  assert.deepEqual(s[0], ["send-keys", "-t", "%1", "-l", "--", "テスト本文"]);
  assert.deepEqual(s[1], ["send-keys", "-t", "%1", "Enter"]);
});

test("viewport だけを撮る(-S を付けない = 過去の行を今の状態と読まない)", () => {
  const t = fakeTmux(screen("idle-boot"));
  new TmuxInjector({ tmux: t }).state("%1");
  const cap = t.calls.find((c) => c[0] === "capture-pane");
  assert.deepEqual(cap, ["capture-pane", "-t", "%1", "-p"]);
  assert.ok(!cap.includes("-S"), "scrollback を読んではいけない");
});

test("★CHOICE 画面には絶対に送らない(本文も Enter も)", async () => {
  const t = fakeTmux(screen("choice-model-menu"));
  const inj = new TmuxInjector({ tmux: t });
  const r = await inj.send("%1", "うっかり");
  assert.equal(r.sent, false);
  assert.equal(r.state, "CHOICE");
  assert.equal(r.reason, "choice");
  assert.equal(sends(t).length, 0, "1文字も送ってはいけない");
});

test("UNKNOWN にも送らない(入力欄が確認できなければ fail-closed)", async () => {
  const t = fakeTmux("???");
  const inj = new TmuxInjector({ tmux: t });
  const r = await inj.send("%1", "x");
  assert.equal(r.sent, false);
  assert.equal(r.reason, "unknown");
  assert.equal(sends(t).length, 0);
});

test("★本文の後に選択画面が出たら Enter を送らない(Enter が承認/課金になる)", async () => {
  // 相1 = 送ってよい画面 / 相2(本文送信後) = 上限画面が割り込んだ
  const t = fakeTmux([screen("idle-boot"), screen("choice-model-menu")]);
  const inj = new TmuxInjector({ tmux: t });
  const r = await inj.send("%1", "本文");
  assert.equal(r.sent, false);
  assert.equal(r.reason, "modal-appeared");
  const s = sends(t);
  assert.equal(s.length, 1, "本文までは出ているが Enter は出していない");
  assert.ok(!s.some((c) => c.includes("Enter")));
});

test("★本文が画面に載っていなければ Enter を送らない", async () => {
  // send-keys の成功 = バイトが届いた証明であって、TUI が受け取った証明ではない。
  // 待っても載らない事を確かめる必要があるので上限を短くして回す(規約は同じ)。
  const base = screen("idle-boot");
  const t = fakeTmux([base, base, base]); // 本文送信後も画面が変わらない
  const inj = new TmuxInjector({ tmux: t, echoBudgetMs: 60 });
  const r = await inj.send("%1", "届かない本文");
  assert.equal(r.sent, false);
  assert.equal(r.reason, "composer-mismatch");
  assert.equal(sends(t).length, 1, "Enter は押さない");
});

test("★画面の描き直しは同期しない — 遅れて載った本文でも送れる(実機由来の回帰)", async () => {
  // 2026-08-01 実機: `send-keys -l` の直後に撮ると本文はまだ映っていない
  // (12回測って min 8ms / median 9ms / max 77ms)。初版は1枚しか撮らず、
  // 実機では毎回 composer-mismatch で Enter を押さずに終わっていた。
  // 偽 tmux は即時反映なので単体も e2e も緑のまま = テストが届いていなかった。
  const base = screen("idle-boot");
  const t = fakeTmux([base, base, base, base + "\n遅れて載る本文", base]);
  const r = await new TmuxInjector({ tmux: t, sleep: async () => {} }).send("%1", "遅れて載る本文");
  assert.equal(r.sent, true, "待てば載る本文を取り逃してはいけない");
  assert.equal(r.delivered, "verified");
  assert.equal(sends(t).length, 2);
  assert.ok(t.captures() >= 4, "1枚しか撮らない実装ではこの状況を通せない");
});

test("★待っている間に選択画面が出たら、そこで打ち切って Enter を押さない", async () => {
  // 描き直し待ちのループの中でも menu の見張りを外さない。
  const base = screen("idle-boot");
  const t = fakeTmux([base, base, screen("choice-model-menu")]);
  const r = await new TmuxInjector({ tmux: t, sleep: async () => {} }).send("%1", "本文B");
  assert.equal(r.sent, false);
  assert.equal(r.reason, "modal-appeared");
  assert.ok(!sends(t).some((c) => c.includes("Enter")));
});

test("Enter 後に入力欄から本文が消えていれば verified", async () => {
  const base = screen("idle-boot");
  const t = fakeTmux([base, base + "\nこんにちは", base]);
  const r = await new TmuxInjector({ tmux: t }).send("%1", "こんにちは");
  assert.equal(r.sent, true);
  assert.equal(r.delivered, "verified");
});

test("★Enter 後も入力欄に本文が残っていれば unverified(送れたと言わない)", async () => {
  const rule = "─".repeat(40);
  const held = `過去の応答\n${rule}\n❯ 残ったままの本文\n${rule}`;
  const t = fakeTmux([screen("idle-boot"), held, held]);
  const r = await new TmuxInjector({ tmux: t, echoBudgetMs: 60 }).send("%1", "残ったままの本文");
  assert.equal(r.sent, true);
  assert.equal(r.delivered, "unverified");
});

test("★Enter 後に入力欄ごと消えていても verified と言わない(確かめられていない)", async () => {
  const base = screen("idle-boot");
  const t = fakeTmux([base, base + "\n本文A", "画面が別物になった"]);
  const r = await new TmuxInjector({ tmux: t, echoBudgetMs: 60 }).send("%1", "本文A");
  assert.equal(r.sent, true);
  assert.equal(r.delivered, "unverified");
});

test("★生成中でも送れる(TUI 自身がキューする = 自前キューは持たない)", async () => {
  // M5 実測: 生成中に本文+Enter を送っても生成は中断されず、TUI が
  // `❯ Press up to edit queued messages` と表示して次のターンとして処理した。
  const gen = screen("generating");
  const t = fakeTmux([gen, gen + "\nMARKQ 4たす4は?", screen("queued-during-generation")]);
  const r = await new TmuxInjector({ tmux: t }).send("%1", "MARKQ 4たす4は?");
  assert.equal(r.sent, true);
  assert.equal(r.delivered, "verified");
  assert.equal(sends(t).length, 2);
});

test("キュー API は存在しない(復活したら設計が退行している)", () => {
  const inj = new TmuxInjector({ tmux: fakeTmux() });
  assert.equal(typeof inj.pending, "undefined");
  assert.equal(typeof inj.drain, "undefined");
});

// ---- 割り込み ----

test("割り込みは Escape。C-c は使わない", () => {
  const t = fakeTmux(screen("generating"));
  const inj = new TmuxInjector({ tmux: t });
  inj.interrupt("%1");
  assert.deepEqual(sends(t)[0], ["send-keys", "-t", "%1", "Escape"]);
  assert.ok(!JSON.stringify(t.calls).includes("C-c"), "C-c は緊急専用で通常経路に出さない");
});

// ---- ペイン特定 ----
// 出典: 2026-07-31 edith 実測 `tmux list-panes -a`
//   work:0.0 | cmd=2.1.220 | path=/Users/Shared/dev/roundtrip   ← 対話 claude
//   rc-inject-test-99017:0.0 | cmd=zsh | path=/private/tmp      ← 素のシェル

test("cwd からペインを引ける(実物の cmd は claude でなくバージョン文字列)", () => {
  const inj = new TmuxInjector({ tmux: fakeTmux() });
  assert.equal(inj.findPaneByCwd("/Users/Shared/dev/roundtrip"), "%1");
  assert.equal(inj.findPaneByCwd("/nope"), null);
});

test("パスに空白があっても壊れない(空白分割していない)", () => {
  const panes = parsePaneList("%3\t2.1.220\t/Users/tom/My Docs/proj\n");
  assert.deepEqual(panes, [{ pane: "%3", command: "2.1.220", path: "/Users/tom/My Docs/proj" }]);
});

test("★cwd は一致するが claude でないペインには送らない(素の zsh に打ち込む事故)", () => {
  const inj = new TmuxInjector({ tmux: fakeTmux("", "%9\tzsh\t/private/tmp\n") });
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
