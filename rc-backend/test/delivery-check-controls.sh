#!/bin/bash
# controls-for: tools/delivery-check.sh
#
# 「作ったのに配っていない物」を探す道具の**判定**の対照。
#
# ── なぜ今まで無かったか、なぜ書けた様になったか(2026-08-31)──────────────
# `delivery-check.sh` は生きた机への ssh・curl・launchctl が要る。だから門から回せず、
# **判定の分岐が一度も対照に掛かっていなかった** —— そして実際に壊れていた。
# 同じ日に、其の中の「時代判定」が **20 分で2回** 壊れている:
#   1回目 判定そのものを書き忘れ(「配ってある file は直っているか」と
#         「process は其れより新しいか」は書いたのに、**既に書かれている行**を見ていない)
#   2回目 `date -j` に `-u` が無く UTC の刻を CDT で読む(5 時間ずれ、刻が未来になり
#         門が構造的に一度も閉じない)
# 今日、外へ出る道具に継ぎ目を足した(`RC_DELIVERY_SSH` / `_CURL` / `_LAUNCHCTL` /
# `_PLISTBUDDY`)ので、**机が無くても「どの入力でどの判定に落ちるか」を測れる**。
#
# ★測る中心は「緑が出るか」ではない —— 偽物を差した机は当然 赤だらけになる。
#   測るのは **入力を変えると判定が変わるか**、そして
#   **測れない時に『大丈夫』と言わないか**。
#
#   D1 机が黙っていても台本は最後まで走り、非ゼロで帰る(途中で落ちない)
#   D2 ★app の要求が今の走行より前の行なら、版の話をせず「判らない」と言う
#   D3 ★机の reqlog がまだ UA から版を採る形なら、版の話をしない
#   D4 ★両方 揃っていて、電話が配布中より古ければ**其の差**を数で言う
#   D5 ★両方 揃っていて、電話が追いついていれば緑
#   D6 手元で焼いた物を「電話」と呼ばない(2026-08-31 に直した嘘)
#   D7 机が黙った時に「電話は最新」と言わない(fail-closed)
#
# 使い方: bash rc-backend/test/delivery-check-controls.sh
# 終了コード: 0=全部緑 / 1=1本でも赤
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # = rc-backend/
SUT="$HERE/tools/delivery-check.sh"
[ -f "$SUT" ] || { echo "測る対象が無い: $SUT"; exit 1; }

pass=0; fail=0
ok() { echo "PASS  $1"; pass=$((pass + 1)); }
ng() { echo "FAIL  $1  ($2)"; fail=$((fail + 1)); }

SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT
BIN="$SB/bin"; mkdir -p "$BIN"

# ── 偽物 ──────────────────────────────────────────────────────────────────
# ★`launchctl` と `PlistBuddy` は**黙って失敗する**物を差す。此の対照が測るのは
#   1/1b の版の判定だけで、常設や署名の有無は関係ない(其処が赤いのは想定どおり)。
printf '#!/bin/bash\nexit 1\n' > "$BIN/false-tool"; chmod +x "$BIN/false-tool"

# 偽 curl: healthz の本文を返す。`-w '%{http_code}'` 付き(第6段)の時は番号だけ。
cat > "$BIN/curl" <<'EOF'
#!/bin/bash
for a in "$@"; do case "$a" in '%{http_code}') echo -n "000"; exit 0 ;; esac; done
printf '%s' "${FAKE_HEALTH:-{\"ok\":true,\"pid\":1,\"uptime\":${FAKE_UPTIME:-100},\"version\":\"${FAKE_VERSION:-deadbee}\"}}"
EOF
chmod +x "$BIN/curl"

# 偽 ssh: 引数の**中身**で枝を分ける。実物と同じ順で呼ばれる事が前提。
cat > "$BIN/ssh" <<'EOF'
#!/bin/bash
cmd="${*: -1}"
case "$cmd" in
    *"grep 'client=app'"*) printf '%s' "${FAKE_APPLINE:-}" ;;
    *"grep -c 'const build = headerBuild('"*) printf '%s' "${FAKE_HASFIX:-1}" ;;
    *"stat -f %m"*) printf '%s' "${FAKE_FIXMTIME:-1}" ;;
    *"bundle-version"*) printf '%s' "${FAKE_PUB:-115}" ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$BIN/ssh"

