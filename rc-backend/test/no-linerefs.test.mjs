// 注釈が引く**他所への参照**が、腐らない形で書かれているか。
//
// 経緯: 2026-08-03 に src/test/tools の行番号参照 27件を数えたら、**21件が別の行を指していた**。
// 番号は書いた瞬間から写しであって、上に1行足せば全部ずれる。直し方は2通りあって、
//   ① 現在値に振り直す  ② 番号を持たない形にする
// ①は「次に1行足した人がまた全部ずらす」ので、腐るのが確定している方を選ぶ事になる。
// 採ったのは②。番号の代わりに**中身の目印**(関数名・特徴のある文字列)を書けば、
// grep で辿れて、行が動いても指す先は動かない。
//
// この検査が測るのは2つ:
//   ① 行番号の参照が**1件も無い**(戻した瞬間に赤)
//   ② backtick で引いたファイル名が**実在する**(改名で置き去りにされた参照を捕まえる)
//
// ★この検査は**自分自身も走査する**。除外すると「検査の説明文だけは腐ってよい」になる。
//   その代わり、例に使う文字列は全部**連結で組み立てて**、この file の中に
//   「見つかってはいけない綴り」が1バイトも現れないようにしてある。
//   (§2.20 と同じ理由で、検査が自分の説明文に当たる形は2回踏んでいる)
//
// ★宿主の設定は読まない(DESIGN §2.26)。チルダ始まり・絶対パス始まりの参照は
//   **解決を試みない** = 検査が Tom の home に stat をかける事は無い。
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync, existsSync, statSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const SCAN_DIRS = ["src", "test", "tools"];
const SCAN_EXT = [".mjs", ".sh", ".py"];

/**
 * 走査の対象。**この file 自身も含む**(上の注釈の理由)。
 */
function scanFiles() {
  const out = [];
  const walk = (d) => {
    for (const e of readdirSync(d, { withFileTypes: true })) {
      const p = join(d, e.name);
      if (e.isDirectory()) walk(p);
      else if (SCAN_EXT.some((x) => e.name.endsWith(x))) out.push(p);
    }
  };
  for (const d of SCAN_DIRS) walk(join(ROOT, d));
  assert.ok(out.length >= 20, `走査の対象が少なすぎる(${out.length}件)= 数え方が壊れている`);
  return out;
}

const rel = (p) => p.slice(ROOT.length + 1);

// ── 綴りは全部ここで組み立てる。生の literal をこの file に置かない為 ──────────
const EXT_NUM = "(?:mjs|sh|py|json)";
const EXT_CITE = "(?:mjs|sh|py)";
/** `名前.拡張子:行番号` の形。これが1件でも在れば赤。 */
const numRe = () => new RegExp("[A-Za-z0-9_.-]+" + "\\." + EXT_NUM + ":" + "[0-9]+", "g");
/** backtick で囲まれたファイル名。 */
const citeRe = () =>
  new RegExp("`([~$A-Za-z0-9_./-]+" + "\\." + EXT_CITE + ")`", "g");

/**
 * 解決を試みない前置き。**それぞれ「なぜ repo に無いのが正しいか」が違う**ので、
 * 一括で「外部」と呼ばずに分けて持つ。使われなくなった行は下の双方向の検査が落とす。
 */
const OUT_OF_REPO = [
  ["~", "宿主の home。読みに行かない(DESIGN §2.26)"],
  ["/", "絶対パス = edith 上の実体、または電話が取りに行く URL の道(`/view.mjs` 等)"],
  ["$", "走行時に組み立てる一時パス(複製先の木など)"],
  ["scratchpad/", "使い捨ての計測台本。repo に入れない物を実測の出典として引いている"],
];
const outOfRepo = (c) => OUT_OF_REPO.find(([pre]) => c.startsWith(pre));

/** repo の中で解決するか。**宿主側には一切 stat をかけない**。 */
function resolves(cite, fromFile) {
  if (cite.startsWith("./") || cite.startsWith("../")) {
    return isFile(resolve(dirname(fromFile), cite));
  }
  if (cite.includes("/")) return isFile(join(ROOT, cite));
  return ["src", "test", "tools", "test/fixtures", "."].some((d) => isFile(join(ROOT, d, cite)));
}
const isFile = (p) => existsSync(p) && statSync(p).isFile();

/** 走査の本体。buffer を渡せる形にして、陰性対照が同じ道を通れるようにする。 */
function findLinerefs(text) {
  return [...text.matchAll(numRe())].map((m) => m[0]);
}
function findBrokenCites(text, fromFile) {
  const bad = [];
  for (const m of text.matchAll(citeRe())) {
    const c = m[1];
    if (outOfRepo(c)) continue;
    if (!resolves(c, fromFile)) bad.push(c);
  }
  return bad;
}

// ── ① 行番号の参照はゼロ ────────────────────────────────────────────
test("★注釈が行番号で他所を引いていない(1件でも戻れば赤)", () => {
  const hits = [];
  for (const f of scanFiles()) {
    for (const h of findLinerefs(readFileSync(f, "utf8"))) hits.push(`${rel(f)}: ${h}`);
  }
  assert.deepEqual(
    hits, [],
    "行番号は書いた瞬間から写し。中身の目印(関数名・特徴のある文字列)へ張り替える事",
  );
});

test("陰性対照: 行番号を1件混ぜれば見つかる(検査が空振りしていない証拠)", () => {
  const planted = "// 出所は " + "server" + "." + "mjs" + ":" + "209" + " を見よ";
  assert.deepEqual(findLinerefs(planted), ["server" + ".mjs" + ":" + "209"]);
  assert.deepEqual(findLinerefs("// 出所は server.mjs の `screenOf()` を見よ"), []);
});

// ── ② 引いたファイル名は実在する ──────────────────────────────────────
test("★backtick で引いたファイル名が全部実在する(改名の置き去りを捕まえる)", () => {
  const bad = [];
  for (const f of scanFiles()) {
    for (const c of findBrokenCites(readFileSync(f, "utf8"), f)) bad.push(`${rel(f)}: ${c}`);
  }
  assert.deepEqual(
    bad, [],
    "実在しない名前を引いている。改名したか、最初から存在しない物を書いた" +
      "(2026-08-03 の実例: 存在しない fleet-notify という名前と、その中の存在しない環境変数)",
  );
});

test("陰性対照: 実在しない名前を1件混ぜれば見つかる", () => {
  const ghost = "fleet" + "-" + "notify" + "." + "sh";
  const planted = "# 出し先は `" + ghost + "` の厳格な戻り値を見る";
  assert.deepEqual(findBrokenCites(planted, join(ROOT, "tools", "x.sh")), [ghost]);
  assert.deepEqual(findBrokenCites("# 出し先は `tools/health-observer.sh` を見る",
    join(ROOT, "tools", "x.sh")), []);
});

// ── 免除の側も腐る。使われていない前置きは畳む ──────────────────────────
test("解決を試みない前置きは、全部**現に使われている**(死んだ免除を残さない)", () => {
  const used = new Map(OUT_OF_REPO.map(([pre]) => [pre, 0]));
  for (const f of scanFiles()) {
    for (const m of readFileSync(f, "utf8").matchAll(citeRe())) {
      const hit = outOfRepo(m[1]);
      if (hit) used.set(hit[0], used.get(hit[0]) + 1);
    }
  }
  const dead = [...used].filter(([, n]) => n === 0).map(([p]) => p);
  assert.deepEqual(
    dead, [],
    "この前置きを引いている参照が1件も無い = 免除だけが残っている。畳む事",
  );
});
