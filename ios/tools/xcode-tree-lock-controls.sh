#!/bin/bash
# ★N8/N9 の題材は 2026-08-30 に **2 回**差し替えた:
#   `list-return-refresh-control.sh` → `conversation-ui-control.sh` → `build.sh`。
#   前の2つは砂場へ移って生成木の錠を使わなくなり、**錠の行を壊す変異が空振り**した。
#   ★`build.sh` を選んだのは、**移行後も生成木を書き続ける**から ——
#     製品のビルド本体が砂場へ移る事は無い。対照の題材は、移行で消えない物を選ぶ。
#   (元の理由: 前者は砂場へ移って生成木の錠を
#   使わなくなり、**錠の行を壊す変異が空振り**するので陰性対照が空虚になっていた
#   (実測: 「変異が当たっていない」と自己申告して赤くなった = 黙って緑にはならなかった)。
#   借金が 0 になる日には、此の題材も生成木を触る別の台本(`build.sh` 等)へ移す事。
# controls-for: ios/tools/xcode-tree-lock.sh ios/tools/xcode-tree-guard.sh ios/tools/build.sh ios/tools/shots.sh ios/tools/account-ui-control.sh ios/tools/conversation-ui-control.sh ios/tools/inflight-sentence-control.sh ios/tools/list-return-refresh-control.sh ios/tools/signout-notice-control.sh ios/tools/ui-fixture-absence-control.sh ios/tools/ui-fixture-behavior-control.sh .harness/dod-sprint-6.5-controls.sh
# ★掛け先を全部並べているのは、C1-C4 が**其の11本の中身**を見ているから。
#   1 本でも取っ手を外したり trap を上書きしたりすれば此の対照が赤くなる —— だから
#   其の 1 本だけを直す commit でも回らないと意味が無い。
#
# `xcode-tree-lock.sh` の**挙動**対照。註釈でも静的検査でもなく、錠を実際に取らせて測る。
#
# 測る物 / 測らない物をはっきりさせておく:
#   測る   = 2 本目が本当に降りるか / 札の持ち主だけが外せるか / 古い錠を引き継ぐか
#   測らない = 真の同時 mkdir(この計器は逐次に撃つ)。mkdir の原子性は OS の保証で、
#             其処を疑い始めると測れる物が無くなる。**陰性対照 N1 で「mkdir を
#             `mkdir -p` に緩める」= 原子性を捨てる変異**を植えて、緩めた瞬間に
#             赤が出る事だけは押さえてある。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCKSH="$HERE/xcode-tree-lock.sh"

SB="$(mktemp -d "${TMPDIR:-/tmp}/xtl-controls.XXXXXX")"
trap 'rm -rf "$SB"' EXIT

PASS=0; FAIL=0
chk() { # chk <名前> <期待> <実測>
    if [ "$2" = "$3" ]; then
        PASS=$((PASS+1)); printf 'PASS  %s\n' "$1"
    else
        FAIL=$((FAIL+1)); printf 'FAIL  %s\n        期待=[%s] 実測=[%s]\n' "$1" "$2" "$3"
    fi
}

L="$SB/tree.lock"

# ★★待ちの既定を**此の対照が自分で決める**。継がない。
#
# 2026-08-31 実測: 束ねて回す側(`rc-backend/tools/run-controls.sh` の `export` の行)は
# `export RC_XCODE_TREE_LOCK_WAIT_S="${...:-1800}"` を**全ての子へ輸出**する。
# 之を継ぐと、「握られている間 2 本目は非零で降りる」を測る L2 が、降りずに
# **1800 秒 待つ**。掃引側の 1 本あたりの帽子も 1800 秒なので、此の対照は毎回
# 帽子で切られて `rc=2`(測っていない)になり、**一度も判定が出ないまま 30 分を焼く**。
# 単独で叩くと `WAIT_S` の既定が 0 なので 48/48 緑 —— だから気付けなかった。
#
#   同じ機械・同じ瞬間の実測:
#     WAIT_S=1800 → L1/L1b の 2 本で停止(L2 で詰まる、75 秒で打ち切り)
#     WAIT_S=0    → PASS 48 / FAIL 0
#
# ★一般化: **X の対照は、X の摘みを走らせる側から継いではいけない**。継ぐと
#   「対照が測っている物」が走らせ方で変わる。今朝 `tunnel-observer.sh --report` で
#   踏んだ argv の乗っ取りと同じ型(外から入る値が中の意味を書き換える)。
#   待ちを要る場面(W1/W2)は各自が命令行で立てるので、此処の 0 に潰されない。
export RC_XCODE_TREE_LOCK_WAIT_S=0

run() { RC_XCODE_TREE_LOCK="$L" RC_XCODE_TREE_LOCK_MAX_S="${MAXS:-3600}" bash "$1" "${@:2}"; }

# ── L1 取れる ────────────────────────────────────────────────────────────
run "$LOCKSH" acquire "A" >/dev/null 2>&1; rc=$?
chk "L1 空いていれば取れる" 0 "$rc"
chk "L1b 札に持ち主が入る" "A" "$(run "$LOCKSH" holder 2>/dev/null)"

