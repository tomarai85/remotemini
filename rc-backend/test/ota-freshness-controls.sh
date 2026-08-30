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
    out="$(RC_OTA_SSH="$FAKE" RC_SIGNED_PLIST="$SB/Info.plist" bash "$SUT" 2>&1)"; rc=$?
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
run 2 "C7 手元の署名済み plist が無ければ 2"

# ★file は在るが key が無い場合。PlistBuddy は "File ... Will Create" ではなく
#   "Does Not Exist" を返す。どちらも数字ではないので 2 に落ちる事を測る。
cat > "$SB/Info.plist" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>Other</key><string>x</string></dict></plist>
XML
run 2 "C8 手元に版番号の欄が無ければ 2(エラー文を版番号にしない)"

echo ""
echo "OTA-FRESHNESS-CONTROLS: pass=$pass fail=$fail"
exit $(( fail > 0 ))
