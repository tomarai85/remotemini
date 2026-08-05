// `npm test` の**走査**そのものを測る。走らなかった検査は、落ちた検査より静かで危ない。
//
// ── なぜ要るか(2026-08-05)────────────────────────────────────────────────
// この案件は同じ形で既に一度刺されている。`vacuous-scan.py` の旧版が `*.test.mjs`(非再帰)で
// 走査していて、`ios/Tests` の 19 本中 18 本が部分木に在った為、**一本も見ていないのに**
// 「否定だけの検査: N 本」と堂々と報告していた。見ている範囲を言わない道具は、
// 見ていない事を緑として報告する。
//
// 同じ書き方が `package.json` の `scripts.test` にも在った(`node --test 'test/*.test.mjs'`)。
// 今日の時点では実害ゼロ —— `test/` の部分木は `fixtures/` だけで、検査 file は 29 本とも
// 直下に在る(非再帰 29 / 再帰 29 で一致)。だから「壊れていた」のではなく、
// **次に部分木へ1本置いた人が、黙って走らない検査を持つ**という罠だった。
//
// 罠は塞いだ(`test/**/*.test.mjs`)。この検査はその状態を固定する為に在る。
// ★測るのは文字列ではなく**結果**: 走査パターンが非再帰へ戻る事自体は許す。
//   許さないのは「非再帰なのに部分木に検査 file が在る」= 落ちている本数が 0 でない状態。
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const TESTDIR = HERE;
const PKG = join(HERE, "..", "package.json");

/** 実在する検査 file を**再帰で**数える(= 分母)。 */
function allTestFiles() {
  return readdirSync(TESTDIR, { recursive: true })
    .map(String)
    .filter((p) => p.endsWith(".test.mjs"))
    .map((p) => p.split("\\").join("/"));
}

/** `scripts.test` から走査パターンを取り出す。 */
function discoveryPattern() {
  const pkg = JSON.parse(readFileSync(PKG, "utf8"));
  const cmd = pkg.scripts?.test ?? "";
  const m = cmd.match(/'([^']+)'|"([^"]+)"/);
  return { cmd, pattern: m ? m[1] ?? m[2] : null };
}

test("★走査パターンが取り出せる(取り出せない = 以下の判定が空回り)", () => {
  const { cmd, pattern } = discoveryPattern();
  // ★肯定の錨。ここが null のまま下の検査へ進むと、全部が「該当なしで緑」になる。
  assert.ok(pattern, `scripts.test から走査パターンを取り出せない: ${JSON.stringify(cmd)}`);
  assert.match(pattern, /\.test\.mjs$/, `検査 file を指していない走査: ${pattern}`);
});

test("★実在する検査 file を歩けている(分母が立つ事)", () => {
  const all = allTestFiles();
  // 錨: この file 自身が必ず居る。居なければ歩けていない。
  assert.ok(
    all.includes("test-discovery.test.mjs"),
    `自分自身を見つけられない = 走査が回っていない(見えた物: ${all.length} 件)`,
  );
  assert.ok(all.length >= 25, `検査 file が少なすぎる: ${all.length} 件(数え方が壊れている)`);
});

test("★`npm test` が実在する検査 file を1本も落としていない", () => {
  const { pattern } = discoveryPattern();
  const all = allTestFiles();
  assert.ok(all.length >= 25, `分母が立たない: ${all.length} 件`); // 上と同じ錨(自立させる)

  const inSubtree = all.filter((p) => p.includes("/"));
  if (pattern.includes("**")) {
    // 再帰なら部分木も拾う。落ちる物は無い。
    return;
  }
  assert.deepEqual(
    inSubtree,
    [],
    `走査 '${pattern}' は非再帰。部分木のこれらは **npm test で一度も走らない**: ${inSubtree.join(", ")}`,
  );
});
