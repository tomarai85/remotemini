#!/bin/bash
# `tools/mutation-run-live.sh` が「走行中か」を**正しく**見分ける事の確認。
#
# なぜ要るか(2026-08-02): この判定は3箇所(配備 / 的検査 / その対照)に複製されていて、
#   3つとも同じ欠陥 —— 素の `pgrep -f 'mutation-controls\.py'` は**文字列を含むだけの
#   無関係なプロセス**にも当たる —— を持っていた。実害は2つ:
#     (a) 待ち受け `until ! pgrep -f mutation-controls.py; ...` が**自分自身**を見つけて
#         永久に終わらない(実測で2本が1時間53分回り続けていた)
#     (b) `tools/deploy-to-edith.sh` はこの判定で配備を拒否するので、無関係なシェルが1本
#         残っているだけで**配備が恒久的に塞がる**
#
# ★★2026-08-04 の作り直し。監査2本が独立に同じ首位を出した ——
#   **この対照は本体を呼んでいなかった**。判定の正規表現を手で写して `pgrep` するだけで、
#   5本中4本が `bash "$LIVE"` を一度も実行していない。つまり本体側だけが穴に戻っても
#   この対照は緑のまま。本体の冒頭が「複製された判定は片方だけ直して片方が腐る」と
#   書いている、その教訓が**対照そのものの形で再演されていた**。
#   直した点は3つ:
#     1. 正規表現を**本体から抜く**(写しを持たない。取り出せなければ赤で止まる)
#     2. 各シナリオで **`bash "$LIVE"` を実際に呼ぶ**
#     3. 囮は**一度に1つだけ**生かす。前は W/E/R/RU が同時に生きていて、旗なしの R が
#        常に本物の一致を供給していたので、広すぎ/狭すぎの退行がその陰に隠れた
#
# ★★★同日、Codex の査読で更に4点。**囮の判別しか測っていなかった**のが要点:
#     4. 本体の**終了コードの作り方**を、`pgrep` の差し替え(下の ⑤)で直接撃つ。囮を使う
#        (1)-(3b) は「一致するか」しか測れないので、`pgrep` が**失敗した**時に本体が何と
#        答えるかを一度も見ていなかった。実際そこが最大の穴で、旧版は失敗を「居ない」に
#        丸めており、配備の門が**判らない時に開いて**いた(同日 fail-closed へ是正)。
#     5. `head -1` を捨てる。`PAT=` が2つある木では**先頭を黙って採る**ので、実際に使われる
#        方と違う正規表現で全シナリオを測り得た。曖昧なら測らずに赤で止まる方が正しい。
#     6. 各シナリオの前後で**一致集合そのもの**を撮る。知らない PID が湧いていたら、
#        緑も赤も自分の囮の話ではない = 未測定として出す。
#     7. 劣化版(member)の緑を `PASS` と印字しない。同じ語で出すと、後から読む人には
#        「本体を実行して確かめた」と読める —— この作り直しが潰した嘘そのもの。
#
# ★残る制約を隠さない: `$LIVE` は「今この機械で何か走っているか」しか答えない。
#   本物の変異走行の最中はどの囮でも 0 を返すので、直接呼びでは discriminate できない。
#   その時は **PID が一致集合に入るか**という劣化版へ落ちる —— ただし黙って落ちず、
#   どちらの脚で測ったかを1行ずつ出し、**終了コードを 2(未測定)にする**
#   (`tools/run-controls.sh` の規約)。劣化版の緑で 0 を返すと「本体を実行して確かめた」と
#   読まれてしまい、この作り直しが潰した嘘がそのまま復活する。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# ★継ぎ目。`tools/prove-control.sh` が**直す前の版**を此処へ差し込んで、
#   「その旧版でこの対照が本当に赤くなるか」を機械で確かめられる様にする(差替型)。
#   手で壊して手で戻す証明は1回きりで、次に誰かが回す物が無い —— それが
#   `tools/run-controls.sh` の頭に在る規則が一度守られなかった理由そのもの。
LIVE="${MUTLIVE_SCRIPT:-$ROOT/tools/mutation-run-live.sh}"

