#!/bin/bash
# `tools/prove-control.sh` を**回す物**。これが無いと prover 自身が
# 「誰も回さない対照」になる —— 手で思い出して回す限り、毎回はやらない。
#
# ── 一覧を手で持たない ────────────────────────────────────────────────────
# 対象(差替型の対照)を固定の配列で持つと、**新しい対照を書いた時に黙って漏れる**。
# 漏れた事は誰にも見えない。だから `test/*-controls.sh` を毎回読んで継ぎ目を**探す**。
# これは run-controls.sh の規則(1)「入力は本物の生成元から取る」を、この道具自身に
# 当てた物 —— 手書きの一覧は「対象はこれで全部だ」という思い込みごと緑になる。
#
# ── 読めなかった物を黙って落とさない ──────────────────────────────────────
# 継ぎ目を見つけたが既定値の形が読めない / repo の追跡下に無い場合、**名指しで出す**。
# 落とした事を出さないと「全部見た」と読まれる。それが一番危ない嘘。
#
# 終了コード: 0=全部効いている / 1=効いていない物がある / 2=測れていない物がある
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

# `--dry` = 何が測られ、何が落ちるかだけ出す。対照を1本も実行しないので走行中でも安全。
# (変異台本の `--dry` と同じ考え。「回す物が無い」の次に多い失敗は「回した結果、
#  対象が思っていた集合と違った」で、それは実行しなくても分かる)
DRY=0
[ "${1:-}" = "--dry" ] && DRY=1

# 変異走行と競らせない(prove-control.sh 自身も断るが、197本を順に断られても意味が無い)
if [ "$DRY" -eq 0 ] && [ -x tools/mutation-run-live.sh ] && bash tools/mutation-run-live.sh 2>/dev/null; then
    echo "★変異走行が動いている。対照を回すと競るので測らない" >&2
    echo "PROVE-ALL: 未測定(変異走行中)= **効いている事の証拠ではない**"
    exit 2
fi

# ── 継ぎ目を探す ──────────────────────────────────────────────────────────
# 出力 3列: 対照 / 継ぎ目 / 既定値が指す repo 相対path(読めなければ空 + 理由)
MAP="$(python3 - <<'PYEOF'
import glob, os, re, sys

# 既定値の形は2つだけ実在する。増えたら「読めない」に落ちて名指しで出る。
SHAPE_ROOT = re.compile(r'\$\{([A-Z][A-Z0-9_]*):-\$ROOT/([^}"\s]+)\}')
SHAPE_DIRNAME = re.compile(
    r'\$\{([A-Z][A-Z0-9_]*):-\$\(cd\s+"\$\(dirname\s+"\$0"\)/\.\./([a-zA-Z0-9_-]+)"\s+&&\s+pwd\)/([^}"\s]+)\}')
# repo の外の実体を指す継ぎ目。**測れないのは同じでも理由が違う**ので分けて出す:
# 「守っている物を指していない」(TMPDIR 等)と「守っている物を指しているが repo の外」は別の話。
# 後者を前者と同じ籠に入れると、履歴が引けないだけの対照が「対象外」に見えて消える。
SHAPE_OUTSIDE = re.compile(r'\$\{([A-Z][A-Z0-9_]*):-\$HOME/([^}"\s]+)\}')
ANY_SEAM = re.compile(r'\$\{([A-Z][A-Z0-9_]{3,}):-')

for ctl in sorted(glob.glob("test/*-controls.sh")):
    text = open(ctl, encoding="utf-8", errors="replace").read()
    resolved = {}
    for m in SHAPE_ROOT.finditer(text):
        resolved[m.group(1)] = m.group(2)
    for m in SHAPE_DIRNAME.finditer(text):
        resolved[m.group(1)] = m.group(2) + "/" + m.group(3)
    for m in SHAPE_OUTSIDE.finditer(text):
        resolved.setdefault(m.group(1), "!OUTSIDE:~/" + m.group(2))
    seen = set()
    for m in ANY_SEAM.finditer(text):
        seam = m.group(1)
        if seam in seen:
            continue
        seen.add(seam)
        print("%s\t%s\t%s" % (ctl, seam, resolved.get(seam, "")))
PYEOF
)" || { echo "継ぎ目の抽出に失敗" >&2; exit 2; }

