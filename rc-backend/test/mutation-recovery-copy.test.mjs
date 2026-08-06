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
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const REPO = dirname(ROOT);

const FILES = [
  ".harness/dod-sprint-6-controls.sh",
  "ios/tools/conversation-ui-control.sh",
];

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

// ── 錨 ────────────────────────────────────────────────────────────────────
// 下は「2つが等しい」= 一致の主張なので、両方とも空でも緑になる。だから先に
// **切り出しが本物の手順を掴んでいる**事を、実在する行の名前で固定する
// (件数の下限は書かない —— 行が1本増えた日に此処が理由なく赤くなる)。
test("復旧区間の切り出しが実際に中身を掴んでいる", () => {
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

test("ios の変異対照2本は、同じ復旧手順を持っている", () => {
  const [a, b] = FILES.map((f) => code(region(f)));
  assert.deepEqual(
    b,
    a,
    "殺された回の取り残しを戻す手順が2本でズレている。\n" +
      "  片方だけ直すと、もう片方が残した変異をこちらが復元の基準点として複製する。\n" +
      `  対象: ${FILES.join(" と ")}`,
  );
});

test("ios の変異対照2本は、同じ目印(INFLIGHT)を見ている", () => {
  const [a, b] = FILES.map(inflightPath);
  assert.equal(
    b,
    a,
    "目印の path がズレている = 互いの取り残しを拾えない。\n" +
      "  同じ Swift の file を変異させる対照どうしなので、ここが違うと\n" +
      "  片方の変異が他方の「走る前の中身」として複製され、誰にも戻せなくなる。",
  );
});
