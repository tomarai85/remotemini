#!/bin/bash
# controls-for: ios/Sources/Screens/Conversation/ConversationView.swift
#
# 会話画面の灰色の帯(.bar)が composer だけの物である事を見張る検査
# rc-backend/test/bar-is-composer-only.test.mjs の負の対照(監査 X-3 / DESIGN 2.63)。
#
# なぜ要るか(2026-08-08、実測で前言を撤回した経緯を含む):
#   X-3 を当てた時、私は「変異対照は書かない」と検査の頭に書いた。理由は
#   「赤くなるべき検査が此処には無いので、対照の顔をした空回りになる」。
#   これは**偽だった** —— 手で変異を植てみたら、当の検査が実際に赤くなった。
#   赤くなる物が在るのに対照を書かないのは、ただの省略であって設計判断ではない。
#
#   守る対象が「背景の材質」なので、この土地には特有の脆さが在る:
#   材質は画面の見た目にしか現れず、単体でも UI 検査でも読めない(XCUITest は
#   色も材質も取れない)。つまり見張りはバイトの走査しか有り得ず、走査は
#   整形・改名・枝の追加で**静かに的を外す**。外れた事は緑で出る。
#   だからここでは、外れた時に赤が出る事の方を測る。
#
# 4本の変異と、それぞれが撃つ物:
#   M1 bar-ceiling      上限の枝に帯を戻す        -> 主張が赤(錨1は緑のまま)
#   M2 bar-button       ボタンの枝に帯を戻す      -> 主張が赤(錨1は緑のまま)
#   M3 anchor-truncated 上限の枝の識別子を改名    -> 錨1が赤(主張は緑のまま)
#   M4 spelling-gone    composer から帯ごと消す   -> 錨2が赤
#   M5 glass-bar-ceiling  上限の枝にガラスの面を敷く -> 主張が赤(2026-08-29 追加)
#   M6 glass-spelling-gone ガラスの帯の材質を替える  -> 錨3が赤(2026-08-29 追加)
#
#   ★M3 が此処に在る理由: 主張は「入っていない」= 否定なので、切り出しが痩せると
#   中身を見ずに緑になる。M3 は切り出しを痩せさせた時、主張が**緑のまま**で錨1
#   だけが赤くなる事をその走行の実測として出す。片方だけでは通る欠陥が在る、を
#   主張ではなく実演で言う。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"   # = repo の根
ROOT="$HERE"
CV="$ROOT/ios/Sources/Screens/Conversation/ConversationView.swift"
TEST="$ROOT/rc-backend/test/bar-is-composer-only.test.mjs"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/bar-material-XXXXXX")" || { echo "UNMEASURED  作業場を作れない"; exit 2; }
LOGDIR="$WORK/logs"; mkdir -p "$LOGDIR"
# ★ios の対照で共有する目印。殺された走行の取り残しを、次に走る誰かが戻す為。
INFLIGHT="${TMPDIR:-/tmp}/rc-ios-mutation-inflight.tsv"
PASS=0; FAIL=0; UNMEASURED=0

TARGETS=("$CV")
ORIG="$WORK/orig"; mkdir -p "$ORIG"
snap_path() { printf '%s/%s' "$ORIG" "$1"; }

restore_one() { # $1 = 添字
    # local の右辺は全部展開されてから代入されるので、1行にまとめない事
    # (まとめると $i が引数でなく呼び出し元の i を読む。bash 3.2 で実測)。
    local i="$1"
    local f s
    f="${TARGETS[$i]}"
    s="$(snap_path "$i")"
    [ -f "$s" ] || return 0
    /bin/cp "$s" "$f"
}
restore_all() {
    local j=0
    while [ "$j" -lt "${#TARGETS[@]}" ]; do restore_one "$j"; j=$((j+1)); done
}
cleanup() {
    restore_all
    # 目印は復元より後に消す。逆だと、消した直後に殺された時に
    # 「戻っていないのに手掛かりも無い」状態が作れる。
    /bin/rm -f "$INFLIGHT"
    [ -n "${WORK:-}" ] && [ -d "$WORK" ] || return 0
    find "$WORK" -type f -print0 2>/dev/null | xargs -0 /bin/rm -f 2>/dev/null
    find "$WORK" -type d -depth -exec /bin/rmdir {} + 2>/dev/null
}
trap cleanup EXIT

