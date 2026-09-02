#!/bin/bash
# no-operator: 本番へ GET を撃つので tailnet と鍵が要り、門からは回せない。撃つのは
#   /loop の verifier と、電話の Decodable / 机の封筒を触った人が形を取り直したい時。
#   ★`controls-for:` にはしない —— 此れは対照ではなく入口で、対照として宣言すると
#     mjs に触る commit の度に本番へ GET が飛び、tailnet が落ちている日に commit が止まる。
#
# 走っているサーバの**実応答の形**を採り、Swift の復号器が必須とする鍵と突き合わせる薄い殻。
# 中身は `wire-shape-capture.mjs`(理由と扉の宣言は其方の頭に全部書いた)。
#
#   bash tools/wire-shape-capture.sh --check   # 捕捉 → 突き合わせ → TSV を書く → MISMATCH: N を出す
#
# 出力: `.harness/evidence-<日付>/wire-shapes.tsv`(2列目は必ず live か local。
#        叩けなかった経路は**行にしない** —— 推測で埋めない為。名前は下の「叩けなかった」に出る)
# 終了コード: 0 = 不一致 0 件 / 1 = 不一致あり、または捕捉が立たなかった
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
REPO="$(cd "$ROOT/.." && pwd)"
DATE="${RC_SHAPE_DATE:-$(date +%Y-%m-%d)}"
OUT_DIR="$REPO/.harness/evidence-$DATE"
OUT="$OUT_DIR/wire-shapes.tsv"

case "${1:-}" in
  --check) ;;
  *) echo "usage: $0 --check" >&2; exit 2 ;;
esac

mkdir -p "$OUT_DIR"
cd "$ROOT" || exit 2

node --input-type=module -e '
import { capture } from "'"$HERE"'/wire-shape-capture.mjs";
import { writeFileSync } from "node:fs";
const out = process.env.RC_SHAPE_OUT;
const { rows, skipped } = await capture();
const head = ["endpoint","source","method","status","swift_type","required_keys","emitted_keys","missing"].join("\t");
const body = rows.map(r => [r.id, r.src, r.method, r.status, r.type,
  r.required.sort().join(","), r.emitted.sort().join(","), r.missing.sort().join(",") || "-"].join("\t"));
writeFileSync(out, [head, ...body].join("\n") + "\n");
const bad = rows.filter(r => r.missing.length);
for (const r of bad) {
  console.log(`  MISS  ${r.src}/${r.id}  ${r.type}  電話が要求して机が吐いていない鍵: ${r.missing.join(", ")}`);
}
const vac = rows.filter(r => r.required.length === 0);
for (const r of vac) {
  console.log(`  VACUOUS  ${r.src}/${r.id}  ${r.type} は必須鍵を1つも持たない(全部 Optional)= 此の行の照合は恒真。検証済みと数えない`);
}
console.log(`captured ${rows.length} shapes (live=${rows.filter(r=>r.src==="live").length} local=${rows.filter(r=>r.src==="local").length}) / うち恒真 ${vac.length} 件 = 実質 ${rows.length - vac.length} 件`);
if (skipped.length) {
  console.log("叩けなかった経路(推測で埋めない):");
  for (const [src, id, why] of skipped) console.log(`  SKIP  ${src}/${id}  ${why}`);
}
console.log(`MISMATCH: ${bad.length}`);
process.exit(bad.length === 0 && rows.length > 0 ? 0 : 1);
' 2>&1
rc=$?
echo "TSV: $OUT"
exit $rc
