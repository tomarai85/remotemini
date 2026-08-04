// 設計書の**古くなった節の頭**に、後継を指す銘板が立っているか。
//
// 経緯: 2026-08-04、`ae42724` が電話の配信を SSE から長待ち受けへ替えた。新しい規約は
// DESIGN.md の後ろの方に §2.36 として足したが、**前の方に在る §2.11 は
// 「ライブ配信 `/stream` の規約」という題のまま**残っていた。6900 行の設計書で、
// 先に読まれるのは前の方である。
//
// これは前科のある失敗の形: 2026-07-27 に別案件で、DESIGN.md の裁定が後の spec に
// 上書きされていたのに気付かず **13 時間**を失っている。教訓は「後ろに新しい節を足す」
// では防御にならない事 —— 古い節の**頭**に立てないと読み手は辿り着かない。
//
// ★この検査が測るのは「銘板が在るか」ではなく **「古いのに銘板が無い」**。
//   古いかどうかは散文ではなく**コードの事実**から決める(下の `stale()`)。
//   コードが元へ戻れば銘板の要求も自動で消える = 直した人が此処を消して回らずに済む。
//
// ★検出器そのものにも対照を置く。`stale()` が常に false を返す様に壊れると、
//   この検査は**何も要求しない緑**になる。それは守っている様に見えて測れていない
//   (`src/mutex.mjs` の頭に書いた死んだ守りの原則)。だから
//   「植えた source なら真」「注釈だけなら偽」の両方向を下で撃つ。
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");

// ── ★木の外を**先頭で**読むと、変異走行が丸ごと起動できなくなる(2026-08-04、実測)──
// `DESIGN.md` は `rc-backend` の**外**(repo の頭)に在る。一方 `test/mutation-controls.py`
// は `rc-backend` だけを temp へ写して、その写しで `npm test` を回す —— 写しに親は無い。
// 初版はこの読みを module の先頭に置いていたので、写しでは import の時点で throw し、
// この file が丸ごと `testCodeFailure` になった。すると変異台本の**対照1(無変異の木は緑)**
// が死に、`die()` で走行そのものが始まらない。197 件の変異が 1 件も回らない状態を、
// この場では 580/580 緑に見えたまま作っていた(見つけたのは `run-controls.sh` の
// mutation-freeze-controls が赤くなった事)。
//
// だから読みを**遅らせず、無い事を許す**形にする。ただし「無ければ飛ばす」だけだと
// fail-open になる —— repo の中で DESIGN.md を消しても緑になってしまう。
// 飛ばしてよいのは「そもそも木の外が存在しない = repo から写した木」の時だけである。
//
// ── ★世界を2つだと思っていた(2026-08-04、配備が此処で止まって判明)────────────
// 初版はその見分けを **`.git` が1つ上に在るか**という代理で書いていた。代理は性質では
// ない —— 答えているのは「**何かの** repo が上に在るか」であって、「**自分の** repo の
// 中に居るか」ではない。実際に外したのは想定していなかった**3つ目の世界**:
//
//   `tools/deploy-to-edith.sh` は edith の `/Users/edith/rc-staging` へ木を写して
//   其処で `npm test` を回す。親は `/Users/edith` で、2026-08-03 の艦隊衛生作業が
//   其処に `.git` を作っていた。代理は「repo の中に居る」と答え、DESIGN.md は無いので
//   赤 —— **12 commit が電話に届かないまま配備が止まった**。
//
// なので代理をやめ、**性質そのもの**を git に訊く: 「囲む repo は、**此処に在る**
// DESIGN.md を版管理しているか」。実測(4 世界、2026-08-04):
//
//   | 世界                                   | ls-files --error-unmatch | 判定     |
//   |----------------------------------------|--------------------------|----------|
//   | 本物の repo                            | exit 0                   | 要求     |
//   | 版管理下だが作業木の実体を消した       | exit 0                   | **要求** |
//   | edith の配備用の写し(`.git` だけ在る) | 非 0                     | 飛ばす   |
//   | 変異走行の写し(どちらも無い)         | 非 0                     | 飛ばす   |
//
// 2行目が要点 —— `ls-files` は**索引**を見るので、`rm DESIGN.md` しても版管理下のままで
// 赤が保たれる(= fail-closed が生きている)。`git rm` すれば飛ぶが、版管理から外すのは
// 事故ではなく決定なので、それでよい。
//
// ★環境変数を落とす理由も実測。`npm test` は git の pre-commit の中でも走り、其処では
//   `GIT_INDEX_FILE=.git/index` が渡ってくる(使い捨ての repo で commit して観測)。
//   更に `GIT_DIR` が他の repo を指していると、**素の temp dir が「版管理下」と答える** ——
//   変異走行の写しは正に素の temp dir なので、これは 241 件の変異を丸ごと殺した事故と
//   同じ向きの誤判定になる。だから子には `GIT_DIR`/`GIT_WORK_TREE`/`GIT_INDEX_FILE` を
//   渡さない。
//
// ★`git` 自体が起動できない時は**飛ばす**(= 世界を見分けられないなら写し側に倒す)。
//   逆に倒すと、git の無い機械で変異走行が丸ごと死ぬ —— 前科のある方の事故である。
//   代償は「repo の中で git を失い、かつ DESIGN.md も消えた」時に見逃す事。両機械に
//   `git` が在る事は実測済みなので、この取引を選ぶ。
//   撃っているのは `test/design-supersede-world-controls.sh` の 7 本目
//   (`PATH=/nonexistent` を前置きして走らせる)。取引を変えるなら其処も一緒に直す事。
const REPO = process.env.RC_DESIGN_REPO || join(ROOT, "..");   // ← 対照の差し替え口
const DESIGN_PATH = join(REPO, "DESIGN.md");
const DESIGN = existsSync(DESIGN_PATH) ? readFileSync(DESIGN_PATH, "utf8") : null;

