// 選択メニューへの打鍵 — **良性と同定できた画面にしか打たない**事の検証。
//
// 契約の出典: Tom 裁定「自動化に安全確認を押させない」/ DESIGN D4(電話から permission
// 承認は採らない)/ `src/choice.mjs` 冒頭(なぜ許可一覧で、拒否一覧ではないか)。
//
// ★この file で一番重い検査は「hard-stop の語を全部剥いでも打てない」。
//   守りが denylist の完全性に依存していない事の**直接の証拠**で、これが赤くなる時は
//   設計が拒否一覧に退化した時。
//
// 判定の材料は手書きしない。`fixtures/screens/choice-*.txt` は実機の生 capture-pane 出力
// (`/model` の選択と、Bash の許可確認)。**唯一の例外**は下の
//   ★入力欄が描かれたまま選択肢が出る画面
// で、これは実機で**まだ一度も観測していない**形を意図的に組み立てている。理由はコメント参照。
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import {
  parseMenu,
  classifyChoice,
  digestOf,
  keyArgs,
  keyKind,
  CHOICE_KEYS,
  MATCHERS,
  ESC_SETTLE_MS,
} from "../src/choice.mjs";
import { TmuxInjector, classifyScreen, composerCloseOf, choiceViewOf, PANE_SEP } from "../src/inject.mjs";
import { makeKeyedMutex } from "../src/mutex.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const screen = (name) => readFileSync(join(HERE, "fixtures", "screens", `${name}.txt`), "utf8");
/** 実機の画面を、実際の判定と同じ道(入力欄の位置を渡す)で分類する。 */
const classify = (text) => classifyChoice(text, composerCloseOf(text));

const paneLine = (...cols) => cols.join(PANE_SEP);
function fakeTmux(paneText, sleepLog = []) {
  const calls = [];
  const frames = Array.isArray(paneText) ? [...paneText] : [paneText];
  let n = 0;
  const run = (args) => {
    calls.push(args);
    if (args[0] === "capture-pane") return frames[Math.min(n++, frames.length - 1)];
    if (args[0] === "list-panes") return paneLine("%1", "2.1.220", "/dev/ttys001", "/tmp") + "\n";
    return "";
  };
  return { calls, run, runStrict: run, sleepLog };
}
const inject = (t) =>
  new TmuxInjector({ tmux: t, sleep: async (ms) => void t.sleepLog.push(ms) });
const sends = (t) => t.calls.filter((c) => c[0] === "send-keys");

// ---- 同定 ----

test("★実機の /model メニューは良性と同定される(打てる鍵つき)", () => {
  const c = classify(screen("choice-model-menu"));
  assert.equal(c.kind, "benign");
  assert.equal(c.matcher.name, "select-model");
  assert.equal(c.menu.options.length, 5);
  assert.equal(c.menu.cursor, 5, "カーソルは 5 番(Haiku)に載っている");
  assert.deepEqual(c.matcher.keys, ["digit", "enter", "escape"]);
});

test("★実機の許可確認は打鍵できない(電話から承認しない)", () => {
  const c = classify(screen("choice-permission-bash"));
  assert.equal(c.kind, "hard-stop");
  assert.equal(c.matcher, null, "matcher が付かない = 打てる鍵がゼロ");
  assert.deepEqual(choiceViewOf("%1", screen("choice-permission-bash")).keys, []);
});

test("★★hard-stop の語を全部剥いでも打てない(守りが拒否一覧に依存していない証拠)", () => {
  // 「危険と書いてある事」を根拠にしていたなら、語を消せば良性に化ける。
  // 許可一覧なら、語が1つも無くても「見覚えのない画面」として断る。
  const stripped = screen("choice-permission-bash")
    .replace(/Do you want to proceed\?/g, "Choose one")
    .replace(/requires confirmation for this command\./g, "is configured.")
    .replace(/\/permissions to update rules/g, "");
  const c = classify(stripped);
  assert.equal(c.kind, "unrecognized", "語を消しただけで良性になってはいけない");
  assert.notEqual(c.kind, "benign");
  assert.deepEqual(choiceViewOf("%1", stripped).keys, []);
});

test("陰性対照: 見た事のない選択画面は良性と名乗れない", () => {
  const unknown = [
    "   Select a workspace",
    "",
    "     1. Personal",
    "   ❯ 2. Team",
    "",
    "   Enter to confirm · Esc to cancel",
  ].join("\n");
  assert.equal(classifyScreen(unknown).state, "CHOICE", "前提: メニューとしては見えている");
  assert.equal(classify(unknown).kind, "unrecognized");
});

