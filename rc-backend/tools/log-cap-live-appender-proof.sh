#!/bin/bash
# log-cap-live-appender-proof.sh — 上限が **launchd が抱えている追記者** の log を切っても
# 書き込みが1本も落ちない事を、friday の実物で示す。誰でも撃ち直せる形で残す。
#
# ── なぜ要るか(CF-9 の未着手、2026-08-30)────────────────────────────────────
# `log-size-cap.sh` の対照は、**私が起こした追記者**相手にしか測っていなかった。
# 本番の追記者は launchd が抱えている node で、fd の持ち方も再起動の仕方も違う。
# 「私の砂場では落ちない」は「本番でも落ちない」ではない ——
# 此の repo が繰り返し踏んだ型(緑は、其の検査が測った物としか一致しない)。
#
# ── 何を主張するか(此処が要。2026-08-30 の実測で書き直した)──────────────────
# 上限は**頭を捨てる**(末尾だけ `<file>.tail` へ退避してから空にする)。だから
# 「1行も失わない」は捨てる仕事の否定になる。測るのは**境目**だけ:
#
#   退避した末尾の最初の番号から、追記者が最後に書いた番号まで、抜けが在るか。
#
# ★**「抜けゼロ」は原理的に達成できない**。`tail` が読み終わってから `: > "$F"` が
#   走るまでの間に書かれた行は、退避にも入らず切られて消える。両者を原子的に
#   行う手が無い(追記者は錠を取らないので `flock` も効かない)。実測:
#     並べ替え前(退避の整形・chmod・mv を全部済ませてから切る) …… **406 行**
#     並べ替え後(読んだ直後に切る)                             …… **8 行**
#   だから主張を2つに分ける:
#     A. **本番並みの書き込み速度では抜けが 0**(此方が合否)
#     B. 最大速度での抜けは**有界**(此方は上限を数で記録する。合否にしない ——
#        機械の速さで揺れる数を合否にすると、検査が季節で色を変える)
#
# 落ち方の型: 追記者が `O_APPEND` を持たなければ切った後も古い offset へ書き続け、
# **穴だらけの疎な file** を作る(番号が大きく飛ぶ)。此れは A で必ず出る。
#
# ── 使い方 ──────────────────────────────────────────────────────────────────
#   bash rc-backend/tools/log-cap-live-appender-proof.sh          # friday で実測
#   bash rc-backend/tools/log-cap-live-appender-proof.sh --check <退避> <log>
#                                                                 # 解析だけ(検査の継ぎ目)
#
# 終了コード: 0=抜け無し / 1=**抜けが在る** / 2=測定不成立
#
# no-operator: 人が撃つ。生きた friday と launchd が要り、向こうに使い捨ての
#   LaunchAgent を立てて数十秒書かせるので、門から毎 commit 回す物ではない。
#   撃つ時: `log-size-cap.sh` を触った後と、上限の挙動を疑った時。
#   解析部だけは `--check` で切り出してあり、其方は対照
#   (`test/log-cap-live-appender-controls.sh`)が毎 commit 撃つ。
set -uo pipefail

HOST="${RC_PROOF_HOST:-athenas}"
SSH_BIN="${RC_PROOF_SSH:-ssh}"
LABEL="com.fleet.rc-capproof"

# ── 解析だけ(此処を分けるのが要)────────────────────────────────────────────
# 実測は friday と launchd が要るので高い。**抜けを見つける論理**だけを切り出して
# おけば、対照は細工した2枚の file を食わせるだけで「抜けを見逃さないか」を撃てる。
# 分けないと、検査は「本番で緑だった」しか言えず、**抜けを検出できるか**を測れない。
if [ "${1:-}" = "--check" ]; then
    snap="${2:-}"; live="${3:-}"
    [ -f "$snap" ] && [ -f "$live" ] || {
        echo "log-cap-proof: 退避か log が無い($snap / $live)= 測定不成立" >&2; exit 2; }
    # 番号だけを集める。行の形は `seq=<n> ...`。
    nums="$(cat "$snap" "$live" 2>/dev/null | sed -n 's/.*seq=\([0-9][0-9]*\).*/\1/p' | sort -n -u)"
    [ -n "$nums" ] || { echo "log-cap-proof: 番号を1つも読めない = 測定不成立" >&2; exit 2; }
    first="$(printf '%s\n' "$nums" | head -1)"
    last="$(printf '%s\n' "$nums" | tail -1)"
    have="$(printf '%s\n' "$nums" | wc -l | tr -d ' ')"
    want=$((last - first + 1))
    if [ "$have" -ne "$want" ]; then
        echo "log-cap-proof: ★抜けが在る($first..$last の $want 個のうち $have 個しか無い)" >&2
        # どこが抜けたかを出す。数だけだと直しに使えない。
        printf '%s\n' "$nums" | awk -v f="$first" '
            NR == 1 { prev = $1; next }
            $1 != prev + 1 { printf "  抜け: %d..%d\n", prev + 1, $1 - 1 }
            { prev = $1 }' >&2
        exit 1
    fi
    echo "log-cap-proof: 抜け無し($first..$last の $want 個が全部在る)"
    exit 0
