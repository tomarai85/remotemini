#!/bin/bash
# 対照が**本当にその欠陥を測っているか**を機械で確かめ、
# **どの assertion が見分けているか**を1枚の表にする。
#
# ── なぜ要るか ────────────────────────────────────────────────────────────
# `tools/run-controls.sh` の頭に規則が書いてある:
#   「直したら、直す前の版で対照が赤になるか個別に見る。赤にならない対照は
#     その欠陥について何も測っていない。」
# 書いてあるが、**それを回す物が無かった**。人が手で回す限り毎回はやらない。
#
# ★答えるのは1つ: **守りを直す前の版に戻した時、その対照は赤くなるか**。
#   緑のままなら、その対照はその欠陥について何も言っていない(= 名前だけの対照)。
#   さらに、**どの行が倒れたか**まで出す。「suite が赤い」では足りない —— 8/03 に
#   実際、対照 21 枚のうち赤くなったのは狙った 4 枚だけ、という所まで見て初めて
#   「巻き添えではなく狙った欠陥を測っている」と言えた。
#
# ── 壊さない。差し替える ──────────────────────────────────────────────────
# 初稿は live の file に `sed -i` を当てて壊し、後で戻す造りだった。捨てた。理由:
#   ① 復元に失敗すると repo が壊れたまま残る(trap を書いても、書いた trap が正しい保証が無い)
#   ② `sed` の型が当たらないと**壊していない木**で対照を回して当然の緑を得る
#   ③ 壊し方が下手だと構文エラーになり、対照は測りたい物に辿り着く前に落ちる。
#      終了コードは非ゼロだが、それは測定ではない
# 代わりに **git の履歴から直す前の版を出して、対照の継ぎ目へ差し込む**。
# live の file には一度も触らない。①②③ が構造的に起きない。
#
# ── 継ぎ目が無い対照について ──────────────────────────────────────────────
# 継ぎ目が無い = この道具では測れない、だが**それが欠陥とは限らない**。対照には型が2つある:
#   自力型 —— 対照自身が壊れた状態を作る(`test/child-reaping-controls.sh` は直す前の版を
#             その場で組み立てる / `test/mutation-freeze-controls.sh` は走行中に本当に木を汚す)。
#             毎回の実行が自分の負の対照を兼ねるので、この道具は要らない。
#   差替型 —— 守っている物を外から差し替えられる(`PII_SCRIPT` 等)。この道具の対象。
# どちらでもない物だけが本当の欠陥。**継ぎ目が無い事だけを根拠に欠陥と呼ばない事**。
#
# ── 使い方 ────────────────────────────────────────────────────────────────
#   prove-control.sh <対照script> <継ぎ目の環境変数名> <守られている file> [<比較する rev>]
#
#   例:
#     prove-control.sh test/pii-controls.sh PII_SCRIPT tools/check-no-pii.sh
#       -> 既定では「その file を最後に変えた commit の**親**」= 直す前の版と比べる
#     prove-control.sh test/pii-controls.sh PII_SCRIPT tools/check-no-pii.sh HEAD~5
#
# 終了コード: 0=効いている / 1=**効いていない**(旧版でも緑) / 2=未測定
set -u

usage() { /bin/cat >&2 <<'U'
prove-control.sh <対照script> <継ぎ目の環境変数名> <守られている file> [<比較する rev>]
  終了コード 0=効いている / 1=効いていない / 2=未測定
U
exit 2; }

