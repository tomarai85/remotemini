#!/bin/bash
# controls-for: rc-backend/tools ios/tools
#
# shell の道具に **warning 以上の shellcheck 指摘を 1 件も入れない**門。
#
# ── なぜ要るか(2026-09-09)────────────────────────────────────────────────
# 走らせた事が一度も無かった。撃ったら 16 件出て、其のうち **3 件は本物の欠陥**:
#   - `ios/tools/adhoc-ota.sh` が `rm -rf "$STAGE/…"` を生の変数でやっていた(SC2115)。
#     `STAGE` が空になる経路は今は無いが、`rm -rf` の引数に生の変数を置く事自体が
#     其の日を待つ形。`${STAGE:?}` にして、空なら消す前に大声で落ちる様にした。
#   - `rc-backend/tools/delivery-check.sh` の「例が在るなら実物も在る筈」の表が
#     **1 行しか無かった**(SC2043)。`tools/` には例が 3 本 在り、`observer.conf` は
#     同じ場所へ置かれるのに見ていなかった = 配達の検査に穴。
#   - `rc-backend/tools/verify-rc-backend-state.sh` の launchd job id が
#     手元と remote のヒアドキュメントに **2 枚**在り、片方は誰も読んでいなかった(SC2034)。
#     構造上ひとつに出来ないので、走る前に一致を機械で確かめる形にした。
# 残りは「消して良い死んだ宣言」と「構造上ひとつに出来ない対」で、後者は
# `# shellcheck disable=SC….  # <理由>` として**その file に理由ごと残る**。
#
# ★`disable` は免除の札ではない。理由の無い `disable` を此の門は**赤にする** ——
#   理由が無ければ、次に読む人は「本当に安全なのか」を最初から調べ直す事になる。
#
# ★shellcheck が入っていない機体では **緑にせず測定不成立(rc=2)**。
#   「道具が無い」を「指摘が無い」と読むのが、此の repo が何度も踏んだ形。
#
# ── 此の門が測らないもの(2026-09-09、Codex が名指し)──────────────────────
# 段は `warning` 以上。**`info` は見ていない**ので、其処に居る本物が通る。
# Codex の原文どおりの例:  name='Ada Lovelace'; printf '<%s>\n' $name
#   引用漏れで単語分割が起き `<Ada>` `<Lovelace>` の 2 行になる。之は `SC2086` =
#   **info** なので此の門は何も言わない。★私自身が同じ型を 2026-09-09 に 2 度踏んだ
#   (zsh は単語分割しないので走査ループが 1 回しか回らず、146/166 と 0 件という
#   嘘を出した)。つまり之は理論上の穴ではなく、此の repo で実際に起きる型。
# 実測(2026-09-09): info 以上は **311 件**。内訳の大半は構造的に意図された物 ——
#   SC2329(source される library の関数は呼ばれていない様に見える)71 /
#   SC2016(単引用符の中で展開しないのは ssh へ渡す時の要件)61 / SC1091 30 等。
#   段ごと下げると其の 278 件を一度に抱える事になるので、下げていない。
# ★**SC2086 だけは 33 件**。之は別タスクとして掃く(1 件ずつ「意図的か」を見る要が
#   在り、`case` の右辺の様に引用しないのが要件の場所も混ざる)。
#   掃き終わったら `RC_SHELLCHECK_SEV` ではなく **SC2086 を名指しで足す**:
#   段を丸ごと下げると、意図された 278 件を黙らせる為の disable が大量に生えて、
#   此の門が守っている「理由の無い免除を作らない」が崩れる。
# ★退却条件: SC2086 の 33 件が 0 になったら、名指しの検査を此処へ足す。
#
# 終了コード: 0=指摘なし / 1=指摘が在る か 理由の無い disable が在る / 2=測れなかった
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SEV="${RC_SHELLCHECK_SEV:-warning}"
DIRS=("$ROOT/rc-backend/tools" "$ROOT/ios/tools")

# 走査から外す file。名前|理由(20 文字以上)。★除外は**理由の宣言**であって免除ではない。
#   file が消えたら測定不成立で止める(腐った除外を残さない)。
EXCLUDED=(
  "rc-backend/tools/edith-gui-run.sh|対象機 edith は 2026-08-20 に艦隊を離れた。其の対照 rc-backend/test/gui-run-controls.sh は生きた edith が無いと 1 件も測れず(実測 UNMEASURED)、staged-controls-gate は測れない対照が在る commit を正しく止める。つまり此の file への変更は**検証できない** —— 門が編集を迫るのは、誰も確かめられない差分を強いる事になる。艦隊へ戻るか、対照が offline で測れる形になったら外す事"
)

# ★道具は差せる様にする(継ぎ目)。対照が「道具が居ない」を作れないと、
#   `exit 2` の枝は**一度も撃たれないまま**「書いてあるから正しい」になる。
SHELLCHECK_BIN="${RC_SHELLCHECK_BIN:-shellcheck}"
command -v "$SHELLCHECK_BIN" >/dev/null 2>&1 || {
    echo "shellcheck-gate: shellcheck が居ない = 測っていない(brew install shellcheck)"
    exit 2
}

