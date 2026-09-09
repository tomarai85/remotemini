#!/bin/bash
# controls-for: tools/parity-observer-control.sh tools/ota-undelivered-observer-control.sh
#
# 観測器の変異対照が **殺されても実物を汚さない** 事の対照。
#
# ── なぜ要るか(2026-09-08、実測で再現した)────────────────────────────────
# 両対照は元々 `SUT` が**実物**を指し、`mutate()` が本番の観測器をその場で書き換え、
# `trap 'rm -rf "$SB"' EXIT` は砂場を消すだけで実物を戻さなかった。
# 変異と復元の間で殺されると **変異した観測器が木に残り、唯一の控えも一緒に消える**。
#   `tunnel-observer.sh` が両方の実物を source して `parity_observe` /
#   `undelivered_observe` を呼び、`com.tomtim.rc-tunnel-observer` が Jervis で
#   10 分毎に走らせる = 本番。
#   殺され方は珍しくない: `run-controls.sh` は各対照を `perl -e 'alarm …'` で
#   時間切れにするので、上限に当たった走行は **SIGALRM** で死ぬ。
# 写しの上で再現した時、実物に残ったのは `grace=0`(= 猶予なしで毎回鳴る)——
# 警報疲れを避ける為の猶予が消えた版が、誰にも気付かれずに本番で回る状態だった。
#
# 直しは trap の補強ではなく **写しの上で変異させる**(ios 側の裁定と同じ:
# 「殺されても木に変異は残らない —— trap が走るかどうかに安全が依存しなくなる」
# = `ios/tools/mutation-sandbox.sh` の頭)。此の対照は其の性質を直接測る。
#
# 測る事:
#   S1/S2 対照を **TERM** で殺しても実物のバイトが動かない(2 本)
#   S3/S4 対照を **ALRM** で殺しても実物のバイトが動かない(= 時間切れと同じ殺し方)
#   S5    ★陰性対照: 昔の形(実物を変異させ、trap が戻さない)を合成して
#          **此の検査が本当に赤を出せる**事を示す。之が無いと S1..S4 は恒真になり得る
#          —— 「殺すのが早すぎて変異が始まる前だった」でも緑になるから。
#
# 使い方: bash rc-backend/test/observer-control-sandbox-controls.sh
# 終了コード: 0=全部緑 / 1=1本でも赤 / 2=測れなかった
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"      # = rc-backend/test
TOOLS="$(cd "$HERE/.." && pwd)/tools"
pass=0; fail=0; unmeasured=0
ok() { echo "PASS  $1"; pass=$((pass + 1)); }
ng() { echo "FAIL  $1  ($2)"; fail=$((fail + 1)); }
un() { echo "UNMEASURED  $1"; unmeasured=$((unmeasured + 1)); }

SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT

# 対照を走らせて <signal> で殺し、実物のバイトが動いたかを返す。
# ★「殺す前に完走してしまった」を緑と読まない。完走したら測定不成立にする ——
#   完走した走行は復元が正常に働いた場合と区別できず、殺された時の話を何も語らない。
kill_midrun() {  # kill_midrun <対照 path> <実物 path> <signal> → 0=無傷 / 1=汚れた / 2=測れず
    local ctl="$1" live="$2" sig="$3" before after pid
    before="$(shasum "$live" | awk '{print $1}')"
    bash "$ctl" >/dev/null 2>&1 &
    pid=$!
    sleep 0.7
    if ! kill -0 "$pid" 2>/dev/null; then wait "$pid" 2>/dev/null; return 2; fi
    kill -"$sig" "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    sleep 0.4
    after="$(shasum "$live" | awk '{print $1}')"
    [ "$before" = "$after" ]
}

for pair in \
    "parity-observer-control.sh|parity-observer.sh" \
    "ota-undelivered-observer-control.sh|ota-undelivered-observer.sh" ; do
    ctl="$TOOLS/${pair%%|*}"; live="$TOOLS/${pair##*|}"
    if [ ! -f "$ctl" ] || [ ! -f "$live" ]; then
        un "${pair%%|*}: 対照か実物が居ない = 何も測っていない"; continue
    fi
    for sig in TERM ALRM; do
        kill_midrun "$ctl" "$live" "$sig"; rc=$?
        case "$rc" in
            0) ok "${pair##*|} は $sig で殺しても1バイトも動かない" ;;
            1) ng "${pair##*|} が $sig で汚れた" "本番が source する実物に変異が残った。手で git checkout -- rc-backend/tools/${pair##*|} する事" ;;
            *) un "${pair%%|*}($sig): 殺す前に完走した = 殺された時の話を測っていない" ;;
        esac
    done
done

# ── S5 ★陰性対照 ───────────────────────────────────────────────────────────
# 昔の形を最小限で合成する: 実物を書き換え、trap は砂場を消すだけ。
# 上の検査が之を**赤と呼べなければ**、S1..S4 の緑は「壊れていない」ではなく
# 「測れていない」を意味する。
FAKE="$SB/fake"; mkdir -p "$FAKE"
printf '#!/bin/bash\necho "本番の観測器(合成)"\n' > "$FAKE/victim.sh"
{
  printf '#!/bin/bash\n'
  printf 'H="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"\n'
  printf 'SUT="$H/victim.sh"\n'
  printf 'S="$(mktemp -d)"; trap %s EXIT\n' "'rm -rf \"\$S\"'"
  printf 'cp "$SUT" "$S/orig.sh"\n'
  printf 'printf %s >> "$SUT"\n' "'mutated\\n'"      # 変異を植えたまま
  printf 'sleep 30\n'                                 # 復元に到達する前に殺される
  printf 'cp -f "$S/orig.sh" "$SUT"\n'
} > "$FAKE/victim-control.sh"
chmod +x "$FAKE/victim-control.sh"

kill_midrun "$FAKE/victim-control.sh" "$FAKE/victim.sh" TERM; rc=$?
case "$rc" in
    1) ok "S5 ★陰性対照: 昔の形は赤になる(此の検査は本当に落ちる)" ;;
    0) ng "S5 陰性対照が緑" "昔の形すら汚れていないと判定した = S1..S4 の緑は何も意味しない" ;;
    *) un "S5 陰性対照が完走した = 検査が落ちる事を確かめていない" ;;
esac

echo ""
echo "--- 合計: PASS $pass / FAIL $fail / UNMEASURED $unmeasured ---"
[ "$fail" -gt 0 ] && exit 1
[ "$unmeasured" -gt 0 ] && exit 2
exit 0