# ★L2 が「降りる」を測れる前提は WAIT_S=0。上の export が消えると、束ねて回す側の
#   1800 が効いて L2 は**降りずに 30 分 待つ** = 詰まりとしてしか現れない。
#   詰まりは読みにくいので、其の前に**即座に赤くして理由を名指しする**。
if [ "${RC_XCODE_TREE_LOCK_WAIT_S:-}" != "0" ]; then
    echo "FAIL  L2-pre ★待ちの既定が 0 でない(=[${RC_XCODE_TREE_LOCK_WAIT_S:-未設定}])。"
    echo "        束ねて回す側の輸出を継いでいる。此のまま進むと L2 は降りずに待ち、"
    echo "        帽子で切られて『測っていない』になる。冒頭の export を戻す事。"
    exit 1
fi

# ── L2 ★2 本目は降りる(此の計器の本体。9 本の偽の赤はここが無かったから出た)──
run "$LOCKSH" acquire "B" >/dev/null 2>&1; rc=$?
chk "L2 ★握られている間、2 本目は非零で降りる" 1 "$rc"
chk "L2b ★持ち主は奪われない" "A" "$(run "$LOCKSH" holder 2>/dev/null)"

# 断り文に**持ち主の名前**が出る(出ないと、次に何を待てばよいか判らない)。
msg="$(run "$LOCKSH" acquire "B" 2>&1 >/dev/null)"
has() { printf '%s' "$msg" | /usr/bin/grep -qF "$1" && echo yes || echo no; }
chk "L2c 断り文が持ち主を名指しする" "yes" "$(has '持ち主 A')"
chk "L2d 断り文が理由(偽の赤)を言う" "yes" "$(has '偽の赤')"

# ── L3 他人は外せない ────────────────────────────────────────────────────
run "$LOCKSH" release "B" >/dev/null 2>&1
chk "L3 ★札が違う者は外せない" "A" "$(run "$LOCKSH" holder 2>/dev/null)"

# ── L4 持ち主は外せる。外れれば次が取れる ────────────────────────────────
run "$LOCKSH" release "A" >/dev/null 2>&1
chk "L4 持ち主は外せる" "" "$(run "$LOCKSH" holder 2>/dev/null)"
run "$LOCKSH" acquire "B" >/dev/null 2>&1; rc=$?
chk "L4b 外れた後は次が取れる" 0 "$rc"
run "$LOCKSH" release "B" >/dev/null 2>&1

# ── L5 古い錠は引き継ぐ(落ちた走行で永久に塞がらない)────────────────────
run "$LOCKSH" acquire "C" >/dev/null 2>&1
printf '%s\n' "0" > "$L/at"        # 1970 年 = 必ず古い
MAXS=1 run "$LOCKSH" acquire "D" >/dev/null 2>&1; rc=$?
chk "L5 ★古い錠は取り直せる(死んだ走行で永久に塞がらない)" 0 "$rc"
chk "L5b 取り直した者が持ち主になる" "D" "$(run "$LOCKSH" holder 2>/dev/null)"
run "$LOCKSH" release "D" >/dev/null 2>&1

# ── L6 生きている錠は「古い」と誤読しない ────────────────────────────────
run "$LOCKSH" acquire "E" >/dev/null 2>&1
MAXS=3600 run "$LOCKSH" acquire "F" >/dev/null 2>&1; rc=$?
chk "L6 ★生きている錠を古いと誤読しない" 1 "$rc"
run "$LOCKSH" release "E" >/dev/null 2>&1

# ── 陰性対照 ─────────────────────────────────────────────────────────────
# 変異を植えた複製を作り、**落ちるべき対照だけ**が落ちる事を測る。
#
# ★`mutate` を通すのは、**変異が当たらなかった時に黙って緑になる**のを防ぐ為
#   (2026-08-15 実測): 錠を書き直したら N6 の sed が旧い字面を探したまま何も
#   置換せず、変異体が本物の複製になった。N6 は「奪える(rc=0)」を期待していたので
#   赤で気付けたが、**「奪えない(rc=1)」を期待する陰性なら緑のまま通る**。
#   陰性対照は「変異を植えた」事自体が前提なので、其処を測らないと検査が嘘をつく。
#   空振りは**親の shell で数える**。`mutate_run` は `$(...)` の中で走るので、
#   其処で数えても部分 shell と一緒に消える(数えたつもりで 0 のまま出る)。
mutate() { # mutate <元> <sed 式> <先> — 置換が 1 文字も起きなければ記録する
    /usr/bin/sed "$2" "$1" > "$3"
    if /usr/bin/cmp -s "$1" "$3"; then
        printf '%s\t%s\n' "$(basename "$1")" "$2" >> "$SB/mutate-noop"
        return 1
    fi
    return 0
}

mutate_run() { # mutate_run <sed 式> -> 落ちた対照名の並び
    local m="$SB/mutated.sh"
    mutate "$LOCKSH" "$1" "$m" || true
    local ml="$SB/mut.lock"
    rm -rf "$ml"
    {
        RC_XCODE_TREE_LOCK="$ml" bash "$m" acquire "A" >/dev/null 2>&1
        a2=$?; RC_XCODE_TREE_LOCK="$ml" bash "$m" acquire "B" >/dev/null 2>&1; a2=$?
        [ "$a2" -eq 1 ] || echo -n "L2 "
        RC_XCODE_TREE_LOCK="$ml" bash "$m" release "B" >/dev/null 2>&1
        h="$(RC_XCODE_TREE_LOCK="$ml" bash "$m" holder 2>/dev/null)"
        [ "$h" = "A" ] || echo -n "L3 "
    }
}

