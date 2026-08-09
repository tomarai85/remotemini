/**
 * Swift の原文を読む検査が共有する道具。
 *
 * ★何故 module にしたか(2026-08-08、S8-24)。此処に在るのは元々
 * `fixture-labels-producible.test.mjs` の中の関数で、新しく Swift を読む検査を
 * 書いた時に**同じ物を2本目として書きかけた**。写しを持って照合しない形は、
 * この一連の commit (S8-19〜S8-23) が潰して回っている型そのものなので、
 * 書き写す代わりに1本へ寄せた。読む側が増えたら import を足すだけにする。
 */
import { readdirSync, statSync } from "node:fs";
import { join } from "node:path";

/**
 * Swift の注釈(行注釈と塊注釈の両方)を落とす。文字列の中の `//` は落とさない。
 *
 * ★これが要る理由(2026-08-08、実測)。呼び手の検査は UI 検査の本体から
 * `staticTexts["…"]` を数える。UI 検査の側に「此処は `staticTexts["…"]` を
 * 突き合わせている」と**説明を書いた瞬間に3本になって赤が出た** —— 注釈は
 * 画面に何も出さないのに、検査からは主張と見分けが付かない。
 * 直し方を「注釈の書き方を変える」にすると、次に書く人が同じ罠を踏む。
 *
 * `"""` の複数行文字列は扱わない(読んでいる Swift file には無い)。増えたら
 * 此処が壊れるので、その時に足す。
 */
/**
 * `dir` の下の `.swift` を名前順で全部拾う。
 *
 * ★2本目を書く直前に此処へ移した(2026-08-09、S8-26 phase 3)。元は
 * `wire-key-agreement.test.mjs` の中の局所関数で、語彙の検査を書き始めた時に
 * **同じ物を書き写しかけた** —— この module の冒頭が書いている失敗の2度目。
 * 走査の順序が2本で違うと、赤の出方まで木ごとに変わる。
 */
export function swiftFiles(dir, out = []) {
  for (const e of readdirSync(dir).sort()) {
    const p = join(dir, e);
    if (statSync(p).isDirectory()) swiftFiles(p, out);
    else if (e.endsWith(".swift")) out.push(p);
  }
  return out;
}

export function stripSwiftComments(src) {
  let out = "";
  let i = 0;
  let inStr = false;
  while (i < src.length) {
    const ch = src[i];
    const nx = src[i + 1];
    if (inStr) {
      out += ch;
      if (ch === "\\") { out += nx ?? ""; i += 2; continue; }
      if (ch === '"') inStr = false;
      i++;
      continue;
    }
    if (ch === '"') { inStr = true; out += ch; i++; continue; }
    if (ch === "/" && nx === "/") {
      while (i < src.length && src[i] !== "\n") i++;
      continue;
    }
    if (ch === "/" && nx === "*") {
      i += 2;
      while (i < src.length && !(src[i] === "*" && src[i + 1] === "/")) i++;
      i += 2;
      continue;
    }
    out += ch;
    i++;
  }
  return out;
}
