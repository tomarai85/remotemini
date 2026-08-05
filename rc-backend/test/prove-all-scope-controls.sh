#!/bin/bash
# controls-for: tools/prove-all-controls.sh
# `tools/prove-all-controls.sh` が **どの dir を見るか** の対照。
#
# 経緯 (2026-08-05): prove-all の頭には「一覧を手で持たない」と書いてあり、実際
# *継ぎ目* は毎回探していた。しかし **どの dir を探すか** は `test/*-controls.sh` の
# 直書きで、`.harness/` と `ios/tools/` に居る対照は一度もこの道具の視野に入らなかった
# (実測: 門が見ている 46 本のうち prove-all が見ていたのは 41 本)。
# 範囲の正本は `tools/staged-controls-gate.sh` の `SCAN_SPECS` = commit の門が見る範囲。
#
# ★対照は2方向要る。①縮める方向(正本から dir を削ると、その dir の対照が視野から消える)
#   ②**伸ばす方向**(正本に dir を足すと、此処を1文字も直さずに追随する)。
#   ②が本命 —— ①だけだと「生きた導出」と「たまたま今の値と等しい定数」を区別できない。
#
# 終了コード: 0 = 全部期待どおり / 1 = どれかが違う / 2 = 測れなかった
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"          # = rc-backend
REPO="$(cd "$ROOT/.." && pwd)"

# 差し替えの口。live の道具を壊さずに証明する為に在る(この repo の他の対照と同じ作法)。
PROVE_ALL="${RC_PROVE_ALL:-$ROOT/tools/prove-all-controls.sh}"
REAL_GATE="${RC_STAGED_GATE:-$ROOT/tools/staged-controls-gate.sh}"

pass=0; fail=0
ok() { pass=$((pass+1)); echo "PASS  $1"; }
ng() { fail=$((fail+1)); echo "FAIL  $1  ($2)"; }

[ -f "$PROVE_ALL" ] || { echo "測れない: 道具が居ない ($PROVE_ALL)"; exit 2; }
[ -f "$REAL_GATE" ] || { echo "測れない: 門が居ない ($REAL_GATE)"; exit 2; }

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/prove-all-scope.XXXXXX")" || { echo "測れない: mktemp 失敗"; exit 2; }
# repo の中に置く仮の dir。**門の SCAN_SPECS は repo 相対でしか書けない**ので、
# 伸ばす方向を測るには repo の中に的が要る。trap で必ず消す。
PLANT_REL="rc-backend/.prove-scope-plant"
PLANT_ABS="$REPO/$PLANT_REL"
cleanup() {
    [ -n "${PLANT_ABS:-}" ] && [ -d "$PLANT_ABS" ] && {
        /usr/bin/find "$PLANT_ABS" -type f -delete 2>/dev/null
        /bin/rmdir "$PLANT_ABS" 2>/dev/null
    }
    [ -n "${SCRATCH:-}" ] && [ -d "$SCRATCH" ] && {
        /usr/bin/find "$SCRATCH" -type f -delete 2>/dev/null
        /usr/bin/find "$SCRATCH" -depth -type d -exec /bin/rmdir {} \; 2>/dev/null
    }
    return 0
}
trap cleanup EXIT

# 偽の門を1枚書く。`SCAN_SPECS=(` 〜 `)` の形だけが読まれる。
write_gate() {   # $1=出力path  $2..=SCAN_SPECS の中身(行ごと)
    local out="$1"; shift
    { echo '#!/bin/bash'
      echo 'SCAN_SPECS=('
      local line
      for line in "$@"; do echo "    \"$line\""; done
      echo ')'
    } > "$out"
}

run_dry() {      # $1=GATE_FOR_SPECS  → 標準出力+標準エラーを返す。rc は捨てる(--dry は常に 2)
    GATE_FOR_SPECS="$1" bash "$PROVE_ALL" --dry 2>&1
}

# ── ① 本物の門で走らせた時、`test/` の外に居る対照が視野に入っている ─────────
OUT_REAL="$(run_dry "$REAL_GATE")"
if printf '%s' "$OUT_REAL" | /usr/bin/grep -q 'dod-sprint-3-controls.sh'; then
    ok "本物の門: .harness/ の対照が視野に入る"
else
    ng "本物の門: .harness/ の対照が視野に入る" "出力に dod-sprint-3-controls.sh が出ない"
fi
if printf '%s' "$OUT_REAL" | /usr/bin/grep -q 'sim-log-summary-control.sh'; then
    ok "本物の門: ios/tools/ の対照が視野に入る"
else
    ng "本物の門: ios/tools/ の対照が視野に入る" "出力に sim-log-summary-control.sh が出ない"
fi

# ── ②-a 縮める方向: 門から dir を削ると、その dir の対照が視野から消える ──────
# ★門を `ios/tools` **だけ**にする。`test` を残して縮めると、変更前の版(= 範囲が
#   `test/` 固定)でも同じ結果になり、**何も見分けない対照**になる。実際に一度そう
#   書いて、変更前の版に対して緑を返した。消える側と残る側を両方入れ替える事。
SHRUNK="$SCRATCH/gate-shrunk.sh"
write_gate "$SHRUNK" "ios/tools|"
OUT_SHRUNK="$(run_dry "$SHRUNK")"
if printf '%s' "$OUT_SHRUNK" | /usr/bin/grep -q 'prove-control-controls.sh'; then
    ng "縮める方向: 門から test を削ると消える" "削ったのに まだ出る = 範囲が門を見ていない"
