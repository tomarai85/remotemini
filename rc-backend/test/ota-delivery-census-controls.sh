#!/bin/bash
# controls-for: tools/ota-delivery-census.sh
#
# 配布口の受け渡しを数える台帳の**挙動**対照。
#
# ★測る中心は「数えられるか」ではない。1本の作り物で通る。
#   測るのは **上限に食われても数が残るか** と **数える対象を取り違えないか**。
#
#   C1  結末を三分する(渡し切り / 中断 / 断り)
#   C2  manifest や install ページを数に混ぜない
#   C3  ★切られた後も**足す**(max だと切断を跨いだ鍵の件数が消える)
#   C4  同じ世代で伸びた分は二重に数えない
#   C5  元 log が無ければ 2(0 本と読ませない)
#   C6  読めない行は飛ばして落ちない
#   C7  将来 `/:ipa.sha256` の様な path が出来ても混ざらない
#   C8  ★置き場が**掃く dir の外**(掃かれる場所に置けば数える前に消える)
#
# 使い方: bash rc-backend/test/ota-delivery-census-controls.sh
# 終了コード: 0=全部緑 / 1=1本でも赤
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # = rc-backend/
SUT="$HERE/tools/ota-delivery-census.sh"
[ -f "$SUT" ] || { echo "測る対象が無い: $SUT"; exit 1; }

pass=0; fail=0
ok() { echo "PASS  $1"; pass=$((pass + 1)); }
ng() { echo "FAIL  $1  ($2)"; fail=$((fail + 1)); }
SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT

line() {  # line <時刻> <path> <client> <code>
    printf '[ota] req %s GET %s client=%s peer=xff code=%s bytes=100\n' "$1" "$2" "$3" "$4"
}
run() { RC_OTA_CENSUS_LOG="$1" RC_OTA_CENSUS_OUT="$2" bash "$SUT" >/dev/null 2>&1; }
cell() { awk -F'\t' -v d="$2" -v h="$3" -v c="$4" -v o="$5" \
         '$1==d && $2==h && $3==c && $4==o {print $5}' "$1"; }

# ── C1 結末の三分 ─────────────────────────────────────────────────────────
L="$SB/c1.log"; O="$SB/c1.tsv"
{ line 2026-08-30T18:00:00.000Z /:secret/:ipa app 200
  line 2026-08-30T18:10:00.000Z /:secret/:ipa app 0
  line 2026-08-30T18:20:00.000Z /:secret/:ipa app 429; } > "$L"
run "$L" "$O"
if [ "$(cell "$O" 2026-08-30 18 app done)" = "1" ] \
   && [ "$(cell "$O" 2026-08-30 18 app aborted)" = "1" ] \
   && [ "$(cell "$O" 2026-08-30 18 app refused)" = "1" ]; then
    ok "C1 渡し切り / 中断 / 断り を三分する"
else ng "C1 三分" "$(cat "$O" | tr '\n' ' ')"; fi

# ── C2 manifest を混ぜない ────────────────────────────────────────────────
L="$SB/c2.log"; O="$SB/c2.tsv"
{ line 2026-08-30T18:00:00.000Z /:secret/:ipa app 200
  line 2026-08-30T18:01:00.000Z /:secret/manifest.plist app 200
  line 2026-08-30T18:02:00.000Z /:secret/ app 200; } > "$L"
run "$L" "$O"
[ "$(awk -F'\t' '{s += $5} END {print s + 0}' "$O")" = "1" ] \
    && ok "C2 manifest や install ページを数に混ぜない(欄に path が無いので混ぜたら読めない)" \
    || ng "C2 混入" "$(cat "$O" | tr '\n' ' ')"

# ── C3 ★切られた後も足す ─────────────────────────────────────────────────
# 上限が log を切ると、切った後の走行では過去の件数が**減って**見える。
# max で畳むと `max(3,2)=3` になり後半の 2 件が消える。和なら 5。
L="$SB/c3.log"; O="$SB/c3.tsv"
for i in 1 2 3; do line "2026-08-30T18:0${i}:00.000Z" /:secret/:ipa app 200; done > "$L"
run "$L" "$O"
before="$(cell "$O" 2026-08-30 18 app done)"
# 上限が切った後の姿を作る(中身を入れ替え = inode も大きさも変わる)
/bin/rm -f "$L"
for i in 4 5; do line "2026-08-30T18:0${i}:00.000Z" /:secret/:ipa app 200; done > "$L"
run "$L" "$O"
after="$(cell "$O" 2026-08-30 18 app done)"
if [ "$before" = "3" ] && [ "$after" = "5" ]; then
    ok "C3 切られた後も足す(3 → 5。max なら 3 のまま = 2 件が消える)"
else ng "C3 世代を跨ぐ和" "切る前=$before 切った後=$after(5 が期待)"; fi

# ── C4 同じ世代で伸びた分を二重に数えない ─────────────────────────────────
L="$SB/c4.log"; O="$SB/c4.tsv"
for i in 1 2 3; do line "2026-08-30T18:0${i}:00.000Z" /:secret/:ipa app 200; done > "$L"
run "$L" "$O"
line 2026-08-30T18:04:00.000Z /:secret/:ipa app 200 >> "$L"   # 追記 = 同じ世代
run "$L" "$O"
[ "$(cell "$O" 2026-08-30 18 app done)" = "4" ] \
    && ok "C4 同じ世代で伸びた分は二重に数えない(4。和にすると 7 になる)" \
    || ng "C4 二重計上" "$(cell "$O" 2026-08-30 18 app done)(4 が期待)"