fi

# ── 実測 ────────────────────────────────────────────────────────────────────
# ★本番の log には**触らない**。使い捨ての dir と使い捨ての label で完結させる。
#   `com.fleet.rc-*` の名前空間を使うのは、`fleet-plist-parity-check.sh` が
#   `com.fleet.*` を全部見に行くから —— 残骸が出れば其方が赤くなる = 気付ける。
run_phase() {  # run_phase <1行ごとの待ち("" = 全速)> <書く行数> <育つまでの秒>
    "$SSH_BIN" -o ConnectTimeout=20 -o BatchMode=yes "$HOST" \
        "RC_PROOF_SLEEP='$1' RC_PROOF_LINES='$2' RC_PROOF_GROW='$3' bash -s" <<'REMOTE'
set -uo pipefail
LABEL="com.fleet.rc-capproof"
DIR="$HOME/.rc-capproof"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$DIR/live.log"
uid="$(id -u)"
SLEEP="${RC_PROOF_SLEEP:-}"
LINES="${RC_PROOF_LINES:-40000}"
GROW="${RC_PROOF_GROW:-300000}"

cleanup() {
    launchctl bootout "gui/$uid/$LABEL" 2>/dev/null
    /bin/rm -f "$PLIST"
    /bin/rm -rf "$DIR"
}
trap cleanup EXIT
cleanup                 # 前回の残骸があれば先に片付ける
mkdir -p "$DIR" || { echo "PROOF-FAIL 置き場を作れない"; exit 2; }

# 追記者。**`>>` で開く**(= O_APPEND)。番号を振って書き続ける。
cat > "$DIR/append.sh" <<APP
#!/bin/bash
LOG="$LOG"
n=0
while [ "\$n" -lt $LINES ]; do
    n=\$((n + 1))
    printf 'seq=%d padding-to-make-the-file-grow-faster-0123456789012345678901234567890123456789\\n' "\$n" >> "\$LOG"
    $( [ -n "$SLEEP" ] && printf 'sleep %s' "$SLEEP" || printf ':' )
done
printf 'seq=%d LAST\\n' "\$n" >> "\$LOG"
sleep 3
APP
chmod +x "$DIR/append.sh"

cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string><string>$DIR/append.sh</string>
  </array>
  <key>RunAtLoad</key><true/>
</dict></plist>
PL
launchctl bootstrap "gui/$uid" "$PLIST" 2>/dev/null || { echo "PROOF-FAIL bootstrap できない"; exit 2; }

# 追記者が走り出して log が育つのを待つ。
for _ in $(seq 1 200); do
    sz="$(stat -f%z "$LOG" 2>/dev/null || echo 0)"
    [ "${sz:-0}" -gt "$GROW" ] && break
    sleep 0.25
done
sz="$(stat -f%z "$LOG" 2>/dev/null || echo 0)"
[ "${sz:-0}" -gt "$GROW" ] || { echo "PROOF-FAIL log が育たない(${sz:-0} B / 要 $GROW)"; exit 2; }

# ★**書いている最中に**切る。止めてから切るのでは境目を測れない ——
#   本番の上限は毎時、追記者が動いたまま走る。
bash "$HOME/rc-backend/tools/log-size-cap.sh" "$LOG" $((GROW * 2 / 3)) >/dev/null 2>&1
caprc=$?
[ "$caprc" -eq 0 ] || { echo "PROOF-FAIL 上限が非零で終わった(rc=$caprc)"; exit 2; }

# 追記者が書き終えるまで待つ。
for _ in $(seq 1 400); do
    grep -q "LAST" "$LOG" 2>/dev/null && break
    sleep 0.5
done

# ★番号では見えない破損を別に測る(2026-08-30、Codex の指摘3)。
#   追記者が `O_APPEND` を持たなければ、切った後も**古い offset** から書き続け、
#   先頭に巨大な NUL の穴を作る。番号は飛ばないので、番号だけ見ていると緑が出る。
nulbytes="$(tr -dc '\000' < "$LOG" 2>/dev/null | wc -c | tr -d ' ')"
echo "PROOF-NUL ${nulbytes:-0}"
# 行の途中で切れた物 = `seq=` で始まらない行。
# ★上限が自分で書き足す註記(`[log-size-cap] …`)を除く。**設計どおり** `seq=` で
#   始まらないので、数えると毎回きっかり1本が「壊れた行」として出る ——
#   2026-08-30 に実測で踏んだ(3回とも 1 本。註記が1回1本なのが決め手だった)。
#   検査が測る物と、守りたい物がずれていた形。
badlines="$(grep -v '^seq=' "$LOG" 2>/dev/null | grep -c -v '^\[log-size-cap\]' || echo 0)"
echo "PROOF-BADLINES ${badlines:-0}"

cat "$LOG.tail" "$LOG" 2>/dev/null | sed -n 's/.*seq=\([0-9][0-9]*\).*/\1/p' | sort -n -u > "$DIR/nums"
echo "PROOF-FIRST $(head -1 "$DIR/nums")"
echo "PROOF-LAST $(tail -1 "$DIR/nums")"
echo "PROOF-HAVE $(wc -l < "$DIR/nums" | tr -d ' ')"
awk 'NR==1{p=$1;next} $1!=p+1{printf "PROOF-GAP %d..%d\n", p+1, $1-1} {p=$1}' "$DIR/nums"
echo "PROOF-DONE"
REMOTE
}