# N1: 原子的な `mkdir` を `mkdir -p` に緩める = 既に在っても成功する。
#     → 2 本目が取れてしまう = L2 が落ちる。「錠として成立しているか」の芯。
#     ★L3 も一緒に落ちる。最初 "L2 " だけを期待して書き、**対照に訂正させられた**:
#       B が取れてしまうと札の持ち主が B に書き換わるので、続く `release B` が
#       正当に通り、持ち主が空になる。原子性を失うと「他人が外せない」も同時に
#       意味を失う —— 2 本は独立ではなく、L3 は L2 の上に乗っている。
#       予測でなく実測を書く(同じ訂正を 8/15 に deploy 側の N7 でも受けている)。
chk "N1 ★陰性: mkdir を -p に緩めると L2 と、その上に乗る L3 が落ちる" "L2 L3 " \
    "$(mutate_run 's/if mkdir "\$LOCK" 2>\/dev\/null; then/if mkdir -p "$LOCK" 2>\/dev\/null; then/')"

# N2: release の札照合を外す = 他人が外せる → L3 が落ちる。
chk "N2 ★陰性: release の札照合を外すと L3 が落ちる" "L3 " \
    "$(mutate_run 's/if \[ "\$held" != "\$owner" \]; then/if false; then/')"

# ── W 空くまで待つ(既定 0 = 待たない。束ねて回す側だけが立てる)────────────
run "$LOCKSH" acquire "W" >/dev/null 2>&1
t0="$(date +%s)"
RC_XCODE_TREE_LOCK="$L" RC_XCODE_TREE_LOCK_WAIT_S=5 \
    bash "$LOCKSH" acquire "X" >/dev/null 2>&1; rc=$?
t1="$(date +%s)"
chk "W1 待っても空かなければ非零で降りる" 1 "$rc"
chk "W1b 待ち時間を実際に使う(>=5 秒)" "yes" "$( [ $(( t1 - t0 )) -ge 5 ] && echo yes || echo no )"
# 待っている最中に空けば通る。**別の走行が外す**形でしか測れないので背景に置く。
( sleep 3; RC_XCODE_TREE_LOCK="$L" bash "$LOCKSH" release "W" >/dev/null 2>&1 ) &
RC_XCODE_TREE_LOCK="$L" RC_XCODE_TREE_LOCK_WAIT_S=60 \
    bash "$LOCKSH" acquire "Y" >/dev/null 2>&1; rc=$?
wait
chk "W2 ★待っている最中に空けば取れる(束の走行が途中で赤くならない)" 0 "$rc"
run "$LOCKSH" release "Y" >/dev/null 2>&1

# ── G 入れ子(`xcode-tree-guard.sh`)────────────────────────────────────────
# 親が錠を持ったまま子を呼ぶ形。子が素直に acquire すると自分で自分を締め出すので、
# 取っ手側で「親の札が在れば取りに行かない」を持つ。**其処だけを測る**。
mkdir -p "$SB/tools"
cp "$LOCKSH" "$HERE/xcode-tree-guard.sh" "$SB/tools/"
cat > "$SB/parent.sh" <<'EOF'
set -uo pipefail
. "$XTLD/xcode-tree-guard.sh"
trap 'xtl_release' EXIT
bash "$SBD/child.sh"; echo "child_rc=$?"
echo "after_child_holder=$("$XTLD/xcode-tree-lock.sh" holder)"
EOF
cat > "$SB/child.sh" <<'EOF'
set -uo pipefail
. "$XTLD/xcode-tree-guard.sh"
trap 'xtl_release' EXIT
echo "child_ran"
EOF

nest_run() { # nest_run [guard に当てる sed 式] -> 親の出力 + 終了後の持ち主
    local gl="$SB/nest.lock"
    rm -rf "$gl"
    if [ -n "${1:-}" ]; then
        mutate "$HERE/xcode-tree-guard.sh" "$1" "$SB/tools/xcode-tree-guard.sh" || true
    else
        cp "$HERE/xcode-tree-guard.sh" "$SB/tools/"
    fi
    local out
    out="$(RC_XCODE_TREE_LOCK="$gl" XTLD="$SB/tools" SBD="$SB" \
        bash "$SB/parent.sh" 2>/dev/null)"
    printf '%s\n' "$out"
    printf 'final_holder=%s\n' "$(RC_XCODE_TREE_LOCK="$gl" bash "$SB/tools/xcode-tree-lock.sh" holder)"
}

g="$(nest_run '')"
gh() { printf '%s' "$g" | /usr/bin/grep -qF "$1" && echo yes || echo no; }
chk "G1 ★親が握ったまま子を呼んでも子は止まらない(自分で自分を締め出さない)" "yes" "$(gh 'child_ran')"
chk "G1b 子は 0 で終わる" "yes" "$(gh 'child_rc=0')"
chk "G2 ★子の終了で親の錠は外れない" "yes" "$(gh 'after_child_holder=parent.sh')"
chk "G3 親が終われば錠は外れる" "yes" "$(gh 'final_holder=')"

