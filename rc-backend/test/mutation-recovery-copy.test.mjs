// 作業木を変異させる対照が全部、**同じ復旧区間と同じ目印**を持っている事を毎 commit 測る。
//
// 何を守るか:
//   `.harness/dod-sprint-6-controls.sh` や `ios/tools/conversation-ui-control.sh` は
//   どちらも作業木の Swift を書き換えて戻す。trap EXIT は SIGKILL では走らないので
//   (向こうの header の実測)、殺された回の変異は作業木に残る。残った物を拾うのは
//   「次に起きた対照」で、その為に各対照は
//     ① 同じ固定 path の目印(INFLIGHT)を見る
//     ② 同じ復旧手順を持つ
//   の2つが要る。①が食い違うと、片方が残した変異をもう片方が「走る前の中身」として
//   複製し、**復元の基準点ごと汚染される** —— その変異は以後どちらにも戻せない。
//   しかも各対照は自分の仕事は正しく終えるので、緑のまま作業木だけが汚れる。
//
// なぜ手で揃えるだけにしないか:
//   同じ手順が複数箇所に在る限り、片方を直した日に他方が黙って古くなる。この repo が
//   2026-08-02 から6回踏んでいる形そのもの(門の走査 dir / 対照の宣言 / 的の数)。
//   だから写しは残したまま**ズレを毎 commit 測る**。commit-suite-gate から呼ばれる。
//
// ★2026-08-08 訂正(この file 自身が同じ形で壊れていた)。ここは長らく対象を
//   **手書きの2本**で持っていた。2026-08-08 の S8-5 が3本目
//   (`ios/tools/list-return-refresh-control.sh`)を、同日夜の S8-6 が4本目
//   (`ios/tools/inflight-sentence-control.sh`)を足したが、一覧は2本のまま ——
//   つまり増えた写しは**一度も測られないまま**共有の目印を触っていた。
//   守る対象を手で数える検査は、対象が増えた日に黙って穴が開く。
//   だから一覧を捨てて、**復旧区間の錨を持つ file を走査で拾う**形に変えた ——
//   数える側(手書きの表)ではなく、実際に其れを持っている側から数える。
//   走査が死んで0本や1本になったら「一致した」ではなく**測っていない**と名乗る。
//
// 取らなかった道: 区間を共有 library へ括り出して両者に source させる。筋は良いが、
//   dod-sprint-6 側は 13 変異 x xcodebuild の 27 分物で、書き換えたら丸ごと回して
//   確かめる必要が在る。今夜の commit で触るには重いので、括り出しは別建てにして、
//   それまでの間ズレだけを見張る。括り出した日にこの検査は不要になる(その時消す)。
//
// ★2026-08-06 追記(この file が実際に壊した物)。対象は全部 rc-backend の**外**なので、
//   rc-backend だけを写した木では3本とも赤くなる。その写しは `test/mutation-controls.py`
//   が立てる対照1で、落ちれば `die()` = 変異が1件も回らない。手元 687/687 緑のまま
//   判定器が死んでいた。木の外を測る検査は、外が居ない木では「赤」ではなく
//   **「測っていない」と名乗る**事。分岐は `test/subtree.mjs` に1つだけ置く。
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, existsSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { requireOutside, REPO_INTACT } from "./subtree.mjs";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const REPO = dirname(ROOT);

const BEGIN = "# ---- 前回の走行が殺されていたら、その取り残しを先に戻す(ここから)";
const END = "# ---- 前回の取り残しの復旧(ここまで)";

/** 復旧区間を持つ対照が住む dir。**file の一覧ではなく dir の一覧**である事が肝 —— */
/*   ここへ新しい対照が1本置かれた日に、何も書き足さずに測る側へ入る。            */
const DIRS = ["ios/tools", ".harness"];

// 木の外の要求は **dir** で立てる(写しでは dir ごと居ない)。
const GATE = requireOutside(DIRS);

/**
 * 共有の目印の**参加者**を、dir を走査して拾う。REPO からの相対 path。
 *
 * ★参加の宣言は `INFLIGHT=` の方であって、復旧区間の錨ではない。この向きは
 *   実測で決まった(2026-08-08、この走査を書いた当日に負の対照が2回赤くした):
 *
 *   誤り①「錨の文字列を含む file」で拾う ——
 *     `.harness/dod-sprint-6-recovery-controls.sh` が混ざる。あれは復旧区間**を
 *     測る側**の対照で、錨を `A_BEGIN='^# ---- …'` という**探し文として**持っている。
 *     目印は1つも宣言していないので `inflightPath` が測定不能で落ちた。
 *
 *   誤り②「錨で始まる行を持つ file」で拾う ——
 *     1本の錨を改名すると、その1本が**黙って走査から落ちて全部緑になる**。
 *     負の対照 NC3 で実際に緑が出た。件数の床(>=2)も残り3本を数えるので効かない。
 *     計器が死んだのに、主張している値をそのまま出す形 —— S8-5 で踏んだ物と同型。
 *
 *   正しい向き: **`INFLIGHT=` を宣言する事が「私は作業木を変異させ、共有の目印の
 *   契約に参加する」という申告**そのもの。だから参加者はそれで数え、区間を持って
 *   いるかは**参加者に課す義務**として別に測る(下の「参加者は全員…」)。
 *   こうすると錨の改名は「参加者なのに区間が無い」= 赤で、名指しで出る。
 */
