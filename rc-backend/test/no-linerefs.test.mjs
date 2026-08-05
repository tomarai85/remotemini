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
const REPO = dirname(ROOT);
const SCAN_EXT = [".mjs", ".sh", ".py", ".swift"];

// ── 木は2つ在る ────────────────────────────────────────────────────────
// 2026-08-05: 電話側(`ios/`)の注釈が backend の code を行番号で引いていて、
// **16件が別の行を指していた**。この検査は既に在ったのに1件も捕まえていない。
// 走査していたのが `rc-backend/` だけで、`ios/` は隣の木だったから。
//
// ★守りの**届く範囲**が、守られる側の木構造から自動で決まっていなかった、という事。
//   同じ夜に別の形で3回踏んでいる(DESIGN §2.18-10)。名前や場所の一致で対象を
//   導出すると、新しい木は**元から一覧に居ない**ので、緑のまま素通りする。
const TREES = [
  { name: "rc-backend", root: ROOT, dirs: ["src", "test", "tools"], floor: 20,
    bare: ["src", "test", "tools", "test/fixtures", "."] },
  { name: "ios", root: join(REPO, "ios"), dirs: ["Sources", "Tests", "tools"], floor: 15,
    bare: ["Sources", "Tests", "tools", "."] },
];
/** 実在する木だけ走る。**居ない事は下の検査が必ず名指しで報告する**(黙って減らさない)。 */
const present = (t) => existsSync(t.root) && statSync(t.root).isDirectory();
const LIVE_TREES = TREES.filter(present);
const MISSING_TREES = TREES.filter((t) => !present(t)).map((t) => t.name);

/**
 * 走査の対象。**この file 自身も含む**(上の注釈の理由)。
 *
 * ★木ごとに下限を持つ。合計で持つと、片方の walk が丸ごと空振りしても
 *   もう片方の件数で下限を越えてしまい、**0件が緑の下に隠れる**。
 *   これは今夜4回踏んだ欠陥そのもの(分母を実在する集合から取る)。
 */
function scanFiles() {
  const out = [];
  for (const t of LIVE_TREES) {
    const before = out.length;
    const walk = (d) => {
      if (!existsSync(d)) return;
      for (const e of readdirSync(d, { withFileTypes: true })) {
        const p = join(d, e.name);
        if (e.isDirectory()) walk(p);
        else if (SCAN_EXT.some((x) => e.name.endsWith(x))) out.push(p);
      }
    };
    for (const d of t.dirs) walk(join(t.root, d));
    const n = out.length - before;
    assert.ok(n >= t.floor, `${t.name} の走査が少なすぎる(${n}件 < ${t.floor})= 数え方が壊れている`);
  }
  return out;
}

const rel = (p) => (p.startsWith(REPO + "/") ? p.slice(REPO.length + 1) : p);

// ── 綴りは全部ここで組み立てる。生の literal をこの file に置かない為 ──────────
const EXT_NUM = "(?:mjs|sh|py|json|swift)";
// ★`swift` を**引用の側には足していない**。今日 `ios/` に在る backtick 引用 18件は
//   全部 backend の file 名で、`.swift` の名前を引いている物は**0件**(実測)。
//   足すには bare 名の解決を `Sources/Core` `Screens/KeyEntry` の入れ子まで
//   降ろす必要が在り、**現に1件も無い物の為に解決規則を複雑にする**事になる。
//   取らなかった上限として、黙らせずにここに書いておく。1件でも書かれたら足す。
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

/**
 * repo の中で解決するか。**宿主側には一切 stat をかけない**。
 *
 * ★木が2つ在るので、**引いた側の木から先に**探す。同じ綴りが別の実体を指すから:
 *   両方の木が持つ名前(例えば tools/ の下に同名の台本が在る時)は、ios の file から
 *   引けば ios 側、backend の file から引けば backend 側である。引いた側を先に
 *   見ないと、**実在はするが別物**を掴んで緑になる —— 名前の一致で対象を決める、
 *   今夜の欠陥と同じ形。その後に隣の木も見るのは、ios の注釈が backend の
 *   `tail.mjs` 等を引くのが正常だから(現に 18件全部がその向き)。最後に repo 直下を
 *   見るのは、木の名前ごと path に書いた引用の為。
 *
 * ★ここに**実在する file 名を backtick で例示しない**事。この検査は自分自身も走査
 *   するので、例示が引用として数えられる。2026-08-05 に一度踏んだ: 例に書いた2件は
 *   完全な木では解決して緑、**ios の居ない作業コピーでだけ赤**になった。つまり
 *   commit の門は通り、変異走行の中でだけ落ちる —— `test/mutation-controls.py` の
 *   凍結の節に在る、以降の変異が全部「検出」に化ける事故と同じ入口だった。
 */
