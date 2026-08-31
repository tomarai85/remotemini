#!/bin/bash
# controls-for: tools/run-controls-coverage.sh
#
# 「取りこぼしが無いか」を答える計器が、**答えるだけで何も起こさない**事の対照。
#
# ── なぜ要るか(2026-08-31、自分で踏んだ)────────────────────────────────────
# 初版の案内文が「二重引用符の中に backtick」を書いていた。bash は其れを命令置換として
# 扱うので、読むだけの筈の計器が **40 分の掃引を黙って起動していた**。発覚は `ps` の
# 親子を辿った時 —— coverage → run-controls --resume → conversation-ui-control → xcodebuild が
# 砂場で走り、同時に走っていた `build.sh --sim` と資源を食い合っていた。
#
# ★教訓は「引用符に気を付ける」ではない。**其れは次も見落とす**。
#   計器が読み取り専用である事を、目でなく**対照で**押さえる。
#
#   V1 ★★計器を走らせても掃引が起動しない(偽の掃引に印を書かせて実測する)
#   V2 集計行 `green=N red=N 未測定=N` を刷る(此の書式は任務の判定条件でもある)
#   V3 台帳に判定の無い対照を名指しして非零で降りる
#   V4 ★空の台帳では非零(= 「何も測っていない」を緑に丸めない)
#   V5 理由付きで外した対照は**名前を刷る**(黙って消えない事が除外の条件)
#   V6 同じ対照が複数回 積まれていたら**最後の行**を採る(`--resume` の後の姿)
#   V7 門が答えない時は 2(測っていない)。0 にも 1 にも丸めない
#   N1 ★陰性: backtick の形を戻すと V1 が倒れる(V1 が空虚でない事の確認)
#
# 使い方: bash rc-backend/test/run-controls-coverage-controls.sh
# 終了コード: 0=全部緑 / 1=1本でも赤
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # = rc-backend/
SUT="$HERE/tools/run-controls-coverage.sh"
[ -f "$SUT" ] || { echo "測る対象が無い: $SUT"; exit 1; }

pass=0; fail=0
ok() { echo "PASS  $1"; pass=$((pass + 1)); }
ng() { echo "FAIL  $1  ($2)"; fail=$((fail + 1)); }
SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT

BE="$SB/repo/rc-backend"
/bin/mkdir -p "$BE/tools" "$SB/repo/.harness"

# 偽の門が返す一覧。★**10 本以上**必要 —— 計器は「門が答えない」を少なすぎる本数で
# 判定する(門が壊れた時に静かに緑になるのを防ぐ為)。対照が其の閾値を割ると、
# 測っているつもりで `UNMEASURED` を測る事になる(初版で実際に踏んだ)。
FILLERS="f1 f2 f3 f4 f5 f6 f7 f8"
gate_list() {
    echo "rc-backend/test/alpha-controls.sh"
    echo "rc-backend/test/beta-controls.sh"
    echo "rc-backend/test/gone-controls.sh"
    echo "rc-backend/test/edith-controls.sh"
    for f in $FILLERS; do echo "rc-backend/test/$f-controls.sh"; done
}

build_sandbox() { # build_sandbox <計器の中身の file>
    /bin/cp "$1" "$BE/tools/run-controls-coverage.sh"
    { echo '#!/bin/bash'; echo 'cat <<'"'"'L'"'"''; gate_list; echo 'L'; } \
        > "$BE/tools/staged-controls-gate.sh"
    # 偽の掃引: **走ったら印を残す**。之が此の対照の芯。
    printf '#!/bin/bash\necho ran >> "%s/RAN"\n' "$SB" > "$BE/tools/run-controls.sh"
    # 除外の宣言は掃引の側から読まれるので、偽の掃引に持たせる。
    printf 'EXCLUDED_CTLS=(\n    test/edith-controls.sh\n)\n' >> "$BE/tools/run-controls.sh"
    /bin/chmod +x "$BE/tools/"*.sh
}

LED="$SB/repo/.harness/run-controls-ledger.tsv"
row() { printf '%s\t%s\t%s\t1\n' "$1" "$2" "$3" >> "$LED"; }
fillers_green() { local i=10; for f in $FILLERS; do row "$i" "$f-controls.sh" 0; i=$((i+1)); done; }

run_sut() { # 出力は $SB/out.txt、rc は $RUN_RC
    /bin/rm -f "$SB/RAN"
    /bin/bash "$BE/tools/run-controls-coverage.sh" > "$SB/out.txt" 2>&1
    RUN_RC=$?
}
tally() { /usr/bin/grep -oE 'green=[0-9]+ +red=[0-9]+ +未測定=[0-9]+' "$SB/out.txt" | /usr/bin/head -1; }

# ── 揃った台帳(alpha 緑 / beta 赤 / gone 未測定 / edith は除外 / filler 8 本 緑)──
build_sandbox "$SUT"
: > "$LED"; row 1 alpha-controls.sh 0; row 2 beta-controls.sh 1; row 3 gone-controls.sh 2; fillers_green
run_sut