else
    ok "縮める方向: 門から test を削ると消える"
fi
# 縮めても `ios/tools` の物は残る = 「全部消えた」で緑になっていない事の確認。
# (--dry の PASSED 行は basename なので、path ではなく既知の basename で見る)
if printf '%s' "$OUT_SHRUNK" | /usr/bin/grep -q 'sim-log-summary-control.sh'; then
    ok "縮める方向: ios/tools の対照は残っている(空振りで緑になっていない)"
else
    ng "縮める方向: ios/tools の対照は残っている" "何も出ない = 抽出そのものが壊れた可能性"
fi

# ── ②-b ★伸ばす方向: 門に dir を足すと、此処を1文字も直さずに追随する ────────
if ! /bin/mkdir -p "$PLANT_ABS" 2>/dev/null; then
    echo "測れない: 仮 dir を作れない ($PLANT_ABS)"; exit 2
fi
cat > "$PLANT_ABS/zz-fresh-control.sh" <<'PLANTEOF'
#!/bin/bash
# 対照の対照が植えた仮の対照。実行はされない(--dry)。
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="${RC_ZZ_FRESH_TOOL:-$HERE/zz-fresh.sh}"
echo "$TOOL"
PLANTEOF
[ -f "$PLANT_ABS/zz-fresh-control.sh" ] || { echo "測れない: 仮の対照を書けなかった"; exit 2; }

GROWN="$SCRATCH/gate-grown.sh"
write_gate "$GROWN" "rc-backend/test|rc-backend" "ios/tools|" ".harness|" "$PLANT_REL|"
OUT_GROWN="$(run_dry "$GROWN")"
if printf '%s' "$OUT_GROWN" | /usr/bin/grep -q 'zz-fresh-control.sh'; then
    ok "★伸ばす方向: 門に足した dir の対照へ、此処を直さずに追随する"
else
    ng "★伸ばす方向: 門に足した dir の対照へ追随する" \
       "足したのに出ない = 範囲が定数(今の値とたまたま等しいだけ)"
fi

# ── ③ 門が読めない時、緑にならず「測っていない」で止まる ─────────────────────
EMPTY="$SCRATCH/gate-empty.sh"
echo '#!/bin/bash' > "$EMPTY"        # SCAN_SPECS を持たない = 取り出せない
OUT_EMPTY="$(GATE_FOR_SPECS="$EMPTY" bash "$PROVE_ALL" --dry 2>&1)"; RC_EMPTY=$?
# ★rc だけを見ない。`--dry` は元から常に 2 を返すので、rc の一致は**何も見分けない**
#   (実測: 変更前の版もこの rc を満たす)。理由を名指しした出力まで見て初めて判定になる。
if [ "$RC_EMPTY" -eq 2 ] && printf '%s' "$OUT_EMPTY" | /usr/bin/grep -q '探す範囲が空'; then
    ok "門が読めない: 理由を名指しして未測定で止まる"
else
    ng "門が読めない: 理由を名指しして未測定で止まる" "rc=$RC_EMPTY / 出力に理由が無い"
fi
if printf '%s' "$OUT_EMPTY" | /usr/bin/grep -q '測る対象'; then
    ng "門が読めない: 測定の顔をした出力を出さない" "「測る対象 N 本」を出している"
else
    ok "門が読めない: 測定の顔をした出力を出さない"
fi

# ── ④ 対照自身の dir を基点に取る形の継ぎ目が読める ──────────────────────
# sim-log-summary-control.sh の RC_SIMSUMMARY_TOOL は、$ROOT ではなく**その対照が
# 置かれた dir**を基点に既定値を書いている。視野に入れただけで「既定値の形が読め
# ない」に落ちるなら、範囲を広げた意味が半分無い。
# (此処に継ぎ目の綴りをそのまま書くと、この file 自身が prove-all の走査に
#  引っ掛かって出力を汚すので、綴りは書かない)
# ★「読めない一覧に出ていない」で緑にしない —— 視野に入っていない時も出ないので、
#   不在を合格と読む対照になる(変更前の版に対して実際に緑を返した)。
#   解決先まで名指しされた行が**在る**事を要求する。
if printf '%s' "$OUT_REAL" \
   | /usr/bin/grep 'sim-log-summary-control.sh' \
   | /usr/bin/grep -q 'sim-log-summary\.sh'; then
    ok "対照の dir を基点にした継ぎ目が、解決先まで読めている"
else
    ng "対照の dir を基点にした継ぎ目が、解決先まで読めている" \
       "解決先を名指しした行が無い(視野の外か、形が読めていないか)"
fi

echo ""
echo "--- 合計: PASS $pass / FAIL $fail ---"
[ "$fail" -gt 0 ] && exit 1
exit 0
