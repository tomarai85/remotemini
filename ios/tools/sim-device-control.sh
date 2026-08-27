#!/bin/bash
# controls-for: ios/tools/sim-device.sh
# sim-device-control.sh — 対照が **どの機へ install しに行くか** を測る。2026-08-26 新設。
#
# 守る一線: 「`xcodebuild test` の宛先が **Tom が見る機ではない**」。
#   これが破れると、対照を回すたびに Tom の機の中身が種なしの Debug 版へ差し替わり、
#   Tom が開くと「鍵を手で入れろ」= 本人が名指しで拒否した画面が出る。
#   ★2026-08-26 に実際に起きていた。緑の数にも healthz にも出ず、**画を撮って初めて**
#     分かった(3案の画が byte 単位で同一 = アプリが一覧へ到達していなかった)。
#
# ★文字列一致で `iPhone-dogfood` を grep するだけにしない。それは「写しの述語」で、
#   宛先の組み立て方が変われば黙って緑になる(この repo が何度も踏んだ型)。
#   だから **偽の xcodebuild を PATH に差して、実際に渡された引数を記録**して測る。
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS="$(cd "$HERE/.." && pwd)"
ROOT="$(cd "$IOS/.." && pwd)"

fail=0; reds=0
DOG="iPhone-dogfood"

# `xcodebuild test` を撃つ対照(= 機へ install する物)だけが対象。
# `build` しかしない物(ui-fixture-absence)は install しないので入れない。
TARGETS=(
  "ios/tools/account-ui-control.sh"
  "ios/tools/list-return-refresh-control.sh"
  "ios/tools/signout-notice-control.sh"
  "ios/tools/inflight-sentence-control.sh"
  "ios/tools/conversation-ui-control.sh"
  "ios/tools/ui-fixture-behavior-control.sh"
  ".harness/dod-sprint-6-controls.sh"
)

STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR"' EXIT
REC="$STUB_DIR/args.log"
REC_SIM="$STUB_DIR/simctl.log"

# 対象の機の UDID(名前ではなく **UDID** で照合する。台本は `simctl list` から UDID を
# 引いてから install するので、install 行に名前は出てこない)。
DOG_UDID="$(xcrun simctl list devices 2>/dev/null | grep -F "$DOG (" | grep -oE '[0-9A-F-]{36}' | head -1)"
CTL_UDID="$(xcrun simctl list devices 2>/dev/null | grep -F "iPhone-controls (" | grep -oE '[0-9A-F-]{36}' | head -1)"
[ -n "$DOG_UDID" ] || { echo "★$DOG の UDID が引けない(この検査は機の実在が前提)"; exit 2; }

# 偽の xcodebuild: 引数を1行で記録して即座に失敗する。失敗させるのは、対照を最後まで
# 走らせない為(本物のビルドを回したらこの検査自体が数分 x 7 になる)。
cat >"$STUB_DIR/xcodebuild" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$RC_STUB_REC"
exit 65
STUB
# xcodegen も止める(本物を回すと project を書き換える = 検査が副作用を持つ)。
printf '#!/bin/bash\nexit 0\n' > "$STUB_DIR/xcodegen"

# ★`xcrun` の偽物は **素通しと記録の二枚舌**にする。`simctl list` を潰すと
#   `sim-device.sh` の「機が在るか」の確認が落ちて、そもそも台本が始まらない =
#   何も測れないまま緑になる。だから読み取りは本物へ通し、**機を変える呼び出しだけ**
#   記録して握り潰す(本物を撃つと此の検査自体が機を起動して数分 x 7 の熱になる)。
cat >"$STUB_DIR/xcrun" <<'XSTUB'
#!/bin/bash
printf '%s\n' "$*" >> "$RC_STUB_REC_SIM"
if [ "${1:-}" = "simctl" ]; then
    case "${2:-}" in
        list|help|getenv|get_app_container) exec /usr/bin/xcrun "$@" ;;
        *) exit 0 ;;
    esac
fi
exec /usr/bin/xcrun "$@"
XSTUB
chmod +x "$STUB_DIR/xcodebuild" "$STUB_DIR/xcodegen" "$STUB_DIR/xcrun"