pass=0; fail=0; weak=0; unmeasured=0
ok()   { pass=$((pass+1)); echo "PASS  $1"; }
ng()   { fail=$((fail+1)); echo "FAIL  $1  ($2)"; }
# ★劣化版の緑は `PASS` と書かない(Codex 指摘 7)。語が同じだと強さの違いが消える。
weakly() { weak=$((weak+1)); echo "WEAK  $1  — 弱い一致。緑ではない"; }
unmeas() { unmeasured=$((unmeasured+1)); echo "UNMEA $1  ($2)"; }

# --- 0) 判定の正規表現を**本体から抜く**(写しを持たない) ----------------------
#   `test/mutation-target-controls.sh` の ALPHA と同じ作法。本体が置き場所を変えたら
#   取り出しが空になって**此処で赤く止まる** = 以降の全判定が当てにならない事を明示する。
#   ★`head -1` を使わない: 曖昧さを「先頭を採る」で消すと、**実際に効く方と違う版**で
#     全シナリオを測ってしまう。丁度1本でなければ測らない。
NPAT="$(/usr/bin/grep -c "^PAT='" "$LIVE" 2>/dev/null || true)"
PAT="$(sed -n "s/^PAT='\(.*\)'\$/\1/p" "$LIVE")"
if [ "$NPAT" != "1" ]; then
    ng "正規表現の取り出し" "本体の \`^PAT='\` が ${NPAT} 本ある。1本でないと、どれが効くか判らない"
    echo ""; echo "MUTATION-RUN-LIVE-CONTROLS: pass=$pass fail=$fail"; exit 1
elif [ "${#PAT}" -ge 20 ]; then
    ok "判定の正規表現を本体から丁度1本取り出せた(写しを持たない)"
else
    ng "正規表現の取り出し" "取れたのは「${PAT}」— 本体の書き方が変わった。以降は測れないので止める"
    echo ""; echo "MUTATION-RUN-LIVE-CONTROLS: pass=$pass fail=$fail"; exit 1
fi

# ★囮は必ず stdout を切って起動する事(`>/dev/null 2>&1 &`)。
#   切らないと、この対照を `out=$(bash ...)` の形で呼んだ親が**囮の sleep が終わるまで待つ**。
#   コマンド置換は「書き手が全員 pipe を閉じる」まで返らないので、背景の子が pipe を
#   握ったままだと親が固まる。実測: 1秒で終わる筈の対照が 31 秒かかった(2026-08-02)。
DECOY=""
SB=""
cleanup() {
    [ -n "$DECOY" ] && kill "$DECOY" 2>/dev/null
    # 中身は自分で置いた物だけなので、名指しで消す(`rm -rf` を使わない)。
    if [ -n "$SB" ] && [ -d "$SB" ]; then
        /bin/rm -f "$SB/test/mutation-controls.py" "$SB/bin/pgrep" "$SB/argv.txt"
        /bin/rmdir "$SB/test" "$SB/bin" "$SB" 2>/dev/null
    fi
    return 0
}
trap cleanup EXIT INT TERM

matched() {  # $1 = pid → その pid が一致集合に居れば 0
    pgrep -f "$PAT" 2>/dev/null | grep -qx "$1"
}
# ★一致集合そのものの写し(Codex 指摘 6)。シナリオの前後で変わっていたら、
#   その緑/赤は**自分の囮の話ではない**。知らない走行が湧いた木では判定を信じない。
snapshot() { pgrep -f "$PAT" 2>/dev/null | sort | tr '\n' ' '; }

