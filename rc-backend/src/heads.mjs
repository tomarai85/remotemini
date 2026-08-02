// 頭(head)の登録簿 — 「この会話を続けるには、今どのセッション ID へ `--resume` すればいいか」。
// DESIGN.md §2.18-4〜6。H2(同じ転写ファイルを2人で書く)の当ての片側。
//
// なぜ要るか: 既定の `--resume` は**元の ID を再利用する**ので、ワーカーと机の TUI が
// 同じ転写ファイルへ書く。だからワーカーは fork して自分の枝を持つ。すると2通目以降は
// 「祖先」ではなく**その枝の先端**へ resume しないといけない = その対応を持つのがここ。
//
// ★`~/.rc-backend/panes/`(ペイン登録簿)には置かない。あそこは書き手が別(statusline の
//   rc-backend ブロック)で、寿命も形も向こうが持っている。こちらが書けば所有者が2人になる。
//
// ★単一の `heads.json` は却下した。lost update を直す道具が read-modify-write で
//   lost update を作るのは筋が通らない。1会話1ファイルなら会話同士が最初から干渉せず、
//   書き込みの原子性は rename が持つ。
//
// ---
// ★倒す向き(§2.18-6、先に決めてある): **読めない時は分岐する。共有はしない。**
//
//   壊れている / 無い / 読めない を**区別せずに**全部「頭が無い」へ畳む。
//   区別する意味が無いからではない —— **区別できる形にすると、片方だけ resume 側へ
//   倒す実装が書けてしまう**から。resume 側へ倒れた時に起きるのは共有書き込み =
//   H2 が防ごうとしている破壊そのもの。fork 側へ倒れて起きるのは枝が増える事だけで、
//   §2.17 が既に「データの喪失ではなく**名前の問題**」と値付けしている。
//
// この層は I/O を持つが、`fs` を差し替えられる形にしてあるので unit で測れる
// (`registry.mjs` と同じ作法)。

import { readdirSync, readFileSync, writeFileSync, renameSync, unlinkSync } from "node:fs";
import { join } from "node:path";

/** セッション ID の形。`registry.mjs` の判定と同じ物を使う(片方だけ緩むと取り違える)。 */
const SESSION_ID = /^[0-9a-f-]{8,64}$/i;

/**
 * 走査に出す名前の条件。**`.json` で終わる物だけ**。
 * ★書きかけ(temp)がこの条件に当たると、rename の原子性が意味を失う
 *  (= 部分的に書かれた中身を「頭」として読む)。だから temp は `.tmp` で終わらせる。
 */
const isHeadFile = (name) => name.endsWith(".json");

/** 同一プロセス内で temp 名が衝突しない様にするだけの数え上げ。時計は要らない。 */
let tempSeq = 0;

/**
 * 書きかけの置き場所。**固有名**にする(Codex 指摘)。
 * pid で他プロセスと、連番で自プロセス内と衝突しない。
 * 共有の temp 名を使うと、2本が同時に書いた時に**互いの書きかけを rename する**。
 */
function tempPathFor(dir, ancestor, pid) {
  tempSeq += 1;
  return join(dir, `${ancestor}.${pid}.${tempSeq}.tmp`);
}

/**
 * 1ファイル分を検証する。壊れていれば null。純関数。
 *
 * @param {string} text ファイルの中身
 * @param {string} name ファイル名(中身と突き合わせる)
 */
export function parseHead(text, name) {
  let obj;
  try {
    obj = JSON.parse(text);
  } catch {
    return null; // 書き込み途中を読んだ等。次に読み直せばよい(= その回は fork 側へ倒れる)
  }
  const ancestor = typeof obj?.ancestor === "string" ? obj.ancestor : "";
  const head = typeof obj?.head === "string" ? obj.head : "";
  if (!SESSION_ID.test(ancestor)) return null;
  if (!SESSION_ID.test(head)) return null;
  // ★ファイル名と中身の祖先が食い違う物は捨てる(`registry.mjs` と同じ理由 = 取り違えの温床)。
  //   ここを緩めると、名前を付け替えただけのファイルが**別の会話の頭**として通る。
  if (`${ancestor}.json` !== name) return null;
  return { ancestor, head };
}

/**
 * 祖先に対する今の頭を返す。**無い / 読めない / 壊れている は全部 `""`**(= fork しろ)。
 *
 * @returns {string} 頭のセッション ID。空文字 = 登録が無い
 */
export function readHead(dir, ancestor, fs = { readFileSync }) {
  if (!SESSION_ID.test(String(ancestor || ""))) return "";
  const name = `${ancestor}.json`;
  let text;
  try {
    text = fs.readFileSync(join(dir, name), "utf8");
  } catch {
    return ""; // まだ無い / 読めない
  }
  const e = parseHead(text, name);
  return e ? e.head : "";
}

/**
 * 頭を書く。`temp → rename` なので、読み手からは**古い頭か新しい頭のどちらか**しか見えない
 * (書きかけは見えない)。
 *
 * ★`fsync` はしない。機械ごと落ちて書き込みが飛んだ場合に起きるのは「頭が無い」で、
 *   それは §2.18-6 が既に**安全側**と決めた状態(= もう一度 fork する)。
 *   落ちない様にする価値より、倒れる向きが正しい事の方がここでは効く。
 */
export function writeHead(
  dir,
  ancestor,
  head,
  fs = { writeFileSync, renameSync, unlinkSync },
  pid = process.pid,
) {
  if (!SESSION_ID.test(String(ancestor || ""))) throw new Error(`祖先の ID の形が違う: ${ancestor}`);
  if (!SESSION_ID.test(String(head || ""))) throw new Error(`頭の ID の形が違う: ${head}`);
  const tmp = tempPathFor(dir, ancestor, pid);
  const dest = join(dir, `${ancestor}.json`);
  fs.writeFileSync(tmp, JSON.stringify({ ancestor, head }) + "\n");
  try {
    fs.renameSync(tmp, dest);
  } catch (e) {
    // rename に失敗したら書きかけを残さない(走査には出ないが、溜まると人が読む時に邪魔)
    try {
      fs.unlinkSync(tmp);
    } catch {
      /* 消せなくても本題ではない */
    }
    throw e;
  }
  return dest;
}

/**
 * 全部の頭を読む(一覧・点検用)。**壊れた1件で全体を落とさない**。
 * 書きかけ(`.tmp`)はここに出てこない。
 */
export function readAllHeads(dir, fs = { readdirSync, readFileSync }) {
  let names;
  try {
    names = fs.readdirSync(dir);
  } catch {
    return []; // まだ1本も無い = 全会話が fork 側へ倒れるだけ
  }
  const out = [];
  for (const name of names) {
    if (!isHeadFile(name)) continue;
    try {
      const e = parseHead(fs.readFileSync(join(dir, name), "utf8"), name);
      if (e) out.push(e);
    } catch {
      continue; // 消えた/読めない1件で全体を落とさない
    }
  }
  return out;
}