echo "=== 対照の宛先を、偽 xcodebuild に渡された引数で測る ==="
for t in "${TARGETS[@]}"; do
    p="$ROOT/$t"
    label="$(basename "$t")"
    if [ ! -f "$p" ]; then
        printf '  %-38s → ★file が無い\n' "$label"; fail=1; continue
    fi
    : > "$REC"; : > "$REC_SIM"
    # SIM_NAME は**意図的に unset**。既定がどこを指すかを測っている。
    # ★**門と同じ起動の形**にする: repo の根から **相対 path** で叩く。
    #   絶対 path で叩くと `${BASH_SOURCE[0]}` が絶対になり、台本が自分で `cd` した後でも
    #   dirname が効いてしまう = 実際に壊れた形を再現できない。2026-08-26 に此処を
    #   絶対 path で書いていて、`SIM_NAME: unbound variable` の全台本墜落を見逃した。
    ( cd "$ROOT" && env -u SIM_NAME RC_STUB_REC="$REC" RC_STUB_REC_SIM="$REC_SIM" \
        PATH="$STUB_DIR:$PATH" timeout 180 /bin/bash "$t" >/dev/null 2>"$STUB_DIR/run.err" )
    crash="$(grep -aE "unbound variable|No such file|command not found" "$STUB_DIR/run.err" 2>/dev/null | head -1)"
    rm -f "$STUB_DIR/run.err"
    if [ -n "$crash" ]; then
        printf '  %-38s → ★台本が墜落している: %s\n' "$label" "$crash"; fail=1; continue
    fi

    # 機を変える呼び出しだけを見る(`list` は本物へ通しているので、宛先の証拠にならない)。
    mut="$(grep -aE 'simctl (install|boot|launch|terminate|bootstatus|uninstall|io)' "$REC_SIM" 2>/dev/null || true)"

    # dogfood は **名前でも UDID でも** 出てはいけない。これは常に見る。
    if grep -qF "name=$DOG" "$REC" 2>/dev/null || printf '%s' "$mut" | grep -qF "$DOG_UDID"; then
        printf '  %-38s → ★%s を指している\n' "$label" "$DOG"; fail=1; continue
    fi

    if grep -qF "name=iPhone-controls" "$REC" 2>/dev/null; then
        printf '  %-38s → iPhone-controls (xcodebuild)  OK\n' "$label"; continue
    fi
    if [ -n "$CTL_UDID" ] && printf '%s' "$mut" | grep -qF "$CTL_UDID"; then
        printf '  %-38s → iPhone-controls (simctl)      OK\n' "$label"; continue
    fi

    # ★宛先を渡す呼び出しへ到達しなかった台本(先に `xcodebuild build` を撃ち、偽物が
    #   失敗を返すのでそこで降りる型)。**構造で通さない** —— 「sim-device.sh を読んで
    #   いるか」を grep するのは写しの述語で、読み方が変われば黙って緑になる。
    #   代わりに **dogfood を刺して、拒否する事**を振る舞いで測る。守りを外せば赤くなる。
    dogrc=0
    perr="$STUB_DIR/probe.err"
    ( cd "$ROOT" && env SIM_NAME="$DOG" RC_STUB_REC="$STUB_DIR/probe.x" RC_STUB_REC_SIM="$STUB_DIR/probe.s" \
        PATH="$STUB_DIR:$PATH" timeout 180 /bin/bash "$t" >/dev/null 2>"$perr" ) || dogrc=$?
    probe_mut="$(grep -aE 'simctl (install|boot|launch)' "$STUB_DIR/probe.s" 2>/dev/null || true)"
    # ★★非ゼロで帰った事を「拒否」と読まない。**守りが出した合図**を要求する。
    #   2026-08-26 に此処を rc だけで判定していて、相対 path 起動で source が空振りし
    #   `SIM_NAME: unbound variable` で全台本が墜落していたのを、**2秒で全ケース緑**と
    #   報告した。墜落と拒否は、rc からは区別が付かない。
    guarded=0
    grep -qF "RC-SIMDEV-REFUSED-DOGFOOD" "$perr" 2>/dev/null && guarded=1
    why="$(head -1 "$perr" 2>/dev/null)"
    rm -f "$STUB_DIR/probe.x" "$STUB_DIR/probe.s" "$perr"
    if [ "$guarded" = 1 ] && [ "$dogrc" != 0 ] && [ -z "$probe_mut" ]; then
        printf '  %-38s → dogfood を刺すと守りが拒否           OK\n' "$label"
    elif [ "$guarded" != 1 ]; then
        printf '  %-38s → ★守りの合図が無い(墜落か素通り): %s\n' "$label" "${why:-出力なし}"; fail=1
    else
        printf '  %-38s → ★dogfood を刺しても機へ触れた(rc=%s)\n' "$label" "$dogrc"; fail=1
    fi
done

echo
echo "=== 解決口そのものの負の対照 ==="
SD="$IOS/tools/sim-device.sh"
run_sd() { # <説明> <期待exit> <env...>
    local desc="$1" want="$2"; shift 2
    local rc; ( env "$@" /bin/bash "$SD" >/dev/null 2>&1 ); rc=$?
    [ "$want" != 0 ] && reds=$((reds + 1))
    if [ "$rc" = "$want" ]; then printf '  %-46s → exit=%s OK\n' "$desc" "$rc"
    else printf '  %-46s → exit=%s ★期待 %s\n' "$desc" "$rc" "$want"; fail=1; fi
}
run_sd "既定(SIM_NAME 無し)は通る"                    0 SIM_NAME=
run_sd "外から dogfood を刺されたら断る[負]"           2 SIM_NAME=iPhone-dogfood
run_sd "明示の緊急口は通る"                            0 SIM_NAME=iPhone-dogfood RC_ALLOW_DOGFOOD_SIM=1
run_sd "存在しない機は大声で落ちる[負]"                2 SIM_NAME=iPhone-does-not-exist

printf '  %-46s → ' "断り文が xcodebuild を起動しない[負]"
out=$( SIM_NAME="$DOG" /bin/bash "$SD" 2>&1 )
if printf '%s' "$out" | grep -q "ResultBundle"; then
    printf '★起動している(バッククォートがコマンド置換になっている)\n'; fail=1
else printf 'OK\n'; fi
reds=$((reds + 1))

echo
echo "  赤に倒れる入力: ${reds} 件"
[ "$reds" -lt 2 ] && { echo "  ★対照が空虚: 赤に出来る入力がほぼ無い"; fail=1; }
echo
[ "$fail" = 0 ] && { echo "全ケース OK"; exit 0; } || { echo "★赤あり"; exit 1; }