test("★入力欄が描かれたまま選択肢が出る画面は良性にしない(前提が破れた時は断る)", () => {
  // ★これは**実機でまだ観測していない形**。組み立てているのは、`inject.mjs` の menuAt が
  //   履歴と本物のメニューを割る材料が「メニュー中は入力欄が描かれない」の1つしか無く、
  //   その前提が破れた時に何が起きるかを、破れる前に決めておく為。
  //   実物が出た時に良性へ化けない事だけをここで固定する。
  const grafted = [
    "────────────────────────",
    "❯ ",
    "────────────────────────",
    "   Select model",
    "   Enter to set as default · s to use this session only · Esc to cancel",
    " ❯ 1. Default (recommended)",
    "   2. Opus (1M context)",
  ].join("\n");
  assert.equal(classifyScreen(grafted).state, "CHOICE", "前提: メニューとしては見えている");
  assert.equal(composerCloseOf(grafted) >= 0, true, "前提: 入力欄の箱が取れている");
  assert.equal(classify(grafted).kind, "unrecognized", "matcher の字面が揃っていても良性にしない");
});

test("★履歴のこだま・入力欄の番号行はメニューですらない(送信不能にしない)", () => {
  for (const name of ["transcript-echo-numbered", "composer-numbered-multiline"]) {
    assert.equal(classify(screen(name)).kind, "not-menu", `${name} をメニューと読んでいる`);
    assert.equal(choiceViewOf("%1", screen(name)), null);
  }
});

test("番号行が1つだけの画面はメニューと呼ばない", () => {
  assert.equal(parseMenu("   ❯ 1. Yes\n   Enter to confirm"), null);
});

// ---- 指紋 ----

test("★指紋は履歴が動いても変わらない(スピナー1コマで毎回断る検査にしない)", () => {
  const base = screen("choice-model-menu");
  const noisy = "✻ Cogitating… (3s)\n⏺ 途中の出力\n" + base;
  assert.equal(digestOf("%1", classify(noisy)), digestOf("%1", classify(base)));
});

test("★指紋は選択肢が変われば変わる(違うメニューを同一視しない)", () => {
  const base = screen("choice-model-menu");
  const swapped = base.replace("4. Sonnet", "4. Sonnnet");
  assert.notEqual(digestOf("%1", classify(swapped)), digestOf("%1", classify(base)));
});

test("指紋はペインごとに違う(別のペインの指紋を持ち回れない)", () => {
  const c = classify(screen("choice-model-menu"));
  assert.notEqual(digestOf("%1", c), digestOf("%2", c));
});

// ---- 打鍵の綴り ----

test("★数字は literal で送る(tmux に繰り返し回数と読ませない)", () => {
  assert.deepEqual(keyArgs("%1", "3"), ["send-keys", "-t", "%1", "-l", "--", "3"]);
  assert.deepEqual(keyArgs("%1", "enter"), ["send-keys", "-t", "%1", "Enter"]);
  assert.deepEqual(keyArgs("%1", "escape"), ["send-keys", "-t", "%1", "Escape"]);
});

test("受け付ける鍵は 1-9 / enter / escape だけ", () => {
  assert.deepEqual(CHOICE_KEYS.filter((k) => keyKind(k) === null), []);
  for (const bad of ["0", "10", "y", "C-c", "Enter", ""]) {
    assert.equal(CHOICE_KEYS.includes(bad), false, `${bad} を受け付けている`);
  }
});

test("許可一覧の各項目は実物の画面を持っている(架空の matcher を増やさない)", () => {
  for (const m of MATCHERS) {
    const text = screen(m.fixture.replace(/\.txt$/, ""));
    const c = classify(text);
    assert.equal(c.kind, "benign", `${m.name} の fixture が良性にならない`);
    assert.equal(c.matcher.name, m.name);
  }
});

// ---- 注入器 ----

test("★良性メニューには打鍵が飛ぶ", async () => {
  const menu = screen("choice-model-menu");
  const t = fakeTmux([menu, screen("idle-boot")]);
  const digest = digestOf("%1", classify(menu));
  const r = await inject(t).choice("%1", "3", { digest });
  assert.equal(r.sent, true);
  assert.equal(r.applied, "verified", "打った後にメニューが消えたのを見た");
  assert.deepEqual(sends(t), [["send-keys", "-t", "%1", "-l", "--", "3"]]);
});