// ── ★「非 0 は全部 写し」も代理だった(2026-08-04、Codex 査読 + 実測)───────────
// 上の版は `catch { return false }` = **git の全ての失敗を「写しだ」と読んで飛ばして**いた。
// 終了コードは3種類あり、意味が違う(実測):
//
//   | 状況                                   | exit | stderr                                  |
//   |----------------------------------------|------|-----------------------------------------|
//   | repo が有効で、その名が索引に在る       | 0    | —                                       |
//   | repo が有効で、その名が索引に**無い**   | 1    | —                                       |
//   | そもそも repo が無い(世界 B / C)      | 128  | `fatal: not a git repository …`         |
//   | repo は在るが git が拒んだ / 壊れている | 128  | `fatal: .git/index: index file smaller…`|
//
// 最後の行が問題だった。索引が壊れた・`safe.directory` に拒まれた等は
// 「**判定できなかった**」であって「写しだ」ではない。写し側に倒すと、本物の repo で
// DESIGN.md が消えていても静かに飛ぶ = この門が守る当のものが抜ける。
// なので **128 のうち `not a git repository` だけを写し**と読み、それ以外は
// `"undetermined"` を返す。`designOrSkip` は `false` 以外を全部赤にするので、
// 判らない時は赤へ倒れる(fail-closed)。module 読み込み時に throw はしない ——
// throw にすると DESIGN.md が読める健全な木でも、git の一時的な lock で
// この file が丸ごと落ちる。判断が要る所だけで倒す。
//
// ★索引だけでは足りない事も査読で出た: `git rm --cached DESIGN.md` = **staged deletion**
//   は索引から消えるので `ls-files` は 1 を返し、本物の repo が静かに飛ぶ。だから
//   索引で見付からなければ `HEAD` も見る。commit が1つも無い repo では `HEAD` が
//   無いので、その時は索引の答えのまま(対照の世界 A' がそれ)。
//
// ★`LC_ALL=C` を渡すのは、上の stderr 照合を訳文で壊さない為。`--literal-pathspecs` と
//   `--` は `DESIGN.md` が pathspec の魔法として解釈される道を塞ぐ。
//
// ★採らなかった助言も残す: Codex は `rev-parse --show-toplevel` が REPO と一致する事も
//   要求せよと言った(祖先の repo が同名を版管理していると誤検出する、という理由)。
//   採らない。此処で測りたい性質は「**この DESIGN.md が版管理されているか**」であって
//   「此処が repo の根か」ではない。祖先の repo が版管理しているなら、それは本当に
//   版管理されている。逆に根の一致を要求すると、package をもう一段深くした時に
//   **黙って全部飛ぶ**新しい fail-open が生まれる。edith の `/Users/edith` が
//   `rc-staging/DESIGN.md` を版管理していない事は実測済みで、この助言が防ぐ誤検出は
//   現存しない。実例が出たら考え直す。
//   `git` が起動できない時に throw せよ、も採らない —— 上の取引(対照 7)を壊す。