missing_of() {  # 抜けた総数を数える
    # ★区切りは**正規表現として** `\.\.` と書く。`".."` だと awk は `.` を
    #   「任意の1文字」と読み、`8469..8472` を別の位置で割って数を取り違える
    #   (2026-08-30 実測: 4 行の抜けを「1 行」と報告した)。
    printf '%s\n' "$1" | awk '/^PROOF-GAP /{ if (split($2, a, /\.\./) == 2) t += a[2] - a[1] + 1 } END{ print t + 0 }'
}

echo "== 上限 vs launchd が抱えた追記者(実測: $HOST)=="

# ── A: 本番並みの速さ。**此方が合否** ────────────────────────────────────────
# 本番の `rc-ota.log` は約 11 KB/時 = 秒あたり数バイト。`0.02` 秒間隔は其れより
# **桁違いに速い**ので、緑なら本番では尚更落ちない(厳しい側で測っている)。
# ★**繰り返す**(2026-08-30、Codex の指摘1)。1回の緑は「其の1回は落ちなかった」しか
#   言わない —— 競合は確率的で、1回で当てられない。1回でも落ちたら失敗。
ROUNDS="${RC_PROOF_ROUNDS:-3}"
echo "-- A: 本番並みの速さ(1行 0.02 秒間隔)× $ROUNDS 回 = 合否 --"
missA=0; nulA=0; badA=0
for r in $(seq 1 "$ROUNDS"); do
    outA="$(run_phase 0.02 800 20000)"
    case "$outA" in *PROOF-FAIL*) echo "$outA" >&2; echo "log-cap-proof: A の $r 回目が成立しなかった" >&2; exit 2 ;; esac
    printf '%s' "$outA" | grep -q "PROOF-DONE" || { echo "log-cap-proof: A の $r 回目が最後まで走らなかった" >&2; exit 2; }
    m="$(missing_of "$outA")"
    n="$(printf '%s\n' "$outA" | awk '/^PROOF-NUL /{print $2}')"
    b="$(printf '%s\n' "$outA" | awk '/^PROOF-BADLINES /{print $2}')"
    echo "  A[$r] 抜け=$m NUL=${n:-?} B 行途中=${b:-?}"
    missA=$((missA + m))
    nulA=$((nulA + ${n:-0}))
    badA=$((badA + ${b:-0}))
    printf '%s\n' "$outA" | grep "^PROOF-GAP " | sed 's/^/    /'
done

# ── B: 全速。**合否にしない**。窓の広さを数で記録する ──────────────────────
# 機械の速さで揺れる数を合否にすると、検査が季節で色を変える。
echo "-- B: 全速(窓の広さの実測。合否にしない)--"
outB="$(run_phase '' 40000 300000)"; printf '%s\n' "$outB"
missB="$(missing_of "$outB")"

echo ""
if [ "${missA:-1}" -ne 0 ]; then
    echo "log-cap-proof: ★A で抜けが在る(計 $missA 行 / $ROUNDS 回)= 本番並みの速さでも落としている" >&2
    exit 1
fi
if [ "${nulA:-0}" -ne 0 ]; then
    # ★番号は飛ばないのに壊れている形。追記者が `O_APPEND` を持たず、切った後も
    #   古い offset へ書いて先頭に穴を作った時に出る。
    echo "log-cap-proof: ★A で NUL が $nulA バイト出た = 疎な穴(番号では見えない破損)" >&2
    exit 1
fi
if [ "${badA:-0}" -ne 0 ]; then
    echo "log-cap-proof: ★A で seq= で始まらない行が $badA 本 = 行の途中で切れている" >&2
    exit 1
fi
echo "log-cap-proof: A 抜け 0 / NUL 0 / 行途中 0($ROUNDS 回とも)"
echo "  B 全速での抜け = $missB 行。之が窓の広さの実測 —"
echo '  tail が読み終わってから truncate が走るまでに書かれた行は、'
echo "  退避にも入らず切られて消える。原子的に行う手が無いので 0 にはできない。"
echo "  ★本番の伸びは約 11 KB/時なので、此の窓に行が入る確率は実質 0。"
exit 0