function resolves(cite, fromFile, repoIntact = REPO_INTACT) {
  if (cite.startsWith("./") || cite.startsWith("../")) {
    return isFile(resolve(dirname(fromFile), cite)) ? OK : BROKEN;
  }
  const own = LIVE_TREES.find((t) => fromFile.startsWith(t.root + "/"));
  const order = [own, ...LIVE_TREES.filter((t) => t !== own)].filter(Boolean);
  if (cite.includes("/")) {
    if (order.some((t) => isFile(join(t.root, cite)))) return OK;
    if (isFile(join(REPO, cite))) return OK;
    // ★未解決。だが「無い」には2種類在り、**片方は赤ではない**:
    //   ① 根が在るのに解決しない = 本物の腐り(改名の置き去り)
    //   ② 根ごと此処に無い       = **検めていない**だけ
    //   ②を赤にしていたのが、下の実測の事故。
    return repoIntact ? BROKEN : UNVERIFIABLE;
  }
  return order.some((t) => t.bare.some((d) => isFile(join(t.root, d, cite)))) ? OK : BROKEN;
}
const isFile = (p) => existsSync(p) && statSync(p).isFile();

const OK = "ok", BROKEN = "broken", UNVERIFIABLE = "unverifiable";

/**
 * repo の**根が本物か**。`rc-backend/` だけを写した木では偽になる(写し先の親は
 * ただの一時 dir で、そこに repo 直下の物は1つも無い)。
 *
 * ★2026-08-05 実測。`tools/run-controls.sh` が repo 直下の照合表を backtick で
 *   引いた —— 引用として正しい(現にその台本を走らせている)。だが完全な木では
 *   repo 直下で解決して緑、`rc-backend/` だけの写しでは解決せず**赤**になった。
 *   commit の門は通り、**変異走行の中だけで落ちる** = `test/mutation-controls.py`
 *   の凍結の節に在る、以降の変異が全部「検出」に化ける事故の入口そのもの。
 *   **同じ入口を踏むのは2件目**(1件目は §2.18-10 (e) の、説明文に実在する名前を
 *   例示した件)。1件目は引用の書き方を直して終わりにした —— 今回それでは足りないと
 *   判ったので**検査の側**を直した: 此処に無い物を「実在しない」と言い切っていた事が
 *   誤りで、引用の側は最初から正しかった(現にその台本を走らせている)。
 *
 * ★先に「入れ物(先頭の一節)が此処に在るか」で分ける案を書いて、**実測で捨てた**。
 *   同じ綴りの入れ物が repo 直下と `rc-backend/` の両方に在り(前者は照合表、
 *   後者は証拠の置き場)、写しの中では後者だけが在る。入れ物は在って中身が無い、
 *   という見え方になるので、腐りと区別が付かない。**写しの中には区別に要る情報が
 *   端から無い** —— だから根の有無そのもので分ける。
 *
 * ★目印に `DESIGN.md` を使う。拡張子が引用の規則(`EXT_CITE`)に入っていないので、
 *   この行自体が引用として数えられる事は無い。
 *
 * ★この目印は**自分の機械の外にも効く**必要が在る: 配備は `rc-backend/` だけを edith へ
 *   送り、向こうで `npm test` を回す(`tools/deploy-to-edith.sh` の仮置き / 本番、
 *   `tools/verify-on-edith.sh`)。送り先の親に repo 直下の物が在ると、此処が本物の根だと
 *   誤判定して門が赤くなる。実測して確かめてある(2026-08-05、edith の home に
 *   `DESIGN.md` も `.harness` も無い)。写す側は全部 `rc-backend/` 単位なので、
 *   親に repo 直下の物が現れる経路は今の所どれにも無い。
 *
 * ★残る上限を黙らせない: **裸の名前**(`/` を含まない引用)と `../` 始まりは、
 *   根が欠けていても厳格なまま。`ios/` にしか無い名前を backend 側が裸で引くと、
 *   部分木で偽の赤になる。今日の実測では**該当 0件**(部分木の赤は3件、全部
 *   `/` を含む repo 直下の引用)なので、居ない物の為に規則を増やしていない。
 */
const REPO_INTACT = isFile(join(REPO, "DESIGN.md"));

/** 走査の本体。buffer を渡せる形にして、陰性対照が同じ道を通れるようにする。 */
function findLinerefs(text) {
  return [...text.matchAll(numRe())].map((m) => m[0]);
}
/**
 * @param sink 省略可。**検めきれなかった**引用の置き場(部分木でだけ埋まる)。
 *   戻り値に混ぜないのは、混ぜた瞬間に「赤の一覧」と「測れなかった一覧」が
 *   同じ配列になって、片方を数えたつもりが両方を数える形になるから
 *   (道具の出口は 0=緑 / 1=赤 / 2=測っていない で分けてある。此処も同じ分け方)。
 */
