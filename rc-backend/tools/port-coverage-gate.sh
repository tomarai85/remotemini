#!/bin/bash
# commit の直前に**JS から Swift への移植の照合**(tools/port-coverage.py)を回す。
#
# なぜ門が要るか(2026-08-07): `tools/vacuous-scan.py` と**同じ病気の2件目**。
# `port-coverage.py` には対照(`test/port-coverage-controls.sh`)が在り、その対照は
# 掃き(`tools/run-controls.sh`)にも登録されていた。にも関わらず **道具そのものを
# 呼ぶ物が repo のどこにも無かった** —— 走るのは私が手で叩いた時だけ。結果、出口が
# 0(2026-08-05 の WORKLOG)から 2 へ落ちても誰も気付かないまま残っていた。
#   ★対照が在る事は、道具が回っている事を意味しない。**対照は道具を測る物であって、
#     道具を走らせる物ではない**。走らせる者(= 門)が別に要る。
#   `vacuous-scan.py` が同じ形を免れているのは門が在るからで、設計の差ではない。
#
# ── なぜ python3 を直に呼ばずに、この薄い皮を挟むか ──────────────────────
# 対照(`test/pre-commit-gates-controls.sh`)は、本体が呼ぶ門を
#   bash "$ROOT/rc-backend/tools/<名前>.sh"
# という形から**数え上げて**、一本ずつ log を吐く木偶に差し替えて測る。直に
# `python3 …` と書くと、その網に掛からない = 数にも入らず、木偶にも差し替わらず、
# 偽の repo の中で本物の python3 が走って落ちる。実測 2026-08-07: 直書きのまま
# 対照を回したら 3 本倒れた(2/9/10。呼ばれた門が 6 本のはずが 5 本で止まった)。
#   ★「下流に能力を足しても、上流の絞り込みがそれを知らなければ守りは伸びない」の
#     5 件目。皮を被せる事で、上流の数え上げが**私の手を借りずに**新しい門を見付ける。
#
# 終了コード: 0=緑 / 1=赤(移っていないリテラル入力 or 死んだ受理 or 腐った印)/
#             2=**測れなかった**。2 を 0 に丸めない。
#
# ── 逃がし弁を置かない事は意図的 ────────────────────────────────────────
# `vacuous-gate.sh` の RC_VACUOUS_OK や `check-mutation-targets.sh` の
# RC_TARGETS_SHRINK_OK に当たる物を、この門は**持たない**。理由: 降ろす為の口は
# 既に道具の側に2つ在る —— 移植表に行を足す / `not-a-port:` の印を理由付きで置く。
# どちらも**外した事が file に残り、腐れば赤くなる**。門に3つ目の口を足すと、
# 「環境変数に一文書けば黙る」という**痕跡の残らない**降ろし方が増えるだけで、
# しかもそれは `DEFAULT_ACCEPTED` が死んだ受理を溜めたのと同じ壊れ方をする。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || { echo "port-coverage-gate: rc-backend へ入れない"; exit 2; }

# 継ぎ目。対照は本物の走査を回さずに、出力と終了コードだけを差し替えて判定を測る。
SCAN_CMD="${SCAN_CMD:-python3 $ROOT/tools/port-coverage.py}"

# 照合できた関数の下限。**表が空になっても道具は「赤 0」と刷る** —— 潰れた時の
# 出力は健全な時と字面が同じなので、0 をそのまま信じない。実測 2026-08-07 は 6 関数。
# ここを実測値と等しくしない(等しくすると関数を1本減らす度に門が赤くなり、
# 「下限」ではなく「写し」になる)。減る方向の事故だけを捕まえる位置に置く。
PC_FLOOR="${PC_FLOOR:-4}"

OUT="$(/usr/bin/mktemp -t portcovgate)" || exit 2
trap '/bin/rm -f "$OUT" 2>/dev/null' EXIT INT TERM HUP

eval "$SCAN_CMD" > "$OUT" 2>&1
scan_rc=$?

# ── ① 集計行そのものが在るか(走っていない事と緑を区別する)────────────────
if ! /usr/bin/grep -q '^=== 集計 ===' "$OUT"; then
    echo "port-coverage-gate: ★走査の集計を読めない = **測れていない**(緑ではない)"
    echo "  期待する形: '=== 集計 ===' で始まる段落"
    /usr/bin/tail -8 "$OUT" | /usr/bin/sed 's/^/    /'
    exit 2
fi

# ── ② 非ゼロはそのまま返す。赤も未測定も止める ────────────────────────────
if [ "$scan_rc" != "0" ]; then
    echo "port-coverage-gate: ★移植の照合が非ゼロ($scan_rc)= commit を止めた"
    /usr/bin/sed -n '/^=== 集計 ===/,$p' "$OUT" | /usr/bin/sed 's/^/  /'
    echo ""
    echo "  直し方は2通り。どちらも**外した事が file に残る**:"
    echo "    移植表に行を足す  = tools/port-coverage.py の PORTS に Swift 側の path を書く"
    echo "    印を置く          = その Swift の file に not-a-port: の印を理由付きで置く"
    echo "  (印の理由は8文字以上。短いと『黙らせているだけ』として赤くなる)"
    exit "$scan_rc"
fi

# ── ③ 0 と言ったのは**何かを照合した上で**か(潰れた表を緑と読まない)────────
nfn="$(/usr/bin/grep -cE '^■ .*: JS 呼び出し' "$OUT")"
if [ "$nfn" -lt "$PC_FLOOR" ]; then
    echo "port-coverage-gate: ★照合できた関数が $nfn 個(下限 $PC_FLOOR)= **測れていない**"
    echo "  赤 0 は『問題が無い』ではなく『何も見ていない』かもしれない。"
    echo "  移植表(PORTS)が縮んだか、JS 側の検査 file を見付けられていない。"
    /usr/bin/sed -n '/^=== 集計 ===/,$p' "$OUT" | /usr/bin/sed 's/^/    /'
    exit 2
fi

disposed="$(/usr/bin/sed -n 's/^  印で外した検査: \([0-9]*\)$/\1/p' "$OUT" | /usr/bin/tail -1)"
echo "port-coverage-gate: 移植の照合 緑(関数 $nfn 個 / 印で外した検査 ${disposed:-0} 件)"
exit 0