# ---- 前回の走行が殺されていたら、その取り残しを先に戻す(ここから)-------------
# ★この位置でなければならない: 下の複製 loop より**前**。後に置くと、変異したバイトを
#   「走る前の中身」として複製してしまい、復元の基準点そのものが汚染される。
if [ -f "$INFLIGHT" ]; then
    recovered=""; lost=""
    while IFS="$(printf '\t')" read -r rf rs; do
        [ -n "${rf:-}" ] || continue
        if [ -f "$rs" ] && [ -f "$rf" ]; then
            if ! cmp -s "$rs" "$rf"; then
                /bin/cp "$rs" "$rf"
                recovered="$recovered ${rf#$ROOT/}"
            fi
        else
            lost="$lost ${rf#$ROOT/}"
        fi
    done < "$INFLIGHT"
    /bin/rm -f "$INFLIGHT"
    if [ -n "$recovered" ]; then
        echo "復旧: 前回の走行が殺されて残っていた変異を戻した:$recovered"
    fi
    if [ -n "$lost" ]; then
        echo "UNMEASURED  前回の変異を戻せない(複製が消えている):$lost"
        echo "            何が変わっているかは git diff で見え、戻すのは git checkout -- で足りる。"
        exit 2
    fi
fi
# ---- 前回の取り残しの復旧(ここまで)-----------------------------------------

for f in "$CV" "$TEST"; do
    [ -f "$f" ] || { echo "UNMEASURED  無い: ${f#$ROOT/}"; exit 2; }
done
/bin/cp "$CV" "$(snap_path 0)" || { echo "UNMEASURED  複製を取れない(復元手段が無いので走らない)"; exit 2; }
# 複製が取れた後に目印を書く。先に書くと、複製に失敗した回が
# 「戻せる複製が在る」と嘘の申告を残す。
printf '%s\t%s\n' "$CV" "$(snap_path 0)" > "$INFLIGHT"

ok() { PASS=$((PASS+1)); echo "  OK   $1"; }
ng() { FAIL=$((FAIL+1)); echo "  NG   $1"; }
un() { UNMEASURED=$((UNMEASURED+1)); echo "  UNM  $1"; }

run_unit() { # $1 = log -> rc を印字
    local log="$1" rc=0
    ( cd "$ROOT/rc-backend" && node --test test/bar-is-composer-only.test.mjs ) >"$log" 2>&1 || rc=$?
    printf '%s' "$rc"
}
# 検査の名は日本語で空白を含むので、一覧を作らず1件ずつ問う。
is_red()   { grep -q "^not ok [0-9]* - .*$2" "$1"; }
is_green() { grep -q "^ok [0-9]* - .*$2" "$1"; }

N_ANCHOR1="切り出しが両端とも合っている"
N_ANCHOR2=".fill(.bar) は会話画面の何処かに在る"
N_ANCHOR3=".ultraThinMaterial は会話画面の何処かに在る"
N_CLAIM="灰色の帯は composer だけ"

# ---- 変異 ---------------------------------------------------------------------
mutate() { # $1 = 変異の名
    MUT="$1" /usr/bin/python3 - "$CV" <<'PY'
import io, os, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
mut = os.environ["MUT"]
# ★2026-08-29: composer の帯が系ごとに2つになった(glass = material の Rectangle /
# 非 glass = `Rectangle().fill(.bar)`)。植える側も**両方**を植えないと、glass の系で
# 帯が footer へ戻った日にこの対照が沈黙する —— 変異は守っている物と同じ数だけ要る。
BAR = ".fill(" + ".bar)"
GLASS_BAR = ".ultraThin" + "Material"
if mut == "bar-ceiling":
    a = '                .accessibilityIdentifier("conversation.loadEarlierCeiling")'
    if s.count(a) == 1:
        s = s.replace(a, "                .background(Rectangle().fill(.bar))\n" + a)
elif mut == "bar-button":
    a = "            .frame(maxWidth: .infinity)\n\n        case .atCeiling:"
    if s.count(a) == 1:
        s = s.replace(a, "            .frame(maxWidth: .infinity)\n"
                      + "            .background(Rectangle().fill(.bar))\n\n        case .atCeiling:")
elif mut == "anchor-truncated":
    a = "conversation.loadEarlierCeiling"
    if s.count(a) == 1:
        s = s.replace(a, "conversation.ceilingNotice")
elif mut == "spelling-gone":
    # 非 glass の枝の帯を丸ごと消す。錨②(`.fill(.bar)` が在る)が赤くなるべき所。
    a = "Rectangle().fill(.bar).ignoresSafeArea(edges: .bottom)"
    if a in s:
        s = s.replace(a, "Color.clear", 1)
elif mut == "glass-bar-ceiling":
    # ★新規(2026-08-29): glass の系の帯を footer へ戻す。主張の glass 版が赤くなるべき所。
    a = '                .accessibilityIdentifier("conversation.loadEarlierCeiling")'
    if s.count(a) == 1:
        s = s.replace(a, "                .background(." + "ultraThinMaterial)\n" + a)
elif mut == "glass-spelling-gone":
    # glass の帯の材質ごと消す。新しい錨(material が在る)が赤くなるべき所。
    s = s.replace(GLASS_BAR, "regularMaterial")
else:
    raise SystemExit("知らない変異: " + mut)
io.open(p, "w", encoding="utf-8").write(s)
PY
}