# 陰性: 「親の札が在れば取りに行かない」を外す = 子も acquire しに行く。
# 既定 WAIT_S=0 なので子は即断られ、`child_ran` に届かないまま非零で死ぬ。
# ★入れ子の判定を消した瞬間に**子が死ぬ**事を、此処で押さえる。
g="$(nest_run 's/if \[ -z "\${RC_XCODE_TREE_LOCK_OWNER:-}" \]; then/if true; then/')"
chk "N3 ★陰性: 入れ子の判定を外すと子が親の錠に当たって死ぬ" "no" "$(gh 'child_ran')"

# ── G4 取れなかった時の終了コードを呼び側が決められる ─────────────────────────
# `.harness/dod-sprint-6.5-controls.sh` は 2 = 「測れなかった」を持っていて、
# 1 = 「壊れるべき対照が壊れなかった」と混ぜると判定を読み違える。錠が空かないのは
# **測れなかった**方なので、取っ手に既定 1 / 上書き可の口を開けてある。
gl4="$SB/failcode.lock"
rm -rf "$gl4"
RC_XCODE_TREE_LOCK="$gl4" bash "$SB/tools/xcode-tree-lock.sh" acquire "占有" >/dev/null 2>&1
cat > "$SB/failcode.sh" <<'EOF'
set -uo pipefail
. "$XTLD/xcode-tree-guard.sh"
echo "reached_body"      # 此処へ来たら fail-open = 錠を取れずに先へ進んでいる
EOF
out4="$(RC_XCODE_TREE_LOCK="$gl4" XTLD="$SB/tools" bash "$SB/failcode.sh" 2>/dev/null)"; rc=$?
chk "G4 ★既定は 1 で降りる" 1 "$rc"
chk "G4b ★取れなければ本体へ進まない(fail-open でない)" "" "$out4"
RC_XCODE_TREE_LOCK="$gl4" RC_XTL_FAIL_CODE=2 XTLD="$SB/tools" \
    bash "$SB/failcode.sh" >/dev/null 2>&1; rc=$?
chk "G4c ★呼び側が 2(測れなかった)を指定できる" 2 "$rc"
RC_XCODE_TREE_LOCK="$gl4" bash "$SB/tools/xcode-tree-lock.sh" release "占有" >/dev/null 2>&1

# ── S 刻印(`rev unknown` を作らない)────────────────────────────────────────
# 台本が自分で generate すると `${RC_BUILD_REV}` が**文字列のまま**焼かれ、画面に
# `rev unknown` と出る(Tom の 2026-08-15 の写真の下端)。取っ手が入れる。
cat > "$SB/stamp.sh" <<'EOF'
set -uo pipefail
. "$XTLREAL/xcode-tree-guard.sh"
trap 'xtl_release' EXIT
echo "rev=${RC_BUILD_REV:-}"
EOF
stamp_run() { # stamp_run [guard に当てる sed 式] -> rev=...
    local d="$SB/real"; rm -rf "$d"; mkdir -p "$d"
    if [ -n "${1:-}" ]; then
        mutate "$HERE/xcode-tree-guard.sh" "$1" "$d/xcode-tree-guard.sh" || true
    else
        cp "$HERE/xcode-tree-guard.sh" "$d/"
    fi
    cp "$LOCKSH" "$d/"
    # 版の計算は build.sh にしか無いので、其れだけは本物を指す(写しを作らない)。
    # ★symlink では駄目だった: build.sh は `dirname "$0"/..` で ios/ を決めるので、
    #   砂場に置いた名前で呼ぶと git の無い場所を見に行き、版が壊れる(この対照が
    #   最初に FAIL で教えてきた)。`exec` は $0 を**本物の路**に差し替えるので通る。
    printf '#!/bin/bash\nexec "%s" "$@"\n' "$HERE/build.sh" > "$d/build.sh"
    chmod +x "$d/build.sh"
    RC_XCODE_TREE_LOCK="$SB/stamp.lock" XTLREAL="$d" bash "$SB/stamp.sh" 2>/dev/null
}
srev="$(stamp_run '' | /usr/bin/sed -n 's/^rev=//p')"
chk "S1 ★取っ手が版を入れる(空でない)" "yes" "$( [ -n "$srev" ] && echo yes || echo no )"
chk "S2 ★入った版が生の \${…} でない(= 画面が rev unknown にならない)" "yes" \
    "$(printf '%s' "$srev" | /usr/bin/grep -q '[$]{' && echo no || echo yes)"
chk "S3 版の形が commit(7桁の16進、dirty 可)" "yes" \
    "$(printf '%s' "$srev" | /usr/bin/grep -qE '^[0-9a-f]{7}(-dirty)?$' && echo yes || echo no)"

# 陰性: 刻印の段を外すと版が空になる = `rev unknown` が戻る。
chk "N4 ★陰性: 刻印の段を外すと版が空になる(rev unknown が戻る)" "" \
    "$(stamp_run 's/^    RC_BUILD_REV="\$("\$XTL_DIR\/build.sh" --print-rev 2>\/dev\/null)"$/    RC_BUILD_REV=""/' | /usr/bin/sed -n 's/^rev=//p')"

