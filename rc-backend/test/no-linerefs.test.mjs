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
import { basename, dirname, join, resolve } from "node:path";
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
//
// ★2026-08-07、**同じ形の3件目**。今度は「木の中の dir」ではなく**木そのもの**が
//   一覧に無かった: repo 直下の `.harness/` に DoD の台本と其の対照が 11 本(実測)
//   在るのに、木が2つしか宣言されていないので此処は一度も走っていない。
//   実測で当ててみると行番号引用 0 件 / backtick 引用 16 種は全部解決した ——
//   つまり**赤が無かったのではなく、見ていなかった**。緑と区別が付かないのが此の病気。
const TREES = [
  { name: "rc-backend", root: ROOT, dirs: ["src", "test", "tools"], floor: 20,
    bare: ["src", "test", "tools", "test/fixtures", "."] },
  { name: "ios", root: join(REPO, "ios"), dirs: ["Sources", "Tests", "UITests", "tools"], floor: 15,
    bare: ["Sources", "Tests", "tools", "."], outside: true },
  // 台本は全部 `.harness/` の直下に在り、下の evidence-* / feedback には走査対象の
  // 拡張子が 1 件も無い(実測 2026-08-07: 11 件は全部直下)。それでも `dirs` を
  // 直下の名前で並べず `["."]` にしたのは、**証拠の置き場が日付で増える**から ——
  // 名前で並べると増える度に一覧を書き足す事になり、書き忘れた日から静かに範囲外になる。
  // ★`outside` = repo 直下から**別に写される**木。欠けてよい事の宣言で、下の
  //   「起点の木が欠けたら赤」の判定は此の印から導く(名前の直書きを置かない為)。
  { name: "harness", root: join(REPO, ".harness"), dirs: ["."], floor: 8,
    bare: ["."], outside: true },
];
// ★`UITests` を `bare` に足していない。`bare` は**拡張子を持たない裸の名前**を解決する
//   為の一覧で、引用の側の拡張子は `mjs|sh|py` だけ(EXT_CITE)。UITests の中身は
//   `.swift` 1 file なので、足しても永久に当たらない死んだ項になる。
//   1件でも `.sh` / `.py` が置かれたら足す。

/**
 * 走査しない dir と、その理由。
 *
 * ★この一覧が在るのは、下の「範囲が木と一致しているか」の検査が**知らない dir を
 *   全部赤にする**為。黙って範囲外になるのを止めるのがこの仕掛けの目的なので、
 *   除くなら名指しで理由を書く以外の道を用意しない。
 *
 * ★消えた項を赤にする**逆向きは撃っていない**。`build` は綺麗な複製には存在しないのが
 *   正常なので、逆向きにすると clean clone で偽の赤になる。取らなかった向きとして明記。
 */
const NOT_SCANNED = {
  "rc-backend": [
    ["node_modules", "依存の展開先。今この木には無いが `npm install` した瞬間に現れる" +
      " = 先に書いておかないと、その時に全員の commit が偽の赤で止まる"],
    [".harness", "実行の記録と証拠の置き場(実測 2026-08-05: json 48 / txt 15 / md 10 / log 8、" +
      "走査対象の拡張子は 0 件)。source を置く場所ではない。" +
      "★repo 直下の `.harness/` とは**別の dir**。あちらは台本が 11 本在るので " +
      "TREES に木として足した(2026-08-07)。綴りが同じなので混同しない事"],
    [".claude", "この木で走った agent の作業用。追跡 0 件(実測 2026-08-05)"],
    [".git", "**手元の木には無い**。edith の本番の木 `~/rc-backend` にだけ在る他レーンの物" +
      "(2026-08-03 の整備で置かれた。私の物ではないので消さない)。実測 2026-08-07: " +
      "本番の木で `npm test` を撃つと此処だけが赤で、中身は `.mjs/.sh/.py/.swift` 0 件。" +
      "配備の関門は `.git/` を除いた仮置きで走るので元から見えていない = " +
      "**赤が出るのは本番の木を直に叩いた時だけ**、そしてその赤は何も意味しない"],
  ],
  ios: [
    ["build", "xcodebuild の出力"],
    ["RemoteMini.xcodeproj", "生成物(実測 2026-08-05: 追跡 0 件)"],
    ["Assets.xcassets", "アイコン等の画像資産(2026-08-16 新設)。png と Contents.json だけで、" +
      "走査対象の拡張子は 0 件。source を置く場所ではない"],
  ],
};

