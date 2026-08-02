// `app.html` の中の script を**静的に**検査する層。
//
// なぜ要るか(2026-08-02 に作った): この時点まで、電話が実際に読む唯一のファイルに
// 対する検査が **1本も無かった**。e2e は `/` が 200 を返す事しか見ておらず、中身が
// 構文エラーでも、import した名前が存在しなくても、全部緑のまま通る。落ちる場所は
// 移動中の Tom の iPhone で、出るのは真っ白な画面だけ = **一番直しに行けない所**。
//
// ここで掴むのは3つ:
//   1. script が module として構文的に通るか
//   2. import している名前が、その module に**実在する**か
//   3. 逆に、import せずに使っている外部の名前が無いか(= 実行時 ReferenceError)
// 加えて、import 先の path をサーバが**実際に配っているか**(STATIC 表との一致)。
// 見た目・レイアウト・ブラウザ差はここでは何も保証しない(§2.13「検査の届かない所」)。
import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const HTML = readFileSync(join(ROOT, "src", "app.html"), "utf8");
const SERVER = readFileSync(join(ROOT, "src", "server.mjs"), "utf8");

// ---- script の取り出し -----------------------------------------------------
const M = HTML.match(/<script\b([^>]*)>([\s\S]*?)<\/script>/);
const SCRIPT_ATTRS = M ? M[1] : "";
const SCRIPT = M ? M[2] : "";

