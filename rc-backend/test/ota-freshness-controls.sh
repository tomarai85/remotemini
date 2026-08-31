#!/bin/bash
# controls-for: tools/ota-freshness-check.sh
#
# ota-freshness-check.sh の**挙動**対照。本物の friday は叩かない ——
# 叩くと結果が本番の今の状態に依存し、「壊れているから赤い」と
# 「本番がたまたま古いから赤い」を読者が区別できなくなる。
# `RC_OTA_SSH` に偽 ssh を、`RC_SIGNED_PLIST` に砂場の plist を差す。
#
# ★守る一線は「読めなかったを古くないに丸めない」事。
#   配布口の鮮度は Tom の**唯一の復旧経路**が巻き戻るか否かを決めるので、
#   測れなかった時に緑を出す検査は、無い方がまし。
#
#   C1 配布 > 署名済み → 緑
#   C2 配布 = 署名済み → 緑(等しいのは古くない)
#   C3 配布 < 署名済み → 赤(1)。差のビルド数を文面に出す
#   C4 ssh 失敗        → 2
#   C5 向こうが空      → 2
#   C6 向こうが数字でない(PlistBuddy のエラー文が来る)→ 2
#   C7 手元の plist が無い → 2
#   C8 手元が数字でない → 2 ★PlistBuddy は file 不在時に stdout へ出して exit 0 する
#   C9 配布 < **承認済み** → 赤(署名済みと同数でも通さない)
#   C10 承認の記録が無い → 署名済みで代用し、その事を言う
#   C11 承認が HEAD より古い → **3**(緑でも巻き戻りでもない第三の状態)
#
# 使い方: bash rc-backend/test/ota-freshness-controls.sh
# 終了コード: 0=全部緑 / 1=1本でも赤
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # = rc-backend/
SUT="$HERE/tools/ota-freshness-check.sh"
[ -f "$SUT" ] || { echo "測る対象が無い: $SUT"; exit 1; }

pass=0; fail=0
ok() { echo "PASS  $1"; pass=$((pass + 1)); }
ng() { echo "FAIL  $1  ($2)"; fail=$((fail + 1)); }

SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT

# 手元の署名済み plist を砂場に作る(版番号だけ差し替えて使う)
mk_local() {
    cat > "$SB/Info.plist" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleVersion</key><string>$1</string>
</dict></plist>
XML
}

FAKE="$SB/fake-ssh.sh"
cat > "$FAKE" <<'EOF'
#!/bin/bash
[ "${FAKE_RC:-0}" -ne 0 ] && exit "$FAKE_RC"
printf '%s' "${FAKE_OUT:-}"
exit 0
EOF
chmod +x "$FAKE"

run() {  # run <期待 rc> <名前>
    local want="$1" name="$2" out rc
    # ★承認の記録も**砂場に固定する**(2026-08-30 に踏んだ)。固定しないと
    #   本物の repo の `.ota-approved-build` を読みに行き、私が版を上げた日から
    #   C1/C2/C3b が赤くなる —— 検査が本番の状態に依存すると、
    #   「壊れているから赤い」と「今日たまたま版が上がったから赤い」が区別できない。
    out="$(RC_OTA_SSH="$FAKE" RC_SIGNED_PLIST="$SB/Info.plist" \
           RC_OTA_APPROVED_FILE="$SB/approved-default" bash "$SUT" 2>&1)"; rc=$?
    LAST_OUT="$out"
    if [ "$rc" = "$want" ]; then ok "$name (rc=$rc)"
    else ng "$name" "期待 rc=$want 実測 rc=$rc / $(printf '%s' "$out" | tail -1)"; fi
}

mk_local 96
export FAKE_RC=0 FAKE_OUT="99"
run 0 "C1 配布 99 > 署名済み 96 は緑"

export FAKE_OUT="96"
run 0 "C2 配布 = 署名済み も緑(等しいのは古くない)"

export FAKE_OUT="89"
run 1 "C3 配布 89 < 署名済み 96 は赤"
if printf '%s' "$LAST_OUT" | grep -q "7 ビルド巻き戻る"; then
    ok "C3b 何ビルド巻き戻るかを数で言う(『古い』だけでは動けない)"
else ng "C3b 差を数で言う" "$LAST_OUT"; fi

export FAKE_RC=255
run 2 "C4 ssh が失敗したら 2(古くないと言わない)"

export FAKE_RC=0 FAKE_OUT=""
run 2 "C5 向こうが空でも 2"

# ★PlistBuddy は key が無い時にエラー文を stdout へ出す。それを版番号として
#   読むと、数字でない物同士の比較で予期しない結果になる。数字だけ通す。
export FAKE_OUT="Print: Entry, \":items:0:metadata:bundle-version\", Does Not Exist"
run 2 "C6 向こうの出力が数字でなければ 2(エラー文を版番号にしない)"

export FAKE_OUT="99"
/bin/rm -f "$SB/Info.plist"
# ★C7 は「承認の記録が**無い**時」の話。其の時だけ署名済み plist が比較の相手になる
#   ので、読めなければ測定不成立。`run` は承認 file を `$SB/approved-default`
#   (作っていない = 不在)に固定しているので、此の前提は満たされている。
run 2 "C7 承認の記録も署名済み plist も無ければ 2"