/**
 * 囲む repo が `dir` の DESIGN.md を版管理しているか。代理ではなく関係そのものを訊く。
 * @returns {true | false | "undetermined"} `false` だけが「飛ばしてよい」。
 */
export function repoTracksDesign(dir) {
  const env = { ...process.env, LC_ALL: "C" };
  delete env.GIT_DIR;
  delete env.GIT_WORK_TREE;
  delete env.GIT_INDEX_FILE;
  const git = (args) =>
    spawnSync("git", ["--literal-pathspecs", "-C", dir, ...args], { env, encoding: "utf8" });

  const idx = git(["ls-files", "--error-unmatch", "--", "DESIGN.md"]);
  if (idx.error) return false;            // git を起動できない -> 取引どおり写し側へ倒す
  if (idx.status === 0) return true;

  // 索引に無い。staged deletion を「版管理外」と読み違えない様に HEAD も見る。
  const head = git(["cat-file", "-e", "HEAD:DESIGN.md"]);
  if (head.status === 0) return true;

  if (idx.status === 1) return false;     // repo は有効、その名は本当に版管理外
  if (idx.status === 128 && /^fatal: not a git repository\b/m.test(idx.stderr || "")) return false;
  return "undetermined";                  // 判らない -> designOrSkip が赤にする
}

const TRACKED = repoTracksDesign(REPO);

/** DESIGN.md が読めない時、飛ばしてよいかを判定する。よくないなら**この場で赤にする**。 */
function designOrSkip(t) {
  if (DESIGN !== null) return true;
  assert.equal(
    TRACKED, false,
    `DESIGN.md が読めないのに、飛ばしてよい根拠が無い(版管理の判定 = ${JSON.stringify(TRACKED)})。`
    + " true = 版管理されている / \"undetermined\" = git が答えられなかった。どちらも飛ばしてよい不在ではない",
  );
  t.skip("囲む repo が此処の DESIGN.md を版管理していない(= repo から写した木。変異走行と配備の写しがこれ)");
  return false;
}

/** 見出しの後ろ何行までを「頭」と見なすか。銘板が本文に埋もれたら意味が無い。 */
const BANNER_WINDOW = 30;

// ── 検出器: 電話の画面が `/stream` を開いているか ──────────────────────────
/**
 * 注釈を落としてから探す。`src/app.html` には「もう呼ばない」と**注釈で**書いてあり、
 * 素で grep すると古い節が現行だと誤判定される(実際この検査を書く前に1度誤読した)。
 * buffer を受け取る形にして、下の対照が同じ道を通れるようにしてある。
 */