# ── L8/L9 死活は**時刻でなく PID** で見る(Codex が初版を否定した2点)──────────
# 初版は「札が MAX_S より古ければ落ちた跡」だった。此れだと
#   L8: MAX_S を超えて走っている**生きている**走行から錠を奪える(lease に heartbeat が無い)
#   L9: 逆に、死んだ走行の札が新しいと永久に塞がる
# 札の形は `<台本名> <PID>` なので、1 台の中なら死活は推定せず直に見られる。
PL="$SB/pid.lock"; mkdir -p "$PL"
# 生きている持ち主(此の対照自身の PID を使う。名前も一致する)
printf '%s %s\n' "$(basename "$0")" "$$" > "$PL/owner"
printf '%s\n' "0" > "$PL/at"      # 1970 年 = 時刻で見れば「古い」
RC_XCODE_TREE_LOCK="$PL" RC_XCODE_TREE_LOCK_MAX_S=1 bash "$LOCKSH" acquire "X" >/dev/null 2>&1; rc=$?
chk "L8 ★時刻が幾ら古くても、持ち主が生きていれば奪わない" 1 "$rc"

# 死んだ持ち主(絶対に存在しない PID)+ 新しい時刻
DL="$SB/dead.lock"; mkdir -p "$DL"
printf 'ghost-control.sh 2\n' > "$DL/owner"   # PID 2 = kernel 側、名前が一致しない
date +%s > "$DL/at"                           # 時刻で見れば「新しい」
RC_XCODE_TREE_LOCK="$DL" RC_XCODE_TREE_LOCK_MAX_S=3600 bash "$LOCKSH" acquire "Y" >/dev/null 2>&1; rc=$?
chk "L9 ★時刻が新しくても、持ち主が居なければ退けて取れる" 0 "$rc"
chk "L9b 退けた者が持ち主になる" "Y" "$(RC_XCODE_TREE_LOCK="$DL" bash "$LOCKSH" holder 2>/dev/null)"

# 陰性: 死活の判定を外す(全部 unknown = 時刻に落ちる)と、L8 の生きている錠を奪う。
livesh="$SB/live-lock.sh"
mutate "$LOCKSH" 's/^    \[ -n "\$pid" \] || { echo unknown; return; }$/    { echo unknown; return; }/' \
    "$livesh" || true
PL2="$SB/pid2.lock"; mkdir -p "$PL2"
printf '%s %s\n' "$(basename "$0")" "$$" > "$PL2/owner"
printf '%s\n' "0" > "$PL2/at"
RC_XCODE_TREE_LOCK="$PL2" RC_XCODE_TREE_LOCK_MAX_S=1 bash "$livesh" acquire "X" >/dev/null 2>&1; rc=$?
chk "N7 ★陰性: 死活の判定を外すと生きている錠を奪う(= 初版の穴が実在した証拠)" 0 "$rc"

# ── L7 取得の途中の錠(`mkdir` は済んだが `at` がまだ無い)────────────────────
# ★此の状態は L1-L6 のどれも作っていなかった。対照が「取得し終えた錠」しか
#   作らなかったので、28 本 全部緑のまま穴が残っていた(2026-08-15 に差分を
#   読み直して発見)。窓は数ミリ秒だが、塞がらない限り**生きている錠を奪う**。
ML="$SB/midacquire.lock"
mkdir -p "$ML"                       # `mkdir` だけ済ませて owner/at を書かない = 取得の途中
RC_XCODE_TREE_LOCK="$ML" bash "$LOCKSH" acquire "Z" >/dev/null 2>&1; rc=$?
chk "L7 ★取得の途中の錠を「古い」と誤読して奪わない" 1 "$rc"

# 陰性: 時刻の代替(錠 dir の mtime)を外すと、其の場で奪う。
# ★此の式は錠を書き直した時に**空振りになった**(旧い一行版の字面を探していた)。
#   変異体が本物の複製になり、N6 は「奪える」を期待していたので赤で気付けた。
#   期待が逆(奪えない)の陰性なら緑のまま通っていた → 上の `mutate` で空振りを測る。
midsh="$SB/mid-lock.sh"
mutate "$LOCKSH" '/at="\$(\/usr\/bin\/stat -f %m "\$LOCK"/d' "$midsh" || true
ML2="$SB/midacquire2.lock"; mkdir -p "$ML2"
RC_XCODE_TREE_LOCK="$ML2" bash "$midsh" acquire "Z" >/dev/null 2>&1; rc=$?
chk "N6 ★陰性: 時刻の代替を外すと取得途中の錠を奪う(= 穴が実在した証拠)" 0 "$rc"

# ── C 掛け忘れ(此処だけは静的検査。**呼び側の網羅**は走らせても測れない)──────
# 錠の出来が幾ら良くても、新しい台本が生成木へ素で触れば同じ事故が戻る。
# 「取っ手を source しているか」を台本の側から数え上げる。落ちたら名前が出る。
#
# 触り方は 2 通り在って、片方だけ数えると穴が残る:
#   書く = `xcodegen generate` を撃つ                       → C1
#   読む = 本物の木の `ios/build/xcodebuild-sim.*` を複製する → C2
#
# ★C2 は此の対照を書いている最中(2026-08-15)に見付けた穴。
#   `.harness/dod-sprint-6.5-controls.sh` は generate を撃たないので C1 の網に
#   一度も掛からない。しかも其の台本自身の註(24 行目)に
#   「build が走っている最中に回すと偽の NG が出た(2026-08-07)」と**踏んだ記録**が
#   既に在った。註釈で警告済みの事故が、検出器の外側に居た。
#   → 註釈は検出しない。数える側に入れて初めて塞がる。
#
# `.harness/dod-sprint-4-controls.sh` は C2 に掛からない。複製時に `--exclude 'build/'`
# を掛けて log を自前で合成しており、共有状態そのものを持たないから(= 錠より上等な解)。

