#!/bin/bash
# controls-for: .harness/dod-sprint-6-controls.sh
#
# 何を測るか: `dod-sprint-6-controls.sh` の**「前回の走行が殺された時に、残った変異を
# 戻す」区間だけ**。xcodebuild も Swift も要らないので数秒で終わる。
#
# ★的の本文から区間を**切り出して**回す。写しは作らない —— 写した瞬間、測っている物が
#   写しになり、的が変わっても緑のままになる。錨が一意でなければ測定不能(exit 2)。
#
# 何故この区間に対照が要るのか(2026-08-06 の実測):
#   `dod-sprint-6-controls.sh` は Swift の本文を書き換えて戻す。24 行目は
#   「trap EXIT で必ず復元。中断されても作業木は元に戻る」と書いていたが、測ったら:
#     trap ... EXIT              + SIGTERM -> 戻る
#     trap ... EXIT              + SIGKILL -> **戻らない**
#     trap ... EXIT INT TERM HUP + SIGKILL -> **戻らない**
#   実際に `ReachabilityMeter.swift` の変異が**未 staged のまま**作業木に残り、
#   `git add -A` が拾える状態になっていた。signal を足しても直らないので、
#   直せるのは復旧側だけ。その復旧側を、ここで見張る。
#
# 終了コード: 0=全部通った / 1=通らない検査が在る / 2=測れなかった
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="$ROOT/.harness/dod-sprint-6-controls.sh"
SB="$(mktemp -d "${TMPDIR:-/tmp}/s6rec.XXXXXX")"
cleanup() {
    [ -n "${SB:-}" ] && [ -d "$SB" ] || return 0
    find "$SB" -type f -print0 2>/dev/null | xargs -0 /bin/rm -f 2>/dev/null
    find "$SB" -type d -depth -exec /bin/rmdir {} + 2>/dev/null
}
trap cleanup EXIT

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf 'PASS  %s\n' "$1"; }
ng() { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"; }
chk() { # $1=説明 $2=期待 $3=実測
    if [ "$2" = "$3" ]; then ok "$1"; else ng "$1 (期待=[$2] 実測=[$3])"; fi
}

[ -f "$TARGET" ] || { echo "UNMEASURED  的が無い: $TARGET"; exit 2; }

# ---- 1. 錨で切り出す ---------------------------------------------------------
A_BEGIN='^# ---- 前回の走行が殺されていたら、その取り残しを先に戻す(ここから)'
A_END='^# ---- 前回の取り残しの復旧(ここまで)'
s=$(grep -n "$A_BEGIN" "$TARGET" | cut -d: -f1)
e=$(grep -n "$A_END" "$TARGET" | cut -d: -f1)
if [ "$(echo "$s" | wc -w)" -ne 1 ] || [ "$(echo "$e" | wc -w)" -ne 1 ] || [ "$e" -le "$s" ]; then
    echo "UNMEASURED  錨が一意でない(開始=[$s] 終了=[$e])。錨を付け直す事。"
    exit 2
fi
{ echo 'set -uo pipefail'; sed -n "${s},${e}p" "$TARGET"; } > "$SB/recover.sh"
ok "錨が一意($((e - s + 1)) 行を切り出した)"

# ---- 走らせる為の小道具 ------------------------------------------------------
# $1 = 使う script(既定は素の切り出し)。INFLIGHT / ROOT は呼ぶ側が用意する。
run_recover() {
    INFLIGHT="$SB/inflight.tsv" ROOT="$SB/repo" \
        /bin/bash "${1:-$SB/recover.sh}" 2>&1
}
# 毎回まっさらな「repo」を作る
reset_fixture() {
    find "$SB/repo" "$SB/snap" -type f -print0 2>/dev/null | xargs -0 /bin/rm -f 2>/dev/null
    /bin/rm -f "$SB/inflight.tsv"
    mkdir -p "$SB/repo" "$SB/snap"
    printf 'ORIGINAL\n' > "$SB/repo/a.swift"
    printf 'ORIGINAL-B\n' > "$SB/repo/b.swift"
    /bin/cp "$SB/repo/a.swift" "$SB/snap/0"
    /bin/cp "$SB/repo/b.swift" "$SB/snap/1"
}
mark() { # 目印を書く。$@ = 「対象:複製」の対
    : > "$SB/inflight.tsv"
    for pair in "$@"; do
        printf '%s\t%s\n' "${pair%%:*}" "${pair##*:}" >> "$SB/inflight.tsv"
    done
}

# ---- 2. 目印が無い = 前回は正常終了。何も言わず素通りする ---------------------
reset_fixture
out="$(run_recover)"; rc=$?
chk "目印が無ければ rc 0" "0" "$rc"
chk "目印が無ければ何も出力しない" "" "$out"
chk "目印が無ければ本文を触らない" "ORIGINAL" "$(cat "$SB/repo/a.swift")"

# ---- 3. 目印が在るが中身は一致 = 殺されたが変異は植わる前だった ---------------
reset_fixture
mark "$SB/repo/a.swift:$SB/snap/0"
out="$(run_recover)"; rc=$?
chk "一致していれば rc 0" "0" "$rc"
chk "一致していれば「復旧」と言わない" "no" "$(echo "$out" | grep -q '復旧' && echo yes || echo no)"
chk "一致していても目印は消す" "absent" "$([ -f "$SB/inflight.tsv" ] && echo present || echo absent)"

# ---- 4. 目印が在り本文が変異している = 本命 ----------------------------------
reset_fixture
printf 'MUTATED\n' > "$SB/repo/a.swift"
mark "$SB/repo/a.swift:$SB/snap/0"
out="$(run_recover)"; rc=$?
chk "変異が在っても rc 0(戻せたのだから止めない)" "0" "$rc"
chk "★複製から戻る" "ORIGINAL" "$(cat "$SB/repo/a.swift")"
chk "戻した事を黙らずに言う" "yes" "$(echo "$out" | grep -q '復旧' && echo yes || echo no)"
chk "戻したら目印を消す" "absent" "$([ -f "$SB/inflight.tsv" ] && echo present || echo absent)"

# ---- 5. 複数行 = 対象が複数在っても全部戻る ----------------------------------
reset_fixture
printf 'MUTATED\n' > "$SB/repo/a.swift"
printf 'MUTATED-B\n' > "$SB/repo/b.swift"
mark "$SB/repo/a.swift:$SB/snap/0" "$SB/repo/b.swift:$SB/snap/1"
out="$(run_recover)"; rc=$?
chk "複数でも rc 0" "0" "$rc"
chk "1 つ目が戻る" "ORIGINAL" "$(cat "$SB/repo/a.swift")"
chk "2 つ目も戻る(1 件で打ち切らない)" "ORIGINAL-B" "$(cat "$SB/repo/b.swift")"

# ---- 6. 複製が消えている = 戻せない。清潔だと言い張らず UNMEASURED -----------
reset_fixture
printf 'MUTATED\n' > "$SB/repo/a.swift"
mark "$SB/repo/a.swift:$SB/snap/does-not-exist"
out="$(run_recover)"; rc=$?
chk "★複製が無ければ rc 2(緑でも赤でもなく測定不能)" "2" "$rc"
chk "戻せない事を名指しで言う" "yes" "$(echo "$out" | grep -q 'UNMEASURED' && echo yes || echo no)"
chk "戻せない対象の名前を出す" "yes" "$(echo "$out" | grep -q 'a.swift' && echo yes || echo no)"

# ---- 7. 陰性対照A: 戻す cp を潰すと 4 が赤くなるか --------------------------
sed 's#/bin/cp "$rs" "$rf"#:#' "$SB/recover.sh" > "$SB/recover-mut1.sh"
if cmp -s "$SB/recover.sh" "$SB/recover-mut1.sh"; then
    echo "UNMEASURED  陰性対照A の変異が空振り(的の書き方が変わった)"; exit 2
fi
reset_fixture
printf 'MUTATED\n' > "$SB/repo/a.swift"
mark "$SB/repo/a.swift:$SB/snap/0"
run_recover "$SB/recover-mut1.sh" >/dev/null 2>&1
chk "★陰性対照A: 戻す手を潰すと戻らない(= 4 に歯が在る)" "MUTATED" "$(cat "$SB/repo/a.swift")"

# ---- 8. 陰性対照B: 目印の削除を潰すと「消す」検査が赤くなるか ---------------
sed 's#/bin/rm -f "$INFLIGHT"#:#' "$SB/recover.sh" > "$SB/recover-mut2.sh"
if cmp -s "$SB/recover.sh" "$SB/recover-mut2.sh"; then
    echo "UNMEASURED  陰性対照B の変異が空振り(的の書き方が変わった)"; exit 2
fi
reset_fixture
mark "$SB/repo/a.swift:$SB/snap/0"
run_recover "$SB/recover-mut2.sh" >/dev/null 2>&1
chk "★陰性対照B: 削除を潰すと目印が残る(= 3/4 に歯が在る)" "present" \
    "$([ -f "$SB/inflight.tsv" ] && echo present || echo absent)"

echo
echo "== PASS $PASS / FAIL $FAIL"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