/**
 * repo 直下で**木にしない** dir と、その理由。
 *
 * ★上の NOT_SCANNED が「木の中」を守るのに対し、此処は「木の一覧そのもの」を守る。
 *   2026-08-07 に `.harness/` が抜けていたのは前者では原理的に捕まらない —— どの木の
 *   中にも無いから、どの木の直下の照合にも掛からない。**守りの範囲を、守る側の
 *   一覧から導いている限り、一覧の外は永久に見えない**という同じ形の3件目。
 */
const NOT_A_TREE = [
  [".git", "版の記録。走査対象の拡張子 0 件(実測 2026-08-07: 拡張子を持つのは " +
    "hooks の見本 14 件の .sample だけ)"],
  ["research", "調査の記録。中身は md 3 件だけで走査対象の拡張子は 0 件(実測 2026-08-07)"],
];
/** 実在する木だけ走る。**居ない事は下の検査が必ず名指しで報告する**(黙って減らさない)。 */
const present = (t) => existsSync(t.root) && statSync(t.root).isDirectory();
const LIVE_TREES = TREES.filter(present);
const MISSING_TREES = TREES.filter((t) => !present(t)).map((t) => t.name);
/**
 * 欠けたら赤にする木 = `outside` の印を持たない物。
 *
 * ★2026-08-07 まで此処は `!== "ios"` と**名前を直に書いて**いた。木を1つ足した瞬間、
 *   足した木は其の直書きに引っ掛からず「欠けたら赤」の側に落ちる —— つまり
 *   `rc-backend/` だけを写す経路(`test/mutation-controls.py` の凍結と
 *   `tools/deploy-to-edith.sh` の送信)で、足しただけで赤くなる。
 *   一覧に書いた物と木の実態がずれる形が此の file の主題なので、判定も印から導く。
 */
const MISSING_REQUIRED = TREES.filter((t) => !present(t) && !t.outside).map((t) => t.name);

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
 *   部分木で偽の赤になる。2026-08-05 の実測では該当 0件(部分木の赤は3件、全部
 *   `/` を含む repo 直下の引用)だったので、居ない物の為に規則を増やさなかった。
 *
 * ★★2026-08-06、**その 0 件が 2 件になった**。私が `tools/run-controls.sh` の注釈で
 *   ios の対照を裸で2回引き、完全な木では隣の木で解決して緑・写しの中だけで赤に
 *   なった。上の段落は「今は居ない」を「増やす必要が無い」と読み替えていた訳で、
 *   居ないのは**書いていないから**であって、書けば翌日にでも現れる。
 *   → 下の ②-b を足した。裸の引用は**引いた側の木の中**で解決する事を要求する
 *   (向きは非対称。ios の注釈が backend の名前を裸で引くのは正常 —— `ios/` だけを
 *   単独で写す経路がどこにも無いので、その向きは写しの中で壊れない)。
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

/**
 * **単独で写される木**。この木だけを写した状態で単体スイートが回るので、この木の中の
 * 注釈が隣の木の名前を**裸で**引くと、写しの中でだけ赤くなる(= 変異走行の対照1が
 * 落ちて、以降の変異が全部「検出」に化ける)。
 * 出所は2つ、どちらも `rc-backend/` 単位で写す: `test/mutation-controls.py` の凍結と、
 * `tools/deploy-to-edith.sh` の送信。ios を単独で写す経路は今の所どこにも無い。
 */
const COPIED_ALONE = ["rc-backend"];

