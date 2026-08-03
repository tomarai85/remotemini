#!/bin/bash
# `test/mutation-verdict-controls.sh` の**陰性対照** = 対照そのものを検査する。
#
# なぜ要るか(2026-08-03): `mutation-verdict-controls.sh` の頭に §M 変異表が書いてあって、
# 「`scratchpad/verdict-mutants.sh` が当てる」と明記されていた。**その file は存在しなかった。**
# 表は8行の散文で、回す物が無い —— DESIGN (19)「規則は、それを回す物が無いと効かない」を
# 同じ日に5回目に踏んだ形。だから表を消すのでも直すのでもなく、**回す物をこちらへ据える**。
# 置き場が `scratchpad/` でなく `test/` なのも同じ理由で、commit されない場所に置いた規則は
# 次のセッションには存在しない。
#
# 測っている事: `tools/mutation-verdict.sh` を1箇所ずつ壊すと、
# `mutation-verdict-controls.sh` の**狙った項が本当に赤くなるか**。
# 赤くならないなら、その項は「見分けている」のではなく「何をしても緑になる書き方」。
#
# ★言える事と言えない事(先に書く):
#   言える  = 壊した版で狙った項が**落ちる**(= その項は少なくともその壊れ方を見ている)。
#   言えない = 落ちるのが**その項だけ**である事。指紋の範囲を狭める変異は
#              「判定が失効しない」を通じて複数の項に波及するのが**正しい**振る舞いなので、
#              「その項だけ」を要求すると正しい実装を赤にしてしまう。だから照合は
#              **狙った項が落ちた集合に含まれるか**で見る。観測した集合は各行に併記する。
#
# ★空振り防止を2枚:
#   ① 変異が本当に台本を変えたか(`diff`)。当たらない sed は「壊した版でも赤が出ない」を
#      作り、陰性対照を**黙って無効化**する(同日に第1弾の配備対照で踏んだ)。
#   ② 落ちた集合が**空でない**事。空なら「壊れているのに全部緑」= 見たかった欠陥そのもの。
#
# ── 速い側と遅い側 ────────────────────────────────────────────────────────
# 親の対照は §5-9 で**本物の変異の走行を2回**起こすので 1 回 150〜250 秒。8 体を全部当てると
# 20 分を超え、pre-commit の門には置けない。だから既定は本物の走行を要らない 2 体だけ回し、
# 残り 6 体は **未測定(終了コード 2)**として名前を出す。**緑とは言わない。**
#   既定           : assert-green / fp-empty-ok の 2 体(§1-4 だけで判る)→ exit 2
#   RC_VERDICT_MUTANTS_SLOW=1 : 8 体全部 → exit 0/1
#
# 終了コード: 0=緑 / 1=赤 / 2=未測定。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUBJECT="$ROOT/tools/mutation-verdict.sh"
CONTROL="$ROOT/test/mutation-verdict-controls.sh"
[ -f "$SUBJECT" ] || { echo "★対象が読めない: $SUBJECT = 測定不成立"; exit 2; }
[ -f "$CONTROL" ] || { echo "★対照が読めない: $CONTROL = 測定不成立"; exit 2; }

pass=0; fail=0
ok(){ pass=$((pass+1)); printf '  OK %s\n' "$1"; }
ng(){ fail=$((fail+1)); printf '  NG %s\n     %s\n' "$1" "$2"; }

SB="$(cd "$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/verdictmut.XXXXXX")" && /bin/pwd -P)"
cleanup(){
    [ -n "${SB:-}" ] && [ -d "$SB" ] || return 0
    /usr/bin/find "$SB" -type f -print0 2>/dev/null | /usr/bin/xargs -0 /bin/rm -f 2>/dev/null
    /usr/bin/find "$SB" -depth -type d -print0 2>/dev/null | /usr/bin/xargs -0 -n1 /bin/rmdir 2>/dev/null
    return 0
}
trap cleanup EXIT