REPO="$(cd "$HERE/../.." && pwd)"

# ★走査は **repo 全体**。初版は C1 が `ios/tools/` だけ、C2 が `+ .harness/` だけを見ていた
#   —— 「網の狭さ」が正に C2 を生んだ欠陥なのに、C2 自身も同じ狭さを持っていた。
#   `xcodegen generate` を撃つ台本を明日 `rc-backend/tools/` に置けば、検出器の外に落ちる。
#   126 本の `.sh` を舐めるだけなので費用は無視できる(2026-08-15 実測)。
scan_missing() { # scan_missing <触り方の正規表現> <走査の根>
    local pat="$1" root="$2"
    local out="" f
    [ -d "$root" ] || { printf ''; return 0; }
    while IFS= read -r f; do
        case "$(basename "$f")" in xcode-tree-*) continue;; esac
        # ★`^[^#]*` = 註釈の行を数えない。`run-controls.sh` は「掛け場所は `xcodegen
        #   generate` を撃つ台本1本ずつ」と**説明しているだけ**で、自分では撃たない。
        #   此れを付けずに repo 全体へ広げると其の1本を誤って挙げる(実測した)。
        /usr/bin/grep -qE "^[^#]*($pat)" "$f" || continue
        # ★**砂場で撃つ台本は生成木を触らない**(2026-08-30、CF-21 の移行で出来た形)。
        #   `mutation-sandbox.sh` を source する台本は `$MS_TREE` の中で `xcodegen` を
        #   撃つので、`ios/RemoteMini.xcodeproj` も `ios/Info.plist` も書かない。
        #   直列化は砂場側の錠(`ms_prepare` の `mkdir`)が持つ —— 生成木の錠を
        #   握らせると、触らない資源の為に他の台本を待たせるだけになる。
        #   ★限界: 之は静的な信号なので「砂場を source しつつ**本物でも** xcodegen を
        #     撃つ」台本は見逃す。静的に見分ける手は無い。見付けたら台本の側を直す事。
        /usr/bin/grep -qE '^[^#]*(\.|source)[[:space:]]+.*mutation-sandbox\.sh' "$f" && continue
        # ★**自分で `mktemp -d` した写しの中で撃つ台本**も同じく生成木を触らない
        #   (2026-08-31、`client-role-controls.sh` の B9 が此の形)。砂場の助けを
        #   source する形と守る物は同じで、根が使い捨てである事だけが違う。
        #   ★名前では許さない: 撃っている**其の行**が `cd "$VAR…` で始まり、
        #     其の `VAR` が同じ file の中で `mktemp` から代入されている事を要求する。
        #     (`$WORK` と書いてあるだけ、では通さない —— 変数名は誰でも書ける)
        _scratch_ok=0
        while IFS= read -r _ln; do
            _v="$(printf '%s' "$_ln" | /usr/bin/sed -n 's/.*cd "\$\([A-Za-z_][A-Za-z_0-9]*\).*/\1/p' | head -1)"
            [ -n "$_v" ] || continue
            /usr/bin/grep -qE "^[[:space:]]*$_v=.*mktemp" "$f" && _scratch_ok=1
        done <<INNER
$(/usr/bin/grep -E "^[^#]*($pat)" "$f")
INNER
        [ "$_scratch_ok" = 1 ] && continue
        /usr/bin/grep -q 'xcode-tree-guard.sh' "$f" || out="$out$(basename "$f") "
    done <<EOF
$(find "$root" \( -name .git -o -name node_modules -o -name build -o -name dist -o -name .build \) -prune \
      -o -name '*.sh' -type f -print 2>/dev/null)
EOF
    printf '%s' "$out"
}

WRITES='xcodegen generate'
# 本物の木を指す変数経由の参照だけを拾う。註釈の中の `ios/build/...` は掛からない。
READS='\$\{?(ROOT|REAL_ROOT|REPO|IOS)\}?/ios/build/xcodebuild-sim'

chk "C1 ★生成木へ**書く**台本は全部 取っ手を通している(掛け忘れ検出・repo 全体)" "" \
    "$(scan_missing "$WRITES" "$REPO")"
chk "C2 ★生成木の産物を**読む**台本も 取っ手を通している(C1 の網の外に居た穴)" "" \
    "$(scan_missing "$READS" "$REPO")"

# 陰性: 検出器自身が赤になれる事を測る。赤になれない検出器は註釈と同じで何も守らない。
# 本物の file は触らず、取っ手の行を落とした写しを砂場に作って其れを走査する。
FIX="$SB/coverage"
mkdir -p "$FIX"
mutate "$REPO/.harness/dod-sprint-6.5-controls.sh" '/xcode-tree-guard\.sh/d' \
    "$FIX/dod-sprint-6.5-controls.sh" || true
chk "N5 ★陰性: 取っ手の行を落とすと C2 が其の名前を挙げる" \
    "dod-sprint-6.5-controls.sh " "$(scan_missing "$READS" "$FIX")"