run_sut() {  # run_sut → 1b の段だけを取り出して返す
    RC_DELIVERY_SSH="$BIN/ssh" RC_DELIVERY_CURL="$BIN/curl" \
    RC_DELIVERY_LAUNCHCTL="$BIN/false-tool" RC_DELIVERY_PLISTBUDDY="$BIN/false-tool" \
    RC_FRIDAY_HOST=fake-desk.invalid \
        bash "$SUT" 2>&1
}

# 刻を作る(全部 UTC。手元の時間帯で書くと、判定が取り違えていても通ってしまう)。
NOW_EPOCH="$(date +%s)"
ISO_BEFORE="$(date -u -r "$((NOW_EPOCH - 7200))" '+%Y-%m-%dT%H:%M:%S.000Z')"
ISO_AFTER="$(date -u -r "$((NOW_EPOCH - 60))" '+%Y-%m-%dT%H:%M:%S.000Z')"
line_for() {  # line_for <刻> <build>
    printf '[rc-backend] req %s GET /api/sessions route=- client=app build=%s code=200 reason=- ms=9' "$1" "$2"
}

# ── D1 机が黙っていても最後まで走る ────────────────────────────────────────
out="$(FAKE_APPLINE='' run_sut)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "合計:"; then
    ok "D1 机が黙っていても最後まで走り、非ゼロで帰る"
else ng "D1 完走" "rc=$rc / 末尾=$(printf '%s' "$out" | tail -1)"; fi

# ── D7 机が黙った時に「電話は最新」と言わない ──────────────────────────────
if ! printf '%s' "$out" | grep -q "追いついている"; then
    ok "D7 ★app の行が無い時に『電話が追いついている』と言わない"
else ng "D7 fail-closed" "行が1本も無いのに追いついていると言った"; fi

# ── D3 机の reqlog がまだ UA から版を採る形 ────────────────────────────────
out="$(FAKE_HASFIX=0 FAKE_APPLINE="$(line_for "$ISO_AFTER" 114)" run_sut)"
if printf '%s' "$out" | grep -q "UA から版を採る形"; then
    ok "D3 ★机が古い実装なら、版の話をしない"
else ng "D3 古い机" "$(printf '%s' "$out" | sed -n '5,7p')"; fi

# ── D2 行が今の走行より前 ────────────────────────────────────────────────
# `uptime=100` なので起動は 100 秒前。2 時間前の行は其れより古い。
out="$(FAKE_UPTIME=100 FAKE_APPLINE="$(line_for "$ISO_BEFORE" 114)" run_sut)"
if printf '%s' "$out" | grep -q "今の机が起きる前の行"; then
    ok "D2 ★古い行は版の欄の意味が違うと言う(存在しない差を作らない)"
else ng "D2 時代判定" "$(printf '%s' "$out" | sed -n '5,7p')"; fi
# ★同時に、其の時 差の数を**言っていない**事(之が無いと D2 は文面だけの検査)
if ! printf '%s' "$out" | grep -q "ビルド進む"; then
    ok "D2b ★古い行の時に差の数を言わない"
else ng "D2b" "古い行から差を計算した = 存在しない差"; fi

# ── D4 揃っていて電話が古い ──────────────────────────────────────────────
out="$(FAKE_UPTIME=100000 FAKE_PUB=115 FAKE_APPLINE="$(line_for "$ISO_AFTER" 110)" run_sut)"
if printf '%s' "$out" | grep -q "110 < 115" && printf '%s' "$out" | grep -q "5 ビルド進む"; then
    ok "D4 ★揃っていれば差を数で言う(110 → 115 は 5)"
else ng "D4 差の計算" "$(printf '%s' "$out" | sed -n '5,7p')"; fi

