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
  assert.equal(nulls.length, 3, "send() / interrupt() / sendChoice() の3箇所が null を渡している");
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

test("★判断を HTML 側に書き戻していない(移した関数名が定義として復活していない)", () => {
  // 「引き剥がした」を主張し続けられる様にする関門。同名の関数を app.html に
  // 定義し直すと import は死に文になり、検査は view.mjs の方を測り続ける =
  // **緑のまま実物と乖離する**。名前が戻ってきた時点で赤にする。
  const moved = ["scanLine", "whoOf", "gapNotice", "nextAttempt", "nextHistoryLimit",
                 "sendResult", "interruptResult", "mergeHistory", "routeLabel", "subtitleOf", "relTime",
                 "freshness", "readablePoll"];
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
import { choiceView } from "../src/view.mjs";

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
    "1. Opus 5", "2. Sonnet 5", "3. Haiku 4.5", "Enter(2. Sonnet 5 で決定)", "Escape",
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
  assert.ok(why && /許可・信頼の確認/.test(why.textContent), "断る理由が画面に出ていない");
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
