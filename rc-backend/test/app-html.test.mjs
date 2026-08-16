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
  assert.equal(nulls.length, 4,
    "send() / interrupt() / sendChoice() / clearQueue() の4箇所が null を渡している");
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

test("★世代を跨いだ書き込みを `conv &&` だけで守らない(前の後始末が新しい会話を黙らせる)", () => {
  // 実際に出した傷(2026-08-04): poll の catch に `conv && (conv.reading = false)` と書いた。
  // 会話を開き直すと `closeConv` が前の保留を畳むが、その catch が走るのは
  // **新しい conv が入った後**。`conv` は真なので通ってしまい、新しい世代の
  // `reading` が偽になる。すると次の前面復帰が onForeground の
  // `if (!conv || !conv.reading) return;` で落ち、撃ち直されない
  // = 帯は「つながっています」のまま、証拠の無い断定に戻る。
  //
  // ★この検査の限界を先に書く: 掴めるのは**この形**(存在確認だけを門にした代入)
  //   だけで、「世代を確かめずに書く」一般ではない。行を跨いだ書き方には当たらない。
  //   それでも置くのは、これが実際に手が滑った形だから。
  assert.doesNotMatch(SCRIPT, /conv\s*&&\s*\(?\s*conv\.\w+\s*=[^=]/,
    "存在確認だけを門にして conv へ書いている(世代が違えば別の会話を触る)");
  // 直した側が居る事も確かめる。上の否定形だけだと、代入ごと消しても緑になる。
  assert.match(SCRIPT, /if\s*\(conv\s*&&\s*conv\.gen\s*===\s*myGen\)\s*conv\.reading\s*=\s*false;/,
    "poll の失敗経路が reading を戻していない(前面復帰の担当が誰も居なくなる)");
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

test("★判断を HTML 側に書き戻していない(移した関数名が定義として復活していない)", async () => {
  // 「引き剥がした」を主張し続けられる様にする関門。同名の関数を app.html に
  // 定義し直すと import は死に文になり、検査は view.mjs の方を測り続ける =
  // **緑のまま実物と乖離する**。名前が戻ってきた時点で赤にする。
  // ★手書きの一覧は**網の届く範囲がそこで止まる**(M14 と同じ型: 呼び口が増えても
  //   一覧が増えないので、新しく移した関数だけ守られない)。
  // ★★何から導くかを2026-08-05に測り直した。最初は **import 文**から導いたが、
  //   それだと「import を消して同名を app.html に定義し直す」= 引き戻しそのものの形で
  //   網が一緒に縮み、**両方緑のまま通る**(実測: 変更前後どちらも 47/0)。上の
  //   「import せず使っている名前」も `local.has(name)` で除外するので捕らない。
  //   なので導出元は **module がディスク上で export している名前** —— 引き戻しても
  //   view.mjs 側の export は残るので、網は縮まない。手書き側は床として残す。
  const floor = ["scanLine", "whoOf", "gapNotice", "nextAttempt", "nextHistoryLimit",
                 "sendResult", "interruptResult", "mergeHistory", "routeLabel", "subtitleOf", "relTime",
                 "freshness", "readablePoll"];
  const exported = [];
  for (const p of Object.keys(DISK)) exported.push(...Object.keys(await import(DISK[p])));
  const moved = [...new Set([...floor, ...exported])];
  assert.ok(moved.length > floor.length,
    "export 側から1つも増えていない(導出が効いていない = 手書き一覧に戻っている)");
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

// ---- 古さを**描く**側(2026-08-05 に足した。それまで1本も無かった)-------------
//
// 上の3本が測っているのは「時刻を進める場所」「網を叩かない事」「前面復帰の配線」で、
// 描く関数 `paintListAge` そのものは**素通し**だった。此処が外れた時に出るのは白紙でも
// 赤でもない —— **古い一覧が「たった今の値」を名乗る画面**が出る。`freshness` は差が負なら
// 「たった今の値」+ `stale:false` を返すので、引数を入れ替えるだけでそうなる。
// つまり §2.19 が丸ごと守ろうとしている物が、静かに裏返る形が1つ残っていた。
//
// 静的一致(regex)では掴めない。呼んでいる事は書いてあり、**何を渡したか**が問題だから。
// なので原文を切り出して**実際に実行する**。browser も DOM も要らない: 節点・`freshness`・
// `Date` は全部この検査が渡す(仮引数が module 側の名前を覆う)。
const paintListAgeSrc = SCRIPT.match(/function paintListAge\(\)\s*\{[\s\S]*?\n\}/);
const mkPaint = (fakeFreshness, node, fetchedAt, nowMs) =>
  new Function("freshness", "listAgeNode", "listFetchedAt", "Date",
    `${paintListAgeSrc ? paintListAgeSrc[0] : ""}\nreturn paintListAge;`)(
    fakeFreshness, node, fetchedAt, { now: () => nowMs });

test("★★古さを描く側: freshness へ (取得時刻, 今) の順で渡している", () => {
  assert.ok(paintListAgeSrc, "paintListAge を切り出せない(検査自身が壊れている)");
  assert.match(paintListAgeSrc[0], /freshness\(/,
    "切り出しに freshness の呼び口が無い(検査自身が壊れている)");
  const calls = [];
  const node = { isConnected: true, textContent: "", className: "" };
  // ★2つの値は**わざと遠く離す**。同値だと入れ替えても同じ結果になり、
  //   何も測れていない検査が緑で通る(13-D で実際に踏んだ型)。
  mkPaint((a, b) => { calls.push([a, b]); return { text: "T", stale: false }; },
    node, 111, 999)();
  assert.deepEqual(calls, [[111, 999]],
    "引数の順が違う = 差が負になり freshness が『たった今の値』を返す。" +
    "20分前の一覧が現在形で出続ける画面になり、しかも警告は消える");
});

test("★★古さを描く側: 文言と stale の印を取り違えていない", () => {
  const mk = (stale) => {
    const node = { isConnected: true, textContent: "", className: "" };
    mkPaint(() => ({ text: "FRESHNESS-TEXT", stale }), node, 111, 999)();
    return node;
  };
  const fresh = mk(false);
  const old = mk(true);
  assert.equal(fresh.textContent, "FRESHNESS-TEXT",
    "節点へ書いているのが freshness の text ではない");
  assert.doesNotMatch(fresh.className, /\bstale\b/, "新しい値に古さの印が付いている");
  assert.match(old.className, /\bstale\b/,
    "stale の印を落としている = 古い事が**目に見えない**(text だけが頼りになる)");
  // ★恒真でない事の担保: 2つが同じ class になるなら、この検査は何も分けていない
  assert.notEqual(fresh.className, old.className,
    "stale の真偽で class が変わっていない(この検査は何も測れていない)");
});

test("★古さを描く側: 外れた節点には書かない(描き直しで作り直す為)", () => {
  let called = 0;
  const node = { isConnected: false, textContent: "", className: "" };
  mkPaint(() => { called++; return { text: "T", stale: true }; }, node, 111, 999)();
  assert.equal(called, 0, "外れた節点にも freshness を呼んでいる(捨てる値を作っている)");
  assert.equal(node.textContent, "", "外れた節点へ書いている = 画面に出ない所を更新している");
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

// ---- 選択待ちの操作面: **実行して**測る(2026-08-04)-------------------------
//
// この file の他の検査は全部「書いてある事」を測る正規表現で、その限界は上に明記してある。
// ここだけ違う道を採る理由: この操作面は間違いの向きが**安全確認を押す側**へ倒れうる
// 唯一の描画で、「どの指紋を送るか」は**文字列を眺めても分からない**(閉包に入っているか、
// 押した時に読み直しているかは、走らせて初めて差が出る)。
//
// 手は Codex (gpt-5.6-sol xhigh, 2026-08-04) の助言 E に沿う: `document` の**手書きの偽物**を
// 置き、使っているメソッドだけ持たせる。セレクタ・レイアウト・伝播は真似しない
// (真似した瞬間、この偽物自体が正しさを要求される第二の実装になる)。
//
// ★依存ゼロは崩さない。jsdom は入れない。
import { choiceView, queueView } from "../src/view.mjs";

/** SCRIPT から `function <name>(…) {…}` を1本切り出す。文字列とコメントを跨いで数えない。 */
function fnSource(name) {
  const head = SCRIPT.indexOf(`function ${name}(`);
  assert.notEqual(head, -1, `function ${name} が app.html に無い`);
  let i = SCRIPT.indexOf("{", head);
  let depth = 0;
  for (; i < SCRIPT.length; i++) {
    const ch = SCRIPT[i];
    if (ch === "/" && SCRIPT[i + 1] === "/") { i = SCRIPT.indexOf("\n", i); continue; }
    if (ch === '"' || ch === "'" || ch === "`") {
      const q = ch;
      for (i++; i < SCRIPT.length && SCRIPT[i] !== q; i++) if (SCRIPT[i] === "\\") i++;
      continue;
    }
    if (ch === "{") depth++;
    else if (ch === "}" && --depth === 0) return SCRIPT.slice(head, i + 1);
  }
  throw new Error(`function ${name} の終わりを見つけられない`);
}

/** 使っているメソッドだけの偽 DOM。これ以上増やさない事。 */
function fakeDoc() {
  const node = (tag) => ({
    tag, className: "", textContent: "", type: "", disabled: false, children: [], clicks: [],
    appendChild(c) { this.children.push(c); return c; },
    replaceChildren(...n) { this.children = n; },
    addEventListener(ev, f) { if (ev === "click") this.clicks.push(f); },
    tap() { for (const f of this.clicks) f(); },
  });
  return { node, doc: { createElement: node } };
}

/** app.html の `el` + `renderChoicePanel` を切り出して走らせる台。 */
function mount(sendChoice) {
  const { node, doc } = fakeDoc();
  const box = node("div");
  const factory = new Function(
    "document", "$", "choiceView", "sendChoice",
    `${fnSource("el")}\n${fnSource("renderChoicePanel")}\nreturn renderChoicePanel;`,
  );
  const render = factory(doc, (id) => {
    assert.equal(id, "conv-choice", "操作面が別の器を掴んでいる");
    return box;
  }, choiceView, sendChoice);
  return { render, box };
}

const buttonsIn = (box) =>
  box.children.filter((n) => n.tag === "div" && n.className === "choice-keys")
     .flatMap((n) => n.children);

const MENU = {
  screen: "CHOICE",
  choice: {
    kind: "benign", matcher: "select-model@2", head: ["Select model"],
    options: [{ n: 1, label: "Opus 5" }, { n: 2, label: "Sonnet 5" }, { n: 3, label: "Haiku 4.5" }],
    cursor: 2, footer: "", keys: ["digit", "enter", "escape"], digest: "0123456789abcdef",
  },
};
const clone = (o) => JSON.parse(JSON.stringify(o));

test("★実行: 良性メニューで、実在する選択肢の数だけボタンが出る", () => {
  const { render, box } = mount(() => {});
  render(clone(MENU));
  const bs = buttonsIn(box);
  assert.deepEqual(bs.map((b) => b.textContent), [
    "1. Opus 5", "2. Sonnet 5", "3. Haiku 4.5", "Enter(Confirm 2. Sonnet 5)", "Escape(Cancel)",
  ]);
  assert.ok(box.children.some((n) => n.className === "choice-head"),
    "何を選ぶ画面なのかの見出しが出ていない");
});

test("★実行: keys が空なら**ボタンは1つも作られない**(理由だけ出る)", () => {
  const { render, box } = mount(() => { throw new Error("押せない筈の物が押された"); });
  const s = clone(MENU);
  s.choice.kind = "hard-stop";
  s.choice.keys = [];
  render(s);
  assert.equal(buttonsIn(box).length, 0);
  const why = box.children.find((n) => /notice/.test(n.className));
  assert.ok(why && /permission\/trust confirmation/.test(why.textContent), "断る理由が画面に出ていない");
});

test("★実行: 押すと、その描画の指紋がそのまま送られる", () => {
  const calls = [];
  const { render, box } = mount((key, digest) => calls.push([key, digest]));
  render(clone(MENU));
  buttonsIn(box)[1].tap();
  assert.deepEqual(calls, [["2", "0123456789abcdef"]]);
});

test("★★実行: 描画の**後で**状態が入れ替わっても、古いボタンは古い指紋を送る", () => {
  // これがこの検査台を作った理由。押した時に `conv.state` を読み直す実装だと、
  // 描画と押下の間に届いた poll の指紋が乗り、**表示は古いメニューのまま**
  // 新しいメニューの選択がサーバの照合を通る(Codex 指摘 C)。
  // 古い指紋を送れば 409 `digest-mismatch` で確実に断られる = 見ていない物は決まらない。
  const calls = [];
  const { render, box } = mount((key, digest) => calls.push([key, digest]));
  const live = clone(MENU);
  render(live);
  live.choice.digest = "ffffffffffffffff";           // poll が同じ器を書き換えた体
  live.choice.options[0].label = "別のメニューの 1";
  buttonsIn(box)[0].tap();
  assert.deepEqual(calls, [["1", "0123456789abcdef"]],
    "押した時に状態を読み直している = 見ていない選択が通る道が開いている");
});

test("★実行: 最初の1押しで、その描画の**全ての**ボタンが送信より前に伏せられる", () => {
  let seen = null;
  const { render, box } = mount(() => { seen = buttonsIn(box).map((b) => b.disabled); });
  render(clone(MENU));
  const bs = buttonsIn(box);
  assert.deepEqual(bs.map((b) => b.disabled), [false, false, false, false, false]);
  bs[0].tap();
  assert.deepEqual(seen, [true, true, true, true, true],
    "送信の時点でまだ押せる = 二度押しが `choice-already-sent` の雑音になる");
});

test("★実行: ボタンは type=button(将来 form に包まれた時、入力欄の Enter で発火しない)", () => {
  const { render, box } = mount(() => {});
  render(clone(MENU));
  for (const b of buttonsIn(box)) assert.equal(b.type, "button", `${b.textContent} が submit のまま`);
});

test("★実行: 選択待ちでなければ器を空にする(前の会話の操作面を残さない)", () => {
  const { render, box } = mount(() => { throw new Error("消えた筈の物が押された"); });
  render(clone(MENU));
  assert.ok(buttonsIn(box).length > 0);
  render({ screen: "IDLE" });
  assert.deepEqual(box.children, []);
  render(null);
  assert.deepEqual(box.children, []);
});

test("★陰性対照: 偽 DOM が本当に差を見分けるか(常に緑ではない事)", () => {
  // 偽物の作りを間違えて「何を描いても children が空」なら、上の検査は全部無意味に緑になる。
  // 器に節点が積まれる事と、押下が本当に呼び手へ届く事を、対照として独立に固定する。
  const calls = [];
  const { render, box } = mount((k) => calls.push(k));
  render(clone(MENU));
  assert.ok(box.children.length >= 2, "偽 DOM に節点が積まれていない = 何も測れていない");
  buttonsIn(box)[4].tap();
  assert.deepEqual(calls, ["escape"], "押下が呼び手に届いていない = 上の押下検査は空振り");
});

test("sendChoice が /choice へ {key, digest} を送る(静的)", () => {
  const src = fnSource("sendChoice");
  assert.match(src, /\/choice`/, "打鍵の宛先が /choice ではない");
  assert.match(src, /JSON\.stringify\(\{\s*key,\s*digest\s*\}\)/, "key と digest を送っていない");
  assert.match(src, /choiceResult\(r\.status,\s*body\)/, "判定を view.mjs に置いていない");
  // ★指紋の食い違いで自動的に撃ち直さない(Codex 指摘 B)。撃ち直しの語が現れたら赤。
  //   見るのは**本体だけ**(見出しの `function sendChoice(` を自分で拾わない様に落とす)。
  const bodyOnly = src.slice(src.indexOf("{") + 1);
  assert.doesNotMatch(bodyOnly, /sendChoice\s*\(/, "自分を呼び直している = 自動再送の芽");
  assert.doesNotMatch(bodyOnly, /\bbody\.digest\b/, "サーバが返した指紋で撃ち直す道が生えている");
});

// ---- 送信待ちの面(2026-08-04)-----------------------------------------------
//
// 台は上の `mount` と同じ作り。`renderChoicePanel` の台を使い回さないのは、掴む器の id が
// 違うからで、器を取り違えた実装(`conv-choice` に送信待ちを描く)を `$` の中で赤にしたい。

/**
 * app.html の `el` + 送信待ちの面3本を切り出して走らせる台。
 *
 * ★時計(`Date` / `setInterval`)は**注入する**。本物を使うと「1分後にどう見えるか」を
 *   1分待って測る事になり、しかも `setInterval` が試験の間じゅう走り続ける。注入すれば
 *   時刻を進める操作そのものが検査になり、時計が**何本立ったか**も数えられる。
 */
function mountQueue(clearQueue) {
  const { node, doc } = fakeDoc();
  const box = node("div");
  let nowMs = 1_700_000_000_000;
  const ticks = []; // setInterval に渡された物。時計を増やしていない事の計器
  const factory = new Function(
    "document", "$", "queueView", "clearQueue", "Date", "setInterval",
    `let queueLast = null, queueFetchedAt = 0, queueAgeNode = null, queueClock = null;
${fnSource("el")}
${fnSource("renderQueuePanel")}
${fnSource("paintQueueAge")}
${fnSource("startQueueClock")}
return { renderQueuePanel, paintQueueAge, ageNode: () => queueAgeNode };`,
  );
  const m = factory(
    doc,
    (id) => {
      assert.equal(id, "conv-queue", "送信待ちの面が別の器を掴んでいる");
      return box;
    },
    queueView,
    clearQueue,
    { now: () => nowMs },
    (fn, ms) => { ticks.push({ fn, ms }); return ticks.length; },
  );
  return {
    box, ticks,
    ageNode: m.ageNode,
    advance: (ms) => { nowMs += ms; },
    // 既存の検査は時刻を渡さない ―― 台が「今取れた」を既定にする(applyPoll と同じ形)。
    render: (d, fetchedAtMs) => m.renderQueuePanel(d, fetchedAtMs === undefined ? nowMs : fetchedAtMs),
    tick: () => { for (const t of ticks) t.fn(); },
  };
}

const queueBtn = (box) => box.children.find((n) => n.tag === "button");

test("★実行: 送信待ちが在れば、数の文と取り消しのボタンが1つだけ出る", () => {
  const { render, box } = mountQueue(() => {});
  render({ route: "worker", queued: 2, items: [] });
  const texts = box.children.filter((n) => n.tag === "div").map((n) => n.textContent);
  assert.deepEqual(texts, ["2 queued (not yet handed to Claude)", "As of 0s ago"]);
  const b = queueBtn(box);
  assert.ok(b, "取り消しのボタンが出ていない");
  assert.equal(b.textContent, "Cancel 2 queued");
  assert.equal(b.type, "button", "form に包まれた時に入力欄の Enter で発火する");
  assert.equal(box.children.filter((n) => n.tag === "button").length, 1);
});

test("★実行: 0 件になったら面を消す(空になった事も見せる仕事のうち)", () => {
  const { render, box } = mountQueue(() => { throw new Error("消えた筈の物が押された"); });
  render({ route: "worker", queued: 2 });
  assert.ok(box.children.length > 0);
  render({ route: "worker", queued: 0 });
  assert.deepEqual(box.children, [], "行列が捌けたのに古い数が残っている");
});

test("★★実行: 机の会話(`queued:null`)には何も出さない ―― 数を観測していない", () => {
  // 出すと「送信待ち null 件」や「0 件」になる = 観測していない事の反対を電話が断定する。
  const { render, box } = mountQueue(() => { throw new Error("出ない筈の物が押された"); });
  render({ route: "tmux", queued: null, screen: { screen: "IDLE" } });
  assert.deepEqual(box.children, []);
  render({ route: "worker" });          // 欄そのものが無い応答(古いサーバ)
  assert.deepEqual(box.children, []);
  render(null);                          // 会話を開き直した時の初期化
  assert.deepEqual(box.children, []);
  // ★恒真でない事の担保(2026-08-05)。上は全部「何も出ない」しか主張していないので、
  //   `render` が何もしない実装でも満点になる。出る筈の入力を1つ通して、この検査が
  //   **出る/出ないを分けている**事を同じ検査の中で見せる。
  render({ route: "worker", queued: 3 });
  assert.notDeepEqual(box.children, [],
    "出る筈の入力でも空 = この検査は『何も出ない』を測れていない(render が死んでいる)");
});

test("★実行: 押すと、送信より**前**に同期でボタンが伏せられ、取り消しが1回だけ呼ばれる", () => {
  let seenDisabled = null;
  let calls = 0;
  const { render, box } = mountQueue(() => { calls++; seenDisabled = queueBtn(box).disabled; });
  render({ route: "worker", queued: 3 });
  const b = queueBtn(box);
  assert.equal(b.disabled, false);
  b.tap();
  assert.equal(calls, 1);
  assert.equal(seenDisabled, true, "送信の時点でまだ押せる = 同じ物を2回捨てに行ける");
});

test("★実行: 押した数を電話が自分で減らさない(サーバが載せた数をそのまま出す)", () => {
  // 減らすと、409 で断られた時に「0 件」と出たまま実際は積まれている、が起きる。
  const { render, box } = mountQueue(() => {});
  render({ route: "worker", queued: 2 });
  queueBtn(box).tap();
  assert.equal(box.children.filter((n) => n.tag === "div")[0].textContent,
    "2 queued (not yet handed to Claude)", "押しただけで表示上の数が動いている");
});

test("★陰性対照: 偽 DOM が送信待ちの面でも差を見分けるか(常に緑ではない事)", () => {
  const calls = [];
  const { render, box } = mountQueue(() => calls.push("tap"));
  render({ route: "worker", queued: 1 });
  assert.ok(box.children.length >= 2, "偽 DOM に節点が積まれていない = 何も測れていない");
  queueBtn(box).tap();
  assert.deepEqual(calls, ["tap"], "押下が呼び手に届いていない = 上の押下検査は空振り");
});

test("clearQueue が /queue へ DELETE を送り、判定を view.mjs に置いている(静的)", () => {
  const src = fnSource("clearQueue");
  assert.match(src, /\/queue`/, "取り消しの宛先が /queue ではない");
  assert.match(src, /method:\s*"DELETE"/, "DELETE で撃っていない");
  assert.match(src, /clearQueueResult\(r\.status,\s*body\)/, "判定を view.mjs に置いていない");
  // ★取り消した直後に自分で poll を撃ち直さない。サーバが `user_dropped` を出す =
  //   保留中の poll が起きて次の描画で本当の数になる。撃ち直しは二重の描画を生むだけ。
  const bodyOnly = src.slice(src.indexOf("{") + 1);
  assert.doesNotMatch(bodyOnly, /renderQueuePanel\s*\(/, "応答から画面の数を作っている");
});

test("★applyPoll は毎回この面を描き直し、観測の時刻をその場で取る", () => {
  // 条件を付けると、行列が空になった時に面が消えない = 捌けた送信が待っている様に見える。
  // ★時刻も此処で取る。応答が届いて適用する瞬間が、この数を観測した瞬間 ——
  //   固定値や「開いた時刻」を渡すと、古さの行が**永遠に新しい**か**最初から古い**になる。
  const src = fnSource("applyPoll");
  assert.match(src, /\n  renderQueuePanel\(d, Date\.now\(\)\);/,
    "renderQueuePanel の呼び出しが applyPoll の最上層に無い、または観測の時刻を渡していない");
});

// ---- 送信待ちの数の**古さ**(2026-08-04)--------------------------------------
//
// この面は poll が返った時にしか描き直されない = **返らなくなった時**に「送信待ち 2 件」を
// 現在形で出し続ける。一覧(`paintListAge`)と同じ作法で、手元の時計だけで古さを刻む。

test("★実行: 数の隣に「いつ測った値か」が出る(取れた直後は古くない)", () => {
  const q = mountQueue(() => {});
  q.render({ route: "worker", queued: 2 });
  const age = q.ageNode();
  assert.ok(age, "古さの節点が出ていない");
  assert.ok(q.box.children.includes(age), "古さの節点が面に入っていない");
  assert.equal(age.textContent, "As of 0s ago");
  assert.equal(age.className, "queue-age muted", "取れた直後なのに古い印が付いている");
});

test("★★実行: 網を叩かず、時計が進んだだけで古い印が付く", () => {
  // これが直したかった穴そのもの。poll が返らなくなった時、面は描き直されない ——
  // 古さを刻む口が此処に無いと、電話は 20 分前の数を現在形で出し続ける。
  const q = mountQueue(() => {});
  q.render({ route: "worker", queued: 2 });
  q.advance(90_000);
  q.tick();
  assert.match(q.ageNode().textContent, /As of 1m ago/, "時計が進んでも文面が古いままになっていない");
  assert.equal(q.ageNode().className, "queue-age muted stale", "古い印(色)が付いていない");
  // ★数そのものは動かさない。古いのは**いつ測ったか**であって、値の書き換えではない。
  assert.equal(q.box.children[0].textContent, "2 queued (not yet handed to Claude)",
    "電話が自分で数を書き換えている");
});

test("★実行: 時計は面を描き直すたびに増えない(1本だけ・1秒毎)", () => {
  const q = mountQueue(() => {});
  q.render({ route: "worker", queued: 2 });
  q.render({ route: "worker", queued: 3 });
  q.render({ route: "worker", queued: 1 });
  assert.equal(q.ticks.length, 1, `時計が ${q.ticks.length} 本立っている(描画のたびに増えている)`);
  assert.equal(q.ticks[0].ms, 1000);
});

test("★実行: 面を消したら、時計は外れた節点を描き直さない", () => {
  const q = mountQueue(() => {});
  q.render({ route: "worker", queued: 2 });
  const orphan = q.ageNode();
  // ★文面を決め打ちしない。此処が測るのは「時計が外れた節点を触らない」の**一点**で、
  //   初回の描画がどう見えるかは別の検査の持ち物。決め打ちすると、初回描画を壊した変異が
  //   此処を赤にして、名乗っている主張と赤くなった理由がずれる。
  const before = orphan.textContent;
  q.render({ route: "worker", queued: 0 }); // 行列が捌けた = 面ごと消える
  assert.equal(q.ageNode(), null, "面を消したのに古さの節点への参照が残っている");
  q.advance(600_000);
  q.tick();
  assert.equal(orphan.textContent, before, "画面から外れた節点を時計が描き直している");
});

test("★★実行: 時計が刻んでも、伏せたボタンは戻らない(面ごと描き直していない)", () => {
  // 古さを `renderQueuePanel` の再実行で更新すると、押した直後に節点が作り直され、
  // `disabled` が外れて**同じ物を2回捨てに行ける**。塗るのは古さの節点だけ。
  const q = mountQueue(() => {});
  q.render({ route: "worker", queued: 2 });
  const b = queueBtn(q.box);
  b.tap();
  assert.equal(b.disabled, true);
  q.advance(90_000);
  q.tick();
  assert.equal(queueBtn(q.box), b, "時計が面を作り直している(節点が別物になっている)");
  assert.equal(queueBtn(q.box).disabled, true, "伏せたボタンが戻っている");
});

test("★静的: 古さを刻む時計は網を叩かず、判定を app.html に手書きしない", () => {
  const paint = fnSource("paintQueueAge");
  const clock = fnSource("startQueueClock");
  assert.doesNotMatch(paint + clock, /fetch\(|\bapi\(/,
    "1秒毎に相手を殴りに行っている(古さは手元の時計で刻む)");
  assert.match(paint, /queueView\(/, "古さの判定が view.mjs に無い");
  assert.doesNotMatch(paint, /\d{2,}/, "60 秒の境目が二つ目の実装として app.html に生えている");
});

test("★静的: 会話を開き直す時、数と一緒に観測の時刻も 0 に戻す", () => {
  // 残すと、次の会話の最初の数が**前の会話を測った時刻**を名乗る。
  assert.match(fnSource("openConv"), /renderQueuePanel\(null,\s*0\)/,
    "開き直しで観測の時刻を捨てていない");
});