test("app.html が script を1つ持ち、それが module である", () => {
  assert.ok(M, "<script> が見つからない");
  assert.match(SCRIPT_ATTRS, /type\s*=\s*["']module["']/,
    "type=module が無いと import 文がその場で構文エラーになる(画面は白紙)");
  const count = (HTML.match(/<script\b/g) || []).length;
  assert.equal(count, 1, "script が増えたらこの検査の取り出しが片方しか見なくなる");
});

test("★app.html の script が module として構文的に通る", () => {
  // 実行はしない(document を触るので落ちる)。構文だけを見る。
  const dir = mkdtempSync(join(tmpdir(), "rc-apphtml-"));
  try {
    const f = join(dir, "app-script.mjs");
    writeFileSync(f, SCRIPT);
    execFileSync(process.execPath, ["--check", f], { stdio: "pipe" });
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

// ---- import 文の解析 -------------------------------------------------------
/** `import { a, b } from "/x.mjs";` を {source -> [名前]} に解く。 */
function parseImports(src) {
  const out = new Map();
  const re = /import\s*\{([^}]*)\}\s*from\s*["']([^"']+)["']/g;
  for (let m; (m = re.exec(src)); ) {
    const names = m[1].split(",").map((s) => s.trim().split(/\s+as\s+/)[0].trim()).filter(Boolean);
    out.set(m[2], (out.get(m[2]) || []).concat(names));
  }
  return out;
}
const IMPORTS = parseImports(SCRIPT);
// 電話は `/view.mjs` として取りに行く。検査はディスク上の `../src/view.mjs` を読む。
const DISK = { "/view.mjs": "../src/view.mjs", "/frames.mjs": "../src/frames.mjs" };

test("app.html は view.mjs と frames.mjs だけを import する(判断の置き場所を散らさない)", () => {
  assert.deepEqual([...IMPORTS.keys()].sort(), ["/frames.mjs", "/view.mjs"]);
});

test("★import している path をサーバが実際に配っている(STATIC 表と一致)", () => {
  for (const p of IMPORTS.keys()) {
    assert.ok(SERVER.includes(`["${p}",`), `server.mjs の STATIC に ${p} が無い = 電話は 404 を受ける`);
  }
});

test("★import している名前が、その module に実在する", async () => {
  for (const [p, names] of IMPORTS) {
    const mod = await import(DISK[p]);
    for (const n of names) {
      assert.equal(typeof mod[n], "function", `${p} に ${n} が無い(実行時に undefined を呼ぶ)`);
    }
  }
});

test("★★export されているのに import せず使っている名前が無い(実行時 ReferenceError)", async () => {
  // 2026-08-02 にこの検査を作った直接の動機: `scanLine` / `whoOf` を app.html から
  // view.mjs へ移した時、import を書き忘れても**単体も e2e も全部緑のまま**だった。
  // 落ちるのは電話の上だけ = 気付くのが一番遅い場所。
  const imported = new Set([...IMPORTS.values()].flat());
  // script の中で自前に定義している名前(移し忘れの検出で誤検知しない為)。
  const localRe = /(?:^|\n)\s*(?:async\s+)?(?:function|const|let|var|class)\s+([A-Za-z_$][\w$]*)/g;
  const local = new Set();
  for (let m; (m = localRe.exec(SCRIPT)); ) local.add(m[1]);

  for (const [p] of IMPORTS) {
    const mod = await import(DISK[p]);
    for (const name of Object.keys(mod)) {
      if (imported.has(name) || local.has(name)) continue;
      const used = new RegExp(`\\b${name}\\s*\\(`).test(SCRIPT);
      assert.ok(!used, `${name}() を使っているのに ${p} から import していない`);
    }
  }
});

// ---- 2026-08-02 に見つけた「失敗を成功の顔をした値に化かす」型の再発防止 ----
// ★これらは静的検査どまり。この repo に DOM の検査台は無く、`phone-window-controls.sh`
//   は tmux 側しか駆動できない。#1(前面復帰の張り直し)の本当の証明には実機の iPhone が
//   要る = 下の3本は「書いてある事」を測るのであって「動く事」は測っていない。
//   その差を埋めたと主張しない為に、ここに明記して残す。
test("★読めなかった応答を `{}` に捏造していない(catch の既定値)", () => {
  // `.catch(() => ({}))` は「読めた本文に鍵が無い」と区別が付かない。判定層の
  // `body || {}` と組むと、確認していない事を「確認できた」側へ倒す。
  assert.doesNotMatch(SCRIPT, /\.catch\(\s*\(\)\s*=>\s*\(\{\s*\}\)\s*\)/,
    "応答が読めなかった時に空の本文を作っている(null を渡して判定層に決めさせる)");
  const nulls = SCRIPT.match(/\.catch\(\s*\(\)\s*=>\s*null\s*\)/g) || [];
  assert.equal(nulls.length, 2, "send() と interrupt() の2箇所が null を渡している");
});

test("★前面へ戻った時に流れを張り直す配線が居る(帯の断定に証拠を付ける)", () => {
  // sleepOrWake の listener は「切れて待っている間」だけの担当。開いたまま黙った流れは
  // 誰も触っていなかったのに、帯は「つながっています」と出したままだった。
  assert.match(SCRIPT, /function\s+onForeground\s*\(/, "onForeground が定義されていない");
  assert.match(SCRIPT, /document\.addEventListener\("visibilitychange",\s*onForeground\)/,
    "onForeground が visibilitychange に繋がっていない");
  assert.match(SCRIPT, /conv\.refresh\s*=\s*true/, "張り直しが意図的である印を立てていない");
  // 印が無いと catch の `aborted` 分岐が閉じたのか張り直しなのか区別できず、黙って死ぬ。
  assert.match(SCRIPT, /if\s*\(!conv\s*\|\|\s*conv\.gen\s*!==\s*myGen\s*\|\|\s*!conv\.refresh\)\s*return;/,
    "catch 側が refresh を見ていない(自分で閉じた時に張り直してしまう / 逆に張り直せない)");
});

test("★履歴の取得に失敗したら描き直す(「以前を読む」が二度と押せなくならない)", () => {
  // renderConv がボタンを毎回作り直す設計なので、押した時の `more.disabled = true` は
  // 描き直しでしか戻らない。失敗経路で描き直さないと、その1回で押せなくなる。
  const m = SCRIPT.match(/async function loadHistory[\s\S]*?\n}\n/);
  assert.ok(m, "loadHistory を切り出せない(検査自身が壊れている)");
  const cat = m[0].slice(m[0].indexOf("} catch"));
  assert.match(cat, /renderConv\(\)/, "loadHistory の失敗経路が renderConv() を呼んでいない");
});

test("★形の違う 200 を「0件」という断定にしない(一覧・履歴)", () => {
  assert.match(SCRIPT, /if\s*\(!Array\.isArray\(data\.sessions\)\)\s*throw/,
    "一覧が配列でない 200 を「会話がありません。」に化かしている");
  assert.match(SCRIPT, /if\s*\(!Array\.isArray\(d\.history\)\)\s*throw/,
    "履歴が配列でない 200 を空の履歴として飲んでいる");
  assert.doesNotMatch(SCRIPT, /data\.sessions\s*\|\|\s*\[\]/, "`|| []` が戻っている");
  assert.doesNotMatch(SCRIPT, /d\.history\s*\|\|\s*\[\]/, "`|| []` が戻っている");
});

test("★判断を HTML 側に書き戻していない(移した関数名が定義として復活していない)", () => {
  // 「引き剥がした」を主張し続けられる様にする関門。同名の関数を app.html に
  // 定義し直すと import は死に文になり、検査は view.mjs の方を測り続ける =
  // **緑のまま実物と乖離する**。名前が戻ってきた時点で赤にする。
  const moved = ["scanLine", "whoOf", "gapNotice", "nextAttempt", "nextHistoryLimit",
                 "sendResult", "interruptResult", "mergeHistory", "routeLabel", "subtitleOf", "relTime",
                 "freshness"];
  for (const n of moved) {
    const re = new RegExp(`(?:function|const|let|var)\\s+${n}\\b`);
    assert.ok(!re.test(SCRIPT), `${n} が app.html の中で再定義されている(import が死に文になる)`);
  }
});

// ---- 見た目の層(§2.19)------------------------------------------------------
// ★ここで測れるのは**規則がそう書かれている事**だけで、画素が正しい事ではない。
//   この工程には描画を観測できる計器が無い(依存ゼロが原則、Tom の機械で見える
//   ブラウザを開くのは禁止)。だから U2/U3 は「直した筈」であって「直した」ではない
//   = DESIGN §8 の Tom 確認欄に出してある。ここに置くのは**元へ戻った事を掴む網**。
const STYLE = (HTML.match(/<style>([\s\S]*?)<\/style>/) || [])[1] || "";
const cssBlock = (sel) => {
  const esc = sel.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const m = STYLE.match(new RegExp(`(?:^|\\n)\\s*${esc}\\s*\\{([\\s\\S]*?)\\}`));
  return m ? m[1] : null;
};

test("★★画面いっぱいの高さと安全域の余白は、同じ箱に置く(送るボタンが画面外へ出ない)", () => {
  // 別の箱に置くと足し算になる: body(height:100% の内側に余白)+ 子(100dvh)
  // = 差の inset-top だけ下へはみ出し、一番下の `送る`/`止める` が画面の外へ出る。
  // ホーム画面に追加した時(standalone)と横向きで効く = Tom の使い方そのもの。
  const body = cssBlock("body");
  const screen = cssBlock(".screen");
  assert.ok(body, "body の規則を取り出せない(検査自身が壊れている)");
  assert.ok(screen, ".screen の規則を取り出せない(検査自身が壊れている)");
  assert.doesNotMatch(body, /safe-area-inset/,
    "body に安全域の余白が戻っている = 100dvh の子と積み上がり、送るボタンが画面外へ出る");
  assert.match(screen, /safe-area-inset-top/, ".screen が上の安全域を持っていない(切り欠きに潜る)");
  assert.match(screen, /height:\s*var\(--vvh/, ".screen が実高さを見ていない");
});

test("★鍵盤が出た時に縮む道が在る(--vvh を JS が必ず入れる)", () => {
  assert.match(SCRIPT, /visualViewport/, "visualViewport を見ていない = 鍵盤で入力欄が隠れる");
  assert.match(SCRIPT, /setProperty\("--vvh"/, "実高さを CSS へ流していない");
  // ★visualViewport が無い環境でも値を入れる。CSS 側の `var(--vvh, 100dvh)` の
  //   既定値に頼ると、`dvh` を知らない browser では計算時に宣言ごと無効になり
  //   高さが auto へ落ちる(= 画面が伸びきる)。
  assert.match(SCRIPT, /window\.innerHeight/, "visualViewport が無い時に値を入れる道が無い");
  assert.match(SCRIPT, /\nsyncViewportHeight\(\);/, "起動時に一度も呼んでいない");
});

test("★★一覧の古さ: 取れなかった時に時刻を進めない(古い画面が新しい顔をしない)", () => {
  const m = SCRIPT.match(/async function loadList\(\)\s*\{([\s\S]*?)\n\}/);
  assert.ok(m, "loadList を切り出せない(検査自身が壊れている)");
  const ll = m[1];
  assert.match(ll, /listFetchedAt\s*=\s*now/, "取れた時刻を記録していない");
  const cat = ll.slice(ll.indexOf("} catch"), ll.indexOf("const now"));
  assert.ok(cat.length > 0, "catch と成功経路を切り分けられない(検査自身が壊れている)");
  assert.doesNotMatch(cat, /listFetchedAt/,
    "取れなかった経路で時刻を進めている = 失敗した瞬間に一覧が「たった今の値」を名乗る");
});

test("★一覧の古さ: 前面に戻ったら取り直す配線が居る(§2.19 U1-a)", () => {
  assert.match(SCRIPT, /function\s+onForegroundList\s*\(/, "onForegroundList が定義されていない");
  assert.match(SCRIPT, /document\.addEventListener\("visibilitychange",\s*onForegroundList\)/,
    "前面復帰に繋がっていない = 20分後に拾っても古い値のまま");
  const m = SCRIPT.match(/function onForegroundList\(\)\s*\{([\s\S]*?)\n\}/);
  assert.ok(m, "onForegroundList を切り出せない");
  assert.match(m[1], /loadList\(\)/, "前面へ戻っても取り直していない");
  assert.match(m[1], /s-list/, "一覧を出していない時にも網を叩いている(会話中に無駄打ち)");
});

test("★一覧の古さ: 刻む時計は網を叩かない(電池と相手の負荷)", () => {
  const m = SCRIPT.match(/function startListClock\(\)\s*\{([\s\S]*?)\n\}/);
  assert.ok(m, "startListClock を切り出せない");
  assert.doesNotMatch(m[1], /loadList|fetch|api\(/,
    "時計から網を叩いている = 一覧1回0.75秒を延々と載せる事になる(§2.19 の判断と逆)");
});

// ---- §2.19 U4: 入力欄の上限が「今見えている高さ」を基準にしているか ----
// ★ここも測れるのは**原文がそう書かれている事**だけ。U3 と同じ格。
//   ただし「上限が2箇所に在る」事自体は原文で数えられるので、**片方だけ直した状態**は掴める。

// ★「そこに書いていない」を測る時は、**注釈を落としてから測る**。
//   2026-08-03 に実際に踏んだ: 「window.innerHeight を使っていない事」の検査が、
//   **なぜ使わないかを説明した注釈**に当たって赤になった。検査は原文を読むが、
//   人が読む為の文と機械が実行する文を区別しない。否定の検査だけがこれに嵌る
//   (肯定は注釈に当たっても実装が在れば正しい答えになるので静かに見逃す)。
const codeOnly = (s) =>
  s.split("\n").filter((l) => !l.trim().startsWith("//")).join("\n");

test("★入力欄の上限は window.innerHeight を基準にしない(鍵盤が出ても縮まない値)", () => {
  const m = SCRIPT.match(/\$\("conv-input"\)\.addEventListener\("input",[\s\S]*?\n\}\);/);
  assert.ok(m, "入力欄の input ハンドラを切り出せない(検査自身が壊れている)");
  const code = codeOnly(m[0]);
  assert.match(code, /style\.height/, "切り出しが注釈だけになっている(検査自身が壊れている)");
  assert.doesNotMatch(code, /window\.innerHeight/,
    "入力欄の上限が window.innerHeight = 鍵盤が出ても縮まない値。鍵盤で半分埋まった時に " +
    "『鍵盤が無い時の画面の4割』まで伸びて、会話の本文が潰れる");
  assert.match(code, /visibleHeight\(\)/,
    "入力欄が実高さの物差し(visibleHeight)を通っていない");
});

test("★実高さを測る所は1つだけ(同じ画面を2つの物差しで測らない)", () => {
  // 数えるのは「visualViewport が在るか」の見張りではなく、**高さを取り出している場所**。
  // 見張り(`if (window.visualViewport)` / `addEventListener`)は何個在っても物差しは割れない。
  const n = (codeOnly(SCRIPT).match(/visualViewport[\s\S]{0,12}?\.height|vv\s*&&\s*vv\.height/g) || []).length;
  assert.equal(n, 1, `visualViewport から高さを取り出している場所が ${n} 箇所ある = 物差しが割れている`);
  const m = SCRIPT.match(/function visibleHeight\(\)\s*\{([\s\S]*?)\n\}/);
  assert.ok(m, "visibleHeight を切り出せない");
  assert.match(codeOnly(m[1]), /window\.innerHeight/,
    "visualViewport が無い環境の落とし先が無い(0 のまま高さを 0 にしかねない)");
});

test("★CSS 側の上限も同じ物差しを見る(片方だけ直すと『直した筈』で残る)", () => {
  const ta = cssBlock("textarea");
  assert.ok(ta, "textarea の規則を取り出せない(検査自身が壊れている)");
  assert.doesNotMatch(ta, /max-height:\s*[\d.]+dvh/,
    "CSS の上限が dvh のまま = 鍵盤が出ても縮まない。JS だけ直しても CSS が古い物差しで残る");
  assert.match(ta, /max-height:\s*calc\(var\(--vvh/,
    "CSS の上限が --vvh を見ていない");
});