test("★★許可確認には1文字も送らない", async () => {
  const menu = screen("choice-permission-bash");
  const t = fakeTmux(menu);
  const r = await inject(t).choice("%1", "1", { digest: digestOf("%1", classify(menu)) });
  assert.equal(r.sent, false);
  assert.equal(r.reason, "choice-hard-stop");
  assert.deepEqual(sends(t), [], "打鍵が1つでも飛んでいる");
});

test("★見覚えのない選択画面にも1文字も送らない", async () => {
  const menu = "   Pick one\n\n   ❯ 1. A\n     2. B\n\n   Enter to confirm";
  const t = fakeTmux(menu);
  const r = await inject(t).choice("%1", "1", { digest: digestOf("%1", classify(menu)) });
  assert.equal(r.reason, "choice-unrecognized");
  assert.deepEqual(sends(t), []);
});

test("★指紋が食い違えば何も送らず、今の指紋を返す(画面を撮り直させない)", async () => {
  const menu = screen("choice-model-menu");
  const t = fakeTmux(menu);
  const r = await inject(t).choice("%1", "3", { digest: "0000000000000000" });
  assert.equal(r.sent, false);
  assert.equal(r.reason, "digest-mismatch");
  assert.equal(r.digest, digestOf("%1", classify(menu)));
  assert.deepEqual(sends(t), []);
});

test("選択待ちでない画面には送らない", async () => {
  const t = fakeTmux(screen("idle-boot"));
  const r = await inject(t).choice("%1", "1", { digest: "x" });
  assert.equal(r.reason, "not-choice");
  assert.equal(r.state, "SENDABLE");
  assert.deepEqual(sends(t), []);
});

test("★Escape の後に静穏を置く(次の打鍵が Alt シーケンスに読まれない)", async () => {
  const menu = screen("choice-model-menu");
  const t = fakeTmux([menu, screen("idle-boot")]);
  await inject(t).choice("%1", "escape", { digest: digestOf("%1", classify(menu)) });
  assert.equal(t.sleepLog[0], ESC_SETTLE_MS, "Escape の直後に静穏が入っていない");
});

test("陰性対照: 数字の後に静穏は要らない", async () => {
  const menu = screen("choice-model-menu");
  const t = fakeTmux([menu, screen("idle-boot")]);
  await inject(t).choice("%1", "1", { digest: digestOf("%1", classify(menu)) });
  assert.equal(t.sleepLog.includes(ESC_SETTLE_MS), false);
});

test("★画面が動かなければ applied は unverified(「送った」を「効いた」と読まない)", async () => {
  const menu = screen("choice-model-menu");
  const t = fakeTmux(menu); // 何度撮っても同じ画面
  const inj = new TmuxInjector({
    tmux: t, sleep: async () => {}, echoBudgetMs: 0, // 待たずに諦める
  });
  const r = await inj.choice("%1", "3", { digest: digestOf("%1", classify(menu)) });
  assert.equal(r.sent, true);
  assert.equal(r.applied, "unverified");
});

test("★同じペインへの2本は直列化される(2人が同じ画面を見て両方押す事にならない)", async () => {
  // 鍵を通らないと、2本とも**同じ枚**を見て良性・指紋一致と判断し、両方が打つ。
  // 通れば後の1本は次の枚を見る事になり、そこはもうメニューではない。
  const menu = screen("choice-model-menu");
  const t = fakeTmux([menu, menu, screen("idle-boot")]);
  const inj = inject(t);
  const digest = digestOf("%1", classify(menu));
  const [a, b] = await Promise.all([
    inj.choice("%1", "1", { digest }),
    inj.choice("%1", "2", { digest }),
  ]);
  assert.equal(sends(t).length, 1, "同じメニューに2回打っている");
  assert.equal([a, b].filter((r) => r.sent).length, 1);
  assert.equal([a, b].find((r) => !r.sent).sent, false);
});

test("★別のメニューに変わった事も「効いた」と数える", async () => {
  const menu = screen("choice-model-menu");
  const next = menu.replace("Enter to set as default", "Enter to confirm").replace("Select model", "Select effort");
  const t = fakeTmux([menu, next]);
  const r = await inject(t).choice("%1", "2", { digest: digestOf("%1", classify(menu)) });
  assert.equal(r.applied, "verified");
});

