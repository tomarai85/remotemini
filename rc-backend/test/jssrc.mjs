/**
 * JS の原文を読む検査が共有する道具。`swiftsrc.mjs` の JS 版。
 *
 * ★何故 module にしたか(2026-08-08、S8-24)。此処に在るのは元々
 * `reqlog.test.mjs` の中の関数で、`view.mjs` の builder 本文を読む検査を書いた時に
 * **同じ物を2本目として書きかけた**。写しを持って照合しない形は、この一連の commit
 * (S8-19〜S8-23) が潰して回っている型そのものなので、書き写す代わりに1本へ寄せた。
 *
 * ★実装は**一字も変えずに動かした**。書き直して strict にすると、元の呼び手
 * (`reqlog.test.mjs`) の緑が「今まで通り」なのか「新しい実装で偶々」なのか
 * 分からなくなる。強くするなら別の commit で、赤を1度見てからにする。
 */

/**
 * 注釈を落とす。**検査は散文ではなく実装を読む**。
 *
 * ★これを書く羽目になった経緯を残す: 最初は生の本文を走査していて、`LOG_PATHS` に付けた
 *   自分の注釈(「`path === "…"` を読んで突き合わせる」)を**振り分けとして拾い**、
 *   `…` という道が実在する事になって落ちた。検査が自分の説明文に当たる形は、
 *   直さないと「説明を書き足すと赤くなる」検査になる。
 *
 * ★限界(2026-08-08 に明記): 正規表現1本なので、文字列の中の `/*` や正規表現
 *   literal の中の `//` は見分けられない。`[^:]` の番人が効くのは `http://` の形だけ。
 *   読ませる前に、対象の本文がその形を含まない事を確かめるのは呼び手の仕事。
 */
export function stripComments(src) {
  return src
    .replace(/\/\*[\s\S]*?\*\//g, "")
    .replace(/(^|[^:])\/\/.*$/gm, "$1");
}

/**
 * `開始文字列` の直後の `{` から対応する `}` までを取る(行数窓は隣の節へ漏れる)。
 * 見付からなければ `null`。**呼び手は必ず null を赤にする** —— 見付からないのは
 * 「その書き方が消えた」合図で、検査が黙って0件になってよい理由ではない。
 */
export function blockAfter(src, marker) {
  const i = src.indexOf(marker);
  if (i === -1) return null;
  const rest = src.slice(i + marker.length);
  const open = rest.indexOf("{");
  if (open === -1) return null;
  let depth = 0;
  for (let k = open; k < rest.length; k++) {
    if (rest[k] === "{") depth++;
    else if (rest[k] === "}" && --depth === 0) return rest.slice(open, k + 1);
  }
  return null;
}
