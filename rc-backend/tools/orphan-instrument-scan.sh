#!/bin/bash
# 対照は在るのに**走らせる物が無い**道具を挙げる。
#
# ── なぜ要るか(2026-08-07、実測)────────────────────────────────────────
# `tools/port-coverage.py` は対照(`test/port-coverage-controls.sh`)を持ち、その対照は
# 掃き(`tools/run-controls.sh`)にも登録されていた。にも関わらず**道具そのものを呼ぶ物が
# repo のどこにも無かった** —— 走るのは私が手で叩いた時だけ。結果、出口が 0(08-05 の
# WORKLOG)から 2 へ落ちても誰も気付かないまま残っていた。
#   ★対照は道具を**測る**物であって、道具を**走らせる**物ではない。走らせる者(門・
#     台本・glob)が別に要る。「対照が在る」を「回っている」と読むのがこの病気。
#   `tools/vacuous-scan.py` が同じ形を免れているのは門が在るからで、設計の差ではない。
#
# ── この道具が一番間違えやすい所(先に書く)────────────────────────────
# **「名前で呼ばれていない」は「走っていない」ではない。** 実測 08-07: 素朴に名前で
# 引くと `test/design-supersede.test.mjs` / `test/test-discovery.test.mjs` が孤児に見えたが、
# 実際は `npm test` の glob `test/**/*.test.mjs` が拾って走っていた(検査名を出力から引いて
# 確認済み)。名前で照合する限り、照合する側も同じ病に罹る —— なので glob で回る操作者を
# **package.json から導出して**先に差し引く。
#
# ── 対象の範囲(★狭めた。分母ごと出す)──────────────────────────────
# `# controls-for:` は**道具だけを指していない**。実測 08-07 の一意 75 対象の内訳:
#   .sh 39 / .mjs 16 / .py 3  = path で撃たれ得る = **この道具の対象**(58)
#   .swift 11 / .yml 1 / .json 1  = path で撃たれない。Swift は project.yml の glob で
#     まとめて compile されるので「file 名で呼ばれる」事が原理的に無い —— 名前照合を
#     掛ければ 11 本全部が偽の孤児になる。宣言 file も同じ(読むのは xcodegen)。
#   `*` を含む綴り 3 = file ではなく**類**の指定(`tools/*.plist` 等)
#   external: 1 = repo の外
# 範囲外にした物は毎回**件数を出す**。黙って削ると「全部見た」と読まれる。
#   ★対象を外した物の対照が回っているかは別の門(`tools/controls-registration-gate.sh`)
#     が見ている。此処が見るのは「道具を撃つ者が居るか」だけ。
#
# ── 逃がし方(印は**外される道具の側**に置く)──────────────────────────
#   # no-operator: <理由 8文字以上>
# 印を道具の中に置く理由: 道具の一覧を此処に持つと、file が動いた時に一覧だけが腐る
# (`DEFAULT_ACCEPTED` が死んだ受理を溜めたのと同じ壊れ方)。印は file に付いて動く。
# ★印そのものの腐りも見る: 操作者が在るのに印が付いていれば赤(= 死んだ免除)。
#   `port-coverage.py` の not-a-port と同じ作法。
#
# 終了コード: 0=緑 / 1=赤(印の無い孤児 or 腐った印 or 死んだ指し先)/ 2=**測れなかった**。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"          # = rc-backend
REPO="$(cd "$ROOT/.." && pwd)"
cd "$REPO" || { echo "orphan-instrument-scan: repo へ入れない"; exit 2; }

# (対象, 対照) の行数の下限。宣言の書式を変えて発見が 0 に潰れた時、緑と区別する為。
# 実測 2026-08-07 は 92 行(対照 file 66 本、1 本が最大 4 対象を並べる)。実測値と
# 等しくしない(等しくすると 1 行消す度に赤くなる)。
OIS_FLOOR="${OIS_FLOOR:-60}"

# 印は「行まるごとが印」の物だけを数える(行頭 + 註記号 + 印)。
# ★2026-08-07: 最初は行のどこに在っても拾う綴りにしていて、**この file 自身が引っ掛かった**。
#   上の「逃がし方」で印の書式を説明している行が印と読まれる —— そして此の道具に門を
#   付けた瞬間、操作者が在るのに印が在る = 腐った印で赤になる。説明を消して直すのは
#   本末転倒なので、判定の側を締めた: 説明は註を1段深くして(行頭の # の後がまた #)
#   印にならない。**印は宣言であって、言及ではない。**
MARK_RE='^[[:space:]]*(#|//)[[:space:]]*no-operator:[[:space:]]*'
MIN_REASON=8

