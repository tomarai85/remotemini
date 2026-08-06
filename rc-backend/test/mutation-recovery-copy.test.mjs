// ios の変異対照が2本、**同じ復旧区間と同じ目印**を持っている事を毎 commit 測る。
//
// 何を守るか:
//   .harness/dod-sprint-6-controls.sh と ios/tools/conversation-ui-control.sh は
//   どちらも作業木の Swift を書き換えて戻す。trap EXIT は SIGKILL では走らないので
//   (向こうの header の実測)、殺された回の変異は作業木に残る。残った物を拾うのは
//   「次に起きた対照」で、その為に両者は
//     ① 同じ固定 path の目印(INFLIGHT)を見る
//     ② 同じ復旧手順を持つ
//   の2つが要る。①が食い違うと、片方が残した変異をもう片方が「走る前の中身」として
//   複製し、**復元の基準点ごと汚染される** —— その変異は以後どちらにも戻せない。
//   しかも両対照は自分の仕事は正しく終えるので、緑のまま作業木だけが汚れる。
//
// なぜ手で揃えるだけにしないか:
//   同じ手順が2箇所に在る限り、片方を直した日にもう片方が黙って古くなる。この repo が
//   2026-08-02 から6回踏んでいる形そのもの(門の走査 dir / 対照の宣言 / 的の数)。
//   だから写しは残したまま**ズレを毎 commit 測る**。commit-suite-gate から呼ばれる。
//
// 取らなかった道: 区間を共有 library へ括り出して両者に source させる。筋は良いが、
//   dod-sprint-6 側は 13 変異 x xcodebuild の 27 分物で、書き換えたら丸ごと回して
//   確かめる必要が在る。今夜の commit で触るには重いので、括り出しは別建てにして、
//   それまでの間ズレだけを見張る。括り出した日にこの検査は不要になる(その時消す)。
//
// ★2026-08-06 追記(この file が実際に壊した物)。対象2本とも rc-backend の**外**なので、
//   rc-backend だけを写した木では3本とも赤くなる。その写しは `test/mutation-controls.py`
//   が立てる対照1で、落ちれば `die()` = 変異が1件も回らない。手元 687/687 緑のまま
//   判定器が死んでいた。木の外を測る検査は、外が居ない木では「赤」ではなく
//   **「測っていない」と名乗る**事。分岐は `test/subtree.mjs` に1つだけ置く。
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { requireOutside, REPO_INTACT } from "./subtree.mjs";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const REPO = dirname(ROOT);

const FILES = [
  ".harness/dod-sprint-6-controls.sh",
  "ios/tools/conversation-ui-control.sh",
];

// 対象そのものを木の外の要求として立てる(一覧を2本目に写さない)。
const GATE = requireOutside(FILES);

const BEGIN = "# ---- 前回の走行が殺されていたら、その取り残しを先に戻す(ここから)";
const END = "# ---- 前回の取り残しの復旧(ここまで)";

function body(rel) {
  const p = join(REPO, rel);
  assert.ok(existsSync(p), `対象が無い: ${rel}`);
  return readFileSync(p, "utf8").split("\n");
}

/** 錨の間を切り出す。錨が一意でなければ**測定不能**として落とす(黙って空を返さない)。 */
function region(rel) {
  const lines = body(rel);
  const starts = lines.map((l, i) => (l.startsWith(BEGIN) ? i : -1)).filter((i) => i >= 0);
  const ends = lines.map((l, i) => (l.startsWith(END) ? i : -1)).filter((i) => i >= 0);
  assert.equal(starts.length, 1, `開始の錨が一意でない(${starts.length}件): ${rel}`);
  assert.equal(ends.length, 1, `終了の錨が一意でない(${ends.length}件): ${rel}`);
  assert.ok(ends[0] > starts[0], `錨の順序が逆: ${rel}`);
  return lines.slice(starts[0], ends[0] + 1);
}

/** 注釈と空行を落とした「実行される行」。注釈は各対照の文脈を書くので**違ってよい**。 */
const code = (lines) =>
  lines.map((l) => l.trim()).filter((l) => l.length > 0 && !l.startsWith("#"));

/** 目印の path を宣言している行(値だけを取り出す)。 */
function inflightPath(rel) {
  const hits = body(rel)
    .map((l) => l.match(/^INFLIGHT="([^"]+)"/))
    .filter(Boolean)
    .map((m) => m[1]);
  assert.equal(hits.length, 1, `INFLIGHT の宣言が一意でない(${hits.length}件): ${rel}`);
  return hits[0];
}

// ── 逃げ道の錨 ────────────────────────────────────────────────────────────
// 下の3本が `GATE.skip` で飛べる様になったので、完全な木で**飛んでいない**事を1本だけ
// 主張する。常に飛ぶ側へ壊れたら此処が完全な木で赤くなる
// (`REPO_INTACT` は `DESIGN.md` の実在だけを見るので、GATE の壊れ方と独立)。
test("この木では『部分木だから測らない』を通っていない", { skip: !REPO_INTACT && "部分木の写し" }, () => {
  assert.equal(GATE.skip, false, `親は健在なのに対象を測っていない: ${GATE.skip}`);
  assert.deepEqual(GATE.missing, [], "対象が改名・削除されている");
});

// ── 錨 ────────────────────────────────────────────────────────────────────
// 下は「2つが等しい」= 一致の主張なので、両方とも空でも緑になる。だから先に
// **切り出しが本物の手順を掴んでいる**事を、実在する行の名前で固定する
// (件数の下限は書かない —— 行が1本増えた日に此処が理由なく赤くなる)。
test("復旧区間の切り出しが実際に中身を掴んでいる", { skip: GATE.skip }, () => {
  for (const f of FILES) {
    const c = code(region(f));
    assert.ok(
      c.some((l) => l.includes('/bin/cp "$rs" "$rf"')),
      `復旧の本体(複製からの書き戻し)が切り出せていない: ${f}`,
    );
    assert.ok(
      c.some((l) => l.includes('/bin/rm -f "$INFLIGHT"')),
      `目印の後始末が切り出せていない: ${f}`,
    );
  }
});

test("ios の変異対照2本は、同じ復旧手順を持っている", { skip: GATE.skip }, () => {
  const [a, b] = FILES.map((f) => code(region(f)));
  assert.deepEqual(
    b,
    a,
    "殺された回の取り残しを戻す手順が2本でズレている。\n" +
      "  片方だけ直すと、もう片方が残した変異をこちらが復元の基準点として複製する。\n" +
      `  対象: ${FILES.join(" と ")}`,
  );
});

test("ios の変異対照2本は、同じ目印(INFLIGHT)を見ている", { skip: GATE.skip }, () => {
  const [a, b] = FILES.map(inflightPath);
  assert.equal(
    b,
    a,
    "目印の path がズレている = 互いの取り残しを拾えない。\n" +
      "  同じ Swift の file を変異させる対照どうしなので、ここが違うと\n" +
      "  片方の変異が他方の「走る前の中身」として複製され、誰にも戻せなくなる。",
  );
});
