#!/bin/bash
# controls-for: tools/verify-rc-backend-state.sh
#
# 何を守る対照か —— **証拠 JSON を作る側が、測っていないのに緑を出さない事**。
#
# `verify-rc-backend-state.sh` は safety-core の HARD GATE 1 が食う artifact を作る。
# つまりこの道具が嘘を吐くと、その上に建つ本番判断(「止まっている」「動いている」)が
# **全部まとめて**嘘になる。AI の主観を証拠に使わない為の道具なので、道具自身が
# 主観に落ちていないかは別の場所から測るしかない。
#
# ★この対照の**範囲**(広く読まれると危ないので明示する):
#   見る   = 観測値を与えられた時の**判定**(層の一致・真の停止・復帰)。本物のバイトを切り出す。
#   見ない = プローブ自身(jobpid / listener / httpcode / wrapperkids)。あれは本物の
#            launchd と 8787 に触るので、edith の上でしか動かない。ここでは**駆動しない**。
#   なので「この対照が緑 = 道具が正しい」ではない。「**判定は正しい**」までしか言わない。
#
# ★本番には一度も触れない。`--prove-stop` は実際に常設を bootout する道具なので、
#   この対照は判定ブロックだけを切り出して**合成の観測値**で回す。ssh も launchctl も
#   1回も呼ばない。
#
# ★写しを持たない。判定は本物の file から切り出す。切り出せなくなったら 2 で落ちる
#   = 本体を書き換えた時に、古い形を緑に保ち続ける事が起きない。
#
# 終了コード: 0 = 守られている / 1 = 破れている / 2 = 測れていない
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="$ROOT/tools/verify-rc-backend-state.sh"

if [ ! -f "$TARGET" ]; then
    echo "UNMEASURED  読む file が無い: tools/verify-rc-backend-state.sh"
    exit 2
fi

SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "  ok   $1"; }
ng() { FAIL=$((FAIL + 1)); echo "  ng   $1"; }
chk() { # $1=説明 $2=実際 $3=期待
    if [ "$2" = "$3" ]; then ok "$1"; else ng "$1 —— 実際=[$2] 期待=[$3]"; fi
}

# ---- 判定ブロックを本物から切り出す ----------------------------------------
# 錨は行番号ではなく**中身**。錨が一意でなければ切らずに 2 で落ちる。
slice() { # $1=開始行の正規表現 $2=終了行の正規表現 $3=出力先
    local s e
    s=$(grep -nE "$1" "$TARGET" | cut -d: -f1)
    e=$(grep -nE "$2" "$TARGET" | cut -d: -f1)
    if [ "$(echo "$s" | wc -w)" -ne 1 ] || [ "$(echo "$e" | wc -w)" -ne 1 ]; then
        echo "UNMEASURED  錨が一意でない(開始=[$s] 終了=[$e])。錨を付け直す事。"
        exit 2
    fi
    if [ "$e" -le "$s" ]; then
        echo "UNMEASURED  終了の錨が開始より前に在る。形が変わった。"
        exit 2
    fi
    sed -n "${s},${e}p" "$TARGET" > "$3"
}

slice '^  ok=true; why=""$' '^  exit 0$' "$SB/observe.sh"
# ★prove-stop は `truly_stopped=true` からではなく **`sp=` の抽出から**切る。
#   判定の手前に在る「snapshot の JSON から欄を取り出す」所も判定の一部で、
#   ここの grep/cut が壊れると全欄が空になり、**空を「不在」と読んで緑になる**。
#   切り落とすと、この対照は一番危ない壊れ方を素通りさせる(初版で実際に落ちた)。
slice '^sp=' '^exit 0$' "$SB/provestop.sh"

# 切り出せた事を、中身で確かめる(空の file を回して緑にしない)。
grep -q 'layers_agree_running' "$SB/observe.sh"       || { echo "UNMEASURED  observe の判定が入っていない"; exit 2; }
grep -q 'truly_stopped_at_bootout' "$SB/provestop.sh" || { echo "UNMEASURED  prove-stop の判定が入っていない"; exit 2; }

