// 木の**外**を見る検査を、rc-backend だけの写しでも走れる形にする。
//
// ── なぜ要るか(2026-08-06、実際に踏んだ。しかも一番痛い所で)─────────────────
// `test/mutation-controls.py` は rc-backend **だけ**を temp へ写し、その写しで
// `npm test` を回す。走行の最初に立てる対照1(無変異の木は緑)がそれで、ここが
// 落ちると台本は `die()` する = **変異が1件も回らない**。単体スイートは変異走行の
// 判定器なので、「写しで回る」はスイートの機能要件である(`copied-tree-controls.sh`)。
//
// この日 `0326609` で足した2本が、木の外を**無条件に**読んでいた:
//   `test/fixture-reader-declared.test.mjs`   → ios/Sources/** を走査
//   `test/mutation-recovery-copy.test.mjs`    → ios/ と .harness/ の対照2本を読む
// 手元では 687/687 緑。写しには ios も .harness も居ないので、そこでだけ 6 本が赤。
// 更に `4f3b474` で私が裸の引用を1つ足して 7 本になった(`no-linerefs.test.mjs`)。
//
// 実測(git の object から写しを起こして再現):
//   135fdca = 681 件 / fail 0     ← 0326609 の親
//   0326609 = 687 件 / fail 6
//   4f3b474 = 687 件 / fail 7
// → `0326609` を積んだ 19 時台から、この repo の判定器は**丸ごと死んでいた**。
//
// ★ commit の門はこれを構造的に見られない。門が回すのは完全な木の `npm test` で、
//   そこでは ios が在るので全部緑になる。写しの形を踏むのは定期掃きの
//   `mutation-freeze-controls.sh` と `copied-tree-controls.sh` だけで、事実その2本が
//   赤くなった。**緑の出所(どの木で回したか)を言わない緑は、緑ではない。**
//
// ── 契約 ────────────────────────────────────────────────────────────────
// 木の外の対象は3通りに分かれる。**赤・緑の2値に丸めない**のが肝:
//   在る               → 測る(skip=false)
//   無い + 親が欠け    → 部分木の写し。**測っていない**と名乗って飛ばす(赤にしない)
//   無い + 親は健在    → 改名/削除。これは赤で正しい(skip=false のまま本体で落とす)
// 3つ目を2つ目に混ぜると、改名を黙って飲む逃げ道になる。だから親の健在は
// `DESIGN.md` の実在だけで判定する(`no-linerefs.test.mjs` と同じ目印)。
//
// ── 飛ばしを黙らせない ──────────────────────────────────────────────────
// 飛ばす時は node:test の `{ skip: "理由" }` を使う。TAP に理由ごと出て `# skipped` が
// 増えるので、写しで回した対照(`copied-tree-controls.sh`)がその件数を緑の文言に載せる。
// 加えて各 file は「この木では逃げ道を通っていない」錨を1本持つ —— 此処が壊れて
// 常に飛ばす様になったら、完全な木でその錨が赤くなる。
//
// ── 取らなかった道: `git ls-files` で親の健在を測る ────────────────────────
// 先例が repo 内に在る。`test/doc-linerefs.test.mjs` は自分自身の path を
// `git -C <親> ls-files --error-unmatch` に掛けて、通れば親が本物と見なす。述語としては
// `DESIGN.md` の実在より強い —— 写しで偽になるのは勿論、**別件の repo の中に置かれた
// 写し**(親が git の木では在るが此の repo ではない)でも偽になる。
// それでも採らなかった理由は2つ:
//   ① 追跡されていない新しい test file は、書いた瞬間に黙って飛ぶ。検査を足した当日が
//      一番壊しやすい時機なのに、そこだけ測らない形になる(commit すれば直る、という
//      のは「commit するまで守られない」と同義)。
//   ② 目印が2種類になると、飛んだ TAP を読んだ人が「どの種類の写しなのか」を
//      判定できなくなる。`no-linerefs.test.mjs` が既に `DESIGN.md` を目印に採っており、
//      この repo では此れが写し判定の標準になっている。
// 残る穴を明記しておく: **親が別件の repo で、かつ其処に `DESIGN.md` が在る**場合、
// 此の module は「親は健在」と読んで赤にする。2026-08-05 の実測では edith の home に
// `DESIGN.md` は無く、この repo の写しは全部 `rc-backend/` 単位なので現に踏まない。
// 踏む形(親に `DESIGN.md` を持つ別 repo の下へ写す)が現れたら、①を飲んで
// `git ls-files` 側へ寄せる。`copied-tree-controls.sh` の対照④が丁度その形
// (別件の repo を親にした写し)を立てているので、変えた日は其処が判定の場になる。
import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

export const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
export const REPO = dirname(ROOT);

/** 親が本物の repo か(= 写しではないか)。目印は書類1本の実在だけ。 */
export const REPO_INTACT = existsSync(join(REPO, "DESIGN.md"));

/**
 * 木の外に在る対象を要求する。
 *
 * @param {string[]} rels  REPO からの相対 path(dir でも file でもよい)
 * @param {{repo?: string, intact?: boolean}} opts  対照から差し替える為だけの口
 * @returns {{skip: false|string, missing: string[], measured: boolean}}
 *   skip=false  → 検査を回す(全部在る / 親は健在なのに欠けている=赤にすべき)
 *   skip=文字列 → 部分木の写しなので測らない。文字列は TAP に出る理由
 */
export function requireOutside(rels, opts = {}) {
    const repo = opts.repo ?? REPO;
    const intact = opts.intact ?? existsSync(join(repo, "DESIGN.md"));
    const missing = rels.filter((r) => !existsSync(join(repo, r)));
    if (missing.length === 0) return { skip: false, missing, measured: true };
    if (intact) return { skip: false, missing, measured: true };
    return {
        skip: `部分木の写し(rc-backend だけ)なので測っていない: ${missing.join(" ")}`,
        missing,
        measured: false,
    };
}