probe() { # $1=名 $2=変異 $3=赤くなるべき検査 $4=(任意)緑のままであるべき検査
    local name="$1" mut="$2" want="$3" stays="${4:-}"
    restore_all
    local before after
    before=$(shasum "$CV" | awk '{print $1}')
    mutate "$mut"
    after=$(shasum "$CV" | awk '{print $1}')
    # ★バイトが動かない = 探し文が今の本文に当たっていない(整形や改名で静かに外れる)。
    #   これを緑にすると「変異を植えても赤くならない」を「検査が強い」と読む事になる。
    if [ "$before" = "$after" ]; then
        un "$name: 変異が当たっていない(bytes が動かない)= 測っていない。探し文を付け直す事"
        restore_all
        return
    fi
    local log="$LOGDIR/$name.log" rc
    rc=$(run_unit "$log")
    if [ "$rc" -eq 0 ]; then
        ng "$name: 欠陥を植えたのに全部緑。この検査は $name を測っていない。全文: $log"
    elif is_red "$log" "$want"; then
        ok "$name -> 赤: $want"
        if [ -n "$stays" ]; then
            if is_green "$log" "$stays"; then
                echo "       (実演: $stays は緑のまま = 片側の検査だけでは此の欠陥は通る)"
            else
                un "$name: 対になる検査($stays)まで赤くなった = 2本が別の物を測っている実演にならない"
            fi
        fi
    else
        un "$name: 赤くはなったが $want ではない(rc=$rc)。全文: $log"
    fi
    restore_all
}

echo "=== 基準(変異なし)"
BASE_LOG="$LOGDIR/base.log"
rc=$(run_unit "$BASE_LOG")
if [ "$rc" -ne 0 ]; then
    un "基準が緑でない(rc=$rc)。以降は測れない。全文: $BASE_LOG"
    echo "--- 合計: PASS $PASS / FAIL $FAIL / UNMEASURED $UNMEASURED ---"
    exit 2
fi
for w in "$N_ANCHOR1" "$N_ANCHOR2" "$N_ANCHOR3" "$N_CLAIM"; do
    if ! is_green "$BASE_LOG" "$w"; then
        un "基準で緑であるべき検査が居ない: $w(名が変わったか、飛んでいる)"
        echo "--- 合計: PASS $PASS / FAIL $FAIL / UNMEASURED $UNMEASURED ---"
        exit 2
    fi
done
echo "  基準は緑、狙う4本とも実名で居る"

echo "=== 変異"
probe bar-ceiling      bar-ceiling      "$N_CLAIM"   "$N_ANCHOR1"
probe bar-button       bar-button       "$N_CLAIM"   "$N_ANCHOR1"
probe anchor-truncated anchor-truncated "$N_ANCHOR1" "$N_CLAIM"
probe spelling-gone    spelling-gone    "$N_ANCHOR2"
probe glass-bar-ceiling  glass-bar-ceiling   "$N_CLAIM"    "$N_ANCHOR1"
probe glass-spelling-gone glass-spelling-gone "$N_ANCHOR3"

# ---- 復元の確認 ---------------------------------------------------------------
# trap の前に自分で確かめる。trap 任せだと、戻っていない木で「緑」を出せてしまう。
if ! cmp -s "$(snap_path 0)" "$CV"; then
    un "走行後に ConversationView.swift が元へ戻っていない。git checkout -- で戻す事"
fi

echo "--- 合計: PASS $PASS / FAIL $FAIL / UNMEASURED $UNMEASURED ---"
[ "$UNMEASURED" -gt 0 ] && exit 2
[ "$FAIL" -gt 0 ] && exit 1
exit 0