# ---- 駆動する道具 ------------------------------------------------------------
# observe: p(launchd の pid) l(8787 の listener) c(HTTP) k(server.mjs のプロセス)
run_observe() { # $1=p $2=l $3=c $4=k  → JSON を吐き、判定の exit code を返す
    ( set +u
      p="$1"; l="$2"; c="$3"; k="$4"
      . "$SB/observe.sh" ) 2>/dev/null
}
agree() { run_observe "$@" | sed -n 's/.*"layers_agree_running": \([a-z]*\),.*/\1/p'; }
rc_of() { run_observe "$@" >/dev/null 2>&1; echo $?; }

# prove-stop: 止めた時の観測(snapshot 文字列)と戻した時の観測を作って食わせる
snap_json() { # $1=launchd_pid $2=listener $3=server_mjs_pids $4=job_present $5=http
    printf '{"launchd_pid":"%s","port8787_listener_pid":"%s","server_mjs_pids":"%s","launchd_job_present":%s,"http_code":"%s"}' \
        "$1" "$2" "$3" "$4" "$5"
}
run_provestop() { # $1=stopped の snapshot $2=back の snapshot
    ( set +u
      stopped="$1"; back="$2"
      . "$SB/provestop.sh" ) 2>/dev/null
}
field() { echo "$1" | sed -n "s/.*\"$2\": \([a-z]*\),.*/\1/p"; }

STOPPED_CLEAN="$(snap_json "" "" "" false 000)"
BACK_CLEAN="$(snap_json 4242 4242 4242 true 401)"

echo "── 1. observe: 層が揃っている時だけ緑 ──"
chk "  全層一致(pid も 401 も揃う)は true" "$(agree 1234 1234 401 1234)" "true"
chk "  そのとき exit 0" "$(rc_of 1234 1234 401 1234)" "0"

echo "── 2. observe: 層が1つでも欠けたら赤(4通り)──"
chk "  launchd に pid が無い" "$(agree "" 1234 401 1234)" "false"
chk "  8787 に listener が居ない" "$(agree 1234 "" 401 1234)" "false"
chk "  ★pid が食い違う(古い居座り)" "$(agree 1234 5678 401 5678)" "false"
chk "  HTTP が 401 でない(認証層が居ない)" "$(agree 1234 1234 200 1234)" "false"
chk "  赤の時は exit 1" "$(rc_of 1234 5678 401 5678)" "1"

echo "── 3. ★observe: 何も動いていない時に緑を出さない ──"
# 一番危ない誤りは「全部空 = 食い違いが無い = 一致」と読む形。
chk "  全層が不在でも true にしない" "$(agree "" "" 000 "")" "false"

echo "── 4. ★observe: プローブが盲な時に自分でそう言う ──"
# listener は居るのに server.mjs が1つも見えない = pgrep のパターンが当たっていない。
# この道具は「残留無し」を証明する為に在るので、盲のまま緑を出したら存在意義が消える。
chk "  listener が居るのにプロセス0件は赤" "$(agree 1234 1234 401 "")" "false"
# ★判定ブロックは赤の時に exit 1 で終わる。`pipefail` の下で直にパイプへ繋ぐと、
#   grep が当たっても**パイプ全体が 1 を返す**ので、当たったのに ng に落ちる。
#   先に受け切ってから引く事(初版で実際に踏んだ)。
blind_out="$(run_observe 1234 1234 401 "")"
case "$blind_out" in
    *プローブが盲*) ok "  ★理由に「プローブが盲」と名指しで出る" ;;
    *) ng "  盲である事が JSON の理由欄に出ない" ;;
esac

echo "── 5. prove-stop: 止まって戻った時だけ緑 ──"
out="$(run_provestop "$STOPPED_CLEAN" "$BACK_CLEAN")"
chk "  4層すべて不在なら truly_stopped" "$(field "$out" truly_stopped_at_bootout)" "true"
chk "  pid 一致 + 401 なら restored" "$(field "$out" restored_after_bootstrap)" "true"
run_provestop "$STOPPED_CLEAN" "$BACK_CLEAN" >/dev/null 2>&1
chk "  そのとき exit 0" "$?" "0"