if [ -f "$SB/RAN" ]; then
    ng "V1 ★計器が掃引を起動した" "読むだけの筈の道具が 40 分の走行を始める(2026-08-31 に実際に出荷しかけた)"
else
    ok "V1 ★★計器を走らせても掃引は起動しない(偽の掃引に印が無い)"
fi

if [ -n "$(tally)" ]; then
    ok "V2 集計行を刷る($(tally))"
else
    ng "V2 集計行" "書式が無い: $(/usr/bin/tail -2 "$SB/out.txt" | /usr/bin/tr '\n' ' ')"
fi

/usr/bin/grep -q 'edith-controls.sh' "$SB/out.txt" \
    && ok "V5 理由付きで外した対照の名前を刷る(黙って消えない)" \
    || ng "V5 除外の名前" "外した物が出力に出ない = 黙って消える"

[ "$RUN_RC" = "0" ] && ok "V2b 取りこぼしが無ければ 0(赤や未測定が在っても、判定は付いている)" \
                    || ng "V2b 終了コード" "rc=$RUN_RC / $(/usr/bin/tail -1 "$SB/out.txt")"

# ── V3 判定の無い対照 ───────────────────────────────────────────────────────
: > "$LED"; row 1 alpha-controls.sh 0; row 2 beta-controls.sh 1; fillers_green
run_sut
if [ "$RUN_RC" != "0" ] && /usr/bin/grep -q 'gone-controls.sh' "$SB/out.txt"; then
    ok "V3 判定の無い対照を名指しして非零で降りる"
else
    ng "V3 取りこぼしの検出" "rc=$RUN_RC / gone を名指しした数=$(/usr/bin/grep -c 'gone-controls' "$SB/out.txt")"
fi

# ── V4 ★空の台帳 ───────────────────────────────────────────────────────────
: > "$LED"
run_sut
[ "$RUN_RC" != "0" ] && ok "V4 ★空の台帳では非零(何も測っていないを緑に丸めない)" \
                     || ng "V4 空の台帳" "rc=0 = 一度も回していない状態が緑になる"

# ── V6 最後の行が正 ─────────────────────────────────────────────────────────
# `--resume` の後は同じ名前が2回 積まれる。古い赤を引き摺ると、直したのに赤のままになる。
: > "$LED"; row 1 alpha-controls.sh 1; row 2 alpha-controls.sh 0
row 3 beta-controls.sh 0; row 4 gone-controls.sh 0; fillers_green
run_sut
if /usr/bin/grep -qE 'green=11 +red=0' "$SB/out.txt"; then
    ok "V6 同じ対照が2回 積まれていたら最後の行を採る(alpha の赤→緑が効く)"
else
    ng "V6 最後の行" "$(tally)(green=11 red=0 が期待)"
fi

# ── V7 門が答えない ─────────────────────────────────────────────────────────
printf '#!/bin/bash\nexit 1\n' > "$BE/tools/staged-controls-gate.sh"; /bin/chmod +x "$BE/tools/staged-controls-gate.sh"
run_sut
[ "$RUN_RC" = "2" ] && ok "V7 門が答えない時は 2(測っていない)" \
                    || ng "V7 門の沈黙" "rc=$RUN_RC(2 が期待)= 門が壊れた事を緑や赤に丸めている"

# ── N1 ★陰性: backtick の形を戻すと V1 が倒れる ─────────────────────────────
# 之が無いと V1 は「たまたま起動しなかった」と区別が付かない。
# ★変異は python3 で行う。sed で backtick を扱うと引用の階層が3枚になり、
#   「錨が動いた」のか「sed の引用が壊れた」のか切り分けられない。
MUT="$SB/mutated.sh"
if python3 - "$SUT" "$MUT" <<'PY'
import io, sys
src, dst = sys.argv[1], sys.argv[2]
s = io.open(src, encoding="utf-8").read()
anchor = "echo '  直し方: 掃引を回す(bash rc-backend/tools/run-controls.sh --resume)か、'"
if anchor not in s:
    sys.exit(3)
io.open(dst, "w", encoding="utf-8").write(
    s.replace(anchor, 'echo "  直し方: `bash "$HERE/run-controls.sh" --resume`"', 1))
PY
then
    build_sandbox "$MUT"
    : > "$LED"; row 1 alpha-controls.sh 0; fillers_green
    run_sut
    if [ -f "$SB/RAN" ]; then
        ok "N1 ★陰性: backtick の形へ戻すと掃引が起動する(V1 は空虚でない)"
    else
        ng "N1 陰性が発火しない" "backtick を戻しても起動しない = V1 は何も守っていない"
    fi
else
    ng "N1 ★陰性が空振り" "変異の錨が動いた = 案内文の形が変わった。錨を書き直す事"
fi

echo ""
echo "RUN-CONTROLS-COVERAGE-CONTROLS: pass=$pass fail=$fail"
exit $(( fail > 0 ))