TMP="$(/usr/bin/mktemp -d -t orphaninst)" || exit 2
trap '[ -n "${TMP:-}" ] && [ -d "$TMP" ] && { find "$TMP" -type f -print0 2>/dev/null | xargs -0 /bin/rm -f 2>/dev/null; /bin/rmdir "$TMP" 2>/dev/null; }' EXIT INT TERM HUP

EXCL=(--exclude-dir=.git --exclude-dir=node_modules --exclude-dir=build --exclude-dir=DerivedData)

# ── ① 組を集める(1 行に複数の対象が並ぶ。空白で割る)──────────────────
/usr/bin/grep -rl "${EXCL[@]}" '^# controls-for:' . 2>/dev/null | while IFS= read -r ctl; do
    line="$(/usr/bin/sed -n 's/^# controls-for: *//p' "$ctl" | /usr/bin/head -1)"
    [ -n "$line" ] || continue
    for inst in $line; do
        printf '%s\t%s\n' "$inst" "${ctl#./}"
    done
done | /usr/bin/sort -u > "$TMP/pairs.tsv"

NPAIR="$(/usr/bin/wc -l < "$TMP/pairs.tsv" | /usr/bin/tr -d ' ')"
if [ "$NPAIR" -lt "$OIS_FLOOR" ]; then
    echo "orphan-instrument-scan: ★組が $NPAIR 行(下限 $OIS_FLOOR)= **測れていない**"
    echo "  '# controls-for:' の書式が変わったか、走査が木に届いていない。"
    echo "  孤児 0 は『問題が無い』ではなく『何も見ていない』かもしれないので緑にしない。"
    exit 2
fi