# ── 落ちた項の名前を取り出す ──────────────────────────────────────────────
# 親の対照は `NG <名前>` を出すが、名前は「  終了コード 2」の様に**節をまたいで重複する**。
# だから直前の節見出し(`── 1.` / `  5-b.`)を追い、NG が出た節の id を集める。
# ★親の出力の形に依存するので、形が変われば此処も直す —— 変わった事は「集合が空」で判る
#   (① の diff が通っているのに空 = 抽出が壊れた、と読める)。
#
# ★`LC_ALL=C` は飾りではない。親は赤の行で実際の出力を `head -c 200` で切って見せるので、
#   切り口が多バイト文字の途中に来ると**不正な UTF-8** が混じる。既定のロケールだと awk は
#   そこで `towc: multibyte conversion failure` を出して**その先を読むのを止める** ——
#   つまり後ろの NG を静かに取りこぼし、「壊したのに落ちた項が少ない」という嘘の観測になる。
#   実際に踏んだ(2026-08-03)。バイトとして読めば内容に依らず最後まで走る。
sections_with_ng() { LC_ALL=C /usr/bin/awk '
    /^──[[:space:]]*[0-9]+\./ { s=$2; sub(/\..*$/,"",s); next }
    /^[[:space:]]+[0-9]+-[a-z]\./ { s=$1; sub(/\./,"",s); next }
    /^[[:space:]]*NG / { if (s != "" && !(s in seen)) { seen[s]=1; print s } }
' | /usr/bin/sort | /usr/bin/tr '\n' ' '; }

# ── 1 体当てる ────────────────────────────────────────────────────────────
# 木を丸ごと写し、写しの `tools/mutation-verdict.sh` だけを壊し、**写しの側の対照**を回す。
# 親の対照は `$ROOT` を BASH_SOURCE から出すので、写しを回せば写しの道具を見る。
# 本物の木には一切触らない。
hit() { # hit <名前> <sed式> <狙った節> [fast|slow]
    local name="$1" expr="$2" want="$3" tier="${4:-slow}"
    local d="$SB/$name"
    /bin/mkdir -p "$d"
    /bin/cp -R "$ROOT"/. "$d"/ 2>/dev/null
    /usr/bin/sed "$expr" "$SUBJECT" > "$d/tools/mutation-verdict.sh" || {
        ng "$name" "sed が失敗した = 測定不成立"; return; }

    # ★空振り防止 ①: 当たっていない sed は「壊した版でも赤が出ない」を作る。
    if /usr/bin/diff -q "$SUBJECT" "$d/tools/mutation-verdict.sh" >/dev/null 2>&1; then
        ng "$name" "変異が台本を変えていない(sed が空振り)= 陰性対照が無効"
        return
    fi

    local fastenv=""
    [ "$tier" = fast ] && fastenv=1
    local got
    got="$(RC_VERDICT_CTL_FAST="${fastenv:-0}" /bin/bash "$d/test/mutation-verdict-controls.sh" 2>&1 \
           | sections_with_ng)"

    # ★空振り防止 ②: 壊したのに何も落ちない = 見たかった欠陥そのもの。
    if [ -z "$got" ]; then
        ng "$name" "壊したのに落ちた項が 0(狙い=§$want)= 対照が見分けていない"
        return
    fi
    case " $got" in
        *" $want "*) ok "$name — §$want が落ちた(観測: $got)" ;;
        *) ng "$name" "狙った §$want が落ちていない(観測: $got)" ;;
    esac
}

echo "── §M 変異表を当てる(対象: tools/mutation-verdict.sh)──"

# ★fast の 2 体は本物の走行が要らない。既定はこの 2 体だけ。
#   assert-green: 判定が無い時に 2 でなく 0 を返す = 「測っていない」を「異常なし」に丸める。
#                 この道具が潰す為に在る病気そのもの。§1 が見ている。
#                 ★節で囲って当てる。`        exit 2` は台本に 3 箇所在るので、
#                 素の行照合だと関係の無い 2 箇所も一緒に壊れて診断にならない。
hit assert-green '/未測定: 今の木/,/^    fi$/ s|^        exit 2$|        exit 0|' 1 fast
#   fp-empty-ok : 指紋の空入力の守りを**両方**外す。片方だけだともう片方が拾うので
#                 §4 は赤にならない —— 「1つ外せば通る」と思って書くと空振りする所。
#                 `tree_fp()` の中の `return 1` 2 本がその守りの本体(他の箇所には無い)。
hit fp-empty-ok 's|^        return 1$|        :|' 4 fast

if [ "${RC_VERDICT_MUTANTS_SLOW:-0}" = "1" ]; then
    # 指紋が覆う範囲を1つずつ削る。削った層を直しても判定が失効しなくなる = 偽の緑。
    hit fp-no-tools 's|find src test tools package.json|find src test package.json|g' 5-b
    hit fp-no-test  's|find src test tools package.json|find src tools package.json|g' 5-c
    hit fp-no-src   's|find src test tools package.json|find test tools package.json|g' 5-d
    # 要約行の確認を外す = 途中で殺された走行を「測った」として記録する。
    # (`if ! grep -q` は台本に1箇所しか無いので行の形で当てて足りる)
    hit no-summary  's|^    if ! grep -q .*then$|    if false; then|' 6
    # exit_code を見ずに常に 0 = 素通りが在る判定を緑で返す。
    hit assert-rc   's|^sys.exit(0 if d.get("exit_code") == 0 else 1)$|sys.exit(0)|' 7
    # selector の食い違いを見ない = 別の選び方の判定を今の選び方の緑として使う。
    hit sel-ignore  's|^if d.get("tree_fp") != fp or d.get("selector") != sel:$|if d.get("tree_fp") != fp:|' 8
else
    echo "  ── 残り 6 体(fp-no-tools / fp-no-test / fp-no-src / no-summary / assert-rc /"
    echo "     sel-ignore)は**回していない**。親の対照が本物の変異の走行を2回起こすので"
    echo '     1 体 150〜250 秒 = 全部で 20 分超。RC_VERDICT_MUTANTS_SLOW=1 で回す。'
fi

echo ""
if [ "${RC_VERDICT_MUTANTS_SLOW:-0}" != "1" ]; then
    echo "VERDICT-MUTANTS: pass=$pass fail=$fail  ★未測定(遅い 6 体)= **緑ではない**"
    [ "$fail" -eq 0 ] || exit 1
    exit 2
fi
echo "VERDICT-MUTANTS: pass=$pass fail=$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
