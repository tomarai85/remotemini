// 書類(`.md`)の中の行番号引用を、**今より増やさない**。
//
// ── なぜ別の file なのか ────────────────────────────────────────────────
// 隣の `no-linerefs` は「1件でも在れば赤」で、code の側はそれで通っている。
// 書類は通らない —— 実測 393 件在るので、同じ規則を当てた瞬間に永久に赤になり、
// **使えない検査は外される**。だから規則を分けた: code はゼロ、書類は増やさない。
//
// ── 何を測って、この形にしたか(2026-08-05)────────────────────────────
// 追跡 .md 36 本に行番号引用が 393 件。三段階で見た:
//   ① file が消えた / 行が足りない          → 10 件。読んだら**全部この repo の外**
//      (宿主の `~/bin` の台本、`~/.claude/tools/` の物、edith 上の実体、未追跡の書きかけ)
//      = 本物の腐りは 0 件。第1版の物差しは、腐りの主形を1件も捕まえていなかった。
//   ② 引用が書かれた後にその file が動いたか → 274 件。**上界**。動いた事は
//      その行がズレた事ではない(引用箇所より後ろの変更なら無事)。
//   ③ 無作為に 8 件を人が読んで突き合わせた   → **5 件が別の場所を指していた**。
//      隣の検査の由来(code 側 27 件中 21 件が別行)と同じ桁である。
//
// 全数に効く機械の物差しも書いたが、**自分の対照に落ちたので捨てた**:
// 引用と同じ文の backtick から識別子を取り、±3 行に在るかを見る形にした所、
// 手で読んだ 8 件に対して 一致3 / 不一致1 / 測れない4。しかも測れない 4 件のうち
// 3 件は人が「当たり」と判じた物だった —— 主張が backtick でなく地の文に書いて
// あると窓に何も当たらない。**外れの側にだけ目が利く物差し**で全数の割合を出せば、
// 数字は本物でも結論は嘘になる。だから割合は主張せず、増やさない事だけを守る。
//
// ── 直し方は隣の検査と同じ ──────────────────────────────────────────────
// 番号の代わりに**中身の目印**(関数名・特徴のある文字列)を書く。grep で辿れて、
// 行が動いても指す先は動かない。基準値は**下げる方向にしか動かせない**。
//
// ★この file 自身も `.mjs` なので隣の検査に走査される。綴りは全部連結で組み立て、
//   「見つかってはいけない形」がこの file の中に1バイトも現れない様にしてある。
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, existsSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const REPO = dirname(ROOT);
const BASELINE = join(ROOT, "test", "fixtures", "doc-linerefs-baseline.json");

/**
 * この木の**上**に repo が在るか。
 *
 * ★2026-08-05、`copied-tree-controls.sh` に捕まって足した。変異の台本は `rc-backend`
 *   **だけ**を temp へ写して単体を回すので、写しの中には親も `.git` も無い。この検査の
 *   対象(`.md`)は全部親側に在るから、写しでは**原理的に測れない**。
 *   そこで「緑」でも「赤」でもなく **skip = 測っていない** と名乗る。単体スイートは変異の
 *   判定器なので、測れない物を赤にすると 197 件の変異が 1 件も回らなくなる。
 * ★ただし「黙って飛ばし続ける」形は、この repo が何度も踏んだ穴そのもの。だから
 *   下に、親に `.git` が在るのに飛ばしていたら**赤にする**見張りを置いてある。
 */
const REPO_OK = (() => {
  try {
    execFileSync("git", ["-C", REPO, "rev-parse", "--is-inside-work-tree"], { stdio: "pipe" });
    return true;
  } catch {
    return false;
  }
})();
const SKIP = REPO_OK
  ? false
  : "この木の上に repo が無い(変異の台本は rc-backend だけを写す)= 測っていない";

// ★綴りは組み立てる(この file が自分の規則に当たらない為)。
const EXT = "(?:mjs|js|sh|py|yml|json|swift)";
const numRe = () => new RegExp("[A-Za-z0-9_.-]+" + "\\." + EXT + ":" + "[0-9]+", "g");