export function opensStream(html) {
  const code = html
    .split("\n")
    .map((l) => l.replace(/\/\/.*$/, ""))
    .join("\n")
    .replace(/\/\*[\s\S]*?\*\//g, "");
  return /EventSource/.test(code) || /["'`][^"'`]*\/stream/.test(code);
}

// ── 登録簿: 「この条件が真なら、この節は古い」 ────────────────────────────
const SUPERSEDED = [
  {
    id: "2.11-stream",
    // 見出しは全文で持たない(題は推敲される)。動かない部分だけを目印にする。
    heading: "## 2.11 ライブ配信",
    by: "§2.36",
    why: "電話の画面(`/` = app.html)が /stream を1度も開かない",
    stale: () => !opensStream(readFileSync(join(ROOT, "src", "app.html"), "utf8")),
  },
];

/**
 * 銘板が立っているか。判定は純関数にして、対照が本物の DESIGN.md 無しで撃てる様にする。
 *
 * ★見るのは「窓の中の何処か」ではなく **見出しの直後に始まる引用ブロック**。
 *   最初これを「窓 30 行の中に後継の番号が在るか」で書いたら、陰性対照が**素通りした**
 *   —— 銘板の要の一文を消しても、同じ節の後ろの散文が同じ番号を引いていたので緑のままだった。
 *   銘板とは**頭に在って目に入る塊**の事なので、塊そのものを的にする。
 */
export function bannerMissing(text, row) {
  const lines = text.split("\n");
  const at = lines.findIndex((l) => l.startsWith(row.heading));
  if (at < 0) return "heading-absent";
  let k = at + 1;
  while (k < lines.length && lines[k].trim() === "") k++;
  if (!lines[k] || !lines[k].startsWith(">")) return "no-banner";
  const block = [];
  for (; k < lines.length && k <= at + BANNER_WINDOW; k++) {
    if (!lines[k].startsWith(">") && lines[k].trim() !== "") break;
    block.push(lines[k]);
  }
  const head = block.join("\n");
  if (!head.includes(row.by)) return "no-pointer";
  // 指すだけでは足りない。「もう現行ではない」と読める印が要る。
  if (!/現行では|superseded|後継|置き換|替えた/.test(head)) return "no-verdict";
  return null;
}

// ── ① 本体 ───────────────────────────────────────────────────────────
test("★コードが古いと言っている節には、頭に後継を指す銘板が立っている", (t) => {
  if (!designOrSkip(t)) return;
  const bad = [];
  for (const row of SUPERSEDED) {
    if (!row.stale()) continue; // コードが戻った = 銘板は要らない
    const miss = bannerMissing(DESIGN, row);
    if (miss) bad.push(`${row.id}: ${miss}(${row.why})`);
  }
  assert.deepEqual(
    bad, [],
    "古い節の**頭**に後継への銘板が無い。後ろに新しい節を足すだけでは読み手は辿り着かない" +
      "(2026-07-27 に同じ形で 13 時間を失っている)",
  );
});

// ── ② 登録簿が腐っていない ────────────────────────────────────────────
test("登録簿の見出しが全部**実在する**(題を変えて検査を黙らせない)", (t) => {
  if (!designOrSkip(t)) return;
  const ghosts = SUPERSEDED.filter((r) => !DESIGN.split("\n").some((l) => l.startsWith(r.heading)));
  assert.deepEqual(
    ghosts.map((r) => r.id), [],
    "登録した見出しが DESIGN.md に無い。改名したなら此処も直す事" +
      "(直さないと、この行は**何も要求しない**まま残る)",
  );
});

// ── ③ 陰性対照: 銘板の判定 ────────────────────────────────────────────
test("陰性対照: 銘板が無い設計書なら見つかる / 在れば見つからない", () => {
  const row = { heading: "## 2.11 ライブ配信", by: "§2.36", why: "-" };
  const naked = "## 2.11 ライブ配信 `/stream` の規約\n\n本文が続く。\n";
  const proseOnly = "## 2.11 ライブ配信 `/stream` の規約\n\n現行ではない。正本は §2.36。\n";
  const pointerOnly = "## 2.11 ライブ配信 `/stream` の規約\n\n> 詳しくは §2.36 を見よ。\n";
  const noPointer = "## 2.11 ライブ配信 `/stream` の規約\n\n> この節は現行ではない。\n";
  const full = "## 2.11 ライブ配信 `/stream` の規約\n\n> この節は現行ではない。正本は §2.36。\n";
  assert.equal(bannerMissing(naked, row), "no-banner");
  assert.equal(bannerMissing(proseOnly, row), "no-banner",
    "地の文に紛れた1行は銘板ではない —— 目に入る塊である事まで要る");
  assert.equal(bannerMissing(pointerOnly, row), "no-verdict");
  assert.equal(bannerMissing(noPointer, row), "no-pointer");
  assert.equal(bannerMissing(full, row), null);
  assert.equal(bannerMissing("## 別の題\n", row), "heading-absent");
});

test("★陰性対照: 銘板の要を抜いても**本文が同じ番号を引いていれば緑**、にならない", () => {
  // これは実際に踏んだ穴(2026-08-04)。初版は「見出しから 30 行の窓の中に後継の番号が
  // 在るか」だけを見ていたので、銘板の要の一文を消しても、同じ節の後ろの散文が
  // §2.36 を引いていたせいで**素通りした**。対照が弱かったのではなく検査が弱かった。
  const row = { heading: "## 2.11 ライブ配信", by: "§2.36", why: "-" };
  const gutted =
    "## 2.11 ライブ配信\n\n" +
    "本文。この決定の経緯は §2.36 に書いた。現行ではない話も混ざる。\n";
  assert.equal(bannerMissing(gutted, row), "no-banner",
    "散文が番号を引いているだけでは銘板が立っている事にならない");
});

test("陰性対照: 銘板が窓の外まで押し出されたら見つからない扱いになる", () => {
  const row = { heading: "## 2.11 ライブ配信", by: "§2.36", why: "-" };
  const pushed =
    "## 2.11 ライブ配信\n" + "本文\n".repeat(BANNER_WINDOW + 2) + "> 現行ではない。正本は §2.36。\n";
  assert.equal(bannerMissing(pushed, row), "no-banner",
    "頭から離れた銘板は読み手に届かない = 立っていないのと同じに数える");
});

// ── ④ 陰性対照: 検出器そのもの(此処が壊れると①が空振りする) ──────────────
test("陰性対照: `opensStream` が source と注釈を取り違えない", () => {
  assert.equal(opensStream('const ES = new EventSource("/api/x/stream");'), true);
  assert.equal(opensStream('await fetch("/api/sessions/" + id + "/stream?since=0");'), true);
  assert.equal(opensStream("// サーバの `/stream` は残っているが、此処からは呼ばない。"), false,
    "注釈の中の綴りを source と読むと、古い節が現行だと誤判定される");
  assert.equal(opensStream("/* 旧: new EventSource(\"/stream\") */\nconst x = 1;"), false);
  assert.equal(opensStream("await fetch(`/api/sessions/${id}/poll?x=1`);"), false);
});

test("★検出器が現に**片方を選んでいる**(常に真/常に偽へ潰れていない)", () => {
  // ①が意味を持つのは、`stale()` が本物の木で false を返し得る時だけ。
  // 今は「電話は開かない」= stale=true が期待値。ここが逆転したらコードが戻った合図で、
  // その時は銘板の要求も消えるべき —— この行はその**遷移**を可視にする為に置く。
  const html = readFileSync(join(ROOT, "src", "app.html"), "utf8");
  assert.equal(opensStream(html), false,
    "app.html が /stream を開き始めた。§2.11 は再び現行かもしれない —— " +
      "DESIGN.md の銘板と此処の登録簿を人が読み直す事");
});
