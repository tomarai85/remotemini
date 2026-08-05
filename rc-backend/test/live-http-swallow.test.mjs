// `tools/live-http-check.mjs` の**例外の飲み方**を静的に測る(DESIGN §2.20-a L3 / §2.20-a-ii)。
//
// 測っているのは「`catch` の数」ではない。**「読めなかった」が「無い」に化ける口**が
// 0 かどうか(= §2.16 と同じ基準を、計器の側でもう一度守る)。だから検査の形は
// **除外リスト**になる —— 飲むのが正しい所を1行ずつ理由付きで持ち、それ以外の
// 素の `} catch {` が1つでも生えたら赤。
//
// ★「13 → 0」にしてはいけない理由(§2.20-a-ii): 全部を騒がしくすると、飲むのが正しい所まで
//   detail を汚す。逆に一覧だけ持って中身を読まないと、除外が古くなった事に誰も気づかない。
//   ここでの正本は §2.20-a-ii の表**だけ**で、この file はその唯一の正本を機械が読む形にした物。
//
// ★除外は **8 行**。数の履歴を書いておく —— 一致する数字を見て「合っている」と読むのが
//   この案件で最も繰り返している型(一覧の数字を、実物を数え直した後も持ち歩く)だから。
//     - DESIGN §2.20-a-ii の本文の「8」: 「条件付き1」(ペイン登録簿の json)を**直す前**の 8。
//     - その1件を `catch (e)` に直した = 素の catch ではなくなった → 7。
//     - 2026-08-05、ワーカー経路の観測(`live-http-check.mjs` §11)で `pgrep` の一致数を
//       数える口を足した → 8。
//   ★今の 8 と DESIGN の 8 は**中身が違う**(片方に居るのは登録簿、もう片方は pgrep)。
//   数字が偶然揃っているだけなので、DESIGN の表と突き合わせる者はこの註釈を先に読む事。
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const FILE = join(dirname(fileURLToPath(import.meta.url)), "..", "tools", "live-http-check.mjs");
const SRC = readFileSync(FILE, "utf8");

/**
 * 素の `} catch {`(= 例外を**束縛すらしない** = 理由が確実に消える形)を全部拾い、
 * それぞれの `try` 本体を返す。
 *
 * ★行番号で覚えない。行番号は動く(§3-R で踏んだ型)。当てるのは**中身**で、
 *   行番号は落ちた時の道案内としてだけ出す。
 */
function bareCatches(src) {
  const out = [];
  const re = /\}\s*catch\s*\{/g;
  let m;
  while ((m = re.exec(src)) !== null) {
    out.push({
      line: src.slice(0, m.index).split("\n").length,
      body: tryBody(src, m.index),
    });
  }
  return out;
}

/** `}` から括弧を逆に数えて、対応する `try {` の本体を切り出す。 */
function tryBody(src, closeIdx) {
  let depth = 1;
  for (let i = closeIdx - 1; i >= 0; i--) {
    if (src[i] === "}") depth++;
    else if (src[i] === "{" && --depth === 0) return src.slice(i + 1, closeIdx);
  }
  return src.slice(0, closeIdx);
}

/**
 * ★除外リスト = DESIGN §2.20-a-ii の表を機械が読む形にした物。
 * `why` は飾りではない —— 除外を増やす者に「なぜ飲んでよいか」を1行で書かせる為に在る。
 */