# 囮の argv が実際に見える様になるまで待つ。固定 sleep は速い機械で早すぎ、
# 混んだ機械で遅すぎる —— どちらも「測れていないのに緑」を作る。
# ★待つ的は**最終形の argv**にする(Codex 指摘 5)。`&` で起こした子は exec の前後で
#   argv が変わるので、途中の形に当たって先へ進むと「まだ python になっていない」
#   プロセスを測ってしまう。だから台本の実パスなど、最終形にしか無い字を渡す事。
wait_argv() {  # $1=pid $2,$3=argv に含まれる筈の文字列(全部含むまで待つ)
    local pid="$1"; shift
    local s
    for _ in $(seq 1 60); do
        local cmd; cmd="$(ps -o command= -p "$pid" 2>/dev/null)"
        local all=1
        for s in "$@"; do
            case "$cmd" in *"$s"*) : ;; *) all=0 ;; esac
        done
        [ "$all" -eq 1 ] && return 0
        sleep 0.1
    done
    return 1
}
wait_gone() {  # $1=pid → 消えるまで待つ。残ったまま次へ進むと囮が混ざる
    for _ in $(seq 1 60); do kill -0 "$1" 2>/dev/null || return 0; sleep 0.1; done
    return 1
}
drop_decoy() {
    [ -z "$DECOY" ] && return 0
    kill "$DECOY" 2>/dev/null
    wait_gone "$DECOY" || ng "囮の後始末" "pid $DECOY が残っている — 次のシナリオが汚れる"
    wait "$DECOY" 2>/dev/null
    DECOY=""
    # 撤収後の一致集合が基準線へ戻っているか。戻らなければ知らない走行が居る。
    local now; now="$(snapshot)"
    if [ -n "${BASE_SET+x}" ] && [ "$now" != "$BASE_SET" ]; then
        unmeas "一致集合が基準線へ戻らない" "基準[${BASE_SET}] 今[${now}] — 知らない走行が湧いた"
        BASE_SET="$now"   # 以降の比較が延々と鳴らない様に、新しい基準へ乗せ替える
    fi
    return 0
}

# --- baseline: 囮ゼロで本体を呼ぶ。ここが 0 なら**本物の走行が同居している** -----
BASE_SET="$(snapshot)"
bash "$LIVE"; BASE=$?
if [ "$BASE" -eq 1 ]; then
    MODE=direct
    ok "基準線: 囮ゼロで本体が「動いていない」= 直接呼びで判別できる"
elif [ "$BASE" -eq 0 ]; then
    MODE=member
    echo "NOTE  本物の変異走行が同居している(基準線 exit=0)。"
    echo "NOTE  直接呼びでは囮を判別できないので、PID の所属で測る劣化版へ落ちる。"
else
    # 本体が「測れなかった」と答えた。囮の判別は全部当てにならない。
    MODE=member
    unmeas "基準線" "本体が exit=$BASE(測れなかった)を返した — pgrep 自体が動いていない"
fi

# 各シナリオの本体。`want` = 「この囮は走行として数えられるべきか」
judge() {  # $1=label $2=pid $3=want(yes|no) $4=失敗時の意味
    local rc
    if [ "$MODE" = direct ]; then
        bash "$LIVE"; rc=$?
        # direct: exit 0 = 走行中と判定 / exit 1 = 居ない / それ以外は測れていない
        if [ "$rc" -ne 0 ] && [ "$rc" -ne 1 ]; then
            unmeas "$1 [本体を実行して判定]" "本体が exit=$rc = 判定不能を返した"
        elif { [ "$3" = yes ] && [ "$rc" -eq 0 ]; } || { [ "$3" = no ] && [ "$rc" -eq 1 ]; }; then
            ok "$1 [本体を実行して判定]"
        else
            ng "$1 [本体を実行して判定]" "$4 — 本体の exit=$rc 期待=$([ "$3" = yes ] && echo 0 || echo 1)"
        fi
    else
        if { [ "$3" = yes ] && matched "$2"; } || { [ "$3" = no ] && ! matched "$2"; }; then
            weakly "$1 [劣化版: PID の所属だけ。本体は実行していない]"
        else
            ng "$1 [劣化版: PID の所属]" "$4"
        fi
    fi
}

# --- 1) 偽陽性(a): 待ち受け自身。文字列は含むが python ではない ---
bash -c 'until ! pgrep -f mutation-controls.py >/dev/null 2>&1; do sleep 30; done' >/dev/null 2>&1 &
DECOY=$!
wait_argv "$DECOY" 'until ! pgrep -f mutation-controls.py' || ng "囮の起動(待ち受け)" "argv が見えない"
judge "待ち受けを走行と誤認しない(自己参照しない)" "$DECOY" no \
      "自己参照 — この判定を使う待ち受けは永久に終わらない"