# 陰性 N10: 走査を repo 全体へ広げた事が**実際に何かを買っている**か。
# `ios/tools/` でも `.harness/` でもない場所に、取っ手を通さず generate を撃つ台本を
# 1 本置いて、C1 が其れを挙げるかを見る。初版の走査範囲なら此れは**素通り**していた。
FIX2="$SB/scope"
mkdir -p "$FIX2/rc-backend/tools" "$FIX2/ios/tools"
cat > "$FIX2/rc-backend/tools/rogue.sh" <<'EOF'
#!/bin/bash
xcodegen generate --spec project.yml
EOF
# 対に「取っ手を通していれば挙がらない」も置く。何でも挙げる検出器は検出器ではない。
cat > "$FIX2/ios/tools/polite.sh" <<'EOF'
#!/bin/bash
. "$IOS/tools/xcode-tree-guard.sh"
xcodegen generate --spec project.yml
EOF
chk "N10 ★陰性: ios/tools の外に置いた無錠の台本を C1 が挙げる(網を広げた効果の実測)" \
    "rogue.sh " "$(scan_missing "$WRITES" "$FIX2")"
# ★註釈の中で `xcodegen generate` に言及しているだけの台本を挙げない事も測る
#   (`rc-backend/tools/run-controls.sh` が現に其れ。`^[^#]*` を外すと赤くなる)。
cat > "$FIX2/rc-backend/tools/mentions-only.sh" <<'EOF'
#!/bin/bash
# 掛け場所は `xcodegen generate` を撃つ台本 1 本ずつ
echo hi
EOF
chk "N10b 註釈で言及しているだけの台本は挙げない(false positive も欠陥)" \
    "rogue.sh " "$(scan_missing "$WRITES" "$FIX2")"

# ── N10c/N10d ★使い捨ての写しの除外は**根が mktemp である事**を要求する ──────────
# 2026-08-31 に足した除外。名前だけで許すと、`WORK="$IOS"` と書いて本物の生成木を
# 撃つ台本が素通りする —— 変数名は誰でも書ける。両方向を測る。
cat > "$FIX2/rc-backend/tools/scratch-ok.sh" <<'EOF'
#!/bin/bash
SB="$(mktemp -d)"
( cd "$SB/ios" && xcodegen generate >/dev/null 2>&1 )
EOF
chk "N10c ★mktemp を根に持つ写しで撃つ台本は挙げない" \
    "rogue.sh " "$(scan_missing "$WRITES" "$FIX2")"

cat > "$FIX2/rc-backend/tools/fake-scratch.sh" <<'EOF'
#!/bin/bash
SB="$IOS"
( cd "$SB/ios" && xcodegen generate >/dev/null 2>&1 )
EOF
chk "N10d ★名前が同じでも根が mktemp でなければ挙げる(名前だけでは許さない)" \
    "fake-scratch.sh rogue.sh " "$(scan_missing "$WRITES" "$FIX2")"

# ── C3 source の**パスが実在する**か ─────────────────────────────────────────
# ★C1/C2 は「名前が書いてあるか」しか見ない。台本は全部 `set -uo pipefail` で
#   **`-e` が無い**ので、`. "$IOS/tools/xcode-tree-guard.sh"` のパスが違うと
#   「No such file」を1行吐いて**そのまま先へ進む** = 錠を取らずに generate を撃つ。
#   掛け忘れと同じ穴が、掛けたつもりの側から開く(fail-open)。
#   → source 行のパスを台本の中の変数定義から解決して、実在を確かめる。
resolve_guard_path() { # resolve_guard_path <台本> -> 解決したパス(できなければ空)
    local f="$1" line rest pre
    line="$(/usr/bin/grep -m1 -E '^[[:space:]]*\. .*xcode-tree-guard\.sh' "$f" 2>/dev/null)"
    [ -n "$line" ] || return 0
    rest="$(printf '%s' "$line" | /usr/bin/sed -E 's/^[[:space:]]*\. *"?//; s/"?[[:space:]]*$//')"
    # 解決に要る定義だけを拾う(`VAR="$(cd … && pwd)"` と `VAR="$OTHER"` の 2 形に限る
    # = 任意のコードを走らせない)。★別名(`IOS="$HERE"`)を外していて、5 本を
    #   「パスが不在」と誤って挙げた(2026-08-15)。検出器の false positive も欠陥。
    # `${BASH_SOURCE[0]}` は台本自身の場所なので、其の字面を実パスへ差し替えてから評価する。
    # ★行末を固定しない(`HERE="$(cd …)"   # = ios/` の様に註釈が付く)。
    pre="$(/usr/bin/grep -E '^[A-Za-z_][A-Za-z0-9_]*="(\$\(cd .*&& pwd\)|\$\{?[A-Za-z_][A-Za-z0-9_]*\}?)"' "$f" \
           | /usr/bin/sed "s#\${BASH_SOURCE\[0\]}#$f#g")"
    ( eval "$pre" >/dev/null 2>&1; eval "printf '%s' \"$rest\"" 2>/dev/null )
}

