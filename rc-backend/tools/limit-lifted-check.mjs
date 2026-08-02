// 「週次上限が明けたか」を**生成を1回も起こさずに**判る読み取り専用の検査。
//
// ── なぜ要るか ──────────────────────────────────────────────────────────
// 上限中に本番の台本(live-inject-check / live-http-check / live-fork-check)を撃つと
// どれも「未測定(exit 3)」で終わる。**撃つ前にこれを撃てば、無駄撃ちが消える**。
// 転写を読むだけなので、上限そのものを1トークンも消費しない。
//
// ── ★model 別に数える理由(初版はここで負の対照に落ちた)────────────────
// 初版は「`isApiErrorMessage` でない assistant が1件でも在れば明けた」だった。
// 上限が確実に生きている 2026-08-02 23:1x に回して**「明けている」と誤答**した:
// 拾っていたのは 21:40 JST の **`claude-haiku-4-5` の成功2件**。
// **haiku は週次上限とは別枠**(だから MBP のリハーサルは `--model haiku` で
// 消費を避けられた)。「答えた」は「上限が明けた」ではない —— **どの model が
// 答えたかを見るまでは**。だから model 別に出し、haiku は根拠に採らない。
//
// ── ★拡張子が `.mjs` である理由(2回目の対照で落ちた所)────────────────
// 初版は `.js` + `require` で、**edith では通り repo では落ちた**。
// `package.json` に `"type": "module"` が在るので repo 内の `.js` は ESM 扱い、
// `/tmp` に scp した `.js` は package.json の圏外なので CJS 扱い —— **同じ bytes が
// 置き場所で意味を変えていた**。`import` に直して `.js` のままにすると罠が
// 反転するだけ(今度は /tmp で落ちる)。`.mjs` はどちらでも ESM。
// 教訓: **持ち出して動いた事は、家で動く事の証拠ではない**。
//
// ── 実測で判った印(本文の正規表現照合は要らない)────────────────────────
//   `isApiErrorMessage: true`      … そのターンは API エラーで死んだ(edith 205/699 file)
//   `message.model === "<synthetic>"` … クライアントが作った偽の assistant 応答
//                                       = 上限の告知はこれ。相手の言葉ではない
//
// 使い方: `node limit-lifted-check.mjs [時間]`(既定 2時間)
// 終了コード: 0 = 明けている / 3 = まだ明けていない(= 撃つな) / 2 = 読めない
// 対照: `bash test/limit-lifted-controls.sh`(fake HOME、edith も上限も要らない)
import fs from "node:fs";
import path from "node:path";
import os from "node:os";

const HOURS = Number(process.argv[2] || 2);
const P = path.join(os.homedir(), ".claude", "projects");
if (!fs.existsSync(P)) {
  console.log("転写の置き場が無い: " + P);
  process.exit(2);
}

const cut = Date.now() - HOURS * 3600e3;
const per = Object.create(null); // model -> {ok, err}
let files = 0;

for (const d of fs.readdirSync(P)) {
  const dir = path.join(P, d);
  let st;
  try { st = fs.statSync(dir); } catch { continue; }
  if (!st.isDirectory()) continue;
  for (const f of fs.readdirSync(dir)) {
    if (!f.endsWith(".jsonl")) continue;
    const p = path.join(dir, f);
    let s;
    try { s = fs.statSync(p); } catch { continue; }
    if (s.mtimeMs < cut) continue;
    files++;
    let text;
    try { text = fs.readFileSync(p, "utf8"); } catch { continue; }
    for (const line of text.split("\n")) {
      if (!line) continue;
      let j;
      try { j = JSON.parse(line); } catch { continue; }   // 書き込み途中の末尾行
      if (j.type !== "assistant") continue;
      const m = (j.message && j.message.model) || "(不明)";
      const rec = (per[m] = per[m] || { ok: 0, err: 0 });
      rec[j.isApiErrorMessage ? "err" : "ok"]++;
    }
  }
}

// ★答えに主語を必ず添える。この道具は **走らせた機械の転写**しか読めないので、
//   MBP で回せば MBP の答えが出る —— それは edith の上限について何も言っていない。
//   実際 MBP で回すと `claude-opus-5: 成功 34173` で堂々と「明けている」と出る。
//   だから「どこを測ったか」を答えと同じ行に出し、主語の無い green を作らない。
console.log(`測った所: ${os.hostname()} : ${P}`);
console.log(`直近${HOURS}時間: 転写${files}本`);
const models = Object.keys(per).sort();
if (!models.length) console.log("   (assistant レコードが1件も無い)");
for (const m of models) console.log(`   ${m}: 成功 ${per[m].ok} / エラー ${per[m].err}`);

// ★haiku を除く = 本番の台本が実際に使う model が答えたかだけを見る。
//   `<synthetic>` はクライアント生成なので当然ここには入らない(成功は必ず 0)。
const real = models.filter((m) => !/haiku/i.test(m) && m !== "<synthetic>" && per[m].ok > 0);
if (real.length) {
  console.log(`→ 上限は明けている(成功した model: ${real.join(", ")})`);
  process.exit(0);
}
console.log("→ まだ明けていない(撃たない。haiku の成功は別枠なので根拠にしない)");
process.exit(3);
