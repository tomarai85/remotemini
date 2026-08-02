#!/usr/bin/env node
/**
 * `rc-claude`(= 現場の構成)で、**生成中と停止をどの印で判れるか**を実測する。
 *
 * 直前に分かった事(tools/hint-statusline-control.mjs、同じ機械で両腕):
 *   claude    枠75 / どこかに `esc to interrupt` 39 / 末尾3行に 39 / スピナー 39
 *   rc-claude 枠76 / どこかに `esc to interrupt`  0 / 末尾3行に  0 / スピナー 43
 * = statusLine を足すと footer の印が消える。電話が触るのは rc-claude だけなので、
 * 出荷中の `interrupt()` の事前判定(`inFlightHintIn` 単独)は**本番で一度も真にならない**。
 * 残った材料はスピナーだが 43/76 = 57% の間欠信号で、そのまま入れ替えると
 * 「止まった」の誤報を作る(生成中でも消えて見える枠が在る)。
 *
 * よってこの計器が答えるのは3つ:
 *   A 生成中、スピナーが**連続して何枚消える**か(= 事前判定・停止判定の閾値の根拠)
 *   B Escape の後、何 ms で消え、消えた後に**戻る**か(戻るなら absence は停止の証拠にならない)
 *   C 割り込んだ画面に、自然完了と**区別できる積極的な印**が在るか
 *     (在れば「止めた」を absence でなく presence で言える = 誤報の向きが逆になる)
 *
 * C の為に対照を2本立てる: 壊す方向 = Escape を押す / 伸ばす方向 = 最後まで走らせる。
 * 片方だけ見ると「割り込みの印」と「終了の印」を取り違える。
 *
 * 規則は写さず `classifyScreen()` から間接的に測る。写すと本体が規則を変えた時に
 * この計器だけが古い規則を喋る。
 *
 * 約束: 使い捨てセッション名 `rc-uf-<数字>` しか作らない / 片付けで不在を確認する /
 *       画面を出す時はメールを伏せる。
 *
 * 使い方: node tools/inflight-under-statusline.mjs [--gen-ms 9000] [--after-ms 6000]
 */
import { execFileSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { classifyScreen } from "../src/inject.mjs";

// 実物の画面を fixture として持ち帰る為の置き場(使い捨て)。
const OUT = mkdtempSync(join(tmpdir(), "rc-uf-"));

const TMUX = "/opt/homebrew/bin/tmux";
const BIN = "rc-claude"; // ★素の claude は測らない。現場の構成だけを測る為の計器
const CWD = "/Users/edith/Projects";
const STEP_MS = 150;

const argv = process.argv.slice(2);
const opt = { genMs: 9000, afterMs: 6000 };
for (let i = 0; i < argv.length; i++) {
  if (argv[i] === "--gen-ms") opt.genMs = Number(argv[++i]);
  else if (argv[i] === "--after-ms") opt.afterMs = Number(argv[++i]);
}

const tmux = (a) => execFileSync(TMUX, a, { encoding: "utf8" });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const mask = (s) => s.replace(/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g, "<mail>");
const PROBE = "秒という単位の歴史を 1200 字程度の平文で書いて。箇条書きにしないで。";
// 過去形の完了行(`✻ Brewed for 10s`)。`…` が無いのでスピナー規則には当たらない。
// ★動詞は ASCII とは限らない。実測で `✻ Sautéed for 16s` が出て `\w+` が当たらず、
//   この計器は「40 秒でも完了行が出ず」と嘘を報告した(画面には出ていた)。
const DONE_LINE = /[✳✻✽✶✢·]\s+\S+ for \d+s/;
// ★`…` の無い事は**その行**で見る。画面全体で見ていたら、起動時の release notes に
//   `…` が在るせいで完了行が永久に立たず、この計器は2回続けて「40 秒でも完了行が出ず」
//   と報告した(画面には `✻ Cooked for 19s` が出ていた)。狭い所で測るべき事を
//   広い所で測ると、当たらない検査は「無い」と報告する。
const doneLineIn = (t) => String(t || "").split("\n").some((l) => DONE_LINE.test(l) && !l.includes("…"));

/**
 * 印の在る枠を 1、無い枠を 0 にした列を、**頭・中・尻**に分けて数える。
 *
 * ★分ける理由(2026-08-03 に踏んだ): 最初の実測は「連続して消えた最長 13 枠」と出したが、
 * その 13 枠は Enter を押してから生成が始まるまでの**立ち上がり**だった可能性が高い
 * (撮った miss の1枚を開いたら、進行行が在るのではなく**行そのものが無い**画面だった)。
 * 立ち上がりの空白と、生成中に印だけ消える空白は、設計上まったく別物:
 *   頭の空白 → 押した直後に判定しなければ当たらない、というだけ
 *   中の空白 → 生成中でも印が消える = absence を停止の証拠に使えない
 * 一緒に数えると後者が在るように見える。max だけ出す計器は、この2つを潰していた。
 */
function gapProfile(seq) {
  const first = seq.indexOf(1);
  const last = seq.lastIndexOf(1);
  if (first < 0) return { lead: seq.length, inner: 0, tail: 0, none: true };
  let inner = 0;
  let cur = 0;
  for (let i = first; i <= last; i++) {
    if (seq[i]) cur = 0;
    else inner = Math.max(inner, ++cur);
  }
  return { lead: first, inner, tail: seq.length - 1 - last, none: false };
}

/**
 * 1本測る。
 * @param {"interrupt"|"finish"} mode interrupt = 途中で Escape / finish = 最後まで走らせる
 */
async function arm(mode) {
  const session = `rc-uf-${Date.now()}${process.hrtime()[1] % 1000}`;
  const out = { mode, session, err: null, during: [], after: [], tail: [], cleaned: false };
  try {
    tmux(["new-session", "-d", "-s", session, "-x", "120", "-y", "40", "-c", CWD]);
    const pane = tmux(["list-panes", "-t", `=${session}`, "-F", "#{pane_id}"]).trim().split("\n")[0];
    const cap = () => tmux(["capture-pane", "-t", pane, "-p"]);

    tmux(["send-keys", "-t", pane, "-l", "--", BIN]);
    tmux(["send-keys", "-t", pane, "Enter"]);
    const boot = Date.now();
    for (;;) {
      if (/^\s*❯/m.test(cap())) break;
      if (Date.now() - boot > 90_000) throw new Error("90 秒で入力欄が出ない");
      await sleep(500);
    }
    tmux(["send-keys", "-t", pane, "-l", "--", PROBE]);
    await sleep(300);
    tmux(["send-keys", "-t", pane, "Enter"]);

    // --- A: 生成中の間欠性 -------------------------------------------------
    const t0 = Date.now();
    let sawSpinner = false;
    while (Date.now() - t0 < opt.genMs) {
      const t = cap();
      const from = classifyScreen(t).activityFrom;
      if (from) sawSpinner = true;
      out.during.push({ ms: Date.now() - t0, from });
      // fixture 用: 規則が当たった枠と、当たらなかった枠を1枚ずつ実物で残す。
      // ★miss は**最初の hit より後**の物だけ撮る。前回それをせず、撮れた miss は
      //   「Enter 直後でまだ進行行が描かれていない」画面だった = 立ち上がりの空白であって、
      //   欲しかった「生成中なのに印が消えた」画面ではない。
      if (from && !out.shotHit) { out.shotHit = 1; writeFileSync(join(OUT, `${mode}-spinner-hit.txt`), t); }
      if (!from && out.shotHit && !out.shotMiss) { out.shotMiss = 1; writeFileSync(join(OUT, `${mode}-spinner-miss.txt`), t); }
      if (doneLineIn(t)) { out.finishedEarly = Date.now() - t0; break; }
      await sleep(STEP_MS);
    }
    out.sawSpinner = sawSpinner;

    // 割り込みの積極的な印。**押す前から在るか**を先に数える(在るなら増分でしか言えない)。
    out.markBefore = (cap().match(/Interrupted/g) || []).length;

    if (mode === "interrupt") {
      out.escapeAt = Date.now() - t0;
      tmux(["send-keys", "-t", pane, "Escape"]);
    }

    // --- B: Escape の後 / 最後まで ----------------------------------------
    const t1 = Date.now();
    const limit = mode === "interrupt" ? opt.afterMs : 40_000;
    while (Date.now() - t1 < limit) {
      const t = cap();
      const from = classifyScreen(t).activityFrom;
      out.after.push({ ms: Date.now() - t1, from });
      // 印が**増えた**最初の時刻。押す前から在った分は数に入れない。
      if (out.markAt === undefined && (t.match(/Interrupted/g) || []).length > out.markBefore) {
        out.markAt = Date.now() - t1;
      }
      if (mode === "finish" && doneLineIn(t)) { out.doneAt = Date.now() - t1; break; }
      await sleep(STEP_MS);
    }
    // 最後の画面(電話が「止まった」と言う時に見ている物)
    out.tail = cap().trimEnd().split("\n").filter((l) => l.trim()).slice(-10).map(mask);
    out.full = cap();
    writeFileSync(join(OUT, `${mode}-final.txt`), out.full);
  } catch (e) {
    out.err = e.message;
  } finally {
    try { tmux(["kill-session", "-t", `=${session}`]); } catch { /* 既に無い */ }
    try { tmux(["has-session", "-t", `=${session}`]); } catch { out.cleaned = true; }
  }
  return out;
}

function report(r) {
  console.log(`\n== ${r.mode === "interrupt" ? "壊す方向(Escape を押す)" : "伸ばす方向(最後まで走らせる)"} ===============`);
  if (r.err) { console.log(`  ★落ちた: ${r.err}`); return; }
  const seq = r.during.map((x) => (x.from ? 1 : 0));
  const hit = seq.filter(Boolean).length;
  const g = gapProfile(seq);
  console.log(`  生成中: 枠 ${seq.length} / 印の在った枠 ${hit}(${Math.round((hit / seq.length) * 100)}%）`);
  console.log(`    立ち上がり(最初の印まで) = ${g.lead} 枠 ≈ ${g.lead * STEP_MS}ms`);
  console.log(`    ★生成中に消えた最長(中) = ${g.inner} 枠 ≈ ${g.inner * STEP_MS}ms  ← absence を使えるかはこれで決まる`);
  console.log(`    尻(最後の印から窓の端まで) = ${g.tail} 枠 ≈ ${g.tail * STEP_MS}ms`);
  console.log(`    材料の内訳: ${[...new Set(r.during.map((x) => x.from || "なし"))].join(" / ")}`);
  if (r.finishedEarly) console.log(`    ★この窓の内に自然完了した(${r.finishedEarly}ms)= 生成が短すぎる`);

  const aseq = r.after.map((x) => (x.from ? 1 : 0));
  const firstGone = r.after.findIndex((x) => !x.from);
  const back = firstGone >= 0 ? r.after.slice(firstGone).findIndex((x) => x.from) : -1;
  if (r.mode === "interrupt") {
    console.log(`  Escape 後: 枠 ${aseq.length} / 印の在った枠 ${aseq.filter(Boolean).length}`);
    console.log(`    最初に消えた時刻 = ${firstGone < 0 ? "最後まで消えず" : `${r.after[firstGone].ms}ms`}`);
    console.log(`    消えた後に戻ったか = ${back > 0 ? `★戻った(${r.after[firstGone + back].ms}ms)` : "戻らない"}`);
    console.log(`    ★積極的な印 \`Interrupted\`: 押す前 ${r.markBefore} 本 / 増えた時刻 ` +
      `${r.markAt === undefined ? "★この窓では増えず" : `${r.markAt}ms`}`);
  } else {
    console.log(`    ★積極的な印 \`Interrupted\`: 押していないのに増えたか = ` +
      `${r.markAt === undefined ? "増えない(= 完了と割り込みを取り違えない)" : `★増えた(${r.markAt}ms)`}`);
    console.log(`  完了まで: ${r.doneAt === undefined ? "40 秒でも完了行が出ず" : `${r.doneAt}ms`}`);
  }
  console.log(`  最後の画面(末尾10行):`);
  for (const l of r.tail) console.log(`    | ${l}`);
  console.log(`  片付け: ${r.cleaned ? "不在を確認" : "★残っている"}`);
}

console.log(`実物の置き場: ${OUT}`);
const intr = await arm("interrupt");
report(intr);
const fin = await arm("finish");
report(fin);

// --- C: 割り込みだけに出る行を探す ------------------------------------------
console.log(`\n== 割り込み側にだけ在る行 ===============`);
if (intr.full && fin.full) {
  const finSet = new Set(fin.full.split("\n").map((l) => l.trim()).filter(Boolean));
  const only = intr.full.split("\n").map((l) => l.trim()).filter((l) => l && !finSet.has(l));
  // 本文(モデルの答え)は毎回違うので全部出る。印の候補になるのは短い定型行だけ。
  const cands = only.filter((l) => l.length <= 60 && !/^[|│>❯]/.test(l));
  if (cands.length === 0) console.log("  候補なし(= 積極的な印は見つからない。停止は absence でしか言えない)");
  for (const l of cands.slice(0, 12)) console.log(`    | ${mask(l)}`);
}
process.exit(intr.err || fin.err || !intr.cleaned || !fin.cleaned ? 1 : 0);
