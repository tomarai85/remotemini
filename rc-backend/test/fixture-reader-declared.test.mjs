// RC_UI_FIXTURE を**読む** Swift の file が、その漏れを測る対照に全部宣言されているか。
//
// 何を守るか:
//   ios/tools/ui-fixture-absence-control.sh は「Release バイナリに RC_UI_FIXTURE の
//   文字列が1件も無い」を strings で測る。これは審査に出す実機ビルドが環境変数ひとつで
//   固定データ画面へ落ちない事の唯一の保証で、性質としては**バイナリ全体**の話である。
//   ところがこの対照が commit の門で選ばれるかは、頭の controls-for 行に書かれた
//   file 名だけで決まる。対照の測る範囲(バイナリ全体)と、対照が呼ばれる条件
//   (名指しの数 file)がズレていた。
//
// 実測(2026-08-06、これを書いた理由):
//   宣言は ios/Sources/Core/SessionsListingFixture.swift と ios/project.yml の2つ。
//   一方 ProcessInfo…environment["RC_UI_FIXTURE"] を実際に読む file は**2つ在った** ——
//   もう1つが ios/Sources/Core/HistoryFixture.swift(ConversationHistoryFactory)。
//   つまり会話画面側の #if DEBUG を外す commit は、その漏れを測る唯一の対照を
//   **一度も呼ばずに**通る状態だった。名前が近い file が既に宣言されているので、
//   人の目には「宣言済み」に見えるのが厄介な所。
//
// なぜ手で1行足すだけにしないか:
//   足した一覧は次に3つ目の読み手が現れた日に黙って痩せる —— この repo が
//   2026-08-02 から何度も踏んでいる「手で同期する2本目の一覧」そのもの。
//   だから一覧は残したまま、**現実(grep)と宣言(controls-for)が一致しているか**を
//   毎 commit 測る。commit-suite-gate から呼ばれるので、走らない日は無い。
//
// 取らなかった道: 宣言を ios/Sources/** の様な glob へ広げる。対照は xcodebuild を
//   2回回すので、Swift を1行直す度に数分待たされる。範囲は狭いまま、ズレだけを見張る。
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync, existsSync, statSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const REPO = dirname(ROOT);
const IOS = join(REPO, "ios");
const CONTROL = join(IOS, "tools", "ui-fixture-absence-control.sh");

// 綴りを1箇所で組み立てる。この file 自身の中に、探している綴りが素で現れない為
// (no-linerefs.test.mjs が自分自身を走査するのと同じ配慮)。
const VAR = "RC_UI_FIXTURE";
const READ_RE = () => new RegExp('ProcessInfo\\.processInfo\\.environment\\["' + VAR + '"\\]');

/** ios/Sources の下の .swift を全部。 */
function swiftFiles() {
  const out = [];
  const walk = (d) => {
    if (!existsSync(d)) return;
    for (const e of readdirSync(d, { withFileTypes: true })) {
      const p = join(d, e.name);
      if (e.isDirectory()) walk(p);
      else if (e.name.endsWith(".swift")) out.push(p);
    }
  };
  walk(join(IOS, "Sources"));
  return out;
}

const rel = (p) => p.slice(REPO.length + 1);

/** 変数を**読んでいる** file(注釈で名前を挙げているだけの file は入らない)。 */
function readers() {
  const re = READ_RE();
  return swiftFiles()
    .filter((p) => re.test(readFileSync(p, "utf8")))
    .map(rel)
    .sort();
}

/** 対照の頭の controls-for 行が挙げている path。 */
function declared() {
  const line = readFileSync(CONTROL, "utf8")
    .split("\n")
    .find((l) => l.startsWith("# controls-for:"));
  assert.ok(line, "対照に controls-for 行が無い = この検査の前提が崩れている");
  return line.replace("# controls-for:", "").trim().split(/\s+/).filter(Boolean);
}

// ── 錨 ────────────────────────────────────────────────────────────────────
// 下の主張は「差集合が空」= 否定だけなので、走査が空回りしても緑になる。
// だから件数の下限ではなく、**現に走査に掛かった実名**を先に固定する
// (vacuous-scan.py の言う「数字を発明しない錨」)。
test(`${VAR} を読む file の走査が実際に当たっている`, () => {
  assert.ok(existsSync(IOS), "ios の木が無い");
  const found = readers();
  assert.ok(
    found.includes("ios/Sources/Core/SessionsListingFixture.swift"),
    `走査が一覧の側を捕まえていない(実測: ${JSON.stringify(found)})= 探し方が壊れている`,
  );
  assert.ok(
    found.includes("ios/Sources/Core/HistoryFixture.swift"),
    `走査が会話側を捕まえていない(実測: ${JSON.stringify(found)})= 探し方が壊れている`,
  );
});

test(`${VAR} を読む file は全部、漏れを測る対照に宣言されている`, () => {
  const decl = declared();
  const missing = readers().filter((r) => !decl.includes(r));
  assert.deepEqual(
    missing,
    [],
    "この file を触る commit は、Release への漏れを測る対照を一度も呼ばずに通る。\n" +
      "  直し方: ios/tools/ui-fixture-absence-control.sh の controls-for 行に足す。\n" +
      "  足りない: " + JSON.stringify(missing),
  );
});

test("対照の宣言に、実在しない path が残っていない", () => {
  // 逆向き。改名した時に宣言だけ取り残されると、対照は「宣言はしているのに
  // 何にも当たらない」= 静かに回らない対照になる(門の側の stale 注記は
  // glob を素通しするので、素の path はここでも見ておく)。
  const gone = declared().filter((d) => !/[*?[]/.test(d) && !existsSync(join(REPO, d)));
  assert.deepEqual(gone, [], `宣言先が実在しない: ${JSON.stringify(gone)}`);
});