pass=0; fail=0; unmeasured=0
declare -a SKIPPED=() FAILED=() UNMEAS=() PASSED=() OUTSIDE=()

while IFS=$'\t' read -r ctl seam rel; do
    [ -n "$ctl" ] || continue
    if [ -z "$rel" ]; then
        SKIPPED+=("$ctl  \$$seam  — 既定値の形が読めない(この道具が知る形のどれでもない)")
        continue
    fi
    case "$rel" in
      "!OUTSIDE:"*)
        # 守っている物は指しているが repo の外 = `git show` で旧版が引けない。
        # この道具では測れないが、**対象外とは違う**。別枠で出す。
        OUTSIDE+=("$ctl  \$$seam  → ${rel#!OUTSIDE:}")
        continue ;;
    esac
    if ! git ls-files --error-unmatch "$rel" >/dev/null 2>&1; then
        SKIPPED+=("$ctl  \$$seam  — 指す先が repo の追跡下に無い: $rel")
        continue
    fi
    if [ -d "$rel" ]; then
        SKIPPED+=("$ctl  \$$seam  — 指す先が file ではなく dir: $rel")
        continue
    fi

    if [ "$DRY" -eq 1 ]; then
        PASSED+=("$(/usr/bin/basename "$ctl") → $rel  (--dry: 実行していない)")
        pass=$((pass+1))
        continue
    fi

    echo ""
    bash tools/prove-control.sh "$ctl" "$seam" "$rel"
    rc=$?
    case "$rc" in
        0) pass=$((pass+1));      PASSED+=("$(/usr/bin/basename "$ctl") → $rel") ;;
        1) fail=$((fail+1));      FAILED+=("$(/usr/bin/basename "$ctl") → $rel") ;;
        *) unmeasured=$((unmeasured+1)); UNMEAS+=("$(/usr/bin/basename "$ctl") → $rel (rc=$rc)") ;;
    esac
done <<< "$MAP"

echo ""
echo "════ まとめ ════"
if [ "$DRY" -eq 1 ]; then
    # ★ここで「効いている: N」と出すと、1本も実行していないのに測定に見える。
    #   このコードベースで4回踏んだ「緑の顔をした未測定」と同じ形なので言葉ごと分ける。
    echo "--dry: 測る対象 $pass 本(**1本も実行していない**。効いているかは何も言っていない)"
else
    echo "効いている: $pass / 効いていない: $fail / 測れていない: $unmeasured"
fi
for x in "${PASSED[@]:-}"; do [ -n "$x" ] && echo "  ○ $x"; done
for x in "${FAILED[@]:-}"; do [ -n "$x" ] && echo "  ★ $x  ← 比べた commit の中身を見てから欠陥と呼ぶ事"; done
for x in "${UNMEAS[@]:-}"; do [ -n "$x" ] && echo "  ? $x"; done

if [ "${#OUTSIDE[@]}" -gt 0 ] && [ -n "${OUTSIDE[0]:-}" ]; then
    echo ""
    echo "── 守っている物を指しているが repo の外(この道具では旧版が引けない)──"
    for x in "${OUTSIDE[@]}"; do echo "  ! $x"; done
    echo "  ※ 別の手段で自分の負の対照を持っているかを個別に見る事"
    echo "     (例: remote-mini-root は \$REMOTE_MINI_OLD で直す前の .bak を自分で差している)"
fi

if [ "${#SKIPPED[@]}" -gt 0 ] && [ -n "${SKIPPED[0]:-}" ]; then
    echo ""
    echo "── 測っていない継ぎ目(黙って落とさない為に全部出す)──"
    for x in "${SKIPPED[@]}"; do echo "  - $x"; done
    echo "  ※ 継ぎ目が読めない = 欠陥とは限らない。TMPDIR や偽 binary の差し込み口など、"
    echo "     守っている物を指していない継ぎ目はこの道具の対象外。自力型の対照も同じ。"
fi

# --dry は測定ではないので 0(=全部効いている)を返さない。2=測っていない、が正しい。
[ "$DRY" -eq 1 ] && exit 2
[ "$fail" -gt 0 ] && exit 1
[ "$unmeasured" -gt 0 ] && exit 2
exit 0