badpath=""
for f in "$HERE"/*.sh "$REPO/.harness"/*.sh; do
    [ -f "$f" ] || continue
    case "$(basename "$f")" in xcode-tree-*) continue;; esac
    /usr/bin/grep -q 'xcode-tree-guard.sh' "$f" || continue
    p="$(resolve_guard_path "$f")"
    [ -n "$p" ] && [ -f "$p" ] || badpath="$badpath$(basename "$f") "
done
chk "C3 ★source している取っ手のパスが実在する(-e が無いので不在でも先へ進む)" "" "$badpath"

# 陰性: パスを 1 文字壊した写しを作り、C3 が其れを挙げる事を測る。
FIX3="$SB/pathcov"
mkdir -p "$FIX3"
# ★先に「壊す前は解決する」を測る。砂場に写した時点で解決しないなら、下の N8 は
#   変異ではなく**砂場のせい**で緑になる = 何も測っていない(dod-6.5 の 0 行目と同じ理屈)。
cp "$HERE/build.sh" "$FIX3/pristine.sh"
p0="$(resolve_guard_path "$FIX3/pristine.sh")"
chk "N8-pre 壊す前は砂場でも解決する(= N8 が空虚でない事の確認)" "yes" \
    "$( [ -n "$p0" ] && [ -f "$p0" ] && echo yes || echo no )"
mutate "$HERE/build.sh" \
    's#/tools/xcode-tree-guard\.sh#/tools/NOPE/xcode-tree-guard.sh#' \
    "$FIX3/build.sh" || true
p="$(resolve_guard_path "$FIX3/build.sh")"
chk "N8 ★陰性: パスを壊すと C3 が捕まえる(名前は書いてあるのに不在)" "no" \
    "$( [ -n "$p" ] && [ -f "$p" ] && echo yes || echo no )"

# --- C4: 錠を**返す**側の fail-open ---------------------------------------------
# `trap ... EXIT` は**加算されない** —— 後から掛けた方が前のを丸ごと置き換える。
# 取っ手を source した後に `trap 'cleanup' EXIT` を書くと、`xtl_release` が
# **一文字も残らずに消える**のに、台本を読む限りでは錠が返る様に見える。
# C3(掛ける側)と対になる、**返す側の**「配線されて見えるのに走らない」。
# 2026-08-15、私自身の差分が `dod-sprint-6.5-controls.sh` で此れを踏んだ(trap が
# 上下 2 本並び、上が死んでいた)。→ 性質: **最後の `trap ... EXIT` に
# `xtl_release` が居る事**。位置ではなく「最後」で見るのは、置き換えの規則其の物。
last_exit_trap() { # last_exit_trap <台本> -> 最後の `trap … EXIT` の行(無ければ空)
    /usr/bin/grep -E '^[[:space:]]*trap[[:space:]].*EXIT' "$1" 2>/dev/null | /usr/bin/tail -1
}
# ★`case` を `$(…)` の中へ直に書かない。pattern の `)` が置換の閉じ括弧として読まれて
#   syntax error になる(2026-08-15 実測)。判定は関数へ出して `$(releases_lock …)` で呼ぶ。
releases_lock() { # releases_lock <台本> -> yes | no
    case "$(last_exit_trap "$1")" in
        *xtl_release*) echo yes;;
        *)             echo no;;
    esac
}

norelease=""
for f in "$HERE"/*.sh "$REPO/.harness"/*.sh; do
    [ -f "$f" ] || continue
    case "$(basename "$f")" in xcode-tree-*) continue;; esac
    /usr/bin/grep -q 'xcode-tree-guard.sh' "$f" || continue
    t="$(last_exit_trap "$f")"
    # trap を一本も掛けない台本は対象外(消される物が無いので穴にならない)。
    [ -n "$t" ] || continue
    case "$t" in *xtl_release*) ;; *) norelease="$norelease$(basename "$f") ";; esac
done
chk "C4 ★最後の trap EXIT が錠を返す(後から掛けた trap は前のを置き換える)" "" "$norelease"

# 陰性: 取っ手の後ろに素の trap を 1 行足した写しを作り、C4 が挙げる事を測る。
FIX4="$SB/trapcov"
mkdir -p "$FIX4"
cp "$HERE/build.sh" "$FIX4/pristine.sh"
chk "N9-pre 壊す前の最後の trap は錠を返す(= N9 が空虚でない事の確認)" "yes" \
    "$(releases_lock "$FIX4/pristine.sh")"
# ★`mutate` を通す(空振りしたら親が FAIL にする)。末尾に 1 行足すので `$` を狙う。
mutate "$HERE/build.sh" \
    '$a\
trap '"'"'cleanup'"'"' EXIT' \
    "$FIX4/build.sh" || true
chk "N9 ★陰性: 後ろに素の trap を足すと C4 が捕まえる(錠が黙って返らなくなる)" "no" \
    "$(releases_lock "$FIX4/build.sh")"

# ★空振りした変異を最後に清算する(`mutate` は部分 shell の中でも走るので、
#   数を持ち歩けない。file に落として親で数える)。
if [ -s "$SB/mutate-noop" ]; then
    while IFS="$(printf '\t')" read -r f expr; do
        FAIL=$((FAIL+1))
        printf 'FAIL  ★変異が当たっていない(sed が空振り / %s)\n        式=[%s]\n' "$f" "$expr"
        printf '        → 変異体が本物の複製になっている = 其の陰性対照は何も測っていない\n'
    done < "$SB/mutate-noop"
fi

echo "--- 合計: PASS $PASS / FAIL $FAIL ---"
[ "$FAIL" -eq 0 ]
