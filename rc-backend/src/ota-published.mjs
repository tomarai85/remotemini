// ota-published.mjs — 配布口が**今どの版を配っているか**を、机の disk から読む。
//
// ── なぜ要るか(2026-08-30)──────────────────────────────────────────────────
// CF-11 と CF-17 が一続きの失敗を作った: 私は「修正は反映済み」と報告したが、其の修正は
// Tom が持っているどの版にも入っておらず、CF-17 の実測では配布口に `client=app` が
// **path を問わず1本も来ていない** —— 栞は一度も叩かれていない。
// 「新しい版が在る」を伝える経路が**私が思い出して言う**しか無かった。其れを構造に置き換える。
//
// ★読むのは **manifest**(= 実際に配っている版)であって `.approved-build` ではない。
//   巻き戻った時、承認の記録は新しいまま manifest だけ古い —— 承認を読むと
//   「105 が在る」と言いながら叩いても 96 しか入らない、という嘘になる。
//
// ★plist の解析に PlistBuddy を呼ばない。要求ごとに子プロセスを起こす事になるし、
//   `/api/sessions` は電話が開くたび・前面へ戻るたびに来る。此の manifest は
//   `ios/tools/adhoc-ota.sh` が作る**自分たちの生成物**なので、形は判っている。
//
// ★読めない時は `null`。「配っている版が判らない」を「新しいのが在る」に化かすと、
//   栞を叩いても何も変わらず、その1回で帯は二度と読まれなくなる。
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";

// `<key>bundle-version</key>` の**次の** `<string>` を取る。間に空白と改行だけを許し、
// 別の鍵を跨がない(`[^<]*` ではなく空白類だけ)。
const BUNDLE_VERSION = /<key>bundle-version<\/key>\s*<string>(\d{1,9})<\/string>/;

// 読み直しの間隔。配布は人が撃つ操作なので秒単位の鮮度は要らない。
const DEFAULT_TTL_MS = 60_000;

let cache = { at: 0, value: null, key: "" };

/** 配布 dir を1つに決める。**ちょうど1つの時だけ**返す。 */
function soleDir(root) {
  let found = null;
  let n = 0;
  let names;
  try {
    names = readdirSync(root);
  } catch {
    return null;
  }
  for (const name of names) {
    if (name.startsWith(".")) continue;
    const full = join(root, name);
    try {
      if (!statSync(full).isDirectory()) continue;
    } catch {
      continue;
    }
    n += 1;
    found = full;
  }
  // ★2つ在る時に選ばない。古い秘密の残骸が並んだ日に、**配っていない方**の版を
  //   「配布中」として読みうる —— `ota-freshness-check.sh` が同じ結論に到達している。
  return n === 1 ? found : null;
}

/**
 * 配っている版(文字列の数字)か `null`。
 * @param {string} root 配布 dir の親(既定 `~/ota`)
 * @param {{ ttlMs?: number, now?: () => number }} [opt]
 */
export function publishedBuild(root, opt = {}) {
  const ttl = opt.ttlMs ?? DEFAULT_TTL_MS;
  const now = (opt.now ?? Date.now)();
  if (cache.key === root && now - cache.at < ttl) return cache.value;

  let value = null;
  const dir = soleDir(root);
  if (dir) {
    try {
      const m = BUNDLE_VERSION.exec(readFileSync(join(dir, "manifest.plist"), "utf8"));
      if (m) value = m[1];
    } catch {
      value = null;
    }
  }
  // ★読めなかった回も**憶えておく**。憶えないと、読めない間ずっと毎回 disk を叩く。
  //   憶える中身は `null` なので、「古い値を配り続ける」形にはならない。
  cache = { at: now, value, key: root };
  return value;
}

/** 検査の継ぎ目。プロセス内の記憶を捨てる。 */
export function resetPublishedBuildCache() {
  cache = { at: 0, value: null, key: "" };
}