function findBrokenCites(text, fromFile, sink, repoIntact = REPO_INTACT) {
  const bad = [];
  for (const m of text.matchAll(citeRe())) {
    const c = m[1];
    if (outOfRepo(c)) continue;
    const v = resolves(c, fromFile, repoIntact);
    if (v === BROKEN) bad.push(c);
    else if (v === UNVERIFIABLE && sink) sink.push(c);
  }
  return bad;
}

/** 走査全体で「検めきれなかった」引用。完全な木では必ず 0 件。 */
function unverifiedCites() {
  const out = [];
  for (const f of scanFiles()) {
    const sink = [];
    findBrokenCites(readFileSync(f, "utf8"), f, sink);
    for (const c of sink) out.push(`${rel(f)}: ${c}`);
  }
  return out;
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

test("陰性対照: **電話側の綴り**でも見つかる(2026-08-05 に素通りした形そのもの)", () => {
  // `.swift` を EXT_NUM に足した事の直接の証拠。足す前はこの1行が空配列を返した
  // —— そして実際、`ios/` の 16件はその空配列の下で1件も報告されずに commit された。
  const swiftRef = "Backend" + "Session" + "." + "swift" + ":" + "42";
  assert.deepEqual(findLinerefs("// see " + swiftRef), [swiftRef]);
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

// ── 「此処に無い」と「実在しない」を分ける ────────────────────────────────
// ★根の有無を**引数で渡せる**形にしてある。渡せないと、この分岐は「根が欠けた木」
//   でしか動かず、普段走る完全な木の中では**一度も試されない道**になる。
//   (免除の分岐が試されないまま育つのは、今夜4回踏んだ形の中で一番静かなやつ)
test("★根ごと此処に無い時だけ『赤』が『検めていない』へ落ちる(免除の分岐を両側から踏む)", () => {
  const from = join(ROOT, "tools", "x.sh");
  const ghost = "tools/" + "ghost" + "-" + "probe" + "." + "sh";
  const text = "# `" + ghost + "` を走らせる";

  // 根が在る木として見る → 未解決は赤。免除は一切効かない。
  const sinkWhole = [];
  assert.deepEqual(findBrokenCites(text, from, sinkWhole, true), [ghost],
    "完全な木で免除が効いたら、改名の置き去りを取り逃がす");
  assert.deepEqual(sinkWhole, []);

  // 根が欠けた木として見る → 赤には数えず、置き場へ回す。
  const sinkPartial = [];
  assert.deepEqual(findBrokenCites(text, from, sinkPartial, false), []);
  assert.deepEqual(sinkPartial, [ghost],
    "黙って捨てたら『検めた』と見分けが付かない。名指しで残す事");
});

test(`★『検めていない』引用は木が欠けている時だけ許す(根が本物: ${REPO_INTACT})`, () => {
  const unver = unverifiedCites();
  if (unver.length) console.log(`# 検めきれなかった引用 ${unver.length}件: ${unver.join(" / ")}`);
  assert.deepEqual(
    REPO_INTACT ? unver : [], [],
    "完全な木なのに『検めていない』が出た = 免除の条件が緩い。" +
      "repo 直下に在る物は完全な木では必ず解決するはずで、解決しないなら本物の腐り",
  );
});

// ── 走査した範囲を**毎回名乗る** ──────────────────────────────────────
// 検査名に木の名前を入れてあるので、`npm test` の出力を読むだけで
// 「今回どこまで届いたか」が判る。部分木(変異の作業コピー / edith の配備先)で
// 走ると名前が `rc-backend` だけになり、**減った事が log に残る**。
//
// ★黙って減らす形にしなかった理由が実測で在る: `test/mutation-controls.py` の
//   凍結の節に、この検査が変異走行中に赤くなった結果、**以降の変異が全部
//   「検出」と記録された**事故が書いてある。壊れ方が緑の方向に出るので、
//   要約は「素通り 0件」と書く。走査漏れも同じ向きに壊れる。
test(`★走査した木: ${LIVE_TREES.map((t) => t.name).join(" + ")}` +
  (MISSING_TREES.length ? ` / 居なかった木: ${MISSING_TREES.join(",")}(部分木)` : ""), () => {
  // rc-backend だけは**欠けてよい木ではない**。ここが欠けるのは走査の起点が
  // 壊れた時なので、部分木として黙認せず赤にする。
  assert.deepEqual(
    MISSING_TREES.filter((n) => n !== "ios"), [],
    "起点の木が見つからない = ROOT の求め方が壊れている(部分木の話ではない)",
  );
  assert.ok(LIVE_TREES.length >= 1);
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