// ---- 2026-08-03 の締め直し(Codex 指摘の5点。全部**断る側**へ寄せる変更) ----
//
// 出典は `/private/tmp/.../scratchpad/codex-choice.txt`(SHIP-GATE の相談)。
// 5件とも「誤りの向きが承認側になる並び」を潰す物で、機能を増やす変更は1つも無い。

test("★★hard-stop は許可一覧より先に見る(両方に当たる画面が良性へ倒れない)", () => {
  // 形は実機の `/model` のまま、選択肢の1行だけに hard-stop の語を混ぜる。
  // 判定の順序が逆(許可一覧が先)だと、この画面は `benign` と名乗って**打鍵が飛ぶ**。
  const evil = screen("choice-model-menu").replace("5. Haiku ✔", "5. Haiku ✔ Do you want to proceed");
  const c = classify(evil);
  assert.equal(c.kind, "hard-stop");
  assert.equal(c.matcher, null, "matcher が付いていると鍵が渡ってしまう");
  // 陰性対照: 語を混ぜなければ良性のまま(検査が hard-stop 側へ倒れ切っていない証拠)
  assert.equal(classify(screen("choice-model-menu")).kind, "benign");
});

test("★★見出しと末尾の字面だけ真似た画面は良性にならない(字面の一致は出自の証明ではない)", () => {
  // v1 の matcher は**この2つの字面しか見ていなかった**ので、中身が Yes/No 2択でも通った。
  const spoof = [
    "   Select model",
    "",
    "   ❯ 1. Yes",
    "     2. No",
    "",
    "   Enter to set as default · Esc to cancel",
  ].join("\n");
  const c = classify(spoof);
  assert.equal(c.kind, "unrecognized", "2択の Yes/No が /model の選択として通っている");
  assert.equal(c.matcher, null);
});

test("★選択肢が 1 からの連番でない画面も良性にならない(欠番 = 読み違えの合図)", () => {
  const gap = [
    "   Select model",
    "",
    "   ❯ 1. Alpha",
    "     2. Bravo",
    "     4. Delta",
    "",
    "   Enter to set as default · Esc to cancel",
  ].join("\n");
  assert.equal(classify(gap).kind, "unrecognized");
});

test("matcher の version は指紋に効く(締め直したら指紋が変わる = 古い指紋が通らない)", () => {
  const c = classify(screen("choice-model-menu"));
  assert.equal(c.matcher.version, "2");
  const withV1 = digestOf("%1", { ...c, matcher: { ...c.matcher, version: "1" } });
  assert.notEqual(digestOf("%1", c), withV1, "version が指紋の材料に入っていない");
});

test("★無い番号は打たない(5択へ `7` は未定義の打鍵)", async () => {
  const menu = screen("choice-model-menu");
  const t = fakeTmux(menu);
  const r = await inject(t).choice("%1", "7", { digest: digestOf("%1", classify(menu)) });
  assert.equal(r.sent, false);
  assert.equal(r.reason, "choice-no-such-option");
  assert.deepEqual(sends(t), []);
});

test("★★同じ指紋へ二度は打たない(`unverified` を見た電話の撃ち直しが次の画面へ流れる)", async () => {
  const menu = screen("choice-model-menu");
  const t = fakeTmux(menu); // 何度撮っても同じ = 画面が動いていないように見える
  const inj = new TmuxInjector({ tmux: t, sleep: async () => {}, echoBudgetMs: 0 });
  const digest = digestOf("%1", classify(menu));
  const first = await inj.choice("%1", "3", { digest });
  assert.equal(first.applied, "unverified", "前提: 1本目は結果不明で返る");
  const second = await inj.choice("%1", "3", { digest });
  assert.equal(second.sent, false);
  assert.equal(second.reason, "choice-already-sent");
  assert.equal(sends(t).length, 1, "同じ指紋へ2回打っている");
});

test("指紋が変われば同じペインへまた打てる(締め直しがペインを永久に塞がない)", async () => {
  const menu = screen("choice-model-menu");
  const other = menu.replace("5. Haiku ✔", "5. Haiku ✓"); // 選択肢の字面が変わる = 別の画面
  const t = fakeTmux([menu, menu, other, other]);
  const inj = new TmuxInjector({ tmux: t, sleep: async () => {}, echoBudgetMs: 0 });
  await inj.choice("%1", "3", { digest: digestOf("%1", classify(menu)) });
  const r = await inj.choice("%1", "3", { digest: digestOf("%1", classify(other)) });
  assert.equal(r.sent, true, "別の画面になったのに打てなくなっている");
});

