#!/usr/bin/env node
/**
 * `esc to interrupt` は **statusLine を足した起動でも出るのか**を2本並べて測る。
 *
 * なぜ要るか(2026-08-03): 8/03 未明に「生成中 62/62 枚で footer に出る」と実測して
 * 割り込みの判定材料をこれに替えた。**その測定は素の `claude` で撮っていた**。
 * 電話が触るのは `rc-claude`(= statusLine を1つ足すラッパ)で起動した会話だけなので、
 * 現場の構成では一度も測っていなかった。実際 `live-http-check` を現場構成で回すと
 * 15 秒・約38枚のうち **画面のどこにも 0 枚**。今夜4度目の同じ形
 * (家で撮った画面で現場の判定を決める)なので、ここで両腕を並べて決める。
 *
 * 測り方: 同じ機械・同じ大きさ(120x40)・同じ本文で、起動する実行ファイルだけ変える。
 *   arm A = `claude`      (statusLine 無し = 8/03 未明に測った構成)
 *   arm B = `rc-claude`   (statusLine 有り = 電話が実際に触る構成)
 * 生成が始まってから 20 秒、250ms ごとに撮って数える:
 *   anywhere = 画面のどこかに `esc to interrupt` が在った枚数
 *   footer   = 末尾3行に在った枚数(= 出荷中の `inFlightHintIn` が真になる枚数)
 *   spinner  = 出荷中のスピナー規則が真になる枚数(旧材料の対照)
 *   done     = 完了行(`✻ … for Ns` の過去形)が出た時刻 = 生成が終わった印
 *
 * 約束: 使い捨てセッション名 `rc-hint-<数字>` しか作らない / 片付けで不在を確認する /
 *       画面本文は出さない(数だけ)。footer の形を出す時はメールを伏せる。
 *
 * 使い方: node tools/hint-statusline-control.mjs [--cwd DIR] [--secs 20]
 */
import { execFileSync } from "node:child_process";
import { inFlightHintIn } from "../src/inject.mjs";

const TMUX = "/opt/homebrew/bin/tmux";
const argv = process.argv.slice(2);
const opt = { cwd: "/Users/edith/Projects", secs: 20 };
for (let i = 0; i < argv.length; i++) {
  if (argv[i] === "--cwd") opt.cwd = argv[++i];
  else if (argv[i] === "--secs") opt.secs = Number(argv[++i]);
}

const tmux = (a) => execFileSync(TMUX, a, { encoding: "utf8" });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const mask = (s) => s.replace(/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g, "<mail>");

// 出荷中のスピナー規則をここに写さない為、inject.mjs から間接的に測る。
// (写すと、本体が規則を変えた時にこの計器だけが古い規則を喋る)
const SPINNER = /[✳✻✽✶✢·*]\s*\S+…/;

const PROBE = "秒という単位の歴史を 600 字程度の平文で書いて。箇条書きにしないで。";

/** 1本測る。bin = claude | rc-claude */
async function arm(bin) {
  const session = `rc-hint-${Date.now()}${Math.floor(process.hrtime()[1] % 1000)}`;
  const out = { bin, session, anywhere: 0, footer: 0, spinner: 0, frames: 0, doneAt: null, footerSample: "", err: null };
  try {
    tmux(["new-session", "-d", "-s", session, "-x", "120", "-y", "40", "-c", opt.cwd]);
    const pane = tmux(["list-panes", "-t", `=${session}`, "-F", "#{pane_id}"]).trim().split("\n")[0];
    const cap = () => tmux(["capture-pane", "-t", pane, "-p"]);

    tmux(["send-keys", "-t", pane, "-l", "--", bin]);
    tmux(["send-keys", "-t", pane, "Enter"]);

    // 入力欄が出るまで待つ(最大 90 秒)
    const t0 = Date.now();
    for (;;) {
      if (/^\s*❯/m.test(cap())) break;
      if (Date.now() - t0 > 90_000) throw new Error("90 秒で入力欄が出ない");
      await sleep(500);
    }
    // 起動直後の footer の形を控える(ここで両腕の違いが見える)
    out.bootFooter = cap().trimEnd().split("\n").filter((l) => l.trim()).slice(-3).map(mask);

    tmux(["send-keys", "-t", pane, "-l", "--", PROBE]);
    await sleep(300);
    tmux(["send-keys", "-t", pane, "Enter"]);

    const t1 = Date.now();
    while (Date.now() - t1 < opt.secs * 1000) {
      const t = cap();
      out.frames++;
      if (/esc to interrupt/.test(t)) out.anywhere++;
      if (inFlightHintIn(t)) out.footer++;
      if (t.split("\n").some((l) => SPINNER.test(l))) out.spinner++;
      if (out.anywhere > 0 && !out.footerSample) {
        out.footerSample = t.trimEnd().split("\n").filter((l) => l.trim()).slice(-3).map(mask).join("\n");
      }
      if (out.doneAt === null && /[✳✻✽✶✢]\s+\w+ for \d+s/.test(t)) out.doneAt = Date.now() - t1;
      await sleep(250);
    }
    if (!out.footerSample) {
      out.footerSample = cap().trimEnd().split("\n").filter((l) => l.trim()).slice(-3).map(mask).join("\n");
    }
  } catch (e) {
    out.err = e.message;
  } finally {
    try { tmux(["kill-session", "-t", `=${session}`]); } catch { /* 既に無い */ }
    let gone = false;
    try { tmux(["has-session", "-t", `=${session}`]); } catch { gone = true; }
    out.cleaned = gone;
  }
  return out;
}

const rows = [];
for (const bin of ["claude", "rc-claude"]) {
  const r = await arm(bin);
  rows.push(r);
  console.log(`\n== ${bin} ==============================================`);
  if (r.err) console.log(`  ★落ちた: ${r.err}`);
  console.log(`  起動直後の footer:`);
  for (const l of r.bootFooter || []) console.log(`    | ${l}`);
  console.log(`  枠 ${r.frames} / どこかに esc to interrupt ${r.anywhere} / 末尾3行に ${r.footer} / スピナー ${r.spinner}`);
  console.log(`  完了行が出た時刻: ${r.doneAt === null ? "この窓では出ず(まだ生成中)" : `${r.doneAt}ms`}`);
  console.log(`  その時の末尾3行:`);
  for (const l of r.footerSample.split("\n")) console.log(`    | ${l}`);
  console.log(`  片付け: ${r.cleaned ? "不在を確認" : "★残っている"}`);
}

const a = rows[0];
const b = rows[1];
console.log(`\n== 判定 ==============================================`);
if (a.anywhere > 0 && b.anywhere === 0) {
  console.log("★statusLine を足すと `esc to interrupt` が消える。現場(rc-claude)で判定材料に使えない。");
} else if (a.anywhere > 0 && b.anywhere > 0) {
  console.log("両腕で出る。statusLine は無関係 = live-http-check の 0 は別の理由。");
} else if (a.anywhere === 0) {
  console.log("★素の claude でも出ない。8/03 未明の 62/62 が再現しない = 測り方が違う。");
}
process.exit(rows.some((r) => r.err || !r.cleaned) ? 1 : 0);