const ALLOWED = [
  [/\btmux\(args\);/, "tmux が通るか。真偽そのものが答えで、理由を出す先が無い(返り値が理由)"],
  [/JSON\.parse\(buf\)/, "api() の応答が json でない(HTML など)。設計どおりで、生の本文は body として既に返っている"],
  [/command -v \$\{JSON\.stringify\(opt\.bin\)\}/, "`command -v` が見つけられない = 不在が答え"],
  [/hasTrustDialogAccepted/, "信頼済み dir の一覧。既に正しい —— null を返し『読めない = 分からない。未信頼と決めつけない』を cwdNote に出している"],
  [/await api\(opt\.port, null, "GET", "\/"\)/, "起動待ちの health 叩き。まだ起きていないのだから null が答え"],
  [/stream\?\.close\(\)/, "後始末。後始末の失敗で検査結果を汚さない"],
  [/return realpathSync\(p\)/, "invokedDirectly の正規化。cwd の判定とは無関係(関数名から理由を作らない)"],
  [
    /execFileSync\("\/usr\/bin\/pgrep"/,
    "`pgrep` は一致 0 件で exit 1 を返す。此処での例外は失敗ではなく**『0 件』の表現**なので、0 を返すのが正しい訳し方(数える用途に限る)",
  ],
];

/** 除外に当たらない素の catch を並べる。空 = 規約を満たす。 */
function unlisted(src) {
  return bareCatches(src)
    .filter(({ body }) => !ALLOWED.some(([re]) => re.test(body)))
    .map(({ line, body }) => `:${line}(${body.trim().split("\n")[0].slice(0, 48)})`);
}

/** どの素の catch にも当たらない除外(= 古くなった行)を並べる。 */
function deadEntries(src, list = ALLOWED) {
  const bodies = bareCatches(src).map((c) => c.body);
  return list.filter(([re]) => !bodies.some((b) => re.test(b))).map(([re]) => String(re));
}

test("実物に**一覧に無い素の catch** が居ない", () => {
  // ★錨。`unlisted` は走査が一件も回らなくても `[]` を返す —— `SRC` が読めていなければ
  //   この検査は何も見ずに緑になる。実測(2026-08-05): `SRC = ""` の変異を当てたら、
  //   この file の 10 本中**此処だけ**が緑のまま残った。件数の突き合わせは次の検査の
  //   仕事なので、此処では「歩いたか」だけを固定する。
  assert.ok(bareCatches(SRC).length > 0, "素の catch を1つも歩けていない = 下の行は空振り");
  assert.deepEqual(unlisted(SRC), [], "飲んでよい理由が書かれていない catch が在る");
});

test("★除外リストが古くなっていない(当たらない行 = 直したのに一覧が残っている)", () => {
  assert.deepEqual(deadEntries(SRC), [], "除外が実物に当たらない");
  assert.equal(bareCatches(SRC).length, ALLOWED.length, "素の catch と除外の数が食い違う");
});

test("飲んだ物を**最後に必ず出す**口が生きている(§2.16 を報告側でもう一度)", () => {
  assert.match(SRC, /const swallowed = \[\];/, "溜め場が無い");
  assert.match(SRC, /const swallow = \(where, e\) =>/, "溜める関数が無い");
  // ★定義は `const swallow = (where, e) =>` なので `swallow(` には当たらない。当たるのは
  //   呼び口だけ(最初この行で「定義の1件を引く」と書いて 4 を 3 と数えた = 数える前に読む)。
  const calls = (SRC.match(/\bswallow\("/g) || []).length;
  assert.ok(calls >= 4, `化ける口に当てている数が足りない: ${calls}`);
  assert.match(
    SRC,
    /note\("読めなかった物", swallowed\.length \? swallowed\.join\(" \/ "\) : "無し"\)/,
    "『無し』を出さない報告は、欄を忘れた事と区別が付かない",
  );
});

test("★条件付き1(ペイン登録簿)が直っている = 壊れた json と不在が別の文になる", () => {
  assert.match(SRC, /let lastPaneErr = "";/, "最後の理由を残していない");
  assert.match(SRC, /catch \(e\) \{\n\s+lastPaneErr = /, "輪の中で理由を捨てている");
  assert.match(SRC, /最後に読めなかった物: \$\{lastPaneErr \|\| "無し"\}/, "30 秒で落ちた時に理由が出ない");
});

// --- 陰性対照 ---------------------------------------------------------------
// 「通った」を「何も見ていない」と区別する。★入力は**実物**から作る(手書きの偽物で測ると
// 自分の書き癖にしか当たらない = run-controls.sh 冒頭の規則(1))。実物は読むだけ。
const STRIPS = [
  [
    "★飲み口を1つ素の catch に戻す(= L3 の当てが剥がれた形)",
    (s) => s.replace(
      '} catch (e) {\n    // 読めない dir を「登録が1件も無い」に化かさない。\n    swallow("ペイン登録簿の dir", e);\n    return [];\n  }',
      "} catch {\n    return [];\n  }",
    ),
    (s) => unlisted(s).length > 0,
  ],
  [
    "報告の口(`note(\"読めなかった物\"…)`)を落とす",
    (s) => s.replace(/note\("読めなかった物".*\);/, ""),
    (s) => !/note\("読めなかった物"/.test(s),
  ],
  [
    "★『無し』の既定を落とす(欄が消えて、読めなかった物が無い様に見える)",
    (s) => s.replace('swallowed.length ? swallowed.join(" / ") : "無し"', 'swallowed.join(" / ")'),
    (s) => !/: "無し"\)/.test(s),
  ],
  [
    "条件付き1 を元(理由を捨てる形)へ戻す",
    (s) => s.replace(
      "} catch (e) {\n          lastPaneErr = ",
      "} catch {\n          const _unused = ",
    ),
    (s) => unlisted(s).length > 0,
  ],
];

for (const [name, strip, isRed] of STRIPS) {
  test(`陰性対照: ${name} → 検査が落ちる`, () => {
    const broken = strip(SRC);
    assert.notEqual(broken, SRC, "抜けていない = 検査が実物の書き方に当たっていない");
    assert.ok(isRed(broken), "抜いたのに検査が気づかない");
  });
}

test("陰性対照: 今の木は通る(上の対照が『常に赤』ではない事)", () => {
  // ★肯定の錨を**この検査自身の中に**持つ。`unlisted` も `deadEntries` も、走査が
  //   一件も回らなければ `[]` を返す —— `SRC` が空でも下の2行は緑になる。
  //   兄弟(「★除外リストが古くなっていない」の `bareCatches(SRC).length === ALLOWED.length`)
  //   が捕まえてはくれる。だがそれは、**兄弟が消えたら此処が意味を失う**という事でもある。
  //   対照は自分で立つ。(2026-08-05 vacuous-scan.py が挙げた 36 本の中の、本物の方)
  //   ※この註釈を最初 `:87` と行番号で書いて、実物は `:88` だった。書き足している最中の
  //     file へ行番号で引かない —— 引くなら検査の名前で引く。
  assert.equal(bareCatches(SRC).length, ALLOWED.length, "素の catch を歩けていない = 下の2行は空振り");
  assert.deepEqual(unlisted(SRC), []);
  assert.deepEqual(deadEntries(SRC), []);
});

test("陰性対照: 実物に当たらない除外を1行足すと落ちる(一覧の古さを測っている証拠)", () => {
  const withGhost = [...ALLOWED, [/この文字列は実物に無い/, "偽の除外"]];
  assert.equal(deadEntries(SRC, withGhost).length, 1, "古い除外を見逃す");
});