function discover() {
  const found = [];
  for (const d of DIRS) {
    const abs = join(REPO, d);
    if (!existsSync(abs)) continue;
    for (const name of readdirSync(abs).sort()) {
      if (!name.endsWith(".sh")) continue;
      const rel = `${d}/${name}`;
      let lines;
      try {
        lines = readFileSync(join(REPO, rel), "utf8").split("\n");
      } catch {
        continue; // dir や読めない物は対象外(実在は下の下限が守る)
      }
      if (lines.some((l) => /^INFLIGHT="/.test(l))) found.push(rel);
    }
  }
  return found;
}

const FILES = GATE.skip ? [] : discover();

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
// 下の4本が `GATE.skip` で飛べる様になったので、完全な木で**飛んでいない**事を1本だけ
// 主張する。常に飛ぶ側へ壊れたら此処が完全な木で赤くなる
// (`REPO_INTACT` は `DESIGN.md` の実在だけを見るので、GATE の壊れ方と独立)。
test("この木では『部分木だから測らない』を通っていない", { skip: !REPO_INTACT && "部分木の写し" }, () => {
  assert.equal(GATE.skip, false, `親は健在なのに対象を測っていない: ${GATE.skip}`);
  assert.deepEqual(GATE.missing, [], "対象が改名・削除されている");
});

// ── 錨 ────────────────────────────────────────────────────────────────────
// 下は「全部が等しい」= 一致の主張なので、**対象が0本でも1本でも緑になる**。走査が
// 静かに死ぬ形(錨の文言を変えた / dir を改名した)が丁度それなので、先に下限を打つ。
// 数える対象は「復旧区間を持つ対照」で、これは増える一方の物だから 2 を床にする ——
// 3本目・4本目が増えても此処は理由なく赤くならず、走査が死んだ時だけ赤くなる。
test("走査が実際に参加者を拾えている(0本や1本を一致と読まない)", { skip: GATE.skip }, () => {
  assert.ok(
    FILES.length >= 2,
    `共有の目印を宣言する対照が ${FILES.length} 本しか見付からない = 走査が死んでいる。\n` +
      `  探した dir: ${DIRS.join(" ")}\n` +
      "  対照が別の dir へ移ったか、宣言の綴りが変わったか。一致の主張は対象が空でも緑になる。",
  );
});

// ★上の床は**全滅**しか掴めない(3本残れば緑)。1本だけ落ちる形 —— 錨を改名した
//   対照が黙って走査から消える —— を掴むのは此処。参加を宣言した以上、区間を持つ事は
//   義務であって、持っていない者は「対象外」ではなく**赤**。
test("参加者は全員、復旧区間を自分で持っている", { skip: GATE.skip }, () => {
  for (const f of FILES) {
    const lines = body(f);
    assert.ok(
      lines.some((l) => l.startsWith(BEGIN)),
      `共有の目印(INFLIGHT)を宣言しているのに復旧区間が無い: ${f}\n` +
        "  = 作業木を変異させるのに、殺された回の取り残しを誰も戻さない。\n" +
        "  錨の文言を変えた場合も此処に出る(黙って走査から落ちる方が危険なので赤にする)。",
    );
  }
});

// 下は「全部が等しい」の主張なので、切り出しが空でも緑になる。だから
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

// ★1本目を基準にして全部を突き合わせる。総当たりにしないのは、ズレた時に
//   「どれが基準か」が読み手に判らない失敗文になるから —— 走査は sort 済みなので
//   基準は毎回同じ file になる。
test("復旧区間を持つ対照は、全部が同じ復旧手順を持っている", { skip: GATE.skip }, () => {
  const base = code(region(FILES[0]));
  for (const f of FILES.slice(1)) {
    assert.deepEqual(
      code(region(f)),
      base,
      "殺された回の取り残しを戻す手順がズレている。\n" +
        "  1本だけ直すと、他が残した変異をこちらが復元の基準点として複製する。\n" +
        `  基準: ${FILES[0]}\n  ズレ: ${f}\n  全対象: ${FILES.join(" と ")}`,
    );
  }
});

test("復旧区間を持つ対照は、全部が同じ目印(INFLIGHT)を見ている", { skip: GATE.skip }, () => {
  const base = inflightPath(FILES[0]);
  for (const f of FILES.slice(1)) {
    assert.equal(
      inflightPath(f),
      base,
      "目印の path がズレている = 互いの取り残しを拾えない。\n" +
        "  同じ Swift の file を変異させる対照どうしなので、ここが違うと\n" +
        "  片方の変異が他方の「走る前の中身」として複製され、誰にも戻せなくなる。\n" +
        `  基準: ${FILES[0]}\n  ズレ: ${f}`,
    );
  }
});