/** 裸の引用のうち、**引いた側の木の中で解決しない**物。完全な木でも判る形にした所が肝。 */
function bareOutOfTree(text, fromFile) {
  const own = LIVE_TREES.find((t) => fromFile.startsWith(t.root + "/"));
  if (!own || !COPIED_ALONE.includes(own.name)) return [];
  const bad = [];
  for (const m of text.matchAll(citeRe())) {
    const c = m[1];
    if (outOfRepo(c) || c.includes("/")) continue;
    if (!own.bare.some((d) => isFile(join(own.root, d, c)))) bad.push(c);
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

// ── ②-b 単独で写される木の**裸の引用**は、その木の中で解決する ──────────────
// 「完全な木では緑、写しの中でだけ赤」を、完全な木の側で捕まえる為の1本。
// commit の門が回すのは完全な木なので、この形は今まで門から**構造的に見えず**、
// 12 分の定期掃きだけが見ていた(2026-08-06 に実際にそうなった)。
test("★backend の裸の引用が backend の中で解決する(写しでだけ赤くなる形を捕まえる)", () => {
  const bad = [];
  for (const f of scanFiles()) {
    for (const c of bareOutOfTree(readFileSync(f, "utf8"), f)) bad.push(`${rel(f)}: ${c}`);
  }
  assert.deepEqual(
    bad, [],
    "隣の木にしか無い名前を**裸**で引いている。木の名前から書く事(例: ios/tools/… )。\n" +
      "  この木は単独で写されるので、裸のままだと写しの中でだけ赤くなる = 変異走行の\n" +
      "  対照1が落ち、以降の変異が全部『検出』に化ける",
  );
});

test("陰性対照: 隣の木にしか無い名前を裸で引けば見つかる(向きは非対称)", () => {
  // 綴りは組み立てる(この file 自身も走査されるので、素で書くと引用として数えられる)。
  const iosOnly = "conversation" + "-ui-" + "control" + ".sh";
  const planted = "# 費用は `" + iosOnly + "` の 156 秒と同じ桁である";
  assert.deepEqual(bareOutOfTree(planted, join(ROOT, "tools", "x.sh")), [iosOnly]);
  // ① 木の名前から書けば挙がらない(直し方が本当に直る事の確認)
  assert.deepEqual(
    bareOutOfTree("# 費用は `ios/tools/" + iosOnly + "` と同じ桁である", join(ROOT, "tools", "x.sh")),
    [],
  );
  // ② 逆向きは正常: ios の注釈が backend の名前を裸で引くのは写しの中で壊れない
  assert.deepEqual(bareOutOfTree(planted, join(REPO, "ios", "tools", "x.sh")), []);
  // ③ 自分の木に在る裸の名前は挙がらない
  assert.deepEqual(bareOutOfTree("# 掃きは `run-controls.sh` が回す", join(ROOT, "tools", "x.sh")), []);
});

// ── ③ 走査の範囲が、守られる側の木構造と一致している ──────────────────────
/**
 * ★2026-08-05。`ios/UITests` はこの検査の `dirs` にも Sprint 4 の DoD の台本にも無く、
 *   UI の検査は**どちらからも見えていなかった**。両方とも「一覧に書いた物」を見ていて
 *   「木に実際に在る物」を見ていない。一覧に1つ足すだけでは次に増えた dir で同じ事が
 *   起きるので、直すべきは一覧ではなく**一覧が木と一致している事の検査**の方。
 *
 * ★名前の配列を受ける形にして、陰性対照が同じ道を通れるようにする。
 */
export function unlistedDirs(names, tree) {
  // ★木ごと走る指定(`dirs` に `.` を持つ木)は、直下の dir が**全部走査済み**なので
  //   一覧に無い事が範囲外を意味しない。此処を短絡させないと、証拠の置き場が
  //   日付で1つ増える度に偽の赤が出て、しかも直し方が「一覧に書き足す」= 此の検査が
  //   元々潰した筈の「一覧と木のずれ」を自分の手で作る事になる。
  if (tree.dirs.includes(".")) return [];
  const known = new Set([...tree.dirs, ...(NOT_SCANNED[tree.name] || []).map(([d]) => d)]);
  return names.filter((n) => !known.has(n)).sort();
}

test("★走査の範囲が木の直下と一致している(新しい dir が黙って範囲外にならない)", () => {
  const bad = [];
  for (const t of LIVE_TREES) {
    const names = readdirSync(t.root, { withFileTypes: true })
      .filter((e) => e.isDirectory())
      .map((e) => e.name);
    for (const n of unlistedDirs(names, t)) bad.push(`${t.name}/${n}`);
  }
  assert.deepEqual(
    bad, [],
    "木の直下に、走査もせず除外の理由も書いていない dir が在る。" +
      "TREES の dirs に足すか、NOT_SCANNED に理由付きで足すか、どちらかを必ず選ぶ事",
  );
});

test("陰性対照: 一覧に無い dir を1件混ぜれば見つかる", () => {
  assert.deepEqual(
    unlistedDirs(["Sources", "SnapshotTests"], { name: "ios", dirs: ["Sources"] }),
    ["SnapshotTests"],
  );
  // ★★免除は木ごと。片方の木に書いた1行がもう片方にも効くと、**書いた覚えのない木が
  //   黙って範囲外になる** —— 一覧を共有した瞬間に必ず起きる形で、今夜の欠陥の本体。
  assert.deepEqual(unlistedDirs(["node_modules"], { name: "ios", dirs: [] }), ["node_modules"]);
  assert.deepEqual(unlistedDirs(["node_modules"], { name: "rc-backend", dirs: [] }), []);
  // ★`.git` も木ごと。手元では一度も現れないので、免除が効いている事を確かめられるのは
  //   此処だけ(本番の木でしか赤にならない = 普段の緑は免除の証拠にならない)。
  assert.deepEqual(unlistedDirs([".git"], { name: "rc-backend", dirs: [] }), []);
  assert.deepEqual(unlistedDirs([".git"], { name: "ios", dirs: [] }), [".git"]);
  assert.deepEqual(unlistedDirs(["Sources"], { name: "ios", dirs: ["Sources"] }), []);
  // ★木ごと走る木(`dirs` が `.`)は直下を挙げない。**が、それは走っているからで
  //   免除だからではない** —— 同じ名前を「走らない木」に渡せば挙がる事を並べて撃つ。
  //   片側だけだと、短絡が広過ぎて全部の木を黙らせていても緑になる。
  const rooms = ["evidence-2026-08-1x", "feedback"];
  assert.deepEqual(unlistedDirs(rooms, { name: "harness", dirs: ["."] }), []);
  assert.deepEqual(unlistedDirs(rooms, { name: "harness", dirs: ["src"] }), rooms);
});

// ── ③-b 木の一覧そのものが repo 直下を覆っている ──────────────────────────
/**
 * 木でも免除でもない repo 直下の dir。
 *
 * ★覆っている側(`covered`)も**引数で受ける**。最初は木の根を `join(REPO, 名前)` と
 *   突き合わせる形で書いて、実測で捨てた: 部分木では backend の写し先が `rc` 等の
 *   別名になるので `rc-backend` が根と一致せず、**完全な木では緑・写しの中でだけ赤**に
 *   なった(2026-08-07、この file の頭が警告している形そのものを陰性対照でやった)。
 *   陰性対照が木の実際の並びに依存した時点で、それは純関数の検査ではない。
 */
export function uncoveredRepoDirs(names, covered = TREES.map((t) => basename(t.root))) {
  const known = new Set([...covered, ...NOT_A_TREE.map(([d]) => d)]);
  return names.filter((n) => !known.has(n)).sort();
}

test(`★木の一覧が repo 直下を覆っている(根が本物: ${REPO_INTACT})`, () => {
  // 部分木では repo 直下が「写し先の一時 dir」なので、覆いは**測れない**。
  // 空配列を渡して緑にするのではなく、測っていない事を log に出してから緑にする
  //   —— 出さないと「覆いを確かめた」と見分けが付かない(此の file の主題)。
  if (!REPO_INTACT) {
    console.log("# repo 直下の覆いは**測っていない**(部分木で走っている)");
    return;
  }
  const names = readdirSync(REPO, { withFileTypes: true })
    .filter((e) => e.isDirectory())
    .map((e) => e.name);
  assert.deepEqual(
    uncoveredRepoDirs(names), [],
    "repo 直下に、木でもなく免除の理由も書いていない dir が在る。" +
      "TREES に木として足すか、NOT_A_TREE に**実測した理由**を付けて足すか、必ずどちらかを選ぶ事",
  );
  // 免除の側も腐る。実在しない dir の免除は畳む(完全な木でだけ判る)。
  assert.deepEqual(
    NOT_A_TREE.map(([d]) => d).filter((d) => !existsSync(join(REPO, d))), [],
    "repo 直下に実在しない dir の免除が残っている",
  );
});

test("陰性対照: repo 直下に木でも免除でもない dir を1件混ぜれば見つかる", () => {
  // 覆う側も渡す = 木の実際の並びに一切依存しない(上の注釈の理由)。
  const covered = ["rc-backend", "ios", ".harness"];
  assert.deepEqual(uncoveredRepoDirs([...covered, ".git", "research"], covered), []);
  assert.deepEqual(uncoveredRepoDirs(["rc-backend", "shared"], covered), ["shared"]);
  // 覆う側から1つ落とせば、其の木が挙がる(覆いの判定が現に効いている事)
  assert.deepEqual(uncoveredRepoDirs(covered, ["rc-backend", "ios"]), [".harness"]);
  // ★`.harness` は**木として**覆われているのが正しい。免除の一覧に落ちると
  //   「覆っている」の判定は緑のまま、中の 11 本はまた走らなくなる —— 今日直した形に戻る。
  assert.ok(!NOT_A_TREE.some(([d]) => d === ".harness"),
    "免除で黙らせると、走らせずに緑になる形へ逆戻りする");
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
    MISSING_REQUIRED, [],
    "起点の木が見つからない = ROOT の求め方が壊れている(部分木の話ではない)",
  );
  assert.ok(LIVE_TREES.length >= 1);
  // ★印の側が腐るのも見る。`outside` を全部の木に付ければ上の判定は永久に緑になる
  //   ので、**必須の木が現に1つ在る**事を綴りごと固定する。増やす時は此処も動かす。
  assert.deepEqual(
    TREES.filter((t) => !t.outside).map((t) => t.name), ["rc-backend"],
    "欠けたら赤にする木が 0 個 = 上の判定が何も見ていない(印の付け過ぎ)",
  );
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