# ── C7b ★承認の記録が在るなら、署名済み plist が無くても答えられる(2026-08-31)──
# 之を測る理由: 元の実装は plist の不在で**先に** 2 へ落ちており、承認が在っても
# 黙っていた。判定に使わない入力を必須にしていた形 —— `ios/build/` を掃除しただけで
# 巻き戻りの検査が黙る。「読めなかったを緑に丸めない」は守ったまま、
# 「読む必要が無い物で黙らない」を足す。
export FAKE_OUT="105"
printf '105\n' > "$SB/approved-c7b"
out="$(RC_OTA_SSH="$FAKE" RC_SIGNED_PLIST="$SB/does-not-exist.plist" \
       RC_OTA_APPROVED_FILE="$SB/approved-c7b" \
       RC_OTA_SECRET=deadbeefdeadbeefdeadbeef bash "$SUT" 2>&1)"; rc=$?
# HEAD が 105 より先なら 3、そうでなければ 0。どちらも「答えた」= 2 でない事が要点。
if [ "$rc" -ne 2 ] && ! printf '%s' "$out" | grep -q "測定不成立"; then
    ok "C7b ★承認の記録が在れば、署名済み plist が無くても黙らない (rc=$rc)"
else ng "C7b 承認が在る時の plist 不在" "rc=$rc / $(printf '%s' "$out" | tail -1)"; fi

# ── C7c ★逆向きの対照。C7b が「plist を見なくなった」だけの緩和でない事を測る ──
# 承認の記録が在る時、**配布 < 承認**は plist が無くても赤(1)でなければならない。
export FAKE_OUT="100"
out="$(RC_OTA_SSH="$FAKE" RC_SIGNED_PLIST="$SB/does-not-exist.plist" \
       RC_OTA_APPROVED_FILE="$SB/approved-c7b" \
       RC_OTA_SECRET=deadbeefdeadbeefdeadbeef bash "$SUT" 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "巻き戻る"; then
    ok "C7c ★plist が無くても、配布が承認より古ければ赤(緩和ではない)"
else ng "C7c plist 不在での巻き戻り検出" "rc=$rc(1 が期待) / $(printf '%s' "$out" | tail -1)"; fi
export FAKE_OUT="99"

# ★file は在るが key が無い場合。PlistBuddy は "File ... Will Create" ではなく
#   "Does Not Exist" を返す。どちらも数字ではないので 2 に落ちる事を測る。
cat > "$SB/Info.plist" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>Other</key><string>x</string></dict></plist>
XML
run 2 "C8 手元に版番号の欄が無ければ 2(エラー文を版番号にしない)"

# ── C9-C11 承認済みの版(2026-08-30、Codex の指摘4)──────────────────────
# ★以前は「配布 vs 最後に署名した物」しか見ていなかったので、**両方が同じ番号なら
#   HEAD がどれだけ先でも緑**だった —— 「古くない」と言いながら、出来ている物が
#   届いていない状態を通す。比べる相手を「配布してよいと決めた版」に変えた。
mk_local 96

export FAKE_RC=0 FAKE_OUT="96"
printf '99\n' > "$SB/approved"
out="$(RC_OTA_SSH="$FAKE" RC_SIGNED_PLIST="$SB/Info.plist" RC_OTA_APPROVED_FILE="$SB/approved" \
       RC_OTA_SECRET=deadbeefdeadbeefdeadbeef bash "$SUT" 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "承認済み 99"; then
    ok "C9 配布が**承認済み**より古ければ赤(署名済みと同数でも通さない)"
else ng "C9 承認済みとの比較" "rc=$rc / $(printf '%s' "$out" | tail -1)"; fi

# ★承認の記録がまだ無い時は署名済みで代用する(初回の配布より前 = 承認が起きていない)。
/bin/rm -f "$SB/approved"
out="$(RC_OTA_SSH="$FAKE" RC_SIGNED_PLIST="$SB/Info.plist" RC_OTA_APPROVED_FILE="$SB/approved" \
       RC_OTA_SECRET=deadbeefdeadbeefdeadbeef bash "$SUT" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "承認の記録がまだ無い"; then
    ok "C10 承認の記録が無い時は署名済みで代用し、その事を言う"
else ng "C10 記録が無い時" "rc=$rc / $(printf '%s' "$out" | tail -1)"; fi

# ★**承認そのものが HEAD より古い**時は 0 でも 1 でもなく 3。
#   0 に混ぜると「届いている」と読まれ、1 に混ぜると巻き戻りと区別が付かない。
#   HEAD の番号は本物の repo から引くので、承認を **1 つ小さく**置けば必ず成立する。
head_num="$(bash "$HERE/../ios/tools/build.sh" --print-build-num 2>/dev/null | tr -d '[:space:]')"
case "$head_num" in
    ''|*[!0-9]*) echo "SKIP  C11(HEAD の番号を引けない = 測定不成立)" ;;
    *)
        printf '%s\n' "$((head_num - 1))" > "$SB/approved"
        mk_local "$((head_num - 1))"
        export FAKE_OUT="$((head_num - 1))"
        out="$(RC_OTA_SSH="$FAKE" RC_SIGNED_PLIST="$SB/Info.plist" RC_OTA_APPROVED_FILE="$SB/approved" \
               RC_OTA_SECRET=deadbeefdeadbeefdeadbeef bash "$SUT" 2>&1)"; rc=$?
        if [ "$rc" -eq 3 ] && printf '%s' "$out" | grep -q "HEAD"; then
            ok "C11 承認が HEAD より古ければ 3(緑でも巻き戻りでもない第三の状態)"
        else ng "C11 承認が HEAD より古い時" "rc=$rc(3 が期待) / $(printf '%s' "$out" | tail -1)"; fi
        ;;
esac

echo ""
echo "OTA-FRESHNESS-CONTROLS: pass=$pass fail=$fail"
exit $(( fail > 0 ))