/** 数える本体。buffer を受ける形にして、陰性対照が同じ道を通れるようにする。 */
export function countLinerefs(text) {
  return [...text.matchAll(numRe())].length;
}

/**
 * 追跡されている `.md` だけを見る。
 *
 * ★作業木を歩かない理由が実測で在る: 隣の `no-linerefs` は作業木を歩くので、
 *   **他人の書きかけが全員の commit を止める**。現に今、Sprint 4 の Generator が
 *   書いている途中の file 1 件で、私の commit が止まっている。commit の門が見るべき
 *   分母は「repo に入る物」であって「机の上に在る物」ではない。
 *   (隣の検査を今この場で狭めるのは、自分が詰まった時に門を緩める形なので採らない。
 *    構造課題として WORKLOG に残してある。此処は新しく作る側なので最初から正しくする)
 */
function trackedDocs() {
  const out = execFileSync("git", ["-C", REPO, "ls-files", "*.md"], { encoding: "utf8" });
  return out.split("\n").filter((p) => p.endsWith(".md"));
}

const readBaseline = () =>
  existsSync(BASELINE) ? JSON.parse(readFileSync(BASELINE, "utf8")) : null;

/**
 * 中身は**索引から**読む(作業木からではない)。
 *
 * ★2026-08-05、初回発火でこの穴に落ちて直した。file の**一覧**は索引から取っていたのに
 *   **中身**は作業木から読んでいたので、隣で作業している人の書きかけが私の commit を止めた
 *   (実測: `.harness/progress.md: 13 -> 15` —— Sprint 4 の Generator が書いている最中の
 *   未 stage の増分で、私の 15 file が全部止まった)。
 *   これは上の docstring に自分で書いた「分母は repo に入る物」に真っ向から反している。
 *   索引から読めば、各 commit は**自分が入れる物だけ**で裁かれる: 相手が progress.md を
 *   stage した時に、相手の commit がその2件で止まる。責任の割り当てがそれで正しくなる。
 */
function indexContent(p) {
  try {
    return execFileSync("git", ["-C", REPO, "show", `:0:${p}`], {
      encoding: "utf8", maxBuffer: 64 * 1024 * 1024,
    });
  } catch {
    return null;   // 衝突中など、索引から一意に読めない
  }
}

/** 実測。{path: 件数} で、0 件の file は持たない(基準値も同じ形)。 */
function measure() {
  const now = {};
  for (const p of trackedDocs()) {
    const text = indexContent(p);
    if (text === null) continue;
    const n = countLinerefs(text);
    if (n > 0) now[p] = n;
  }
  return now;
}

// ── ① 増やさない ──────────────────────────────────────────────────────
test("★書類の行番号引用を増やしていない(基準値は下げる方向にしか動かない)", { skip: SKIP }, () => {
  const base = readBaseline();
  assert.ok(base, `基準値が無い: ${BASELINE}(作るには measure() の出力を書く)`);
  const now = measure();
  const grew = [];
  for (const [p, n] of Object.entries(now)) {
    const b = base[p] ?? 0;
    if (n > b) grew.push(`${p}: ${b} -> ${n}`);
  }
  assert.deepEqual(
    grew, [],
    "行番号は書いた瞬間から写しで、上に1行足せば全部ずれる。" +
      "中身の目印(関数名・特徴のある文字列)へ張り替える事。" +
      "実測 2026-08-05: 無作為 8 件のうち 5 件が既に別の場所を指していた",
  );
});

// ── ② 減ったら基準値も下げる(ラチェットが緩まない)──────────────────────
test("★減った分は基準値へ反映されている(緩んだ基準値を残さない)", { skip: SKIP }, () => {
  const base = readBaseline();
  const now = measure();
  const slack = [];
  for (const [p, b] of Object.entries(base)) {
    const n = now[p] ?? 0;
    if (n < b) slack.push(`${p}: ${b} -> ${n}`);
  }
  assert.deepEqual(
    slack, [],
    "直したのに基準値が高いまま = その分だけ**黙って増やせる余地**が残る。" +
      `${["test", "fixtures", "doc-linerefs-baseline" + ".json"].join("/")} を実測値へ下げる事`,
  );
});

