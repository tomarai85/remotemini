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
# ★★★2026-08-04、本体が**推定から観測へ**替わったので、この対照も丸ごと書き直した。
#   本体はもう argv を見ない。走行台本(`test/mutation-controls.py`)が印(lock/pid file)を
#   立て、本体はその主の生死を訊く。よって:
#     - 囮プロセスで「当たる/当たらない」を測る脚は**意味を失った**(全部捨てた)。
#       残した囮は1つだけ、`--who` が argv を出さない事を撃つ為の物。
#     - 代わりに測るのは印の**状態**: 無い / 生きている / 古い / pid 再利用 / 壊れている。
#     - 印の path は `RC_MUTATION_LOCK` で砂場へ逃がす。この結果、**本物の変異走行と
#       同時に回しても干渉しない** —— 旧版に在った「走行と同居していたら劣化版へ落ちて
#       exit 2」という逃げ道が要らなくなった(`weak` / `MODE` を消したのはその為)。
#
# ★引き継いだ作法(旧版が作り直しで獲得した物。捨てない):
#     1. 判定の材料を**本体から抜く**(写しを持たない。取り出せなければ赤で止まる)
#     2. 各シナリオで **`bash "$LIVE"` を実際に呼ぶ**(写しを撃たない)
#     3. 終了コードの契約は**計器を差し替えて**測る。囮では計器の失敗を起こせないし、
#        最大の穴はいつも「判らなかった」を「居ない」に丸める所に在る
#     4. `--who` が argv を出さない事を機械で押さえる(秘密を印字する診断は本末転倒)
#
# ★新しく足した脚のうち、いちばん効くのは **pid 再利用**(下の D)。印を残したまま
#   SIGKILL された走行の pid が別の物に再利用されると `kill -0` は「生きている」と答える
#   —— それは 8/02 の「配備が恒久的に塞がる」と**同じ壊れ方**を新しい根で作り直す事で、
#   起動時刻の照合はその為だけに在る。照合を外しても他の脚は全部緑のままなので、
#   この脚が無ければ穴は見えない。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# ★継ぎ目。`tools/prove-control.sh` が**直す前の版**を此処へ差し込んで、
#   「その旧版でこの対照が本当に赤くなるか」を機械で確かめられる様にする(差替型)。
LIVE="${MUTLIVE_SCRIPT:-$ROOT/tools/mutation-run-live.sh}"
WRITER="$ROOT/test/mutation-controls.py"

pass=0; fail=0; unmeasured=0
ok()     { pass=$((pass+1)); echo "PASS  $1"; }
ng()     { fail=$((fail+1)); echo "FAIL  $1  ($2)"; }
unmeas() { unmeasured=$((unmeasured+1)); echo "UNMEA $1  ($2)"; }

SB="$(mktemp -d /tmp/mutlive-ctl.XXXXXX)"
DECOY=""
SELFTEST=""
cleanup() {
    [ -n "$DECOY" ]    && kill "$DECOY" 2>/dev/null
    [ -n "$SELFTEST" ] && kill "$SELFTEST" 2>/dev/null
    # 中身は自分で置いた物だけなので、名指しで消す(`rm -rf` を使わない)。
    if [ -d "$SB" ]; then
        for _i in 1 2 3 4 5 6 7 8; do /bin/rm -f "$SB/race-$_i.out"; done
        /bin/rm -f "$SB/lock" "$SB/lock2" "$SB/lock3" "$SB/selftest.out" "$SB/bin/ps"
        # 退ける門(`<印>.steal`)と書きかけ(`<印>.tmp.<pid>`)。正常に終われば残らないが、
        # 途中で殺した脚の後始末として名指しで拾う(`rm -rf` を使わない方針のまま)。
        for _f in "$SB"/lock*.steal "$SB"/lock*.tmp.*; do [ -e "$_f" ] && /bin/rm -f "$_f"; done
        /bin/rmdir "$SB/bin" "$SB" 2>/dev/null
    fi
    return 0
}
trap cleanup EXIT INT TERM

