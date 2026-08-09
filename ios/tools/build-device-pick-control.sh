#!/bin/bash
# controls-for: ios/tools/build.sh
#
# `build.sh` が **どの電話へ入れるか決める所**(`resolve_device`)だけを撃つ。
#
# なぜ要るか(2026-08-09、実際に起きた形):
#   此処は `connectionProperties.tunnelState` が `connected` / `available` の機だけを
#   選んでいた。ところが同日、一覧が `tunnelState=disconnected` と言っている実機に対して
#   `xcrun devicectl device install app` がそのまま通り、devicectl 自身が最初の行で
#   `Acquired tunnel connection to device.` と言った —— tunnelState は「いま管が
#   張られているか」であって「張れるか」ではない。
#   結果、繋がる電話を「no connected device」と断って、電話の側を疑いに行った。
#   **正しい値を持たない診断を判定にすると、嘘の赤が出て検査ごと信用されなくなる。**
#   だから門は「対になった iOS 機が1台に決まるか」だけにし、届くかどうかは install
#   自身に決めさせた。その造り替えが**戻されたら赤になる**様に此処を置く。
#
# ★測る物 / 測らない物を分けて書く:
#   測る   = 一覧の JSON → 選ぶ識別子 / 終了コード の対応。名指し(RC_DEVICE)の追い越し。
#            標準出力に識別子**だけ**が出る事(説明を混ぜると呼ぶ側が汚れた値を掴む)。
#   測らない = 実機へ届くか、署名、焼く工程。其れは本物の install が決める事で、
#            此処の主題(門が繋がる電話を断らない事)とは別。
#
# 入力の出所: `tools/fixtures/devicectl-list-devices.json` は **本物の devicectl の
#   出力**から個体を指す値だけを差し替えた物(手で書いた JSON ではない = 対照の規則(1))。
#   `tunnelState=disconnected` は本物のまま残してある —— それが主題だから。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 継ぎ目。守っている物を外から差し替えられる様にしておく —— これが無いと
# 「旧版に戻したら赤くなるか」を **live の file を壊さずに** 見られない
# (壊して戻す造りは、戻し損ねが repo に残る。prove-control.sh の頭に同じ経緯)。
SUT="${RC_BUILD_SH:-$HERE/build.sh}"
FIX="$HERE/fixtures/devicectl-list-devices.json"
[ -f "$SUT" ] || { echo "対象が無い: $SUT"; exit 2; }
[ -f "$FIX" ] || { echo "本物由来の入力が無い: $FIX"; exit 2; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

# 砂場に build.sh の**現物を写して**撃つ(写した中身は毎回この場で取るので、
# 論理の写しにはならない)。狙いは `$DERIVED` を砂場へ寄せる事 —— 本物の
# `ios/build/devices.json` を対照が上書きしないで済む。
mkdir -p "$T/tools" "$T/bin"
cp "$SUT" "$T/tools/build.sh"

# 偽 xcrun。`--json-output <path>` を読んで、渡された一覧を其処へ置く。
# 呼ばれた事を痕跡に残す(名指しの時に**呼ばない**事を測る為)。
cat > "$T/bin/xcrun" <<'EOS'
#!/bin/bash
echo "called" >> "$XCRUN_TRACE"
[ "${FAKE_XCRUN_RC:-0}" = "0" ] || exit "$FAKE_XCRUN_RC"
out=""; prev=""
for a in "$@"; do
    [ "$prev" = "--json-output" ] && out="$a"
    prev="$a"
done
[ -n "$out" ] || exit 9
cat "$FAKE_DEVICES" > "$out"
EOS
chmod +x "$T/bin/xcrun"

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf 'PASS  %s\n' "$1"; }
ng() { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"; printf '%s\n' "$OUT" | /usr/bin/sed 's/^/        /'; }

# run <一覧の JSON の中身> [env 名=値 ...]
# 標準出力と標準エラーを**分けて**取る。混ざると「識別子だけが出る」が測れない。
run() {
    local body="$1"; shift
    printf '%s\n' "$body" > "$T/devices.json"
    : > "$T/xcrun-trace"
    OUTF="$T/out"; ERRF="$T/err"
    env -u RC_DEVICE "$@" \
        FAKE_DEVICES="$T/devices.json" XCRUN_TRACE="$T/xcrun-trace" \
        PATH="$T/bin:$PATH" \
        bash "$T/tools/build.sh" --print-device >"$OUTF" 2>"$ERRF"
    RC=$?
    STDOUT="$(cat "$OUTF")"; STDERR="$(cat "$ERRF")"; OUT="$STDOUT
--- stderr ---
$STDERR"
}

REAL="$(cat "$FIX")"
FAKE_ID="11111111-2222-3333-4444-555555555555"

# ── A: 本物の形そのまま。tunnelState は disconnected ────────────────────────
#    ★これが主題。此処が赤に戻ったら、門がまた「繋がる電話」を断っている。
run "$REAL"
if [ "$RC" -eq 0 ] && [ "$STDOUT" = "$FAKE_ID" ]; then
    ok "A tunnelState=disconnected でも対になった iOS 機を選ぶ"
else
    ng "A 繋がる電話を断った(rc=$RC stdout=[$STDOUT])"
fi

# ── A2: 標準出力は識別子1行**だけ** ────────────────────────────────────────
if [ "$(printf '%s\n' "$STDOUT" | wc -l | tr -d ' ')" = "1" ]; then
    ok "A2 標準出力は1行だけ(説明は stderr へ逃げている)"
else
    ng "A2 標準出力に識別子以外が混ざった"
fi

# ── B: 対になっていない ────────────────────────────────────────────────────
run "$(printf '%s' "$REAL" | /usr/bin/sed 's/"pairingState" : "paired"/"pairingState" : "unpaired"/; s/"pairingState": "paired"/"pairingState": "unpaired"/')"
if [ "$RC" -eq 1 ] && printf '%s' "$STDERR" | grep -q "1台も居ない"; then
    ok "B 対になっていない -> 赤(1)、理由付き"
else
    ng "B 対になっていない機を選んだ / 理由が無い(rc=$RC)"
fi

# ── C: iOS 機が2台。黙って先頭を選ばない ──────────────────────────────────
TWO="$(/usr/bin/python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
a=d["result"]["devices"][0]
b=json.loads(json.dumps(a)); b["identifier"]="99999999-8888-7777-6666-555555555555"
d["result"]["devices"]=[a,b]
print(json.dumps(d))' "$FIX")"
run "$TWO"
if [ "$RC" -eq 4 ] \
   && printf '%s' "$STDERR" | grep -q "$FAKE_ID" \
   && printf '%s' "$STDERR" | grep -q "99999999-8888-7777-6666-555555555555" \
   && [ -z "$STDOUT" ]; then
    ok "C iOS 機が2台 -> 選ばず(4)、両方の識別子を名指しさせる"
else
    ng "C 2台居るのに黙って選んだ / 片方しか出さない(rc=$RC stdout=[$STDOUT])"
fi

# ── D: 名指し(RC_DEVICE)は一覧を追い越し、xcrun を**呼ばない** ────────────
run "$TWO" RC_DEVICE="ZZZZ-NAMED"
if [ "$RC" -eq 0 ] && [ "$STDOUT" = "ZZZZ-NAMED" ] && [ ! -s "$T/xcrun-trace" ]; then
    ok "D RC_DEVICE で名指し -> 一覧を引かずにその機へ決まる"
else
    ng "D 名指しが効かない / 名指しなのに一覧を引いた(rc=$RC stdout=[$STDOUT] trace=$(cat "$T/xcrun-trace"))"
fi

# ── E: iOS ではない機は選ばない ────────────────────────────────────────────
run "$(printf '%s' "$REAL" | /usr/bin/sed 's/"platform" : "iOS"/"platform" : "macOS"/; s/"platform": "iOS"/"platform": "macOS"/')"
if [ "$RC" -eq 1 ] && printf '%s' "$STDERR" | grep -q "1台も居ない"; then
    ok "E iOS でない機は選ばない"
else
    ng "E iOS でない機を選んだ(rc=$RC stdout=[$STDOUT])"
fi

# ── F: 一覧の形が変わった(result.devices が無い) -> 未測定側の 3 ──────────
#    ★空の選択に落として「1台も居ない」と言わせない。形が変わった事と
#      機が居ない事は別の話で、直し方も別。
run '{"info":{},"result":{}}'
if [ "$RC" -eq 3 ] && printf '%s' "$STDERR" | grep -q "形が変わった"; then
    ok "F 一覧の形が変わった -> 3(「居ない」に丸めない)"
else
    ng "F 形の変化を「機が居ない」に丸めた(rc=$RC)"
fi

# ── G: JSON として壊れている -> 3 ─────────────────────────────────────────
run 'not json at all {'
if [ "$RC" -eq 3 ] && printf '%s' "$STDERR" | grep -q "読めない"; then
    ok "G 一覧が壊れている -> 3"
else
    ng "G 壊れた一覧を黙って通した(rc=$RC)"
fi

# ── H: xcrun 自体が落ちる -> 赤(1)。一覧が無い事を「機が居ない」と言わない ──
run "$REAL" FAKE_XCRUN_RC=7
if [ "$RC" -eq 1 ] && printf '%s' "$STDERR" | grep -q "一覧を出せない"; then
    ok "H xcrun が落ちた -> 赤(1)、devicectl 側の話だと名乗る"
else
    ng "H xcrun の失敗を電話の不在にすり替えた(rc=$RC)"
fi

# ── I: 入力そのものに**本物の個体**が残っていない事 ────────────────────────
#    此処だけは対象(build.sh)ではなく**入力**を測る。理由: この fixture は本物の
#    devicectl 出力から作った物で、作り直す人は必ず実機の前に居る。差し替え漏れが
#    そのまま commit へ乗る。2026-08-09 に実際に漏れた形 —— 欄の名前を挙げて潰したら、
#    `potentialHostnames`(文字列の配列)に識別子が3通りの形で残っていた。
#    型で見張る: 近年の iPhone の udid は `8桁hex-16桁hex`、機体固有の連番は
#    `devices://device/open?id=` の後ろに出る。偽の値以外が居たら赤。
BAD=0
if /usr/bin/grep -qE '[0-9A-F]{8}-[0-9A-F]{16}' "$FIX"; then
    echo "        本物の udid の型(8桁hex-16桁hex)が残っている"; BAD=1
fi
for u in $(/usr/bin/grep -oE 'devices://device/open\?id=[0-9A-Za-z-]+' "$FIX" | /usr/bin/sed 's/.*id=//'); do
    [ "$u" = "$FAKE_ID" ] || { echo "        画面 URL に偽物でない識別子が残っている"; BAD=1; }
done
if [ "$BAD" -eq 0 ]; then
    ok "I 入力に本物の個体が残っていない(型で見張る)"
else
    OUT=""; ng "I 入力に本物の個体が残っている -- 作り直した時の差し替え漏れ"
fi

echo "合計 OK=$PASS NG=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
