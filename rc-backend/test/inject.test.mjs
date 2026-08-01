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
import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import {
  TmuxInjector,
  classifyScreen,
  findComposer,
  menuAt,
  composerText,
  composerBox,
  composerIsEmpty,
  parsePaneList,
  looksLikeClaudePane,
  limitNoticeIn,
} from "../src/inject.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
/** 実機の画面(生の capture-pane 出力)。手で書き足さない。 */
const screen = (name) => readFileSync(join(HERE, "fixtures", "screens", `${name}.txt`), "utf8");

/**
 * 実機の画面の**入力欄の中に**本文を載せた画面を作る。手書きの画面ではなく、
 * 生 capture の箱を機械的に書き換えたもの(罫線・下部の行はそのまま残る)。
 *
 * ★2026-08-01 夜に追加。それまでこの層のテストは「載った画面」を
 * `base + "\n本文"` = **箱の下に本文をぶら下げた画面**で作っていた。それは実機の
 * どの画面でもない。そしてコード側の echo 判定が画面全体で印を数えていたので、
 * **テストもコードも同じ誤りを共有して緑**になっていた(旧 BUSY と同じ型)。
 * 箱の外に本文が出た画面は、下の「入力欄の外に出た本文」の回帰で別に扱う。
 */
function withComposerBody(base, body) {
  const box = composerBox(base);
  assert.ok(box, "前提: 元の画面に入力欄の箱がある事");
  const lines = base.split("\n");
  const [first, ...rest] = String(body).split("\n");
  const head = lines[box.head].replace(/(❯\s?).*$/, `$1${first}`);
  return [
    ...lines.slice(0, box.head),
    head,
    ...rest.map((l) => `  ${l}`),
    ...lines.slice(box.head + 1),
  ].join("\n");
}

/** 送信してよい実物の画面 8 枚(起動直後・生成中・入力途中・キュー中・完了後・告知帯つき)。 */
const SENDABLE_FIXTURES = [
  "idle-boot",
  "generating",
  "generating-spinner-visible",
  "generating-spinner-hidden",
  "composer-holds-text",
  "queued-during-generation",
  "idle-after-two-turns",
  // ★8枚目(2026-08-02 edith 実機)。起動直後に Fable 5 の告知帯が出ている画面で、
  //   本文に `usage limit` / `weekly usage limit` という語が**告知として**載っている。
  //   上限の検出(`limitNoticeIn`)がこの語で誤爆すると、**上限でもないのに
  //   「答えは返りません」と電話に出す**事になる。その陰性対照を実物で持つ為の1枚。
  "promo-banner-boot",
];