# ── C5 元 log が無い ──────────────────────────────────────────────────────
RC_OTA_CENSUS_LOG="$SB/absent.log" RC_OTA_CENSUS_OUT="$SB/c5.tsv" bash "$SUT" >/dev/null 2>&1
[ $? -eq 2 ] && ok "C5 元 log が無ければ 2(0 本と読ませない)" || ng "C5 log 不在" "rc=$?"

# ── C6 読めない行 ────────────────────────────────────────────────────────
L="$SB/c6.log"; O="$SB/c6.tsv"
{ printf 'garbage\n[ota] おかしな行\n'
  line 2026-08-30T18:00:00.000Z /:secret/:ipa app 200
  printf '[ota] req 壊れた時刻 GET /:secret/:ipa client=app code=200\n'; } > "$L"
run "$L" "$O"; rc=$?
[ "$rc" -eq 0 ] && [ "$(awk -F'\t' '{s += $5} END {print s + 0}' "$O")" = "1" ] \
    && ok "C6 読めない行は飛ばし、読める行だけ数える" \
    || ng "C6 壊れた行" "rc=$rc / $(cat "$O" | tr '\n' ' ')"

# ── C7 将来の path が混ざらない ──────────────────────────────────────────
L="$SB/c7.log"; O="$SB/c7.tsv"
{ line 2026-08-30T18:00:00.000Z /:secret/:ipa app 200
  line 2026-08-30T18:01:00.000Z /:secret/:ipa.sha256 app 200; } > "$L"
run "$L" "$O"
[ "$(awk -F'\t' '{s += $5} END {print s + 0}' "$O")" = "1" ] \
    && ok "C7 :ipa を欄の終わりとして当てる(:ipa.sha256 が出来ても混ざらない)" \
    || ng "C7 部分一致" "$(cat "$O" | tr '\n' ' ')"

# ── C8 ★置き場が掃く dir の外 ────────────────────────────────────────────
# 既定の置き場が `com.fleet.rc-log-cap` の掃く dir の中だと、数え終わる前に
# 元も台帳も一緒に消える —— 台帳を作る意味そのものが無くなる。
defout="$(grep -m1 'OUT="\${RC_OTA_CENSUS_OUT' "$SUT")"
case "$defout" in
    *'Library/Logs/rc-backend'*|*'.rc-backend/'*)
        ng "C8 置き場" "既定の置き場が掃く dir の中: $defout" ;;
    *rc-census*) ok "C8 既定の置き場は掃く dir の外(rc-census)" ;;
    *)           ng "C8 置き場" "掃く dir の外だと確かめられない: $defout" ;;
esac

# ── C9 副台帳が事象を分ける ★Codex: 「:ipa だけでは押されたか判らない」──────
# iOS は install ページ → manifest.plist → ipa の順に引く。**押した証拠は manifest 側**。
L="$SB/c9.log"; O="$SB/c9.tsv"; E="$SB/c9-events.tsv"
{ line 2026-08-30T18:00:00.000Z /:secret/ app 200
  line 2026-08-30T18:01:00.000Z /:secret/manifest.plist app 200
  line 2026-08-30T18:02:00.000Z /:secret/:ipa app 0; } > "$L"
run "$L" "$O"
g() { awk -F'\t' -v e="$1" -v o="$2" '$3=="app" && $4==e && $5==o {print $6}' "$E"; }
if [ "$(g page done)" = "1" ] && [ "$(g manifest done)" = "1" ] && [ "$(g ipa aborted)" = "1" ]; then
    ok "C9 副台帳が page / manifest / ipa を分ける(押した証拠は manifest 側に出る)"
else ng "C9 事象の分け" "$(cat "$E" | tr '\n' ' ')"; fi

# ── C10 ★「押したが入らなかった」と「一度も押していない」を分けられる ────────
# 此れが台帳の存在理由。分けられないなら、Tom に何をすべきか言えない。
L="$SB/c10.log"; O="$SB/c10.tsv"; E="$SB/c10-events.tsv"
{ line 2026-08-30T18:00:00.000Z /:secret/:ipa tool 200; } > "$L"     # 私の対照だけ
run "$L" "$O"
never="$(awk -F'\t' '$3=="app" {s += $6} END {print s + 0}' "$E")"
{ line 2026-08-30T19:00:00.000Z /:secret/manifest.plist app 200; } >> "$L"
run "$L" "$O"
came="$(awk -F'\t' '$3=="app" {s += $6} END {print s + 0}' "$E")"
if [ "$never" = "0" ] && [ "$came" = "1" ]; then
    ok "C10 『一度も押していない』(app 0 件)と『押した』(app が来た)を分けられる"
else ng "C10 押したか" "押す前=$never 押した後=$came"; fi

echo ""
echo "OTA-DELIVERY-CENSUS-CONTROLS: pass=$pass fail=$fail"
exit $(( fail > 0 ))