[ $# -ge 3 ] && [ $# -le 4 ] || usage
CTL="$1"; SEAM="$2"; GUARDED="$3"; REV="${4:-}"

ROOT="${RC_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT" || { echo "repo が無い: $ROOT" >&2; exit 2; }

[ -f "$CTL" ]     || { echo "対照が無い: $CTL" >&2; exit 2; }
[ -f "$GUARDED" ] || { echo "守られている file が無い: $GUARDED" >&2; exit 2; }

# 継ぎ目が本当に在るか。無い物を差し込んでも既定値が使われて**両方緑**になり、
# 「効いていない」と誤報する。名前だけ渡された時にここで落とす。
grep -q "\${${SEAM}:-" "$CTL" || {
    echo "対照に継ぎ目 \$${SEAM} が無い: $CTL" >&2
    echo "  自力型の対照(自分で壊れた状態を作る物)はこの道具の対象外 —— 毎回の実行が" >&2
    echo "  既に負の対照を兼ねている。継ぎ目が無い事だけを根拠に欠陥と呼ばない事。" >&2
    exit 2
}

# ── 走行中の変異と衝突しない。一部の対照は自分で変異走行を起こす ──────────
if [ -x tools/mutation-run-live.sh ] && bash tools/mutation-run-live.sh 2>/dev/null; then
    echo "★変異走行が動いている。対照を回すと競るので測らない" >&2
    echo "PROVE: 未測定(変異走行が動いている)= **効いている事の証拠ではない**"
    exit 2
fi

# ── 直す前の版を取り出す ─────────────────────────────────────────────────
# 経路は repo の root から見た形でないと `git show` が引けない。
FULL="$(git ls-files --full-name -- "$GUARDED" 2>/dev/null | head -1)"
[ -n "$FULL" ] || { echo "git が追跡していない: $GUARDED" >&2; exit 2; }

if [ -z "$REV" ]; then
    # その file を最後に変えた commit の親 = 「直す直前」。
    last="$(git log -1 --format=%H -- "$FULL" 2>/dev/null)"
    [ -n "$last" ] || { echo "履歴が引けない: $FULL" >&2; exit 2; }
    REV="${last}^"
fi

# ★trap を張る前に3つとも作る。`set -u` の下で、まだ代入していない変数を参照する trap が
#   先に発火すると後片付けそのものが落ちる(片付けの失敗は静かに残る型なので順序で潰す)。
OLD="$(/usr/bin/mktemp -t prove-old)" || exit 2
OUT0="$(/usr/bin/mktemp -t prove-o0)" || exit 2
OUT1="$(/usr/bin/mktemp -t prove-o1)" || exit 2
trap '/bin/rm -f "$OLD" "$OUT0" "$OUT1" 2>/dev/null' EXIT INT TERM HUP

git show "${REV}:${FULL}" > "$OLD" 2>/dev/null || {
    echo "旧版が取れない: ${REV}:${FULL}" >&2
    echo "  (その file が生まれた commit が最初の版なら、比較する前の版は存在しない)" >&2
    exit 2
}
/bin/chmod +x "$OLD"

# ★旧版と今の版が同じなら、この比較は**何も比べていない**。緑にしない。
if /usr/bin/shasum "$OLD" "$GUARDED" | /usr/bin/awk '{print $1}' | /usr/bin/uniq | /usr/bin/wc -l | grep -q '^ *1$'; then
    echo "旧版($REV)と今の版が同一。比べる差が無い"
    echo "PROVE: 未測定(差が無い)= **効いている事の証拠ではない**"
    exit 2
fi

echo "── 対照: $(/usr/bin/basename "$CTL")"
echo "   守り: $FULL   継ぎ目: \$$SEAM   旧版: $REV"

# ★比べている commit が**何をした commit か**を必ず出す。
#   既定の rev は「その file を最後に変えた commit の親」なので、その commit が
#   改名・整形・コメントだけなら旧版に欠陥は**入っていない**。その時に出る「緑のまま」は
#   対照の欠陥ではなく **rev の選び方**の話。名前を出さないと、この2つが見分けられない。
subj="$(git log -1 --format='%h %s' "${REV}..HEAD" -- "$FULL" 2>/dev/null | /usr/bin/tail -1)"
[ -n "$subj" ] && echo "   比べる差分を入れた commit: $subj"
echo "   その commit の $FULL への差分: $(git diff --shortstat "$REV" HEAD -- "$FULL" 2>/dev/null | /usr/bin/sed 's/^ *//')"

# ── ① 今の版では緑でなければならない ────────────────────────────────────
bash "$CTL" > "$OUT0" 2>&1; rc0=$?
if [ "$rc0" -ne 0 ]; then
    echo "  ① 今の版で緑でない(rc=$rc0)。この状態では旧版の赤を切り分けられない"
    /usr/bin/tail -6 "$OUT0" | /usr/bin/sed 's/^/    /'
    echo "PROVE: 未測定(基準が緑でない)"
    exit 2
fi
echo "  ① 今の版 = 緑(rc=0)"

# ── ② 旧版を差し込む ────────────────────────────────────────────────────
env "$SEAM=$OLD" bash "$CTL" > "$OUT1" 2>&1; rc1=$?

if [ "$rc1" -eq 0 ]; then
    echo "  ② 旧版に戻しても**緑のまま**(rc=0)"
    echo ""
    echo "PROVE: ★効いていない —— この対照は $FULL の **$REV からの差分**について何も測っていない"
    echo "  ただし読み違えない事: これが言っているのは「この差分を見分けられない」だけ。"
    echo "  上に出した commit が改名・整形・コメントだけなら、旧版にそもそも欠陥が無いので"
    echo "  緑は正しい —— それは**対照の欠陥ではなく rev の選び方**。欠陥を入れた commit を"
    echo "  第4引数で名指しして測り直す事。差分の中身を見ずにこの行を欠陥として数えない。"
    exit 1
fi
if [ "$rc1" -gt 1 ]; then
    # 落ちた = 対照が測りたい物に辿り着く前に死んだ可能性。赤と同じ扱いにしない。
    echo "  ② 旧版で **rc=$rc1**(赤 1 ではない)。測りたい物に届く前に落ちた可能性がある"
    /usr/bin/tail -8 "$OUT1" | /usr/bin/sed 's/^/    /'
    echo "PROVE: 未測定(対照自体が落ちた)"
    exit 2
fi
echo "  ② 旧版 = 赤(rc=1)"

# ── ③ **どの行が倒れたか**。ここがこの道具の本体 ────────────────────────
#     suite 全体が赤い事は「狙った欠陥を測っている」証明にならない。巻き添えかもしれない。
#     行ごとに突き合わせて、倒れた物と倒れなかった物を両方出す。
flipped=$(/usr/bin/grep -c '^NG' "$OUT1" 2>/dev/null || true)
held=$(/usr/bin/grep -c '^OK' "$OUT1" 2>/dev/null || true)
echo ""
echo "  ③ 旧版で倒れた assertion = ${flipped} 枚 / 倒れなかった = ${held} 枚"
echo "     -- 倒れた(= この欠陥を見分けている) --"
/usr/bin/grep '^NG' "$OUT1" | /usr/bin/sed 's/^NG  /       /' || true
echo "     -- 倒れなかった(= この欠陥については何も言っていない。別の欠陥を見ている可能性) --"
/usr/bin/grep '^OK' "$OUT1" | /usr/bin/sed 's/^OK  /       /' | /usr/bin/head -30 || true
[ "$held" -gt 30 ] && echo "       … 他 $((held - 30)) 枚"

echo ""
echo "PROVE: 効いている(今の版=緑 / 旧版=赤 / 倒れた assertion を名指しできる)"
exit 0
