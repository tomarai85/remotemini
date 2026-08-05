#!/bin/bash
# `tools/prove-control.sh` を**回す物**。これが無いと prover 自身が
# 「誰も回さない対照」になる —— 手で思い出して回す限り、毎回はやらない。
#
# ── 一覧を手で持たない ────────────────────────────────────────────────────
# 対象(差替型の対照)を固定の配列で持つと、**新しい対照を書いた時に黙って漏れる**。
# 漏れた事は誰にも見えない。だから対照を毎回読んで継ぎ目を**探す**。
# これは run-controls.sh の規則(1)「入力は本物の生成元から取る」を、この道具自身に
# 当てた物 —— 手書きの一覧は「対象はこれで全部だ」という思い込みごと緑になる。
#
# ★2026-08-05: 上をそう書いておきながら、**どの dir を探すか**は `test/*-controls.sh` の
#   直書きだった。継ぎ目は毎回探すのに、探す**範囲**が手書き。結果、`.harness/` と
#   `ios/tools/` に居る対照 5 本は一度もこの道具の視野に入っていなかった
#   (門が見る 46 本に対し、此処が見ていたのは 41 本)。範囲の正本は
#   `tools/staged-controls-gate.sh` の `SCAN_SPECS` = commit の門が見る範囲そのもの。
#   対照 = `test/prove-all-scope-controls.sh`(縮める方向と伸ばす方向の両方)。
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
if [ "$DRY" -eq 0 ] && [ -x tools/mutation-run-live.sh ]; then
    _mrl=0; bash tools/mutation-run-live.sh 2>/dev/null || _mrl=$?
    # 進むのは「居ないと確認できた」= 丁度 1 の時だけ。2(測れなかった)で進むと、
    # 走行と競っている最中の結果を「効いている/いない」の証拠として使ってしまう。
    if [ "$_mrl" -ne 1 ]; then
        if [ "$_mrl" -eq 0 ]; then
            echo "★変異走行が動いている。対照を回すと競るので測らない" >&2
            echo "PROVE-ALL: 未測定(変異走行中)= **効いている事の証拠ではない**"
        else
            echo "★変異走行の有無を測れなかった(mutation-run-live.sh exit=${_mrl})。競るかもしれないので測らない" >&2
            echo "PROVE-ALL: 未測定(走行の有無が不明)= **効いている事の証拠ではない**"
        fi
        exit 2
    fi
fi

# ── 探す範囲を、門の生成元から取り出す ────────────────────────────────────
# `SCAN_SPECS=( "<repo からの dir>|<宣言の基点>" ... )` の第1列だけを使う。
# 取り出せなければ**空で走らせない** —— 空の網は「全部登録済み」に見えるので、
# 此処だけは緑でも赤でもなく「測っていない」で止めるのが正しい。
GATE_FOR_SPECS="${GATE_FOR_SPECS:-$ROOT/tools/staged-controls-gate.sh}"
SCAN_DIRS=()
while IFS= read -r _d; do
    [ -n "$_d" ] || continue
    case "$_d" in
        rc-backend/*) SCAN_DIRS+=("${_d#rc-backend/}") ;;   # 此処の cwd = rc-backend
        *)            SCAN_DIRS+=("../$_d") ;;
    esac
done < <(/usr/bin/sed -n '/^SCAN_SPECS=(/,/^)/p' "$GATE_FOR_SPECS" 2>/dev/null \
         | /usr/bin/sed -n 's/^[[:space:]]*"\([^|"]*\)|.*/\1/p')

if [ "${#SCAN_DIRS[@]}" -eq 0 ]; then
    echo "★探す範囲を取り出せなかった: $GATE_FOR_SPECS" >&2
    echo "  SCAN_SPECS の書き方を変えたなら、此処の取り出しも同じ commit で直す事" >&2
    echo "PROVE-ALL: 未測定(探す範囲が空)= **効いている事の証拠ではない**"
    exit 2
fi

# ── 継ぎ目を探す ──────────────────────────────────────────────────────────
# 出力 3列: 対照 / 継ぎ目 / 既定値が指す repo 相対path(読めなければ空 + 理由)
MAP="$(RC_PROVE_SCAN_DIRS="$(printf '%s\n' "${SCAN_DIRS[@]}")" python3 - <<'PYEOF'
import glob, os, re, sys

# 既定値の形は2つだけ実在する。増えたら「読めない」に落ちて名指しで出る。
SHAPE_ROOT = re.compile(r'\$\{([A-Z][A-Z0-9_]*):-\$ROOT/([^}"\s]+)\}')
SHAPE_DIRNAME = re.compile(
    r'\$\{([A-Z][A-Z0-9_]*):-\$\(cd\s+"\$\(dirname\s+"\$0"\)/\.\./([a-zA-Z0-9_-]+)"\s+&&\s+pwd\)/([^}"\s]+)\}')
# repo の外の実体を指す継ぎ目。**測れないのは同じでも理由が違う**ので分けて出す:
# 「守っている物を指していない」(TMPDIR 等)と「守っている物を指しているが repo の外」は別の話。
# 後者を前者と同じ籠に入れると、履歴が引けないだけの対照が「対象外」に見えて消える。
SHAPE_OUTSIDE = re.compile(r'\$\{([A-Z][A-Z0-9_]*):-\$HOME/([^}"\s]+)\}')
# 対照自身の dir を基点に取る形。`test/` の外の対照はこの書き方をしている
# (`HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"` の直後に使う)。
# 範囲を広げただけでは「既定値の形が読めない」に落ちるので、形の方も一緒に足す。
SHAPE_HERE = re.compile(r'\$\{([A-Z][A-Z0-9_]*):-\$HERE/([^}"\s]+)\}')
ANY_SEAM = re.compile(r'\$\{([A-Z][A-Z0-9_]{3,}):-')

DIRS = [d for d in os.environ.get("RC_PROVE_SCAN_DIRS", "").split("\n") if d]
if not DIRS:
    # 呼び出し側が空を渡した = 網が無い。緑を出さずに落とす。
    sys.stderr.write("探す範囲が渡ってきていない (RC_PROVE_SCAN_DIRS)\n")
    sys.exit(3)

CTLS = sorted({os.path.normpath(p)
               for d in DIRS
               for p in glob.glob(os.path.join(d, "*-control*.sh"))})

for ctl in CTLS:
    text = open(ctl, encoding="utf-8", errors="replace").read()
    resolved = {}
    for m in SHAPE_ROOT.finditer(text):
        resolved[m.group(1)] = m.group(2)
    for m in SHAPE_DIRNAME.finditer(text):
        resolved[m.group(1)] = m.group(2) + "/" + m.group(3)
    for m in SHAPE_HERE.finditer(text):
        resolved.setdefault(
            m.group(1), os.path.normpath(os.path.join(os.path.dirname(ctl), m.group(2))))
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
    # ★`</dev/null` を落とさない。この loop の入力は `<<< "$MAP"` = **stdin**。
    #   中で回す対照が stdin を読む物(`ssh` は黙って読み切る)を含むと、
    #   **残りの行ごと食われて loop が途中で終わる**。2026-08-03 実測: 14 本のうち
    #   gui-run(ssh を使う)まで走った所で打ち切られ、以降 8 本が**一覧にすら出ずに消えた**。
    #   この道具は「黙って落とさない」事が売りなので、これは売り物そのものの欠陥だった。
    #   (旧版では prove-control が対照を回す前に必ず exit 2 していたので発現しなかった。
    #    = pathspec を直して初めて見えた、直した事で露出した二次の欠陥)
    bash tools/prove-control.sh "$ctl" "$seam" "$rel" </dev/null
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