LOCK="$SB/lock"
say() {  # $1=見出し $2=期待 exit $3=実際 exit $4=外れた時の意味
    if [ "$3" = "$2" ]; then ok "$1 → exit=$2"; else ng "$1" "$4。期待 exit=$2 実際 exit=$3"; fi
}
call() {  # 本体を砂場の印で呼ぶ。標準出力は捨てる(測るのは終了コード)
    RC_MUTATION_LOCK="$LOCK" bash "$LIVE" >/dev/null 2>&1
}
# ★`TZ`/`LC_ALL` を固定する。`lstart` は呼び手の環境で描かれるので、ここを固定しないと
#   この対照が**本体と違う方言**の印を書き、生きている主を「pid の再利用」に見せてしまう
#   (実際に踏んだ: 本体を UTC 固定に直した直後、手書きの印を使う脚だけが赤くなった)。
lstart() { TZ=UTC LC_ALL=C /bin/ps -o lstart= -p "$1" 2>/dev/null | /usr/bin/sed -e 's/^ *//' -e 's/ *$//'; }
mklock() { printf 'pid=%s\nstarted=%s\nroot=%s\n' "$1" "$2" "${3:-$ROOT}" > "$LOCK"; }
wait_gone() { for _ in $(seq 1 100); do kill -0 "$1" 2>/dev/null || return 0; sleep 0.1; done; return 1; }
wait_argv() {  # $1=pid $2=argv に含まれる筈の文字列。固定 sleep は速い機械で早すぎ、
    local pid="$1" want="$2" cmd   #   混んだ機械で遅すぎる —— どちらも「測れていないのに緑」
    for _ in $(seq 1 100); do
        cmd="$(/bin/ps -o command= -p "$pid" 2>/dev/null)"
        case "$cmd" in *"$want"*) return 0 ;; esac
        sleep 0.1
    done
    return 1
}