echo "── 6. prove-stop: 停止しきっていない4通りを全部赤にする ──"
for spec in "9999::::登録も pid も残る:launchd の pid" \
            ":9999:::8787 を掴んだまま:listener" \
            "::9999::server.mjs が残る:プロセス"; do
    IFS=: read -r sp sl sk _ desc _ <<< "$spec"
    o="$(run_provestop "$(snap_json "$sp" "$sl" "$sk" false 000)" "$BACK_CLEAN")"
    chk "  $desc" "$(field "$o" truly_stopped_at_bootout)" "false"
done
o="$(run_provestop "$(snap_json "" "" "" true 000)" "$BACK_CLEAN")"
chk "  launchd の登録が残る" "$(field "$o" truly_stopped_at_bootout)" "false"

echo "── 7. ★restored は『戻ったか』であると同時に**プローブの自己検査**である ──"
# 読んだだけでは見えない構造。listener / httpcode / jobpid のどれかが壊れて常に空を
# 返すなら、戻した後の観測が揃わないので restored が false になり、道具は exit 1 で落ちる。
# = 停止の観測(全部空)を「本当に止まった」と読んでしまう壊れ方を、**復帰側が捕まえる**。
# ここを「戻ってきたかどうかの確認」だと読んで簡素化すると、停止の証明が静かに死ぬ。
o="$(run_provestop "$STOPPED_CLEAN" "$(snap_json 4242 "" 4242 true 401)")"
chk "  listener プローブが盲なら restored=false" "$(field "$o" restored_after_bootstrap)" "false"
o="$(run_provestop "$STOPPED_CLEAN" "$(snap_json "" "" 4242 true 401)")"
chk "  jobpid プローブが盲なら restored=false" "$(field "$o" restored_after_bootstrap)" "false"
o="$(run_provestop "$STOPPED_CLEAN" "$(snap_json 4242 4242 4242 true 000)")"
chk "  httpcode プローブが盲なら restored=false" "$(field "$o" restored_after_bootstrap)" "false"
o="$(run_provestop "$STOPPED_CLEAN" "$(snap_json 4242 "" 4242 true 401)")"
chk "  ★そのとき道具は緑で終わらない" "$(run_provestop "$STOPPED_CLEAN" "$(snap_json 4242 "" 4242 true 401)" >/dev/null 2>&1; echo $?)" "1"

echo "── 8. 負の対照: 検査に歯が在るか(判定を壊したら赤が消えるか)──"
# 壊すのは切り出した写しだけ。本物の file には一切書かない。
# ★壊す向きに注意。形は `COND || { ok=false; }` なので、門を**無効化**するには
#   COND を常に真にする(`true ||` で短絡させる)。`false ||` にすると逆に**常に発火**し、
#   壊した筈の版が全部赤になって「歯が在る」と誤読する(初版で実際に踏んだ)。
sed 's/\[ -z "\$l" \] || \[ -n "\$k" \] ||/true ||/' "$SB/observe.sh" > "$SB/observe-mut.sh"
if cmp -s "$SB/observe.sh" "$SB/observe-mut.sh"; then
    echo "UNMEASURED  盲プローブの検査を壊す先が当たらない(負の対照が空撃ち)"
    exit 2
fi
mut_agree() { ( set +u; p="$1"; l="$2"; c="$3"; k="$4"; . "$SB/observe-mut.sh" ) 2>/dev/null \
    | sed -n 's/.*"layers_agree_running": \([a-z]*\),.*/\1/p'; }
chk "  ★盲プローブの検査を外すと、盲のまま緑になる(= 本物では効いている)" \
    "$(mut_agree 1234 1234 401 "")" "true"

sed 's/\[ "\$bc" = "401" \] ||/true ||/' "$SB/provestop.sh" > "$SB/provestop-mut.sh"
if cmp -s "$SB/provestop.sh" "$SB/provestop-mut.sh"; then
    echo "UNMEASURED  401 の検査を壊す先が当たらない(負の対照が空撃ち)"
    exit 2
fi
mo="$( ( set +u; stopped="$STOPPED_CLEAN"; back="$(snap_json 4242 4242 4242 true 000)"; \
        . "$SB/provestop-mut.sh" ) 2>/dev/null )"
chk "  ★401 の検査を外すと、応答が無くても復帰扱いになる(= 本物では効いている)" \
    "$(field "$mo" restored_after_bootstrap)" "true"

echo
echo "  == PASS $PASS / FAIL $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
