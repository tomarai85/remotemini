#!/bin/bash
# 「門が知っている全ての対照に、判定が付いているか」を台帳から答える。
#
# ── 何を測るのか(そして何を測らないのか)────────────────────────────────────
# 掃引(`run-controls.sh`)は**その回に回した物**しか知らない。だから掃引の集計行は
# 「全部を測った」の証拠にならない —— 一覧から漏れた対照は、集計にも漏れる。
# 此処が見るのは掃引の出力ではなく **台帳と門の一覧の突き合わせ**:
#
#     門が知る対照  ⊖  台帳に判定が在る対照  ⊖  理由付きで外した対照  =  0 でなければ赤
#
# ★「緑が何本か」は此の計器の目的ではない。赤も未測定も**判定が付いている**なら通す。
#   測っていない事と、測って駄目だった事を混ぜない —— 混ぜると「赤を消す為に一覧から
#   外す」が正解になってしまう。此処が守るのは**取りこぼしが無い事**だけ。
#
# ★理由付きの除外(`EXCLUDED_CTLS`)は通すが、**必ず名前を刷る**。黙って消えない事が
#   除外の条件。今は 3 本(edith 行き)で、機体は 2026-08-20 に譲渡済なので此処では回せない。
#
# 使い方: bash rc-backend/tools/run-controls-coverage.sh
# 環境変数: RC_CTL_LEDGER  台帳の場所(既定 = 掃引と同じ `../.harness/run-controls-ledger.tsv`)
# 終了コード: 0=取りこぼし無し / 1=判定の無い対照が在る / 2=測れなかった(門が答えない等)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"     # = rc-backend/tools
ROOT="$(cd "$HERE/.." && pwd)"                            # = rc-backend
REPO="$(cd "$ROOT/.." && pwd)"
RUNNER="$HERE/run-controls.sh"
GATE="$HERE/staged-controls-gate.sh"
LEDGER="${RC_CTL_LEDGER:-$REPO/.harness/run-controls-ledger.tsv}"

for f in "$RUNNER" "$GATE"; do
    [ -f "$f" ] || { echo "測る材料が無い: $f"; exit 2; }
done

# ── 門から一覧を取る(手で写さない)──────────────────────────────────────────
# ★此処で `SCAN_SPECS` を写すと、門の書き方が変わった日に「計器だけが古い網を相手に緑」
#   になる。持っている側に聞く。
mapfile_gate() { RC_GATE_ROOT="$REPO" /bin/bash "$GATE" --all-controls 2>/dev/null; }
ALL="$(mapfile_gate)"
N_ALL="$(printf '%s\n' "$ALL" | /usr/bin/grep -c . )"
if [ "$N_ALL" -lt 10 ]; then
    echo "UNMEASURED  門から対照の一覧を取れなかった(${N_ALL} 本)= 突き合わせが成立しない"
    exit 2
fi

# ── 理由付きで外した物(走らせる側の宣言から取る。此処でも手で写さない)────────
EXCLUDED="$(/usr/bin/sed -n '/^EXCLUDED_CTLS=(/,/^)/p' "$RUNNER" \
    | /usr/bin/grep -oE '^ *[A-Za-z0-9._/-]+\.(sh|py)' | /usr/bin/tr -d ' ')"

# ── 台帳 ────────────────────────────────────────────────────────────────────
# 同じ対照が複数回 積まれている事が在る(`--resume` / 再走)。**最後の行が正**。
ledger_rc() { /usr/bin/awk -F'\t' -v n="$1" '$2==n{v=$3} END{if(v!="")print v}' "$LEDGER" 2>/dev/null; }

green=0; red=0; unm=0; skipped=0
missing=()
skipped_names=()

while IFS= read -r p; do
    [ -n "$p" ] || continue
    b="$(/usr/bin/basename "$p")"
    rc="$(ledger_rc "$b")"
    if [ -n "$rc" ]; then
        case "$rc" in
            0) green=$((green+1)) ;;
            2) unm=$((unm+1)) ;;
            *) red=$((red+1)) ;;
        esac
        continue
    fi
    if printf '%s\n' "$EXCLUDED" | /usr/bin/grep -q "/$b\$"; then
        skipped=$((skipped+1)); skipped_names+=("$b")
        continue
    fi
    missing+=("$b")
done <<EOF
$ALL
EOF

# ── 刷る ────────────────────────────────────────────────────────────────────
echo "台帳: $LEDGER"
echo "門が知る対照: ${N_ALL} 本"
echo ""
echo "green=$green red=$red 未測定=$unm"
echo ""

if [ "$skipped" -gt 0 ]; then
    echo "理由付きで外した対照 ${skipped} 本(黙って消えない事が除外の条件):"
    for n in "${skipped_names[@]}"; do echo "  - $n"; done
    echo ""
fi

# ★逆向きの隙間も刷る: 掃引は回したが、門は対照だと思っていない物。
#   赤にはしない(判定は付いているので取りこぼしではない)が、**commit で触っても
#   自動では回らない**という別の穴なので黙らない。今は `ios/tools/live-poll-check.sh` 1 本 ——
#   名前が `*-control(s).sh` の形でないので門の網に掛からない。
orphan="$(/usr/bin/awk -F'\t' '{print $2}' "$LEDGER" 2>/dev/null | /usr/bin/sort -u \
    | /usr/bin/grep -vxF -f <(printf '%s\n' "$ALL" | while IFS= read -r p; do
          [ -n "$p" ] && /usr/bin/basename "$p"; done) 2>/dev/null)"
if [ -n "$orphan" ]; then
    echo "註: 掃引は回すが門は対照と認めていない物(= commit で触っても自動では回らない):"
    printf '%s\n' "$orphan" | /usr/bin/sed 's/^/  - /'
    echo ""
fi

if [ "${#missing[@]}" -gt 0 ]; then
    echo "★判定が無い対照 ${#missing[@]} 本 —— 一度も回っていない:"
    for n in "${missing[@]}"; do echo "  - $n"; done
    echo ""
    # ★此処は**案内文**であって実行ではない。二重引用符の中に backtick を書くと
    #   bash はそれを命令置換として**実際に走らせる**。2026-08-31、初版の此の行が
    #   まさにそれで、読むだけの筈の計器が 40 分の掃引を黙って起動していた
    #   (`ps` の親子を辿って発覚: coverage → run-controls --resume → conversation-ui-control
    #    → xcodebuild)。案内に命令を書く時は single quote で括る。
    echo '  直し方: 掃引を回す(bash rc-backend/tools/run-controls.sh --resume)か、'
    echo '          回せない理由が在るなら EXCLUDED_CTLS へ**理由付きで**入れる。'
    echo "RUN-CONTROLS-COVERAGE: 取りこぼし ${#missing[@]} 本"
    exit 1
fi

echo "RUN-CONTROLS-COVERAGE: 取りこぼし 0 本(門が知る ${N_ALL} 本すべてに判定が在る)"
exit 0