// 実行されたコマンドを記録するだけの偽 tmux。
// paneText に配列を渡すと capture-pane の**呼び出し順**に消費する(最後の1枚は使い回す)。
// send() は撮る→本文→撮る→Enter→撮る の3相なので、相の間で画面が変わる状況を再現できる。
function fakeTmux(paneText = "", paneList = "%1\t2.1.220\t/dev/ttys001\t/Users/Shared/dev/roundtrip\n") {
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

// ★賭け金が最大の画面。`/model` と違いこちらは **Enter が実行の承認**になる。
// 2026-08-01 に使い捨てセッションで本物を出して撮った(`--permission-mode default` +
// `--settings` の `permissions.ask` で `sw_vers` だけを確認対象にした)。
// 画面には `Do you want to proceed?` / `❯ 1. Yes` / `2. No` が実際に出ている。
test("★★許可確認の画面は CHOICE(実機。Enter = 実行の承認になる画面)", () => {
  const raw = screen("choice-permission-bash");
  assert.match(raw, /Do you want to proceed\?/, "前提: 撮った画面が許可確認である事");
  assert.match(raw, /❯ 1\. Yes/, "前提: 選択カーソルが 1 番に載っている事");
  const s = classifyScreen(raw);
  assert.equal(s.state, "CHOICE");
  assert.equal(s.composer, -1, "入力欄として扱わない = 本文を打ち込ませない");
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

// ---- 入力欄の中身は何行にもなる(2026-08-01、実機で2件とも踏んだ) ----

test("★★折り返した本文でも入力欄と認める(実機。認めないと長い指示が一切送れない)", () => {
  // 端末幅120・日本語147字。旧実装は `❯` 行のすぐ下も罫線であることを要求していたので
  // 折り返した瞬間に -1 → UNKNOWN → 送信拒否。長い指示ほど送れないという壊れ方だった。
  const raw = screen("composer-wrapped-long");
  const lines = raw.split("\n");
  const head = lines.findIndex((l) => /^\s*❯\s*\S/.test(l));
  assert.ok(head > 0, "前提: 本文の載った入力欄が画面にある事");
  assert.ok(!/^\s*─{8,}\s*$/.test(lines[head + 1] ?? ""), "前提: `❯` の次の行が続き行(罫線でない)事");
  const s = classifyScreen(raw);
  assert.equal(s.state, "SENDABLE");
  assert.equal(s.composer, head);
  assert.ok(composerText(raw).startsWith("移動中にiPhoneから"), "折り返した本文を1つに繋げて返す");
});

test("★★番号付きの複数行を送っても CHOICE にしない(実機。旧コードはここで CHOICE を返した)", () => {
  // ❯ 1. …/ 2. …/ 3. … と入力欄に並ぶと、入力欄の中身がそのままメニューに見える。
  // 発火するのは本文を入れた**後**なので modal-appeared で中断し、本文が残り、
  // 次の送信は最初から CHOICE = そのペインが永久に送信不能になる。
  const raw = screen("composer-numbered-multiline");
  assert.match(raw, /❯\s1\. まずテストを直して/, "前提: 入力欄の先頭に番号行がある事");
  assert.match(raw, /^\s{2}2\. 次に/m, "前提: 入力欄の2行目も番号行である事");
  assert.equal(menuAt(raw), false, "入力欄の中身をメニューと読んではいけない");
  assert.equal(classifyScreen(raw).state, "SENDABLE");
});

test("★★その画面で Enter まで到達する(中断されない)", async () => {
  const withBody = screen("composer-numbered-multiline");
  const empty = withBody.replace(/(❯\s)1\. まずテストを直して\n\s*2\..*\n\s*3\..*\n/, "$1\n");
  assert.equal(classifyScreen(empty).state, "SENDABLE", "前提: 相1は空の入力欄である事");
  assert.ok(!/2\. 次にドキュメント/.test(empty), "前提: 相1に本文が無い事");
  const t = fakeTmux([empty, withBody, empty]);
  const r = await new TmuxInjector({ tmux: t }).send("%1", "1. まずテストを直して\n2. 次にドキュメントを更新して\n3. 最後にコミットして");
  assert.equal(r.sent, true, `中断されてはいけない(reason=${r.reason})`);
  assert.ok(sends(t).some((c) => c.includes("Enter")), "Enter まで到達する");
});

test("★★送信済みメッセージの履歴表示でペインが固まらない(実機。一度送ると二度と送れなくなった)", () => {
  // Claude Code は送った本文を `❯` 付きで履歴に残す。番号付き複数行を送ると、その履歴が
  // 入力欄の**外**に居座り、本物のメニューと行の形が完全に一致する。実測では B を送信成功した
  // 直後、次の送信が送信前から CHOICE で拒否された = そのペインは以後使えない。
  const raw = screen("transcript-echo-numbered");
  assert.match(raw, /❯\s1\. 返事は/, "前提: 送信済み本文が `❯` 付きで履歴に残っている事");
  assert.match(raw, /^\s{2}2\. 他には/m, "前提: 履歴側に2行目の番号行がある事");
  assert.ok(findComposer(raw) > 0, "前提: 入力欄は空で実在する事(メニュー中ではない)");
  assert.equal(menuAt(raw), false, "履歴をメニューと読んではいけない");
  assert.equal(classifyScreen(raw).state, "SENDABLE");
});

test("★入力欄が無い時は今まで通り全部の番号行をメニューとして数える(除外を広げすぎていない)", () => {
  const pane = ["❯ 1. Stop and wait", "  2. Switch to usage credits"].join("\n");
  assert.equal(menuAt(pane), true, "入力欄が無い画面のメニューは検出し続ける事");
  assert.equal(classifyScreen(pane).state, "CHOICE");
});

test("★実機のメニュー2枚はどちらも入力欄を持たない(上の除外規則が成り立つ前提そのもの)", () => {
  // この前提が崩れた画面を1枚でも見つけたら、menuAt の除外規則は即座に見直す必要がある。
  for (const name of ["choice-model-menu", "choice-permission-bash"]) {
    assert.equal(findComposer(screen(name)), -1, `${name}: メニュー中に入力欄が描かれている`);
    assert.equal(classifyScreen(screen(name)).state, "CHOICE", `${name}: CHOICE を取り逃した`);
  }
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
  const t = fakeTmux([base, withComposerBody(base, "テスト本文"), base]);
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

// ★★誤検知の側。実機で撮った画面(2026-08-01):
//   応答が `1. あ / 2. い / 3. う`、入力欄に `❯ 1. まずテストを直して` が載っている。
// composer の頭文字 `❯` は SELECT_CURSOR が認める字体なので、除外しないと
// 「カーソルの載った選択肢 + 番号行」= CHOICE になる。実害は自己ロック:
// 本文を入れた後に発火 → `modal-appeared` で中断 → 本文が入力欄に残る →
// 次の送信は最初から CHOICE → **そのペインが二度と送れない**。
// ★入力欄の `❯` の直後は **U+00A0(NBSP)** で、素の空白ではない(2026-08-01 実測)。
// 本体側の正規表現は `\s`(JS の `\s` は NBSP を含む)なので通っているが、
// `"❯ "` のような素の文字列一致は**静かに外れる**。ここでも `\s` で書く。
const BODY_ROW = /❯\s1\. まずテストを直して/;

test("★★電話から `1. …` と送っても CHOICE にしない(実機。誤検知するとペインが固まる)", () => {
  const raw = screen("composer-numbered-body");
  assert.match(raw, /^\s*2\. い/m, "前提: 応答の箇条書きが画面に残っている事");
  assert.match(raw, BODY_ROW, "前提: 入力欄に番号始まりの本文が載っている事");
  const s = classifyScreen(raw);
  assert.equal(s.state, "SENDABLE", "自分の本文で送信不能になってはいけない");
  assert.ok(s.composer > 0, "入力欄として認識される事");
});

test("★★その画面で送信を続行できる(本文を入れた後に中断されない)", async () => {
  const withBody = screen("composer-numbered-body");
  // 相1 = 本文を入れる前(入力欄は空)、相2 = 本文が載った実機の画面、相3 = 送信後
  const empty = withBody.replace(/(❯\s)1\. まずテストを直して/, "$1");
  assert.ok(!BODY_ROW.test(empty), "前提: 相1は本文を持たない事");
  const t = fakeTmux([empty, withBody, empty]);
  const inj = new TmuxInjector({ tmux: t });
  const r = await inj.send("%1", "1. まずテストを直して");
  assert.equal(r.sent, true, `中断されてはいけない(reason=${r.reason})`);
  assert.ok(sends(t).some((c) => c.includes("Enter")), "Enter まで到達する");
});

// ↑は `/model` 画面(Enter = 表示の切替)。こちらは **Enter がコマンド実行の承認**になる画面。
// 2026-08-01 に実機で同じ事を通してある(使い捨てセッションに本物の許可確認を出し、
// 実物の注入層で送信を試みて `reason:"choice"` + tmux へのキー0個を観測)。
test("★★許可確認の画面にも送らない(実機の画面。Enter = 実行の承認)", async () => {
  const t = fakeTmux(screen("choice-permission-bash"));
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
  const t = fakeTmux([base, base, base, withComposerBody(base, "遅れて載る本文"), base]);
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
  const t = fakeTmux([base, withComposerBody(base, "こんにちは"), base]);
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
  const t = fakeTmux([base, withComposerBody(base, "本文A"), "画面が別物になった"]);
  const r = await new TmuxInjector({ tmux: t, echoBudgetMs: 60 }).send("%1", "本文A");
  assert.equal(r.sent, true);
  assert.equal(r.delivered, "unverified");
});

test("★★履歴に送信済みの `❯` が残った状態でメニューを開いても CHOICE(除外規則の前提そのもの)", () => {
  // 「入力欄より上は数えない」という除外は、**メニュー中は入力欄が描かれない**事に全面依存する。
  // 依存先が崩れる型を1つ実機で作った = 番号付き本文を送った直後に `/model` を開いた画面。
  // 履歴に `❯ 1. …` が在り、かつメニューも番号行 = 最も紛らわしい組み合わせ。
  const raw = screen("echo-then-model-menu");
  assert.match(raw, /^❯\s*1\./m, "前提: 送信済み本文が `❯ 1.` の形で履歴に残っている事");
  assert.equal(findComposer(raw), -1, "メニュー中は入力欄が描かれない(除外規則の前提)");
  assert.equal(menuAt(raw), true);
  assert.equal(classifyScreen(raw).state, "CHOICE");
  // 実測の副産物: メニューの枠は `▔` で、composer の `─` 罫線とは別の文字。
  assert.equal(/^─{8,}\s*$/m.test(raw), false, "メニュー画面に composer の罫線は無い");
});

test("★★本文そのものが罫線を含んでも入力欄を見失わない(実機。見失うとペインが固着する)", () => {
  // `この表を直して⏎────────⏎以上` を打つと画面は `❯ …` / `  ────────` / `  以上`。
  // 罫線の字下げを許していた版は本文の中の罫線を箱の一部と読み、UNKNOWN → 本文が残った。
  const raw = screen("composer-rule-in-body");
  const lines = raw.split("\n");
  const inner = lines.findIndex((l) => /^\s+─{8,}\s*$/.test(l));
  assert.ok(inner > 0, "前提: 字下げされた罫線(= 本文の中の罫線)が画面にある事");
  assert.ok(/^─{8,}/.test(lines[inner + 2] ?? ""), "前提: 本物の閉じ罫線は桁0から始まる事");
  const s = classifyScreen(raw);
  assert.equal(s.state, "SENDABLE");
  assert.equal(composerText(raw), "この表を直して\n" + "─".repeat(40) + "\n以上", "本文をそのまま復元する");
});

// ★2026-08-01 夜、実機で踏んだ2件。どちらも「本文は入力欄に入っているのに確認できず、
// Enter を押さないまま本文が残る」= 次の送信に前回の本文が混ざる、という壊れ方をした。
// 印(本文が載ったかを確かめる短い文字列)の採り方だけが違いを生む。

test("★★印が改行を跨いでも載ったと認める(実機。旧実装は本文が入力欄に在るのに composer-mismatch)", async () => {
  // 画面は続き行を2桁字下げするので、打った `…でいい⏎よろしく` は画面上 `…でいい⏎  よろしく`。
  // 生の文字列のままでは永久に一致しない。
  const body = "返事は「E」の一文字だけでいい\nよろしく";
  const shown = screen("composer-multiline-tail-break");
  assert.equal(shown.includes(body.slice(-12)), false, "前提: 生の末尾12字は画面に存在しない事");
  const t = fakeTmux([screen("idle-boot"), shown, screen("idle-boot")]);
  const r = await new TmuxInjector({ tmux: t, echoBudgetMs: 300 }).send("%1", body);
  assert.equal(r.sent, true);
  assert.equal(r.delivered, "verified");
});

test("★★折り返しで印が行を跨いでも載ったと認める(実機。正規化が無いと長文の約2割が送れない)", async () => {
  // 2026-08-02 未明、実 TUI(端末幅120)で撮った現物 = `composer-wrapped-tail-short`。
  // 打った本文は**改行を1つも含まない**67字だが、画面では 61字 + 6字 に折り返され、
  // 印(末尾12字)がその境目を跨ぐ。= 印の12字は画面のどこにも**文字列として存在しない**。
  //
  // ★なぜ「たまたま」ではないか: 折り返しの最終行は `本文の桁数 mod 行の桁数` で決まる。
  // 行が約118桁なので、最終行が印(12字)より短くなる本文は長文のおよそ2割を占める。
  // 正規化を外すと、その2割は「入力欄に本文が在るのに composer-mismatch」= 永久に送れない。
  //
  // ★この検査が要る事は、この形の変異(M29)が **8/01 の直しで素通りに変わった**ことで分かった。
  // 入力欄限定の照合にした結果 composerText() が字下げを剥がすようになり、
  // それまで M29 を捕まえていた「画面全体に字下げが残る」経路が消えていた。
  const body =
    "移動中にiPhoneから長めの指示を送る時の本文です。あああああああああああああああああああああああああああ末尾の目印はここまでです。";
  const shown = screen("composer-wrapped-tail-short");
  assert.equal(body.includes("\n"), false, "前提: 打った本文に改行は無い(折り返しは画面側の都合)");
  assert.equal(composerText(shown).replace(/\n/g, ""), body, "前提: 画面の入力欄がこの本文そのものである事");
  assert.equal(composerText(shown).split("\n").length, 2, "前提: 画面では2行に折り返されている事");
  assert.equal(shown.includes(body.slice(-12)), false, "前提: 生の末尾12字は画面に存在しない事");

  const t = fakeTmux([screen("idle-boot"), shown, screen("idle-boot")]);
  const r = await new TmuxInjector({ tmux: t, echoBudgetMs: 300 }).send("%1", body);
  assert.equal(r.sent, true, `送れなければならない(reason=${r.reason})`);
  assert.equal(r.delivered, "verified");
});

test("★★本文の先頭が画面から消える長さでも送れる(実機。印を先頭から採ると長文が永久に送信不能)", async () => {
  // 実測(端末幅120): 入力欄の中身は最大15行までしか映らず、JP 1500字から先頭が巻き上がって消える。
  const body = "先頭の目印です。" + "あ".repeat(1484) + "末尾の目印です。";
  const shown = screen("composer-scrolled-1500");
  assert.equal(body.length, 1500);
  assert.equal(shown.includes("先頭の目印です。"), false, "前提: 本文の先頭が画面から消えている事");
  assert.ok(shown.includes("末尾の目印です。"), "前提: 本文の末尾は見えている事");
  const t = fakeTmux([screen("idle-boot"), shown, screen("idle-boot")]);
  const r = await new TmuxInjector({ tmux: t, echoBudgetMs: 300 }).send("%1", body);
  assert.equal(r.sent, true);
  assert.equal(r.delivered, "verified");
});

test("★生成中でも送れる(TUI 自身がキューする = 自前キューは持たない)", async () => {
  // M5 実測: 生成中に本文+Enter を送っても生成は中断されず、TUI が
  // `❯ Press up to edit queued messages` と表示して次のターンとして処理した。
  const gen = screen("generating");
  const t = fakeTmux([gen, withComposerBody(gen, "MARKQ 4たす4は?"), screen("queued-during-generation")]);
  const r = await new TmuxInjector({ tmux: t }).send("%1", "MARKQ 4たす4は?");
  assert.equal(r.sent, true);
  assert.equal(r.delivered, "verified");
  assert.equal(sends(t).length, 2);
});

test("★★短い本文が定型文と衝突しても「届いた」と言える(届いたのに未確認になる欠陥の守り)", async () => {
  // 生成中に一語だけ返す(選択肢に「edit」と出た時の返答など)。印は `edit` の4文字で、
  // これは TUI の定型文 `Press up to edit queued messages` の部分文字列。定型文を本文として
  // 読む限り「まだ入力欄に残っている」と判定され、実際は届いているのに unverified になる。
  const gen = screen("generating");
  const queued = screen("queued-during-generation");
  assert.ok(
    composerText(queued).replace(/\s+/g, "").includes("edit"),
    "前提: 印が定型文に含まれる事",
  );
  const t = fakeTmux([gen, withComposerBody(gen, "edit"), queued]);
  const r = await new TmuxInjector({ tmux: t }).send("%1", "edit");
  assert.equal(r.sent, true);
  assert.equal(r.delivered, "verified", "定型文が出ている = TUI が取り込んだ直接証拠");
});

test("★本文が定型文そのものの時は「分からない」と言う(曖昧さを verified へ倒さない)", async () => {
  // 取り込まれて定型文が出たのか、本文がそのまま残っているのか、画面からは区別が付かない。
  // 判別できない物を「届いた」と言わない。
  const gen = screen("generating");
  const body = "Press up to edit queued messages";
  const t = fakeTmux([gen, withComposerBody(gen, body), screen("queued-during-generation")]);
  const r = await new TmuxInjector({ tmux: t, echoBudgetMs: 300 }).send("%1", body);
  assert.equal(r.sent, true);
  assert.equal(r.delivered, "unverified");
});

test("★★入力欄の**外**に本文が出ただけでは Enter を押さない(fail-open の守り)", async () => {
  // 2026-08-01 夜、実機で踏んだ現物。入力欄の箱だけを描いて stdin を読まない偽物
  // (`scratchpad/fake-composer.sh` = 罫線と `❯` を出して `sleep 600`)へ送ると、
  // 打った文字は tty のエコーで箱の**下**に出る。旧実装は印を**画面全体**で数えていたので
  // これを「入力欄に載った」と読み、Enter を送り、その後の確認で
  // 「入力欄が空 = 取り込まれた」と読んで **一度も届いていないのに verified** を返した。
  // (実測: `echo=3ms clear=3ms` / `delivered: "verified"` / 相手は `sleep 600`)
  const gen = screen("generating");
  const body = "OUTSIDE-MARK-77";
  const outside = gen + "\n" + body; // 箱の下にぶら下がった本文 = 偽物の tty エコーそのもの
  assert.ok(
    composerBox(outside) && !composerText(outside).includes(body),
    "前提: 箱はあるが本文は箱の**中**に無い(この前提が崩れたらこの回帰は無意味)",
  );
  assert.ok(outside.includes(body), "前提: 画面全体で数えれば印は増える(旧実装が通った道)");

  const t = fakeTmux([gen, outside]);
  const r = await new TmuxInjector({ tmux: t, echoBudgetMs: 50 }).send("%1", body);
  assert.equal(r.sent, false);
  assert.equal(r.reason, "composer-mismatch");
  assert.equal(r.delivered, null, "届いていない物を verified と言わない");
  assert.deepEqual(
    sends(t).map((c) => c[c.length - 1]),
    [body],
    "本文のリテラル送信だけ。**Enter を送っていない**",
  );
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
  const panes = parsePaneList("%3\t2.1.220\t/dev/ttys003\t/Users/tom/My Docs/proj\n");
  assert.deepEqual(panes, [
    { pane: "%3", command: "2.1.220", tty: "/dev/ttys003", path: "/Users/tom/My Docs/proj" },
  ]);
});

// ★path はタブを含みうる(macOS のファイル名はタブを許す)。tty を path より後ろに置くと
//   ここが path に食われて tty が壊れる。列の並びが load-bearing だという対照。
test("パスにタブが入っていても tty が壊れない(tty は path より前の列)", () => {
  const panes = parsePaneList("%4\t2.1.220\t/dev/ttys004\t/tmp/a\tb\n");
  assert.deepEqual(panes, [
    { pane: "%4", command: "2.1.220", tty: "/dev/ttys004", path: "/tmp/a\tb" },
  ]);
});

/** 実機の観測に出てくる cwd(下の findPaneByCwd の一次資料と同じ)。 */
const CWD_RT = "/Users/Shared/dev/roundtrip";

// ★list-panes の -F 文字列を**実際に解釈する**偽 tmux。固定文字列を返す偽 tmux では、
//   要求する書式と読み側(parsePaneList)の対応が壊れても気づけない。書式から項目を1つ
//   落とすと列がずれ、全ペインが読み捨てられて「tmux に誰も居ない」= 開いている TUI に
//   対してワーカーを起こす(lost-update)方向に倒れるので、ここは対で検査する。
function formatAwareTmux(rows) {
  return {
    run: (args) => {
      if (args[0] !== "list-panes") return "";
      const fmt = args[args.indexOf("-F") + 1];
      return rows.map((r) => fmt.replace(/#\{(\w+)\}/g, (_, k) => r[k] ?? "")).join("\n") + "\n";
    },
  };
}

test("★要求した書式と読み側の対応が保たれている(列を1つ落とすと全ペインが消える)", () => {
  const inj = new TmuxInjector({
    tmux: formatAwareTmux([
      { pane_id: "%1", pane_current_command: "2.1.220", pane_tty: "/dev/ttys001", pane_current_path: CWD_RT },
      { pane_id: "%2", pane_current_command: "zsh", pane_tty: "/dev/ttys002", pane_current_path: "/private/tmp" },
    ]),
  });
  assert.deepEqual(inj.listPanes(), [
    { pane: "%1", command: "2.1.220", tty: "/dev/ttys001", path: CWD_RT },
    { pane: "%2", command: "zsh", tty: "/dev/ttys002", path: "/private/tmp" },
  ]);
});

test("★同一性の検証に要る tty がペイン一覧に必ず載る", () => {
  const inj = new TmuxInjector({
    tmux: formatAwareTmux([
      { pane_id: "%1", pane_current_command: "2.1.220", pane_tty: "/dev/ttys001", pane_current_path: CWD_RT },
    ]),
  });
  // 登録簿(registry.mjs entryAlive)は「その pid の tty == そのペインの tty」を見る。
  // ここが空だと同一性を検証できず、全ての登録が死んだ扱いになる。
  assert.equal(inj.listPanes()[0].tty, "/dev/ttys001");
});

test("★cwd は一致するが claude でないペインには送らない(素の zsh に打ち込む事故)", () => {
  const inj = new TmuxInjector({ tmux: fakeTmux("", "%9\tzsh\t/dev/ttys009\t/private/tmp\n") });
  const r = inj.resolvePane("/private/tmp");
  assert.equal(r.pane, null);
  assert.equal(r.reason, "not-claude");
});

test("★同じ cwd に claude が2つある時は決めない(別の会話へ届く事故)", () => {
  const list = "%1\t2.1.220\t/dev/ttys001\t/Users/Shared/dev/roundtrip\n%2\t2.1.220\t/dev/ttys002\t/Users/Shared/dev/roundtrip\n";
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

test("★★現物の不変量を固定する(変異の「未到達」注記が根拠にしている実測を、実行可能な検査にする)", () => {
  const dir = join(HERE, "fixtures", "screens");
  const files = readdirSync(dir).filter((f) => f.endsWith(".txt")).sort();
  assert.ok(files.length >= 20, `現物が20枚以上ある事(実際: ${files.length})`);

  const indented = [];
  const gaps = new Set(); // 閉じ罫線の下に何行あるか。**機械ごとに違う**(下の assert 参照)
  for (const f of files) {
    const raw = readFileSync(join(dir, f), "utf8");
    const lines = raw.split("\n");
    while (lines.length && lines[lines.length - 1].trim() === "") lines.pop();
    if (lines.some((l) => /^\s+─{8,}\s*$/.test(l))) indented.push(f);

    const box = composerBox(raw);
    if (box) {
      // 下部8行という窓の根拠。閉じ罫線の下に在るのは権限モードなどの表示行だけ。
      // ★2026-08-02 訂正: 旧版はここを `=== 2` と書いていた。edith の実機を1枚入れたら
      //   赤になった — あちらは `⏸ manual mode on` の1行だけで、2行なのは MBP 側の設定。
      //   「手元の全fixtureがそうだった」を「常にそうだ」と書いていた形。窓 8 の根拠として
      //   要るのは**上限**であって固定値ではないので、上限で書き直す。
      const gap = lines.length - 1 - box.close;
      gaps.add(gap);
      assert.ok(gap >= 1 && gap <= 3, `${f}: 閉じ罫線の下は1〜3行(実際: ${gap})`);
      assert.equal(
        lines.filter((l) => /^─{8,}\s*$/.test(l)).length,
        2,
        `${f}: 桁0の罫線は開きと閉じの2本`,
      );
    } else {
      // 入力欄が無い = 選択画面。下部8行に閉じ罫線が現れない事が、変異 M2(開き罫線を
      // 要求しない)が到達しない理由そのもの。許可確認画面は罫線を1本持つが下から14行目。
      assert.ok(
        !lines.slice(-8).some((l) => /^─{8,}\s*$/.test(l)),
        `${f}: 入力欄の無い画面の下部8行に桁0の罫線があってはならない`,
      );
    }
  }
  assert.deepEqual(indented, ["composer-rule-in-body.txt"], "字下げされた罫線は本文の中のそれだけ");
  // 観測された値そのものを固定する。新しい機械が別の形を出したらここが赤くなり、
  // 窓 8 が今も余裕を持っているかを人が見直す事になる(黙って通り過ぎない)。
  assert.deepEqual([...gaps].sort(), [1, 2], `閉じ罫線の下の行数は 1(edith)と 2(MBP)だけ`);
});

test("★★上限の告知は state と独立に出る(= 送れるのに答えが返らない、が有りうる)", () => {
  // 現物 = edith 実機 2026-08-02。`live-inject-check` が 4/4 delivered=verified / exit 0 を
  // 出したのに、4件とも答えが返っていなかった時の画面。メールだけ伏せてある。
  const hit = screen("limit-reached-edith");
  assert.equal(limitNoticeIn(hit), true, "現物で検出できる事");

  const c = classifyScreen(hit);
  assert.equal(c.limited, true);
  // ★ここが要点。上限は「送れない」ではない。入力欄は実在し、打ち込みは成立する。
  assert.equal(c.state, "SENDABLE", "上限を遮断条件にしていない事(解けた瞬間に送れる)");

  // 陰性対照 — これが無いと「常に true を返す関数」でも上の assert は緑になる。
  assert.equal(limitNoticeIn(screen("idle-boot")), false);
  assert.equal(limitNoticeIn(screen("choice-model-menu")), false);
  assert.equal(classifyScreen(screen("idle-boot")).limited, false);
  assert.equal(limitNoticeIn(""), false);

  // 文言はビルド更新で変わりうる = 当たらなくなったら黙って false を返す。
  // せめて綴りの揺れ(`You've` / `Youve`)と usage 版は拾う。
  assert.equal(limitNoticeIn("Youve hit your usage limit"), true);
  assert.equal(limitNoticeIn("weekly limit の話をしているだけの本文"), false, "語だけでは当てない");

  // ★★実物での陰性対照(2026-08-02 edith)。上の1行は私が手で書いた文字列なので、
  //   「実際に画面に出る紛らわしい文」を測ってはいない。現物はこれ:
  //   起動直後に Fable 5 の告知帯が出ていて、本文に
  //     "You can use up to 50% of your weekly usage limit on Fable 5."
  //   と**上限の語がそのまま**載っている。ここで誤爆すると、上限でも何でもない
  //   起動直後の画面に「答えは返りません」と出す = 電話の側が送るのをやめる。
  //   `USAGE_LIMIT` が要求するのは "hit your ... limit" の形なので当たらない。
  //   ★これが true に変わったら、告知の文面が変わったのではなく**判定が緩んだ**合図。
  const promo = screen("promo-banner-boot");
  assert.match(promo, /weekly usage limit/, "この現物が対照になる前提(語を含む事)を先に確かめる");
  assert.equal(limitNoticeIn(promo), false, "告知帯の 'weekly usage limit' で誤爆しない");
  assert.equal(classifyScreen(promo).limited, false);
  assert.equal(classifyScreen(promo).state, "SENDABLE", "告知帯が出ていても送れる");
});

test("★上限の告知は日付つきの形でも出る(fixture が持っていない実在の形)", () => {
  // ★出典 = **2026-07-31 に edith の画面で読んだ物を DESIGN.md §8-3 に引用した1行**。
  //   撮り直した capture ではない(= fixture を合成していない)。日付が入る形は、
  //   現行 fixture(`limit-reached-edith.txt`)が持っている日付なしの形とは別に実在する。
  //   両方拾える事をここで固定しないと、片方だけ拾える式に締めても誰も気付かない。
  const dated = "You've hit your weekly limit · resets Aug 3 at 12am (Asia/Tokyo)";
  const undated = "You've hit your weekly limit · resets 12am (Asia/Tokyo)"; // fixture と同形
  assert.equal(limitNoticeIn(dated), true, "日付つき");
  assert.equal(limitNoticeIn(undated), true, "日付なし");

  // ★2026-08-02 に修飾語を固定列挙から外した(`weekly|usage` -> 1行内の短い任意)。
  //   未観測の文言に余裕を持たせる為。ここは**その余裕が本当に効いているか**の陽性側。
  //   実機で見た事は無い = 推測。推測である事を明示して置く(観測の顔をさせない)。
  for (const guess of [
    "You've hit your 5-hour limit · resets 3pm",
    "You've hit your Opus weekly limit",
    "You've hit your limit",
    "You’ve hit your weekly limit", // 活字アポストロフィ(実機は ASCII。これも推測)
  ]) {
    assert.equal(limitNoticeIn(guess), true, `未観測だが有りうる形: ${guess}`);
  }

  // ★緩めた側の歯止め。ここが true に変わったら、広げ過ぎている合図。
  assert.equal(limitNoticeIn("He hit your limit"), false, "主語が違う");
  assert.equal(limitNoticeIn("You've hit your\nweekly limit"), false, "行をまたぐ骨格は取らない");
  assert.equal(
    limitNoticeIn("You've hit your absolutely enormous and verbose weekly limit"),
    false, "hit your と limit が 24 字以上離れたら取らない");
  // 実物の陰性対照を**広げた後にもう一度**通す(上の test と重複するが、ここが本題)。
  assert.equal(limitNoticeIn(screen("promo-banner-boot")), false, "広げても告知帯で誤爆しない");

  // ★この陰性対照が**何のおかげで通っているか**を固定する(2026-08-02、edith の実画面を見て気付いた)。
  //   fixture の告知帯は端末幅の都合で `If you hit` / `your limit` の間で**折り返している**。
  //   つまり上の assert は「行をまたぐ骨格は取らない」規則だけでも通ってしまう =
  //   広い端末で折り返しが消えた瞬間に何が起きるかを、この表は一度も測っていなかった。
  //   実際の壁は折り返しではなく **`You've` という主語**の方。それを名指しで固定する。
  //   ここが true に変われば「起動直後の全セッションが上限扱い」= 電話から全部が
  //   「答えは返りません」に見える、という一番痛い誤爆になる。
  const promoUnwrapped =
    "You can use up to 50% of your weekly usage limit on Fable 5. " +
    "If you hit your limit, you can continue on Fable 5 with usage credits.";
  assert.match(promoUnwrapped, /hit your limit/,
    "この対照が成立する前提(骨格の語がそのまま1行に載っている事)を先に確かめる");
  assert.equal(limitNoticeIn(promoUnwrapped), false,
    "折り返しが無くても誤爆しない = 効いているのは改行ではなく You've の側");
});

test("★キュー中の定型文は「空の入力欄」(本文と読むと、短い本文で届いたのに未確認になる)", () => {
  assert.equal(composerText(screen("queued-during-generation")), "Press up to edit queued messages");
  assert.equal(composerIsEmpty(screen("queued-during-generation")), true);
  assert.equal(composerIsEmpty(screen("idle-boot")), true);
  assert.equal(composerIsEmpty(screen("composer-holds-text")), false, "本文が在る画面は空ではない");
  assert.equal(composerIsEmpty(screen("choice-model-menu")), false, "入力欄が無い = 空とは言えない");
  // 印がこの定型文の部分文字列になりうる事の現物確認(`up` / `edit` / `messages` 等)。
  const flat = "Press up to edit queued messages".replace(/\s+/g, "");
  assert.ok(flat.includes("edit"), "前提: 短い本文の印がこの定型文に含まれうる");
});