# ── D5 揃っていて電話が追いついている ─────────────────────────────────────
out="$(FAKE_UPTIME=100000 FAKE_PUB=115 FAKE_APPLINE="$(line_for "$ISO_AFTER" 115)" run_sut)"
if printf '%s' "$out" | grep -q "電話が配布中の版に追いついている"; then
    ok "D5 ★追いついていれば緑と言う(常に赤を出す実装ではない)"
else ng "D5 追いつき" "$(printf '%s' "$out" | sed -n '5,7p')"; fi

# ── D6 手元で焼いた物を「電話」と呼ばない ─────────────────────────────────
# 2026-08-31 に直した嘘。`ios/build/signed/…` は build.sh が書く「最後に焼いた物」で、
# 電話について何も語らない。文面が戻ったら赤。
if grep -q '直近に焼いた物=' "$SUT" && ! grep -qE "printf '  手元=%s 本番=%s 電話=%s" "$SUT"; then
    ok "D6 ★手元の成果物を『電話』と印字しない"
else ng "D6 呼び名" "手元で焼いた物をまた『電話』と呼んでいる"; fi

# ── D8/D9/D10 ★commit の差と**コードの差**を分ける(2026-08-31)──────────────
# 旧版は commit の刻だけを比べたので、docs・検査・iOS だけの commit を1つ入れた瞬間に
# 「本番が手元と違う」で赤くなった —— 配備は要らないのに。**常に赤い検査は読まれない**。
# ★文面の有無ではなく**実際に其の枝へ落ちる**事を測る(偽 healthz の版を差し替える)。

# D8: `rc-backend/src` を触っていない祖先の刻を机が名乗る → 緑(遅れではない)。
#     木の中から**実際に其の性質を持つ commit** を探す。無ければ測定不成立と言う。
anc=""
for c in $(git -C "$HERE/.." log --format=%h -30 2>/dev/null); do
    [ "$c" = "$(git -C "$HERE/.." rev-parse --short HEAD)" ] && continue
    if [ "$(git -C "$HERE/.." diff --name-only "$c"..HEAD -- rc-backend/src rc-backend/package.json 2>/dev/null | wc -l | tr -d ' ')" = "0" ]; then
        anc="$c"; break
    fi
done
if [ -n "$anc" ]; then
    out="$(FAKE_VERSION="$anc" run_sut)"
    if printf '%s' "$out" | grep -q "机が走らせる file は手元と同一"; then
        ok "D8 ★src を触っていない commit の差は緑(常に赤い検査にしない)"
    else ng "D8 src 同一" "$(printf '%s' "$out" | sed -n '2,4p')"; fi
else
    echo "SKIP  D8(src を触っていない祖先が直近 30 commit に無い = 測定不成立)"
fi

# D9: `rc-backend/src` を触った祖先 → 赤(配備が要る)。
anc2=""
for c in $(git -C "$HERE/.." log --format=%h -60 2>/dev/null); do
    if [ "$(git -C "$HERE/.." diff --name-only "$c"..HEAD -- rc-backend/src 2>/dev/null | wc -l | tr -d ' ')" != "0" ]; then
        anc2="$c"; break
    fi
done
if [ -n "$anc2" ]; then
    out="$(FAKE_VERSION="$anc2" run_sut)"
    if printf '%s' "$out" | grep -q "本番が古いコードを走らせている"; then
        ok "D9 ★src に差が在る commit なら赤(緩めたのではなく的を絞った)"
    else ng "D9 src 差あり" "$(printf '%s' "$out" | sed -n '2,4p')"; fi
else
    echo "SKIP  D9(src を触った祖先が直近 60 commit に無い = 測定不成立)"
fi

# D10: この木に無い刻 → 「判らない」。緑にも「古い」にも丸めない。
out="$(FAKE_VERSION=deadbee run_sut)"
if printf '%s' "$out" | grep -q "突き合わせられない"; then
    ok "D10 ★机の刻がこの木に無ければ『判らない』と言う(緑に丸めない)"
else ng "D10 fail-closed" "$(printf '%s' "$out" | sed -n '2,4p')"; fi

echo ""
echo "DELIVERY-CHECK-CONTROLS: pass=$pass fail=$fail"
exit $(( fail > 0 ))