// ── ③ 基準値そのものが腐らない ────────────────────────────────────────
test("基準値に、もう追跡されていない file が残っていない", { skip: SKIP }, () => {
  const base = readBaseline();
  const tracked = new Set(trackedDocs());
  const ghosts = Object.keys(base).filter((p) => !tracked.has(p));
  assert.deepEqual(ghosts, [], "消えた file の枠が残っている = その分だけ緩い");
});

// ── 陰性対照 ──────────────────────────────────────────────────────────
test("陰性対照: 数え方が空振りしていない(1件混ぜれば 1、目印の形なら 0)", () => {
  const planted = "出所は " + "view" + "." + "mjs" + ":" + "320" + " を見よ";
  assert.equal(countLinerefs(planted), 1);
  assert.equal(countLinerefs("出所は view.mjs の `gapNotice()` を見よ"), 0);
  // 範囲の書き方(`:1115-1118`)も 1 件として数える(先頭だけ当たる)
  assert.equal(countLinerefs("`x" + "." + "py" + ":" + "10" + "-" + "12" + "`"), 1);
});

test("陰性対照: 基準値の判定が両向きに動く(片側だけ見て緑になっていない)", () => {
  // 増えた側 / 減った側を、同じ突き合わせの式で作って確かめる。
  const base = { "A.md": 3, "B.md": 5 };
  const grew = (now) =>
    Object.entries(now).filter(([p, n]) => n > (base[p] ?? 0)).map(([p]) => p);
  const slack = (now) =>
    Object.entries(base).filter(([p, b]) => (now[p] ?? 0) < b).map(([p]) => p);
  assert.deepEqual(grew({ "A.md": 4, "B.md": 5 }), ["A.md"]);
  assert.deepEqual(grew({ "A.md": 3, "B.md": 5 }), []);
  assert.deepEqual(slack({ "A.md": 3, "B.md": 4 }), ["B.md"]);
  assert.deepEqual(slack({ "A.md": 3, "B.md": 5 }), []);
  // 新しい file(基準値に無い)は 0 扱い = 1 件でも書けば赤
  assert.deepEqual(grew({ "C.md": 1 }), ["C.md"]);
});

// ── 飛ばして良い時の見張り ────────────────────────────────────────────
// ★これは skip を付けない(付けたら見張りごと消える)。
//   「測っていない」は正直だが、**測れる場所で測っていない**のは只の穴である。
//   親に `.git` が在る = 本物の repo に居るのだから、その時に飛ばしていたら赤。
test("★飛ばして良いのは repo が無い時だけ(黙って飛ばし続ける形になっていない)", () => {
  const looksLikeRepo = existsSync(join(REPO, ".git"));
  assert.equal(
    looksLikeRepo && !REPO_OK, false,
    `親に .git が在るのに repo として読めていない(${REPO})= ` +
      "上の3本が黙って飛ぶ。git の呼び方が壊れた時にここが赤くなる",
  );
});

// ── 走査した範囲を毎回名乗る ──────────────────────────────────────────
// ★名前の中で `trackedDocs()` を呼ばない。名前は **module を読んだ瞬間**に組み立てられるので、
//   写しの中では test が1本も登録されないまま file ごと落ちていた(実測 2026-08-05: pass2/fail3
//   の後、この行で throw して6本目が消えていた)。数えるのは test の中でやる。
test("走査した範囲を名乗る", { skip: SKIP }, () => {
  const docs = trackedDocs();
  assert.ok(docs.length >= 20, `追跡 .md が少なすぎる(${docs.length}本)= 数え方が壊れている`);
  const total = Object.values(measure()).reduce((a, b) => a + b, 0);
  console.log(`# 走査: 追跡 .md ${docs.length} 本 / 行番号引用 合計 ${total} 件(基準値の合計 ` +
    `${Object.values(readBaseline() ?? {}).reduce((a, b) => a + b, 0)} 件)`);
});