drop_decoy

# --- 2) 偽陽性(b): 編集セッション相当。やはり python ではない ---
bash -c 'V="vim test/mutation-controls.py"; sleep 30' >/dev/null 2>&1 &
DECOY=$!
wait_argv "$DECOY" 'V="vim test/mutation-controls.py"' || ng "囮の起動(編集)" "argv が見えない"
judge "編集セッションを走行と誤認しない" "$DECOY" no \
      "無関係なシェルで配備が塞がる"
drop_decoy

# --- 3) 真陽性: 本物の形。ここが緑でないと**守りごと効かない** ---
#   (1)(2) だけ通す判定は「常に走行していない」と言えば作れてしまう。
SB="$(mktemp -d /tmp/mutlive-ctl.XXXXXX)"
mkdir -p "$SB/test" "$SB/bin"
printf 'import time\ntime.sleep(30)\n' > "$SB/test/mutation-controls.py"
python3 "$SB/test/mutation-controls.py" >/dev/null 2>&1 &
DECOY=$!
wait_argv "$DECOY" "$SB/test/mutation-controls.py" || ng "囮の起動(走行)" "argv が見えない"
judge "本物の走行は捕まえる(守りが効いている)" "$DECOY" yes \
      "★守りが空振り — 走行中でも配備できてしまう"
drop_decoy

# --- 3b) 真陽性: **旗付き**の形。2026-08-02 夜に実際に漏れた形そのもの ---
#   `python3 -u <台本>`。(3) が旗なしの形だけを囮にしていた為、`[^ ]*` が `-u` を跨げない
#   という穴が**対照が全部緑のまま**残っていた。私はその穴に落ちて走行中に2本目を起動し、
#   配備の門(`tools/deploy-to-edith.sh`)も同じ判定なので黙って開いていた。
#   ★教訓の形: 偽陽性の対照だけ増やしても偽陰性は見えない。**門は両向きに撃つ**。
#   ★2026-08-04: 此処が**囮を1つだけ生かして**測る様になった事が肝。前は (3) の旗なしが
#     同時に生きていたので、旗付きを跨げない退行が (3) の一致に隠れて見えなかった。
python3 -u "$SB/test/mutation-controls.py" >/dev/null 2>&1 &
DECOY=$!
wait_argv "$DECOY" "-u $SB/test/mutation-controls.py" || ng "囮の起動(旗付き走行)" "argv が見えない"
judge "旗付き(python3 -u …)の走行も捕まえる" "$DECOY" yes \
      "★偽陰性 — 走行中なのに「動いていない」と答える"
drop_decoy

# --- ⑤ 終了コードの作り方そのもの(`pgrep` を差し替えて撃つ) -------------------
#   (1)-(3b) は「一致するか」しか測れない。此処は層が違う: `pgrep` が**失敗した**時に
#   本体が何と答えるか。旧版は `pgrep … && exit 0; exit 1` で、失敗(2=構文 / 3=致命 /
#   127=不在)を全部「居ない」に丸めていた —— 配備の門は「居ない」で**開く**ので、
#   判定不能の瞬間に黙って通る fail-open だった。
#   ★この脚は囮を使わないので、本物の走行が同居していても測れる(direct/member 共通)。
STUB="$SB/bin/pgrep"
{
    echo '#!/bin/bash'
    echo 'printf "%s\n" "$@" > "${PGREP_ARGV_OUT:-/dev/null}"'
    echo 'exit "${PGREP_RC:-1}"'
} > "$STUB"
/bin/chmod +x "$STUB"
ARGVF="$SB/argv.txt"

# pgrep の終了コード → 本体が返すべき値。0=走行中 / 1=居ないと確認 / それ以外=測れなかった
for pair in "0 0" "1 1" "2 2" "3 2" "127 2"; do
    set -- $pair
    drv="$1"; want="$2"
    PATH="$SB/bin:$PATH" PGREP_RC="$drv" PGREP_ARGV_OUT="$ARGVF" bash "$LIVE" >/dev/null 2>&1
    got=$?
    if [ "$got" -eq "$want" ]; then
        ok "pgrep が exit=${drv} を返した時、本体は exit=${want}($([ "$want" = 2 ] && echo 測れなかった || echo 確定))"
    else
        ng "pgrep exit=${drv} → 本体 exit=${want}" \
           "実際は ${got}。$([ "$drv" -ge 2 ] && echo '★fail-open: 判定不能を「居ない」に丸めると配備の門が開く' || echo '確定値の対応が壊れている')"
    fi
