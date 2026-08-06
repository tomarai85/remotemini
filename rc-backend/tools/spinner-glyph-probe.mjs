#!/usr/bin/env node
// no-control: 実機計器。字面を撮るだけで、期待値を持たない(対照ではない)
/**
 * 生成中の**進行行そのものを字面で撮る**。規則を当てず、見えている物を出す。
 *
 * なぜ要るか(2026-08-03): `rc-claude` で生成中 55 枠を測ったら、出荷中の
 * `classifyScreen()` が立てた枠は **0**。ところが同じ構成を別の(広い)正規表現で測った
 * 計器は 76 枠中 43 で当てている。つまり進行行は**在るのに出荷中の規則が当たっていない**
 * 疑いが濃い。両者の差は先頭記号の集合だけ:
 *     出荷中 IN_FLIGHT = /[✻✽✢✶✳][^\n]*…/
 *     計器の SPINNER   = /[✳✻✽✶✢·*]\s*\S+…/   ← `·` と `*` を含む
 * Claude Code のスピナーは何コマかのアニメーションなので、**出荷中の規則がコマの一部しか
 * 覆っていない**なら、DESIGN の M3「31% しか見えない = tmux のヒント文が行を占拠」という
 * 診断自体が違う事になる(症状は同じ、原因が別)。
 *
 * よってここでは規則を一切当てず、進行行の候補を**そのまま**出す:
 *   - `…` を含む行(スピナーは必ず `…` を持つ)
 *   - 入力欄の枠の直上3行
 * 記号は Unicode の符号位置で出す(端末で潰れて見分けが付かない為)。
 *
 * 約束: 使い捨てセッション `rc-glyph-<数字>` のみ / 片付けで不在を確認 / メールは伏せる。
 */
import { execFileSync } from "node:child_process";

const TMUX = "/opt/homebrew/bin/tmux";
const CWD = "/Users/edith/Projects";
const BIN = process.argv[2] || "rc-claude";
const SHOTS = 8;
const STEP_MS = 400;

const tmux = (a) => execFileSync(TMUX, a, { encoding: "utf8" });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const mask = (s) => s.replace(/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g, "<mail>");
const cp = (s) => [...s].slice(0, 3).map((c) => `U+${c.codePointAt(0).toString(16).toUpperCase().padStart(4, "0")}`).join(" ");
const PROBE = "秒という単位の歴史を 1200 字程度の平文で書いて。箇条書きにしないで。";

const session = `rc-glyph-${Date.now()}${process.hrtime()[1] % 1000}`;
let cleaned = false;
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

  console.log(`起動 = ${BIN} / 120x40 / ${CWD}`);
  const t0 = Date.now();
  for (let i = 0; i < SHOTS; i++) {
    await sleep(STEP_MS);
    const lines = cap().split("\n");
    const ell = lines.map((l, n) => [n, l]).filter(([, l]) => l.includes("…"));
    const div = lines.findIndex((l) => /^─{20,}/.test(l.trim()));
    console.log(`\n[${Date.now() - t0}ms] \`…\` を含む行 ${ell.length} 本`);
    for (const [n, l] of ell.slice(0, 4)) {
      const t = l.trim();
      console.log(`  行${n}: ${cp(t)} | ${mask(t).slice(0, 100)}`);
    }
    if (div > 0) {
      console.log(`  枠の直上3行:`);
      for (const l of lines.slice(Math.max(0, div - 3), div)) {
        const t = l.trim();
        if (t) console.log(`    ${cp(t)} | ${mask(t).slice(0, 100)}`);
      }
    }
  }
} catch (e) {
  console.log(`★落ちた: ${e.message}`);
} finally {
  try { tmux(["kill-session", "-t", `=${session}`]); } catch { /* 既に無い */ }
  try { tmux(["has-session", "-t", `=${session}`]); } catch { cleaned = true; }
  console.log(`\n片付け: ${cleaned ? "不在を確認" : "★残っている"}`);
}