test("★★打った後に許可確認が出たら `verified` と名乗らない(一番知らせたい着地)", async () => {
  const menu = screen("choice-model-menu");
  const t = fakeTmux([menu, screen("choice-permission-bash")]);
  const r = await inject(t).choice("%1", "2", { digest: digestOf("%1", classify(menu)) });
  assert.equal(r.sent, true);
  assert.equal(r.applied, "moved-to-hard-stop");
  assert.deepEqual(r.after, { screen: "CHOICE", choice: "hard-stop" });
});

test("着地した画面は成功時にも返る(`applied` だけでは**どこへ**動いたかが落ちる)", async () => {
  const menu = screen("choice-model-menu");
  const t = fakeTmux([menu, screen("idle-boot")]);
  const r = await inject(t).choice("%1", "3", { digest: digestOf("%1", classify(menu)) });
  assert.equal(r.applied, "verified");
  assert.equal(r.after.screen, "SENDABLE");
  assert.equal(r.after.choice, null, "選択画面でないなら choice は null");
});

// ---- 変異 C の走行で**素通りした**2件を塞ぐ(2026-08-03) ----
//
// 18件中16件は検出、素通りは C3(入力欄の有無を見ない)と C12(打鍵が鍵を通らない)。
// 素通り = 「その守りを外しても検査が全部緑」= **その守りを見ている検査が1本も無い**。
// 緑の数ではなく、この2件が赤くなる事が、ここで足す検査の存在理由。

test("★入力欄が在る事**だけ**を理由に良性から落とす(C3 が素通りした穴)", () => {
  // なぜ既存の「★入力欄が描かれたまま〜」では足りなかったか:
  //   あちらは末尾行が選択肢になっていて、**matcher の footer 条件の方で**落ちていた。
  //   つまり `composerAbsent` は一度も単独の理由になっておらず、守りを外しても
  //   別の条件が落とす = 変異 C3 が素通りする。
  //
  // ★この画面の形が「実機 fixture に箱を差し込む」ではないのは、2つの制約が噛むから
  //   (実測して分かった。素朴な差し込みは全部 `close = -1` になる):
  //     1. `composerBox` は**画面の下 8 行**しか閉じ罫線を探さない(引用画面を拾わない為)
  //     2. `parseMenu` は**閉じ罫線以下の行を全部捨てる**
  //   よって入力欄は「メニューのすぐ上」かつ「下 8 行の中」に無ければならない。
  //   実機の /model は選択肢から末尾行まで 9 行あるので、この条件に入らない。
  //   = **実機の select-model では、この守りに単独で到達する画面が作れない**。
  //   選択肢を詰めた形なら到達するので、そこで固定する。
  const rule = "─".repeat(120);
  const grafted = [
    "", " ▐▛███▜▌   Claude Code v2.1.220", "", "", "", "",
    rule, "❯ ", rule, // ← 入力欄の箱。閉じ罫線がメニューの直上に来る
    "   Select model",
    "     1. Default (recommended)  Opus 5 with 1M context",
    "     2. Opus (1M context)      Opus 5 with 1M context",
    "   ❯ 3. Fable                  Fable 5",
    "   Enter to set as default · s to use this session only · Esc to cancel",
  ].join("\n");

  assert.equal(classifyScreen(grafted).state, "CHOICE", "前提: メニューとしては見えている");
  const close = composerCloseOf(grafted);
  assert.ok(close >= 0, "前提: 入力欄の箱が取れている");
  const m = parseMenu(grafted, close);
  assert.ok(m, "前提: メニューとしては読めている");
  assert.equal(m.composerAbsent, false, "前提: 入力欄が在ると読めている");
  // ★これが C3 を検出可能にする1行。**入力欄の有無を除けば許可一覧に完全一致**なので、
  //   `composerAbsent` の判定を外した瞬間に下の行が benign へ倒れる。
  assert.equal(MATCHERS[0].test(m), true, "前提: 入力欄の有無**以外**は許可一覧に一致する");

  assert.equal(classify(grafted).kind, "unrecognized", "入力欄が在るのに良性にしている");
  assert.equal(classify(screen("choice-model-menu")).kind, "benign", "陰性対照: 実機の形は良性のまま");
});

