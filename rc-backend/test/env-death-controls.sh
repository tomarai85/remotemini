#!/bin/bash
# env-death-controls.sh — 「環境の都合で測れていない」を見分ける関門の対照。
#
# なぜ要るか(2026-08-02、同じ日に**両方向**の嘘を踏んだ):
#   向き1(偽の検出): e2e が固定範囲から port を選んでいた頃、孤児プロセスと衝突すると
#     サーバが上がらず、要約行が出ず、変異台本は exit≠0 だけ見て「変異を検出した」と
#     数えた = **守れていない物を守れたと報告**。
#   向き2(一切測れない): その対策に置いた合図 `RC-ENV-DEATH` を throw の文字列に
#     埋めた。Node は未捕捉例外の報告に **throw 文の原文** を stderr へ写すので、
#     環境死でない落ち方でも合図が現れ、78件の走行が最初の対照で即死した。
#     = **検出器が自分の原文に一致していた**。
#
# ★この台本の存在理由は「手書きの文字列で対照を通さない」事。向き2 は、私が想像した
#   出力(合図あり/なしの短い文字列)を関門に食わせて全ケース OK を取った直後に起きた。
#   だからここは **本物の bind 失敗** と **本物の Node クラッシュ報告** で駆動する。
#
# 判定そのものは書き写さない。`mutation-controls.py --env-death <file>` を叩いて
# **本体が使う正規表現**に答えさせる(書き写すと、写した方だけ正しい状態が作れる)。
#
# 使い方: bash test/env-death-controls.sh
# 終了コード: 0 = 全ケース期待通り / 1 = どれかが外れた
set -u

cd "$(dirname "$0")/.." || exit 1
ROOT="$(pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/rc-envdeath.XXXXXX")"
HOLDER=""
ng=0

cleanup() {
  [ -n "$HOLDER" ] && kill "$HOLDER" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

verdict() {  # verdict <stdout ファイル> -> ENV-DEATH | ok
  python3 test/mutation-controls.py --env-death "$1"
}

judge() {  # judge <ケース名> <期待> <実際>
  if [ "$2" = "$3" ]; then
    printf '  %-46s 期待=%-9s 実際=%-9s OK\n' "$1" "$2" "$3"
  else
    printf '  %-46s 期待=%-9s 実際=%-9s ★外れ\n' "$1" "$2" "$3"
    ng=$((ng + 1))
  fi
}

echo "=== 環境死の関門: 本物の出力で駆動する対照 ==="

# --- C1: 本物の bind 失敗 -----------------------------------------------------
# 先に port を**掴んだまま**の助手を立てて、その番号を e2e に強制する。
# 番号を先に選んで後から使う書き方だと、選んだ瞬間に空くので競合になる。掴み続ける。
# サーバの bind 既定は 127.0.0.1(src/server.mjs)なので助手も同じ address で掴む。
node -e '
const net = require("net");
const s = net.createServer();
s.listen(0, "127.0.0.1", () => { console.log(s.address().port); });
setTimeout(() => process.exit(0), 120000);
' > "$WORK/port.txt" &
HOLDER=$!
for _ in $(seq 1 50); do
  [ -s "$WORK/port.txt" ] && break
  sleep 0.1
done
PORT=$(tr -dc 0-9 < "$WORK/port.txt")
if [ -z "$PORT" ]; then
  echo "  ★助手が port を掴めなかった。この対照は成立しない(緑を名乗らない)"
  exit 1
fi
echo "  (助手が 127.0.0.1:${PORT} を掴んでいる)"
RC_E2E_FORCE_PORT="$PORT" node test/e2e-local.mjs > "$WORK/c1.out" 2> "$WORK/c1.err"
c1rc=$?
judge "C1 本物の bind 衝突 -> 走行を止める" "ENV-DEATH" "$(verdict "$WORK/c1.out")"
judge "C1 e2e 自体は落ちている(exit≠0)" "落ちる" "$([ $c1rc -ne 0 ] && echo 落ちる || echo 落ちない)"
# ★job 制御の "Terminated: 15" を出さない。対照の出力は追い詰められている時に読む物なので、
#   本題でない行を混ぜない(実際、直前の走行でこれが判定行の間に割り込んで読み辛かった)。
{ kill "$HOLDER" 2>/dev/null; wait "$HOLDER"; } 2>/dev/null
HOLDER=""

# --- C2: 本物の canary クラッシュ(= 8/02 に外した現物) ----------------------
# 変異でサーバが import 時に死ぬ形。**正しい赤**なので、関門は止めてはいけない。
rsync -a --exclude .git --exclude node_modules "$ROOT"/ "$WORK/canary"/ || exit 1
printf 'throw new Error("canary");\n' | cat - "$WORK/canary/src/inject.mjs" > "$WORK/canary/src/inject.new"
mv "$WORK/canary/src/inject.new" "$WORK/canary/src/inject.mjs"
( cd "$WORK/canary" && node test/e2e-local.mjs ) > "$WORK/c2.out" 2> "$WORK/c2.err"
c2rc=$?
judge "C2 変異でサーバが死んだ -> 止めない(正しい赤)" "ok" "$(verdict "$WORK/c2.out")"
judge "C2 e2e 自体は落ちている(exit≠0)" "落ちる" "$([ $c2rc -ne 0 ] && echo 落ちる || echo 落ちない)"
# ★C2 が「合図が出ない事」を確かめるだけなら、e2e が何も出力しなくなっても緑になる。
#   罠の**機構**が今も生きている事を現物で押さえた上で、こちらがその射線から出ている、
#   の二段で見る。機構 = Node は未捕捉例外の報告に throw 文の原文を stderr へ写す。
if grep -q 'throw new Error(' "$WORK/c2.err"; then
  echo "  (機構の生存を確認: Node が throw 文の原文を stderr に写している)"
else
  echo "  ★機構が再現していない: stderr に原文の写しが無い = C2 はもう当時の罠を見ていない"
  ng=$((ng + 1))
fi
# 不変条件: 合図の語を **throw の行に書かない**。ここを破ると 8/02 の即死が戻る。
if grep -n 'throw' test/e2e-local.mjs | grep -q 'RC-ENV-DEATH'; then
  echo "  ★不変条件を破っている: throw の原文に合図が埋まっている(Node が写す = 自己一致)"
  ng=$((ng + 1))
else
  echo "  (不変条件 OK: 合図は throw の原文に埋まっていない)"
fi

# --- C3: 素の緑 ---------------------------------------------------------------
node test/e2e-local.mjs > "$WORK/c3.out" 2> "$WORK/c3.err"
c3rc=$?
judge "C3 素の走行 -> 止めない" "ok" "$(verdict "$WORK/c3.out")"
judge "C3 素の走行は緑" "緑" "$([ $c3rc -eq 0 ] && echo 緑 || echo 赤)"

echo
if [ $ng -eq 0 ]; then
  echo "全ケース OK(関門は本物の環境死だけで発火する)"
  exit 0
fi
echo "★${ng} 件外れた。変異台本の緑は当てにできない"
exit 1