excluded_paths=""
# ★空配列 + `set -u` は macOS の bash 3.2 で `unbound variable` になる。除外を全部
#   消した状態 = **正常な最終形**で門が落ちる、という形だった(2026-09-09、対照が発見)。
#   `ios/tools/adhoc-ota.sh` が `CLEANUP` で既に使っている書き方に合わせる。
for row in ${EXCLUDED[@]+"${EXCLUDED[@]}"}; do
    nm="${row%%|*}"; why="${row#*|}"
    if [ "${#why}" -lt 20 ]; then
        echo "shellcheck-gate: $nm の除外理由が短すぎる(20 文字以上)= 宣言になっていない"; exit 2
    fi
    if [ ! -f "$ROOT/$nm" ]; then
        echo "shellcheck-gate: 除外に書いた $nm が居ない = 腐った除外。行を消す事"; exit 2
    fi
    excluded_paths="$excluded_paths $ROOT/$nm"
done

files=()
for d in "${DIRS[@]}"; do
    [ -d "$d" ] || continue
    for f in "$d"/*.sh; do
        [ -f "$f" ] || continue
        case " $excluded_paths " in *" $f "*) continue ;; esac
        files+=("$f")
    done
done
# ★下限。glob が外れて 0 本になった時に「指摘 0 件」と読ませない ——
#   空の網は違反ゼロに見える(`port-coverage-gate` / `orphan-instrument-scan` と同じ床)。
FLOOR="${RC_SHELLCHECK_FLOOR:-40}"
if [ "${#files[@]}" -lt "$FLOOR" ]; then
    echo "shellcheck-gate: 台本を ${#files[@]} 本しか集められなかった(下限 $FLOOR)= 走査が壊れている。判定しない"
    exit 2
fi

rc=0
# ★`|| true` と `2>/dev/null` の組で **道具自身の失敗が緑になる**(2026-09-09、自分で撃って確認)。
#   `shellcheck` は指摘が在る時 1、使い方が悪い時 2 等で落ちる。標準出力が空で 2 が返る場合、
#   以前の書き方は「指摘 0 件」と読んでいた —— 道具が動かなかった事を、道具が何も
#   言わなかった事と同じに扱う形。終了コードで読み分け、標準エラーも捨てない。
sc_err="$(mktemp)"
out="$("$SHELLCHECK_BIN" -f gcc -S "$SEV" "${files[@]}" 2>"$sc_err")"; sc_rc=$?
if [ "$sc_rc" -ne 0 ] && [ "$sc_rc" -ne 1 ]; then
    echo "shellcheck-gate: shellcheck が rc=$sc_rc で落ちた = 測っていない"
    sed 's/^/    /' "$sc_err" | head -5
    /bin/rm -f "$sc_err"
    exit 2
fi
/bin/rm -f "$sc_err"
if [ -n "$out" ]; then
    echo "shellcheck-gate: ★$SEV 以上の指摘($(printf '%s\n' "$out" | grep -c .) 件)"
    printf '%s\n' "$out" | sed "s|$ROOT/||" | sed 's/^/    /'
    echo "  直すか、**理由を書いて** その行の直上に \`# shellcheck disable=SC….  # <理由>\` を置く事"
    rc=1
fi

# ★理由の無い disable を赤にする。之が無いと、此の門は「disable を書けば通る」門になり、
#   指摘 0 件は「安全」ではなく「黙らせた」を意味する様になる。
# ★「行末で終わっているか」で判定してはいけない(2026-09-09、自分で回避して確認)。
#   「disable=SC2034」の後ろに空の `#` を足しただけの形や、`#` の直後に空白を置かない形は
#   其の正規表現をすり抜ける —— **空の `#` を足すだけで免除できる門**になっていた。
#   だから *在るか* ではなく **理由の中身が 8 文字以上在るか** を見る。
bare="$(grep -nE '^[[:space:]]*#[[:space:]]*shellcheck[[:space:]]+disable=' "${files[@]}" 2>/dev/null \
        | awk -F'disable=' '{ r=$2; sub(/^[A-Za-z0-9,=]+/, "", r); gsub(/^[[:space:]]*#*[[:space:]]*/, "", r);
                              gsub(/[[:space:]]+$/, "", r); if (length(r) < 8) print $0 }' \
        | sed "s|$ROOT/||")"
if [ -n "$bare" ]; then
    echo "shellcheck-gate: ★理由の無い disable が在る(免除の札になっている):"
    printf '%s\n' "$bare" | sed 's/^/    /'
    echo "  同じ行の後ろに \`  # <なぜ其れで正しいか>\` を足す事(8 文字以上。空の # では通らない)"
    rc=1
fi

[ "$rc" -eq 0 ] && echo "shellcheck-gate: ${#files[@]} 本 / $SEV 以上の指摘 0 件(除外 ${#EXCLUDED[@]} 本、理由つき)"
exit "$rc"