test("★選択の打鍵はペインの鍵を待つ(C12 が素通りした繋ぎ目)", async () => {
  // 鍵が守るのは選択どうしではなく(それは `choice-already-sent` が断る)、
  // **送信と選択が混ざる**事。本文を打った後 Enter の前に数字や Escape が落ちると、
  // 送信側が「入力欄が空 = 取り込まれた」と誤認する(§2.18-2 の fail-open そのもの)。
  const menu = screen("choice-model-menu");
  const t = fakeTmux([menu, screen("idle-boot")]);
  const mutex = makeKeyedMutex();
  const inj = new TmuxInjector({ tmux: t, mutex, sleep: async () => {}, echoBudgetMs: 0 });

  let release;
  const holder = mutex.run("%1", () => new Promise((r) => (release = r)));
  assert.equal(mutex.isHeld("%1"), true, "前提: 鍵は塞がっている");

  const p = inj.choice("%1", "3", { digest: digestOf("%1", classify(menu)) });
  await new Promise((r) => setImmediate(r));
  assert.equal(sends(t).length, 0, "鍵を待たずに打っている");

  release();
  await holder;
  assert.equal((await p).sent, true);
  assert.equal(sends(t).length, 1);
});

test("★陰性対照: 鍵を通さない注入器は保持者が居ても打つ(= 上の緑は鍵を見ている)", async () => {
  const menu = screen("choice-model-menu");
  const t = fakeTmux([menu, screen("idle-boot")]);
  const mutex = makeKeyedMutex();
  let release;
  const holder = mutex.run("%1", () => new Promise((r) => (release = r)));
  // 注入器へは**鍵を通さない**版を渡す = 変異 C12 と同じ姿。
  const inj = new TmuxInjector({
    tmux: t, mutex: { run: (_k, fn) => fn() }, sleep: async () => {}, echoBudgetMs: 0,
  });

  const p = inj.choice("%1", "3", { digest: digestOf("%1", classify(menu)) });
  await new Promise((r) => setImmediate(r));
  assert.equal(sends(t).length, 1, "鍵を外しても打たない = 上の検査は鍵以外の何かを見ている");

  release();
  await holder;
  await p;
});

test("★動いたのを見た後は、同じ指紋へまた打てる(止めは「結果不明」の間だけ)", async () => {
  // `#choiceSent` は初版に `delete` が1つも無く、同じ形のメニューへは
  // **ペインごとに生涯1回**しか打てなかった。止めの目的は「結果が分からない間の撃ち直し」
  // の防止なので、**画面が動いたのを観測した**ら解除する。ここはその解除側。
  // 対になる止め側 =「★★同じ指紋へ二度は打たない」(= 動いていない `unverified` の時)。
  const menu = screen("choice-model-menu");
  const t = fakeTmux([menu, screen("idle-boot"), menu, menu]);
  const inj = new TmuxInjector({ tmux: t, sleep: async () => {}, echoBudgetMs: 0 });
  const opt = { digest: digestOf("%1", classify(menu)) };

  const r1 = await inj.choice("%1", "3", opt);
  assert.equal(r1.applied, "verified", "前提: 1回目で画面が動いたのを見ている");

  const r2 = await inj.choice("%1", "3", opt);
  assert.equal(r2.sent, true, `二度打ち止めが解除されていない(reason=${r2.reason})`);
  assert.equal(sends(t).length, 2);
});

test("メニューを離れたのを見た時も止めは解ける(消し所①)", async () => {
  // 1発目は画面が動かない = `unverified` で止めが残る(ここは残るのが正しい)。
  // その後**メニューに居ない**のを観測したら、前の打鍵の結果はもう分かっている。
  const menu = screen("choice-model-menu");
  const t = fakeTmux([menu, menu, screen("idle-boot"), menu, menu]);
  const inj = new TmuxInjector({ tmux: t, sleep: async () => {}, echoBudgetMs: 0 });
  const opt = { digest: digestOf("%1", classify(menu)) };

  assert.equal((await inj.choice("%1", "3", opt)).applied, "unverified", "前提: 画面は動いていない");
  assert.equal((await inj.choice("%1", "3", opt)).reason, "not-choice", "前提: 離れたのを見ている");

  const r = await inj.choice("%1", "3", opt);
  assert.equal(r.sent, true, `離れたのを見たのに止めが残っている(reason=${r.reason})`);
  assert.equal(sends(t).length, 2);
});
