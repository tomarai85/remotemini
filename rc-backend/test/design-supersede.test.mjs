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
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const DESIGN = readFileSync(join(ROOT, "..", "DESIGN.md"), "utf8");

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
test("★コードが古いと言っている節には、頭に後継を指す銘板が立っている", () => {
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
test("登録簿の見出しが全部**実在する**(題を変えて検査を黙らせない)", () => {
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