# --- 0) 既定の印の path を**両方の本体から抜いて**一致を見る -------------------------
#   この既定値は sh と python の2箇所に書かれている(消せない: 言語が違う)。
#   写しを持たない事より、**写しが割れた事を検出できる**事が大事 —— 割れると書き手と
#   読み手が別の file を見るので、門は「走行していない」と答え続ける(静かな fail-open)。
NSH="$(/usr/bin/grep -c '^LOCK="\${RC_MUTATION_LOCK:-' "$LIVE" 2>/dev/null || true)"
NPY="$(/usr/bin/grep -c '^MUTATION_LOCK = os.environ.get("RC_MUTATION_LOCK"' "$WRITER" 2>/dev/null || true)"
SHDEF="$(/usr/bin/sed -n 's/^LOCK="\${RC_MUTATION_LOCK:-\(.*\)}"$/\1/p' "$LIVE")"
PYDEF="$(/usr/bin/sed -n 's/^MUTATION_LOCK = os.environ.get("RC_MUTATION_LOCK", "\(.*\)")$/\1/p' "$WRITER")"
if [ "$NSH" != "1" ] || [ "$NPY" != "1" ]; then
    ng "既定の印の path を取り出す" "読み手に ${NSH} 本 / 書き手に ${NPY} 本ある。1本ずつでないと、どれが効くか判らない"
    echo ""; echo "MUTATION-RUN-LIVE-CONTROLS: pass=$pass fail=$fail"; exit 1
elif [ -z "$SHDEF" ] || [ "$SHDEF" != "$PYDEF" ]; then
    ng "書き手と読み手が同じ印を見ている" "読み手[${SHDEF}] 書き手[${PYDEF}] — 割れている。門は永久に「走行していない」と答える"
    echo ""; echo "MUTATION-RUN-LIVE-CONTROLS: pass=$pass fail=$fail"; exit 1
else
    ok "書き手と読み手の既定の印が丁度1本ずつ在り、同じ path を指している"
fi

# --- A) 印が無い = **確認できた「居ない」** ------------------------------------------
#   呼ぶ側が進んでよい唯一の値。ここが 2 だと、走行していない平時に配備が塞がる。
/bin/rm -f "$LOCK"
call; rc=$?
say "印が無い" 1 "$rc" "平時に配備が塞がる(または未測定に化ける)"

# --- B) 主が生きていて起動時刻も一致 = 走行中 ------------------------------------------
#   ★囮を起こさない。この対照自身($$)が「確実に生きているプロセス」である。
MY="$(lstart $$)"
if [ -z "$MY" ]; then
    unmeas "生きている印" "自分の起動時刻が ps から読めない — 以降の生死判定は測れない"
else
    mklock "$$" "$MY"
    call; rc=$?
    say "主が生きていて起動時刻も一致する印" 0 "$rc" "★守りが空振り — 走行中でも配備できてしまう"
fi

# --- C) 主が死んでいる = 古い印。走行していない ----------------------------------------
#   SIGKILL された走行は印を降ろせない。古い印で門が永久に塞がってはいけない
#   (8/02 の恒久的な詰まりと同じ形を、新しい根で作り直さない)。
sleep 30 >/dev/null 2>&1 &
D=$!
DLS="$(lstart "$D")"
kill "$D" 2>/dev/null
if wait_gone "$D"; then
    wait "$D" 2>/dev/null
    mklock "$D" "$DLS"
    call; rc=$?
    say "主が死んだ古い印" 1 "$rc" "死んだ走行の印で配備が恒久的に塞がる"
else
    unmeas "古い印" "囮が消えない — 死んだ主を作れなかった"
fi

# --- D) pid は生きているが起動時刻が違う = **pid の再利用** ---------------------------
#   ★この脚がこの作り直しの肝。pid だけを見る実装は全部の脚を緑で通り抜け、
#     再利用が起きた日にだけ「走行中」と言い続けて配備を永久に止める。
mklock "$$" "Thu Jan  1 00:00:00 1970"
call; rc=$?
say "pid は生きているが起動時刻が違う印" 1 "$rc" "★pid 再利用を走行と誤認 — 配備が恒久的に塞がる"

# --- E) 壊れた印は「居ない」に丸めない(全部 2 = 測れなかった)------------------------
#   ここを 1 にすると、印が中途半端な瞬間に門が**開く**(fail-open)。
printf 'started=x\nroot=y\n' > "$LOCK"
call; rc=$?; say "pid の欄が無い印" 2 "$rc" "★fail-open: 壊れた印を「走行していない」に丸めている"

printf 'pid=%s\npid=%s\nstarted=%s\nroot=%s\n' "$$" "$$" "${MY:-x}" "$ROOT" > "$LOCK"
call; rc=$?; say "pid の欄が2本ある印" 2 "$rc" "曖昧な印を先頭採りで黙って解釈している"

printf 'pid=notanumber\nstarted=%s\n' "${MY:-x}" > "$LOCK"
call; rc=$?; say "pid が数でない印" 2 "$rc" "数でない pid を黙って解釈している"

: > "$LOCK"
call; rc=$?; say "空の印" 2 "$rc" "★fail-open: 空の印を「走行していない」に丸めている"

# --- F) 計器(ps)が失敗した時に何と答えるか -------------------------------------------
#   囮では起こせない層。旧版の最大の穴もここに在った(pgrep の失敗を「居ない」に丸め、
#   判定不能の瞬間に門が黙って通っていた)。
/bin/mkdir -p "$SB/bin"
{
    echo '#!/bin/bash'
    echo 'exit "${STUB_PS_RC:-2}"'
} > "$SB/bin/ps"
/bin/chmod +x "$SB/bin/ps"
if [ -n "$MY" ]; then
    mklock "$$" "$MY"
    for drv in 2 3 127; do
        RC_MUTATION_LOCK="$LOCK" RC_PS_BIN="$SB/bin/ps" STUB_PS_RC="$drv" \
            bash "$LIVE" >/dev/null 2>&1
        rc=$?
        say "ps が exit=${drv} で失敗した時" 2 "$rc" "★fail-open: 計器の失敗を「居ない」に丸めると門が開く"
    done
    # ps は「居ない」と言うのに signal は届く = 食い違い。どちらとも確定できないので 2。
    RC_MUTATION_LOCK="$LOCK" RC_PS_BIN="$SB/bin/ps" STUB_PS_RC=1 bash "$LIVE" >/dev/null 2>&1
    rc=$?
    say "ps は居ないと言うのに signal は届く時" 2 "$rc" "同一性を確かめないまま確定している"
else
    unmeas "計器の失敗" "自分の起動時刻が読めず、印を作れない"
fi

# --- G) 判定器は印を**書き換えない** ---------------------------------------------------
#   検査が対象を変えると、次に読む人は検査の残した姿を見る。古い印を勝手に消すのも同じ罪
#   (消した瞬間に、実はまだ生きていた走行の門が開く)。
mklock "12345678" "Thu Jan  1 00:00:00 1970"
before="$(/usr/bin/shasum "$LOCK" | /usr/bin/cut -d' ' -f1)"
call >/dev/null 2>&1
after="$(/usr/bin/shasum "$LOCK" 2>/dev/null | /usr/bin/cut -d' ' -f1)"
if [ -e "$LOCK" ] && [ "$before" = "$after" ]; then
    ok "判定しても印は変わらない(古い印を勝手に消さない)"
else
    ng "判定器が印を書き換えない" "読んだだけで印が変わった/消えた"
fi

# --- H) `--who` は argv を出さない ------------------------------------------------------
#   印の主は**無関係なプロセス**であり得る(古い印 + pid 再利用)。そこに何が書かれて
#   いるかは判らないので、実行体の名前だけを出す。過去に `pgrep -lf` が Google OAuth の
#   client secret を会話へ印字している。
CANARY='CANARY-MUST-NOT-BE-PRINTED'
bash -c 'X="python3 -u /nowhere/test/mutation-controls.py CANARY-MUST-NOT-BE-PRINTED"; sleep 30' >/dev/null 2>&1 &
DECOY=$!
if wait_argv "$DECOY" "$CANARY"; then
    mklock "$DECOY" "$(lstart "$DECOY")"
    who="$(RC_MUTATION_LOCK="$LOCK" bash "$LIVE" --who 2>/dev/null)"; wrc=$?
    if printf '%s' "$who" | /usr/bin/grep -q "$CANARY"; then
        ng "--who が argv を出さない" "★秘密が漏れる形 — 主のコマンド行をそのまま出している"
    else
        ok "--who は argv を出さない(主が何であっても安全に見せられる)"
    fi
    bad="$(printf '%s\n' "$who" | /usr/bin/tail -n +2 | /usr/bin/grep -v '^ *[0-9][0-9]* ' | /usr/bin/grep -c . || true)"
    if [ "$bad" = "0" ]; then
        ok "--who の2行目以降が「pid と実行体」の形をしている"
    else
        ng "--who の出力の形" "pid と実行体でない行が ${bad} 本ある"
    fi
else
    unmeas "--who の出力" "囮の argv が見えない — 主を作れなかった"
fi
kill "$DECOY" 2>/dev/null; wait_gone "$DECOY"; wait "$DECOY" 2>/dev/null; DECOY=""

# --- H2) `--who` は**どの状態でも** exit 0 -------------------------------------------
#   ★2026-08-04、この脚は最初「生きている印」でしか撃っていなかった。それだと
#     `exit "$VERDICT"` へ壊しても VERDICT=0 なので緑のまま通る —— 名乗った性質を
#     一度も測っていない脚だった(変異 R11 が生き残って露見)。
#     `--who` が要るのは**判定が 0 でない時**、つまり塞がれて理由を知りたい時である。
#     そこで終了コードが立つと、`set -e` の下や `&&` で繋いだ診断が黙って落ちる。
/bin/rm -f "$LOCK"
RC_MUTATION_LOCK="$LOCK" bash "$LIVE" --who >/dev/null 2>&1; rc=$?
say "--who: 印が無い状態(判定=1)でも成功する" 0 "$rc" "診断の口が終了コードで詰まる"
printf 'started=x\n' > "$LOCK"
RC_MUTATION_LOCK="$LOCK" bash "$LIVE" --who >/dev/null 2>&1; rc=$?
say "--who: 印が壊れた状態(判定=2)でも成功する" 0 "$rc" "★詰まるのが「塞がれて理由を知りたい時」に一致する"
if [ -n "$MY" ]; then
    mklock "$$" "$MY"
    RC_MUTATION_LOCK="$LOCK" bash "$LIVE" --who >/dev/null 2>&1; rc=$?
    say "--who: 走行中(判定=0)でも成功する" 0 "$rc" "診断の口が終了コードで詰まる"
fi

# --- I) 書き手と読み手が**噛み合う**(end-to-end)----------------------------------------
#   ここまでの印は全部この対照が手で書いた物 = 書式の写しである。本物の走行台本に
#   同じ呼び出し(`_take_run_lock`)で印を立てさせ、本体がそれを読めるかを見る。
#   書式が食い違った日に「対照だけ緑」を作らない為の唯一の脚。
LOCK2="$SB/lock2"
# ★古い印を**先に置いておく**。書き手は印を原子的に取る(`os.link`)ので、退ける道が
#   無いと SIGKILL された走行の印で**以後の全走行が永久に止まる** —— 8/02 の
#   「恒久的に塞がる」を、門ではなく走行側で作り直す事になる。ここはその退け道を撃つ:
#   下で LOCKED が出れば退けられたという事で、印は新しい主を名乗っている筈。
printf 'pid=%s\nstarted=%s\nroot=%s\n' "12345678" "Thu Jan  1 00:00:00 1970" "/nowhere" > "$LOCK2"
RC_MUTATION_LOCK="$LOCK2" RC_LOCK_SELFTEST_S=60 \
    python3 "$WRITER" --lock-selftest > "$SB/selftest.out" 2>&1 &
SELFTEST=$!
locked=0
for _ in $(seq 1 300); do
    /usr/bin/grep -q '^LOCKED ' "$SB/selftest.out" 2>/dev/null && { locked=1; break; }
    kill -0 "$SELFTEST" 2>/dev/null || break
    sleep 0.1
done
if [ "$locked" -ne 1 ]; then
    unmeas "本物の走行台本が立てた印" "台本が印を立てなかった: $(/usr/bin/tail -3 "$SB/selftest.out" 2>/dev/null | /usr/bin/tr '\n' ' ')"
else
    ok "古い印が残っていても、退けて走り出せる(走行側で恒久的に詰まらない)"
    newpid="$(/usr/bin/sed -n 's/^pid=//p' "$LOCK2")"
    if [ "$newpid" = "$SELFTEST" ]; then
        ok "退けた後の印は**新しい主**を名乗っている"
    else
        ng "退けた後の印の主" "印の pid=${newpid} が走り出した台本(${SELFTEST})と違う"
    fi
    RC_MUTATION_LOCK="$LOCK2" bash "$LIVE" >/dev/null 2>&1; rc=$?
    say "本物の走行台本が立てた印を読める" 0 "$rc" "★書き手と読み手の書式が割れている — 門は走行中に開く"

    # ★時間帯と locale を跨いでも同じ印を読めるか(Codex 指摘 #4)。
    #   `lstart` は**呼び手の環境で描かれる**ので、書き手と読み手が違う環境に居ると
    #   同じプロセスが違う文字列になる。読み手はそれを「pid の再利用」と読み、
    #   判定 1 = **走行中に門が開く**(fail-open)。ここは実際に環境をずらして撃つ。
    #   ★この脚は本物の書き手が立てた印にだけ意味がある(手書きの印だと、対照自身が
    #     読み手と同じ環境で作るので永久に一致してしまう)。
    for _tz in "Asia/Tokyo" "America/New_York" "UTC"; do
        TZ="$_tz" LC_ALL="C" RC_MUTATION_LOCK="$LOCK2" bash "$LIVE" >/dev/null 2>&1; rc=$?
        say "読み手が TZ=${_tz} で走っても同じ印を読める" 0 "$rc" "★時間帯で pid 再利用に化ける — 走行中に門が開く"
    done
    TZ="Asia/Tokyo" LC_ALL="ja_JP.UTF-8" RC_MUTATION_LOCK="$LOCK2" bash "$LIVE" >/dev/null 2>&1; rc=$?
    say "読み手が別の locale で走っても同じ印を読める" 0 "$rc" "★locale で pid 再利用に化ける — 走行中に門が開く"

    # --- J) 2本目は走らない(相互排他)---------------------------------------------
    #   8/02 に実際に起きた形 = 2本が同じ log へ書いて混ざり、片方の対照がもう片方の
    #   囮を見て赤くなった。今までこれを止めていたのは私の記憶だけで、機械は何も
    #   見ていなかった。
    out2="$(RC_MUTATION_LOCK="$LOCK2" RC_LOCK_SELFTEST_S=1 python3 "$WRITER" --lock-selftest 2>&1)"
    rc2=$?
    if [ "$rc2" -eq 0 ]; then
        ng "走行中に2本目を起こさない" "★2本目が走った — 同じ木を2本で測ると log も囮も混ざる"
    elif printf '%s' "$out2" | /usr/bin/grep -q '既に動いている'; then
        ok "走行中に2本目を起こそうとすると、理由を言って止まる"
    else
        ng "走行中に2本目を起こさない" "止まったが理由が違う: $(printf '%s' "$out2" | /usr/bin/tail -1)"
    fi

    kill "$SELFTEST" 2>/dev/null
    if wait_gone "$SELFTEST"; then
        wait "$SELFTEST" 2>/dev/null; SELFTEST=""
        RC_MUTATION_LOCK="$LOCK2" bash "$LIVE" >/dev/null 2>&1; rc=$?
        say "台本が落ちた後は印が降りている" 1 "$rc" "★終わった走行の印が残り、配備が恒久的に塞がる"
        if [ -e "$LOCK2" ]; then
            ng "台本は自分の印を片付ける" "SIGTERM で降ろせていない(file が残っている)"
        else
            ok "台本は SIGTERM でも自分の印を片付ける"
        fi
    else
        unmeas "印の後始末" "台本が落ちない"
    fi
fi

# --- J2) 同時に出発した 8 本のうち、印を取れるのは丁度1本 ------------------------------
#   ★上の J は**順番に**起こした2本目を見ている。それだけだと「確かめてから書く」実装
#     (`os.replace`)でも緑を通る —— 古い印だと**同時に**判断した2本が、どちらも
#     「自分が主だ」と思って進む窓が残るからである。相互排他を名乗りながら稀に2本走る形で、
#     結果は 8/02 の偽陰性と同じ(log と囮が混ざる)。
#   古い印を先に置いて 8 本を同時に出発させると、差が確率でなく**個数**で出る:
#     - `os.link` (今の形): 全員が EEXIST で弾かれ、退けた後に丁度1本だけ勝つ → LOCKED 1
#     - `os.replace` (確かめてから書く): 全員が「古い印」と判断して進む → LOCKED 8
#   ★保持時間(`RC_LOCK_SELFTEST_S`)は飾りでなく**この脚の判定そのもの**である。
#     此処は「同時に何本**取れたか**」を数えていて、「同時に何本**握っていたか**」は数えて
#     いない。勝者が保持を終えて降ろした後に、待っていた別の本が**正しく**取れば、それも
#     `LOCKED` 2行として現れる —— 引き継ぎであって同時ではないのに、赤が出る。
#     退ける門の待ちは 1回あたり最大 200*10ms = 2秒(`test/mutation-controls.py` の
#     `_steal_stale_lock()` 内 `for _ in range(200)`)で、取得は 3 回まで試み、その合間に
#     退ける道へ 2 回入る(同 `_take_run_lock()` の `for attempt in (1, 2, 3)`)ので、
#     **正しい実装でも最悪 4 秒待たされてから勝ち得る**。保持がそれ以下だと、2行が
#     「重なった」の証拠にならない。
#     実測(8/04、8本同時 x 30回): 保持 1秒 → 30回中1回が2行(= 引き継ぎ、偽の赤)。
#                                 保持 8秒 → 30回とも丁度1行。
#     よって 4秒より長い所に置く。8 = 最悪待ち 4秒の 2倍。**下げるなら上の算術ごと直す事**。
#     `RC_RACE_HOLD_S` は繰り返し実験(同じ形を N 回回す)用の口。短くすると偽の**赤**が
#     出るだけで、偽の緑にはならない —— 取得が原子的でなければ保持の長さに関わらず 8本
#     全部が `LOCKED` を出すので、この口から緩める事はできない。
LOCK3="$SB/lock3"
printf 'pid=%s\nstarted=%s\nroot=%s\n' "12345679" "Thu Jan  1 00:00:00 1970" "/nowhere" > "$LOCK3"
RACE=""
for i in 1 2 3 4 5 6 7 8; do
    RC_MUTATION_LOCK="$LOCK3" RC_LOCK_SELFTEST_S="${RC_RACE_HOLD_S:-8}" \
        python3 "$WRITER" --lock-selftest > "$SB/race-$i.out" 2>&1 &
    RACE="$RACE $!"
done
for p in $RACE; do wait "$p" 2>/dev/null; done
won=0
for i in 1 2 3 4 5 6 7 8; do
    /usr/bin/grep -q '^LOCKED ' "$SB/race-$i.out" 2>/dev/null && won=$((won+1))
done
if [ "$won" = "1" ]; then
    ok "同時に出発した 8 本のうち、印を取れたのは丁度1本"
elif [ "$won" = "0" ]; then
    unmeas "同時出発の決着" "1本も走り出せなかった = 古い印を退ける道が塞がっている"
else
    ng "同時出発の決着" "★${won}本が同時に走り出した — 印の取得が原子的でない(確かめてから書いている)"
fi

# --- J3) 退ける門が開いたまま残っていたら、走り出さずに**理由と直し方**を言って止まる ----
#   ★これは私が入れた退行である。門(`<印>.steal`)は普通は数マイクロ秒しか握らないが、
#     その隙に SIGKILL されると誰も消さない。門自体には古さの判定が無い —— 付けようと
#     すると「門が古いか」を2本が同時に判断して2本とも入れるので、門を守る門が要る形に
#     戻る(亀の塔)。なので**直さず、閉じる側に倒して**、人が消せる様に道を名指しさせる。
#   ここで測るのは 2つ: (1) 開かない事(= 古い印が在っても勝手に進まない)、
#   (2) 止まる時に**消すべき path を言う**事。理由を言わない fail-closed は、次に踏んだ
#   人にとって原因不明の停止と区別が付かない。
LOCK4="$SB/lock4"
printf 'pid=%s\nstarted=%s\nroot=%s\n' "12345679" "Thu Jan  1 00:00:00 1970" "/nowhere" > "$LOCK4"
printf 'pid=%s\n' "999999" > "$LOCK4.steal"      # 落ちた走行が置き去りにした門
jrc=0
RC_MUTATION_LOCK="$LOCK4" RC_LOCK_SELFTEST_S=1 \
    python3 "$WRITER" --lock-selftest > "$SB/stuckguard.out" 2>&1 || jrc=$?
if [ "$jrc" = "0" ]; then
    ng "門が残っている時の振舞い" "★門を無視して走り出した — 落ちた走行と競って古い印を取り合う"
elif /usr/bin/grep -q '^LOCKED ' "$SB/stuckguard.out" 2>/dev/null; then
    ng "門が残っている時の振舞い" "★印を取ってから落ちた — 門の中に入れてしまっている"
elif /usr/bin/grep -qF "$LOCK4.steal" "$SB/stuckguard.out" 2>/dev/null; then
    ok "退ける門が残っていたら、走り出さずに消すべき path を名指しして止まる"
else
    ng "門が残っている時の理由" "止まりはしたが ${LOCK4}.steal を名指ししていない — 人が直せない"
fi
/bin/rm -f "$LOCK4" "$LOCK4.steal" "$SB/stuckguard.out"

# --- K) 静的: 本体が**推定へ戻っていない** ---------------------------------------------
#   argv への文字列一致は、精密にしても推定のままである。実行行に一つでも戻っていたら、
#   8/02 の両方向の穴が一緒に戻って来る。
pg="$(/usr/bin/grep -n 'pgrep' "$LIVE" 2>/dev/null | /usr/bin/grep -v '^[0-9]*: *#' | /usr/bin/grep -c . || true)"
if [ "$pg" = "0" ]; then
    ok "本体の実行行に pgrep が無い(argv への文字列一致へ戻っていない)"
else
    ng "本体が推定へ戻っていない" "実行行に pgrep が ${pg} 本ある — 誤検出と引数の揺れが戻る"
fi

echo ""
echo "MUTATION-RUN-LIVE-CONTROLS: pass=$pass fail=$fail unmeasured=$unmeasured"
# 終了コードは `tools/run-controls.sh` の規約に合わせる: 0=緑 / 1=赤 / **2=測っていない**。
if [ "$fail" -gt 0 ]; then exit 1; fi
if [ "$unmeasured" -gt 0 ]; then
    echo "  未測定(緑ではない): 上の UNMEA を読む事。測れなかった脚が ${unmeasured} 本ある。"
    exit 2
fi
exit 0