# ── ② glob で回る操作者を package.json から**導出**する ────────────────────
#     一覧を此処に書き写すと、script を変えた時に写しだけが腐る。
#
# ★展開は **node にやらせる**。glob を実際に解くのは `node --test` なので、同じ engine で
#   解かない限り「走っている物」の集合が一致しない。実測 2026-08-07: 最初は shell に
#   `ls -1 test/**/*.test.mjs` を撃たせていたが、macOS の /bin/bash は 3.2 で globstar が
#   無く(4.0 で追加)、`**` が普通の `*` 2つに落ちて **0 件** になった。node の側では
#   `**` が dir 0 個にも当たるので 37/37 件 —— 同じ綴りで結果が全件と 0 件に割れる。
#   0 件だと「glob で回る物は無い」= 37 本が全部『孤児』に化ける所を、下の guard が
#   exit 2(未測定)で止めた。此処を 1(赤)や 0(緑)へ丸めない事が効いた実例。
: > "$TMP/globbed.txt"
if [ -f "$ROOT/package.json" ] && command -v node >/dev/null 2>&1; then
    /usr/bin/sed -n 's/.*"test":[[:space:]]*"\(.*\)".*/\1/p' "$ROOT/package.json" \
      | /usr/bin/grep -oE "'[^']*\*[^']*'" | /usr/bin/tr -d "'" \
      | while IFS= read -r g; do
            ( cd "$ROOT" && GLOB="$g" node --no-warnings -e '
                const { globSync } = require("node:fs");
                for (const f of globSync(process.env.GLOB)) console.log("rc-backend/" + f);
              ' 2>/dev/null )
        done >> "$TMP/globbed.txt"
fi
NGLOB="$(/usr/bin/wc -l < "$TMP/globbed.txt" | /usr/bin/tr -d ' ')"
if [ "$NGLOB" -eq 0 ]; then
    echo "orphan-instrument-scan: ★glob の操作者を1本も導出できなかった = **測れていない**"
    echo "  rc-backend/package.json の test script から glob を読めない(node が無い/書式が変わった)。"
    echo "  この儘だと glob で走っている検査を全部『孤児』と誤って挙げる。"
    exit 2
fi

# ── ③ 名前で呼んでいる**実行され得る** file を1回の走査で引く ──────────────
#     `.md` を入れない: 書類が名前を書いていても、それは撃つ者ではない。
/usr/bin/cut -f1 "$TMP/pairs.tsv" | /usr/bin/sed 's#^external:##' \
  | while IFS= read -r i; do basename "$i"; done | /usr/bin/sort -u > "$TMP/pats.txt"
/usr/bin/grep -rn "${EXCL[@]}" -F -f "$TMP/pats.txt" \
    --include='*.sh' --include='*.py' --include='*.mjs' --include='*.js' \
    --include='*.json' --include='*.plist' --include='*.yml' --include='*.yaml' \
    . 2>/dev/null \
  | /usr/bin/grep -vE '^[^:]+:[0-9]+:[[:space:]]*(#|//)' > "$TMP/hits.txt"

# ── ④ 判定 ───────────────────────────────────────────────────────────────
red=0; orph=0; disposed=0; ext=0; globd=0; pat=0; nonpath=0; inscope=0
: > "$TMP/red.txt"; : > "$TMP/disp.txt"

while IFS=$'\t' read -r inst ctl; do
    case "$inst" in
        external:*) ext=$((ext+1)); continue ;;   # repo の外。此処の網では測れない
        *'*'*)      pat=$((pat+1)); continue ;;   # file ではなく類の指定
    esac
    # path で撃たれ得る拡張子だけを見る(理由は頭の「対象の範囲」)
    case "$inst" in
        *.sh|*.py|*.mjs|*.js) ;;
        *) nonpath=$((nonpath+1)); continue ;;
    esac
    inscope=$((inscope+1))

    # 道具の実体 path(controls-for は rc-backend 相対 or repo 相対の両方が在る)
    ipath=""
    for cand in "$ROOT/$inst" "$REPO/$inst"; do
        [ -f "$cand" ] && { ipath="$cand"; break; }
    done
    if [ -z "$ipath" ]; then
        red=$((red+1))
        echo "  ★指している道具が無い: $inst  (対照 $ctl)" >> "$TMP/red.txt"
        continue
    fi
    rel="${ipath#$REPO/}"
    base="$(basename "$inst")"

    # glob で回っているか
    if /usr/bin/grep -qxF "$rel" "$TMP/globbed.txt"; then
        globd=$((globd+1)); continue
    fi

    # 名前で呼ばれているか(自分自身と自分の対照は数えない)
    nop="$(/usr/bin/grep -F "$base" "$TMP/hits.txt" \
           | /usr/bin/awk -F: -v b="/$base" -v cb="/$(basename "$ctl")" \
               '{ f=$1; if (index(f,b)) next; if (index(f,cb)) next; print }' \
           | /usr/bin/wc -l | /usr/bin/tr -d ' ')"

    mark="$(/usr/bin/grep -E "$MARK_RE" "$ipath" 2>/dev/null | /usr/bin/head -1)"
    reason="$(printf '%s' "$mark" | /usr/bin/sed -E "s/.*no-operator:[[:space:]]*//")"

    if [ -n "$mark" ] && [ "$nop" -gt 0 ]; then
        red=$((red+1))
        echo "  ★腐った印: $rel — 走らせる物が在るのに no-operator の印が付いている" >> "$TMP/red.txt"
        continue
    fi
    if [ "$nop" -gt 0 ]; then continue; fi
    if [ -n "$mark" ]; then
        if [ "${#reason}" -lt "$MIN_REASON" ]; then
            red=$((red+1))
            echo "  ★印の理由が短すぎる(${#reason}字): $rel = 黙らせているだけ" >> "$TMP/red.txt"
        else
            disposed=$((disposed+1))
            echo "      - $rel — $reason" >> "$TMP/disp.txt"
        fi
        continue
    fi
    orph=$((orph+1))
    echo "  ★孤児: $rel  (対照 $ctl は在るのに、走らせる物が無い)" >> "$TMP/red.txt"
done < "$TMP/pairs.tsv"

echo "=== 対照は在るが走らせる物が無い道具 ==="
[ -s "$TMP/red.txt" ] && /bin/cat "$TMP/red.txt"
echo "  組 $NPAIR 行 / 対象 $inscope / glob で回る $globd / 印で外した $disposed"
echo "  範囲外: path で撃たれない $nonpath / 類の指定 $pat / repo 外 $ext"
[ -s "$TMP/disp.txt" ] && { echo "  印で外した内訳:"; /bin/cat "$TMP/disp.txt"; }

if [ "$((red + orph))" -gt 0 ]; then
    echo ""
    echo "  直し方は2通り。どちらも**その file に残る**:"
    echo "    走らせる物を足す = 門(tools/pre-commit-gates.sh)か台本から呼ぶ"
    echo "    印を置く         = その道具の中に no-operator: の印を理由付きで置く"
    echo "  (理由は ${MIN_REASON} 文字以上。手で撃つ物なら『いつ誰が撃つか』を書く)"
    exit 1
fi
echo "orphan-instrument-scan: 走らせる物が無い道具 0 本"
exit 0
