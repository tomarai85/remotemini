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

test("★判断を HTML 側に書き戻していない(移した関数名が定義として復活していない)", () => {
  // 「引き剥がした」を主張し続けられる様にする関門。同名の関数を app.html に
  // 定義し直すと import は死に文になり、検査は view.mjs の方を測り続ける =
  // **緑のまま実物と乖離する**。名前が戻ってきた時点で赤にする。
  const moved = ["scanLine", "whoOf", "gapNotice", "nextAttempt", "nextHistoryLimit",
                 "sendResult", "interruptResult", "mergeHistory", "routeLabel", "subtitleOf", "relTime"];
  for (const n of moved) {
    const re = new RegExp(`(?:function|const|let|var)\\s+${n}\\b`);
    assert.ok(!re.test(SCRIPT), `${n} が app.html の中で再定義されている(import が死に文になる)`);
  }
});
