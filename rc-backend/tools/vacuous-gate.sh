#!/bin/bash
# commit の直前に**空回りする検査を新しく入れていないか**を確かめる。
#
# なぜ要るか(2026-08-05): `tools/vacuous-scan.py` を一日かけて作り直したのに、
# **それを呼ぶ物が repo のどこにも無かった**。grep して確認済み —— 走るのは私が
# 手で叩いた時だけ。「検証スクリプトが在る」は「検証された」ではない
# (method_a_verification_script_that_never_ran)。人の記憶を計器に使わない。
#
# 空回りする検査が生まれる瞬間は**検査を書いた瞬間**なので、門はそこに置く。
#
# ── この門が普通の門と違う所 ────────────────────────────────────────────
# 判定材料が「道具が 0 と言った」である。道具が壊れても 0 と言う —— 分類器が
# 「常に錨あり」へ潰れた時の出力は、健全な時と**字面が同じ**(要人手 0 本 / exit 0)。
# だから 0 をそのまま信じない。**先に `--self-test` を回し、通らなければ未測定として
# 止める**。自己検査は分類を両向きに見分ける 17 件(錨なしを挙げる 6 件を含む)なので、
# 潰れた分類器は自己検査を通れない。
#   ★対照 8/9(test/vacuous-scan-controls.sh)は、その自己検査が両向きの潰れで
#     実際に赤くなる事を測っている。ここはその上に立っている。
#
# 範囲: pre-commit hook 側で検査 file を触った commit に絞ってから呼ぶ。
#   書類だけの commit を止めない理由は hook 本体の注釈と同じ。
#
# 終了コード: 0=緑 / 1=錨なしの検査が在る / 2=**測れなかった**。
#   2 を 0 に丸めない。この道具で一番危ない壊れ方は「測れなかった」を「異常なし」と
#   読む事なので、測れない時は止まる側へ倒す。
#
# 逃がし弁: RC_VACUOUS_OK="降ろす理由"(10文字以上)。文言は出力に残るので後から辿れる。
#   check-mutation-targets.sh の RC_TARGETS_SHRINK_OK と同じ作法。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || { echo "vacuous-gate: rc-backend へ入れない"; exit 2; }

# 継ぎ目。対照は本物の走査を回さずに、出力と終了コードだけを差し替えて判定を測る。
SELFTEST_CMD="${SELFTEST_CMD:-python3 $ROOT/tools/vacuous-scan.py --self-test}"
SCAN_CMD="${SCAN_CMD:-python3 $ROOT/tools/vacuous-scan.py}"

OUT="$(/usr/bin/mktemp -t vacuousgate)" || exit 2
ST="$(/usr/bin/mktemp -t vacuousself)" || exit 2
trap '/bin/rm -f "$OUT" "$ST" 2>/dev/null' EXIT INT TERM HUP

# ── ① 道具が今も見分けているか(0 を信じてよいかの前提)────────────────────
eval "$SELFTEST_CMD" > "$ST" 2>&1
self_line="$(/usr/bin/grep -E 'SELF-TEST: pass=[0-9]+ fail=[0-9]+' "$ST" | /usr/bin/tail -1)"
if [ -z "$self_line" ]; then
    echo "vacuous-gate: ★道具の自己検査の結果を読めない = **測れていない**(緑ではない)"
    /usr/bin/tail -6 "$ST" | /usr/bin/sed 's/^/    /'
    exit 2
fi
self_fail="${self_line##*fail=}"
if [ "$self_fail" != "0" ]; then
    echo "vacuous-gate: ★道具の自己検査が赤($self_line)。走査の結果は信用できない"
    echo "  分類器が潰れた時の出力は健全な時と字面が同じ(要人手 0 本 / exit 0)なので、"
    echo "  自己検査が通らない限り 0 を緑と読まない。"
    /usr/bin/grep -E '^  FAIL ' "$ST" | /usr/bin/head -6 | /usr/bin/sed 's/^/    /'
    exit 2
fi

# ── ② 走査 ────────────────────────────────────────────────────────────────
eval "$SCAN_CMD" > "$OUT" 2>&1
scan_rc=$?

if [ "$scan_rc" = "2" ]; then
    echo "vacuous-gate: ★走査が floor を割った = **測れていない**(木が縮んだか、歩けていない)"
    /usr/bin/grep -E '^\[' "$OUT" | /usr/bin/sed 's/^/    /'
    exit 2
fi

sum_line="$(/usr/bin/grep -E '要人手 [0-9]+ 本' "$OUT" | /usr/bin/tail -1)"
if [ -z "$sum_line" ]; then
    # 集計行が無い = 走査がそもそも走っていない。緑でも赤でもなく未測定。
    echo "vacuous-gate: ★走査の集計行を読めない = **測れていない**(緑ではない)"
    echo "  期待する形: '要人手 N 本' を含む1行"
    /usr/bin/tail -8 "$OUT" | /usr/bin/sed 's/^/    /'
    exit 2
fi

naked="$(printf '%s\n' "$sum_line" | /usr/bin/sed -E 's/.*要人手 ([0-9]+) 本.*/\1/')"

# ── ③ 数えた結果が先。終了コードより数え上げを信じる ──────────────────────
if [ "$naked" != "0" ]; then
    _ok="${RC_VACUOUS_OK:-}"
    if [ "${#_ok}" -ge 10 ]; then
        echo "vacuous-gate: 錨なし $naked 本を承知で通す: ${RC_VACUOUS_OK}"
        exit 0
    fi
    echo "vacuous-gate: ★錨のない検査が $naked 本ある。commit を止めた"
    /usr/bin/grep -B 1 -E '^    否定[0-9]+件のみ' "$OUT" | /usr/bin/head -20 | /usr/bin/sed 's/^/  /'
    echo ""
    echo "  問う事: **前提が壊れたら、この検査は赤くなるか?**"
    echo "  赤くならないなら肯定の錨を足す(件数・具体値・分母)。置き場所は3通り:"
    echo "    literal  = 入力を call の中に書く"
    echo "    producer = 分母を作る helper の中に floor を置く"
    echo "    兄弟     = 同じ file の別の検査で、同じ派生を実値で固定する"
    echo "  ★錨は遠い入力ではなく**直に食う派生**に置く事。詳細は tools/vacuous-scan.py の頭。"
    echo "  見張りを降ろすと決めたなら理由を書いて通す:"
    echo '    RC_VACUOUS_OK="この検査は入力が固定なので錨は要らないと判断した" git commit …'
    echo "  (10文字以上。文言はこの出力に残るので、後から理由を辿れる)"
    exit 1
fi

# ── ④ 数え上げは 0 なのに rc が非ゼロ = 集計の後で壊れている ──────────────
if [ "$scan_rc" != "0" ]; then
    echo "vacuous-gate: ★要人手 0 本と出たが、走査の終了コードが $scan_rc"
    echo "  = 集計の後で壊れている可能性。緑と呼ばない(未測定として止める)"
    /usr/bin/tail -6 "$OUT" | /usr/bin/sed 's/^/    /'
    exit 2
fi

echo "vacuous-gate: 錨なしの検査 0 本($self_line)"
exit 0