done

# 本体が `pgrep` に渡す引数が、抜き出した正規表現**そのもの**である事。
#   (別の物を渡していたら、上の (1)-(3b) は「本体が実際に使う判定」を測っていない)
# `$(...)` は末尾の改行を落とすので、期待値も同じ作り方で作って比べる(片方だけ
# 生の file 内容にすると、改行の有無で永久に赤くなる)。
want_argv="$(printf -- '-f\n%s\n' "$PAT")"
got_argv="$(/bin/cat "$ARGVF" 2>/dev/null)"
if [ "$got_argv" = "$want_argv" ]; then
    ok "本体は pgrep へ丁度 \`-f <抜き出した正規表現>\` を渡している"
else
    ng "pgrep へ渡す引数" "期待[-f / ${PAT}] 実際[$(printf '%s' "$got_argv" | tr '\n' '|')]"
fi

# --- ⑥ `--who` は**実行体の名前しか出さない**(引数を出さない) ----------------
#   `--who` は塞がった人が「当たったのは本当に python か」を見る為の口。当たる相手は
#   **無関係なコマンド行**であり得るので(`pgrep -f` は argv 全体に当たる)、そこに何が
#   書かれているかは判らない。過去に `pgrep -lf` が OAuth の秘密を transcript へ吐いた事が
#   あるので、この口が argv を出さない事を機械で押さえる。
#   ★此処では「その囮に当たる事」は**主張しない**。当たる事自体が直したい欠陥なので、
#     それを期待値にすると欠陥を仕様として固定してしまう。測るのは出力の形だけ。
CANARY='CANARY-MUST-NOT-BE-PRINTED'
bash -c 'X="python3 -u /nowhere/test/mutation-controls.py CANARY-MUST-NOT-BE-PRINTED"; sleep 30' >/dev/null 2>&1 &
DECOY=$!
if wait_argv "$DECOY" "$CANARY"; then
    who="$(bash "$LIVE" --who 2>/dev/null)"
    if printf '%s' "$who" | grep -q "$CANARY"; then
        ng "--who が argv を出さない" "★秘密が漏れる形 — 当たった相手のコマンド行をそのまま出している"
    else
        ok "--who は argv を出さない(当たった相手の中身が何であっても安全)"
    fi
    bad="$(printf '%s\n' "$who" | grep -v '^[0-9][0-9]* ' | grep -c . || true)"
    if [ "$bad" = "0" ]; then
        ok "--who の各行が「pid と実行体」の形をしている"
    else
        ng "--who の出力の形" "「pid 実行体」でない行が ${bad} 本ある"
    fi
else
    unmeas "--who の出力" "囮の argv が見えない — 何も当たっていない状態では測れない"
fi
drop_decoy

echo ""
echo "MUTATION-RUN-LIVE-CONTROLS: pass=$pass fail=$fail weak=$weak unmeasured=$unmeasured mode=$MODE"
# 終了コードは `tools/run-controls.sh` の規約に合わせる: 0=緑 / 1=赤 / **2=測っていない**。
#   劣化版で緑になった時に 0 を返すと、「本体を実行して確かめた」と読まれる —— それは
#   まさにこの作り直しが潰した嘘なので、区別を終了コードにも持たせる。
if [ "$fail" -gt 0 ]; then exit 1; fi
if [ "$unmeasured" -gt 0 ]; then
    echo "  未測定(緑ではない): 上の UNMEA を読む事。測れなかった脚が ${unmeasured} 本ある。"
    exit 2
fi
if [ "$MODE" != direct ]; then
    echo "  未測定(緑ではない): 本物の変異走行と同居していて、本体を実行しての判別ができなかった。"
    echo "  走行が終わってから回し直す事。"
    exit 2
fi
exit 0
