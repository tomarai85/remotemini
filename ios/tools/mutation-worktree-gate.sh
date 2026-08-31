#!/bin/bash
# mutation-worktree-gate.sh — 変異対照が**作業中の木**(`ios/Sources`)を直接書き換える事を、
# これ以上増やさない為の門。
#
# ── なぜ要るか(CF-12、2026-08-30 に**2回**踏んだ)──────────────────────────
# 変異対照は `ios/Sources/**` をその場で書き換えて測り、`trap` で戻す。走行が殺されると
# trap は走らず、変異が木に残る。同日の実測:
#   (1) 全対照の掃引を止めた直後、3本の変異が木に残っていた
#       (`ConversationView` の全ボタンが一斉に回る / `AccountBar` の口座が永久に出ない /
#        `SettingsView` の一覧が空になる)。**焼く3分前**に `git status` で気付いた ——
#       単体も UI も、その間ずっと緑だった。
#   (2) 私が対照の走行中に `ios/Sources` を編集し、其の走行の結果を捨てる羽目になった。
#
# CF-12 で足したのは**検知器**(`adhoc-ota.sh` の汚れ検査 / `mutation-residue-check.sh`)で、
# **残骸を生む設計そのもの**は手付かずだった。之は其の設計を止める門。
#
# ── 何を主張するか(正直に)────────────────────────────────────────────────
# ★此の門は**問題を解決しない**。増えるのを止めるだけ。
#   既存の 10 本は宣言した「借金」として通す —— 全部を worktree へ移すのは
#   1本ずつ検証しながらの数時間仕事で、其れは別の作業。
#   門が保証するのは2つ:
#     (a) **新しい**対照が木を直接書き換えたら赤くなる
#     (b) 借金の数は**減る方向にしか動かせない**(増やそうとすると赤くなる)
#   借金が 0 になった日に、此の門は「木を書き換える対照は1本も無い」を意味する様になる。
#
# ── ★此の門を作って見えた別の穴(2026-08-30、未着手として記録)──────────────
#   `mutation-residue-check.sh` は変異対照を「**`git checkout --` で戻す台本**」で数える。
#   此の門は書き換え先の変数で数える。実測の食い違い:
#     残骸検知器 = **4 本** / 此の門 = **10 本**
#   差の 6 本は**写しから戻す**台本で、残骸検知器は其の書き換え先を一度も走査していない。
#   = 其の 6 本が殺されて木に変異を残しても、**検知器は「残骸なし」と言う**。
#   CF-12 で残骸が実際に残った 3 file のうち `ConversationView` と `SettingsView` は
#   其の側に居る。直すなら検知器の数え方を此の門と揃える —— 別の作業として残す。
#
# ── 使い方 ──────────────────────────────────────────────────────────────────
#   bash ios/tools/mutation-worktree-gate.sh          # 判定
#   bash ios/tools/mutation-worktree-gate.sh --list   # 今の借金を並べる
#
# 走らせる物: `staged-controls-gate` が `controls-for:` で拾う対照
#   (`mutation-worktree-gate-controls.sh`)と、`mutation-residue-check.sh` が
#   「誰が変異対照か」を問う為に呼ぶ `--is-mutator`。
#   ★`no-operator:` の印は 2026-08-30 に外した —— 呼ぶ物が出来た後も印が残ると、
#     **走っている物を走っていないと記録する**事になり、次に読む人が判断を誤る
#     (`tunnel-observer.sh` が同じ理由で同じ印を外している)。
#
# 終了コード: 0=増えていない / 1=**増えた**(名前を出す) / 2=測れない
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"     # = ios/tools
IOS="$(cd "$HERE/.." && pwd)"
ROOT="$(cd "$IOS/.." && pwd)"

# 走査する場所。★`.harness` も入れる —— sprint の対照も同じ書き方をしている。
SCAN_DIRS="${RC_MWG_SCAN:-$HERE $ROOT/.harness}"

# ── 借金の宣言 ──────────────────────────────────────────────────────────────
# ★**名前を書く**。数だけだと、1本直して1本足した日に気付けない。
#   ここから消す時は、其の対照が本当に木を触らなくなった事を確かめてから。
#   ★足すな。足したくなったら、其れは此の門が止めるべき変更。
#   ★2026-08-30 に 10 → 7 へ減った。減った3本はどれも**元から写しの上で撃っていた** ——
#     借金が減ったのではなく、私の検出器が過大に数えていた。
#     `dod-sprint-6.5`(第二の木)/ `dod-sprint-4`(`$SCRATCH`)/
#     `initial-load-narration`(`$MUT`)。借金の数が実態より多いと、
#     本当に減った日に気付けない。
#   ★2026-08-30 の経緯: `dod-sprint-6.5-controls.sh` は
#     `mktemp -d` で第二の木を作って其処を撃っており、作業中の木は触っていない ——
#     **借金 9 本を移す時の、此の repo に既に在る手本**。
# ★検査の継ぎ目(2026-08-30)。借金が 0 になった日、G6(宣言が実態より古い)は
#   **測れる宣言が無くなって**赤くなった。宣言を差し替えられないと、
#   0 に到達した瞬間に其の枝が永久に測れなくなる。
#   `-`(コロン無し)なので、明示的な空も尊重する。
DEBT="${RC_MWG_DEBT-
dod-sprint-6-controls.sh
}"
# ── 借金の理由(消す時は此処も消す)────────────────────────────────────────
#   dod-sprint-6-controls.sh
#     2026-08-31 に**新しく見える様になった**物で、増えた訳ではない。3 つの取り零しが
#     重なって、門は「0 本」と言いながら **本物の木が POST → PUT に書き換えられている
#     最中**だった:
#       1. 変異を `MUTATIONS+=("名前|$ICLIENT|s/…/…/")` と**文字列に畳んで**渡すので、
#          検出器が探す `"$ICLIENT"`(引用符つき)に当たらない
#       2. 其の埋め込みを「引用符つきが無い時だけ」探していたが、4 変数はどれも
#          退避の行で引用符つきを**1つだけ**持つので、埋め込みの枝に一度も入らない
#       3. 適用は `perl -0777 -pi` で、道具の型が `-i` 単独しか見ていなかった
#     ★移行は別途(20 本超の変異を持つ DoD 台本で、走行が長い)。**数えられる形**にして
#       置くのが此の一覧の役目 —— 見えない穴より、見える借金の方が良い。
#     ★復元は正しく働いている(実測: 走行中に変異を観測し、終了後に木は綺麗)。
#       危険なのは「殺された時に残る」形で、其れは `mutation-residue-check.sh` が見る。
# ── 直接書き込みの検出 ──────────────────────────────────────────────────────
# ★**その場で書き換える**書き方だけを見る。`git checkout --`(戻す側)や
#   `grep`(読む側)は当てない —— 復元を持つ事は美徳であって欠陥ではない。
# ★書き換え先は**変数**で渡される(`sed -i '' '<式>' "$VM"`)ので、`sed` の行に
#   `Sources` の path は出ない。初版は其れを見に行って **0 本**を返した ——
#   検出器が何も検出しない事に自分で気付けたのは、実物を1本開いたから。
#
# 使う信号は此の repo が既に実証している物:「**作業中の木を `git checkout --` で戻す**」
# = 其の木を書き換えた証拠。`mutation-residue-check.sh` が同じ信号で変異対照を数えている。
# ★何を信号にするか(2026-08-30、3回書き直した)。
#   1回目: `sed -i` の行に `Sources` の path が在るか → **0 本**。書き換え先は変数で渡る。
#   2回目: `git checkout --` で戻すか → 註記の中の文まで当たり、**もう木を触らない台本**まで
#          借金に数えた。更に、**写しから戻す**台本(`conversation-ui` / `signout-notice`)を
#          丸ごと取り零した —— 其れらは木を書き換える当の主犯。
#   5回目(2026-08-30): 見るのを `Sources/` から **`Sources|Tests|UITests`** へ広げた。
#     `signout-notice-control.sh` が `$IOS/Tests/…` を書き換えていたのを、移行の最中に
#     取り零して初めて気付いた —— **検査 file を書き換える対照も、殺されれば
#     作業中の木に変異を残す**。門は其れを一度も見ていなかった。
#   3回目: **書き換え先の変数を追う**。`VAR="…Sources/….swift"` を集め、
#          其の変数が `sed -i` / `perl -i` の対象や `cp` の宛先、`>` の先に出るかを見る。
#          復元の仕方(git か写しか)に依存しない = 主犯を取り零さない。
#   ★註記と `echo` の行は落としてから当てる(false positive も欠陥。
#     `mutation-residue-controls.sh` の N10b が同じ結論を先に書いている)。
# ★「その場で書き換える道具」の型。**旗を1つの綴りに決め打たない**(2026-08-31 実測)。
#   `.harness/dod-sprint-6-controls.sh` は `perl -0777 -pi -e "$expr" "$file"` で撃つ ——
#   `-i` 単独しか見ない型では当たらず、**本物の木を POST→PUT に書き換えている最中に
#   門は「0 本」と言っていた**。旗の綴りは書く人の自由なので、i で終わる旗を許す。
INPLACE_RE='(sed|perl|ed)[[:space:]]+([^|;&]*[[:space:]])?-[a-zA-Z0-9]*i([[:space:]]|\.|$)'

writes_live_tree() {  # writes_live_tree <file> → 0=書き換えている
    local body vars v tgt hits
    # ★**別の木を作る台本は最初に外す**(2026-08-30、実測で判った)。
    #   `.harness/dod-sprint-6.5-controls.sh` は `git worktree add` で第二の木を作り、
    #   `$WT/ios/Sources/…` を書き換える —— 作業中の木は1バイトも触らない。
    #   ★之は**此の repo に既に在る、正しい形の実例**。借金 10 本を移す時の手本になる。
    #   (`WORK=` / `mkcopy` / `cp -R` / `rsync` = 写しを作る形も同じ理由で外す)
    grep -qE 'git worktree add|^[[:space:]]*WT=' "$1" 2>/dev/null && return 1
    body="$(grep -v '^[[:space:]]*#' "$1" 2>/dev/null | grep -v -E '(echo|printf)[[:space:]]')"
    # `<NAME>="…Sources/….swift…"` の左辺を集める。
    # ★**file の名前で終わる物だけ**を経路と読む(2026-08-31、実測で踏んだ)。
    #   `TEST_ID="RemoteMiniUITests/ConversationUITests/testOpening…"` の様な
    #   **検査の識別子**は `UITests/` を含むが file ではない —— 拡張子を要求しないと、
    #   識別子を持っているだけの台本を「木を書き換えている」と数える(実際に数えた)。
    #   守る側を緩めてはいない: 木の中の変異対象は必ず拡張子を持つ。
    vars="$(printf '%s\n' "$body" | grep -oE '^[[:space:]]*[A-Za-z_][A-Za-z_0-9]*="[^"]*(Sources|Tests|UITests)/[^"]*\.(swift|plist|yml|yaml|json|xcassets)"' \
            | sed 's/^[[:space:]]*//; s/=.*//' | sort -u)"
    [ -n "$vars" ] || return 1
    for v in $vars; do
        # ★**写しを指す宣言は最初に外す**(2026-08-30、計画者の実測で判った)。
        #   `MET="$SCRATCH/ios/Sources/…"` / `MUT_RULE="$MUT/Sources/…"` の様に、
        #   根が `mktemp -d` の変数なら其れは作業中の木ではない。
        #   ★初版は此の判定を**間接参照の枝にだけ**置いていたので、直接の枝が先に
        #     `return 0` して `dod-sprint-4-controls.sh` と
        #     `initial-load-narration-control.sh` を借金に数えていた ——
        #     借金の数が実態より 2 本多いと、減った時に気付けない。
        root="$(printf '%s\n' "$body" | grep -E "^[[:space:]]*$v=" | head -1 \
                | sed 's/^[^=]*="//; s/".*//' | grep -oE '^\$[A-Za-z_][A-Za-z_0-9]*' | tr -d '$')"
        if [ -n "$root" ] && [ "$root" != "IOS" ] && [ "$root" != "ROOT" ]; then
            printf '%s\n' "$body" | grep -E "^[[:space:]]*$root=" | grep -qE 'mktemp|TMPDIR' && continue
            # ★共通の砂場(`mutation-sandbox.sh`)を使う台本。根の変数は其の file に在るので
            #   此の台本の中を幾ら探しても `mktemp` は出て来ない。**source している事**を
            #   信号にする —— 名前だけで許すと、`MS_TREE=` を自分で定義して素通りできる。
            case "$root" in
                MS_TREE|MS_ROOT)
                    printf '%s\n' "$body" | grep -qE '\.[[:space:]]+.*mutation-sandbox\.sh|source[[:space:]]+.*mutation-sandbox\.sh' \
                        && ! printf '%s\n' "$body" | grep -qE "^[[:space:]]*$root=" \
                        && continue ;;
            esac
        fi
        # ★literal を先に組み、**固定文字列**で行を絞る。正規表現に変数名を織り込むと
        #   `\$$v` が後方参照に化けて grep が全滅する(2026-08-30 実測)。
        tgt="\"\$$v\""
        hits="$(printf '%s\n' "$body" | grep -F -- "$tgt")"
        # ★**文字列に埋めて渡す形**も当てる(2026-08-31、実測で取り零した)。
        #   `.harness/dod-sprint-6-controls.sh` は変異を
        #   `MUTATIONS+=("名前|$ICLIENT|s/…/…/|…")` と1本の文字列に畳んで渡すので、
        #   引用符つきの `"$ICLIENT"` は一度も現れない —— 本物の木を
        #   `POST → PUT` に書き換えている最中に、門は「0 本」と言っていた。
        # ★埋め込みは**引用符つきの有無と独立に**見る(2026-08-31、二度目の取り零し)。
        #   最初は「引用符つきが無い時だけ」埋め込みを探したが、dod の 4 変数は
        #   どれも引用符つきの用例を**1つだけ**持っている(退避や複製の行)。
        #   其の1行で `hits` が埋まり、埋め込みの枝に一度も入らなかった。
        #   片方が在るからもう片方を見ない、は「多い方を見落とす」形。
        hits_e="$(printf '%s\n' "$body" | grep -F -- "|\$$v|")"
        [ -n "$hits$hits_e" ] || continue
        embedded=0; [ -n "$hits_e" ] && embedded=1
        # ★埋め込み形は**行の中に道具が無い**。`MUTATIONS+=("名前|$ICLIENT|s/…/…/")` は
        #   置換の式を運ぶだけで、`sed -i` を撃つのは其れを読む別の loop。だから
        #   此の形だけは**台本のどこかに其の場で書き換える道具が在るか**で判ずる ——
        #   宣言が在り、埋め込みで渡され、道具が在るなら、書き換え先は其の宣言しか無い。
        #   (下の間接参照の枝と同じ理屈。あちらは `WORK=` の一括除外に阻まれて届かない)
        if [ "$embedded" = 1 ]; then
            printf '%s\n' "$body" | grep -qE "$INPLACE_RE" && return 0
        fi
        printf '%s\n' "$hits" | grep -qE "$INPLACE_RE" && return 0
        # ★`cp`/`mv` は**宛先が其の変数の時だけ**書き込み。`cp "$VM" "$WORK/a"` は
        #   変数から**読んで**別所へ写す行で、木は触らない —— 之を書き込みと数えると
        #   写しの上で撃つ正しい台本まで借金になる(2026-08-30、G2 が掴んだ)。
        #   宛先 = 行の末尾に其の literal が在る事で見る。
        printf '%s\n' "$hits" | grep -E '^[[:space:]]*(cp|mv|install)[[:space:]]' \
            | grep -qF -- "$tgt" \
            && printf '%s\n' "$hits" | grep -E '^[[:space:]]*(cp|mv|install)[[:space:]]' \
               | sed 's/[[:space:]]*$//' | grep -q -- "$(printf '%s' "$tgt" | sed 's/[][\\.*^$/]/\\&/g')\$" \
            && return 0
        printf '%s\n' "$hits" | grep -qE '>[[:space:]]*"\$' && return 0
        printf '%s\n' "$hits" | grep -qE '(python3?|ruby)[[:space:]]' && return 0
    done
    # ★**間接参照**も当てる(2026-08-30、自分の対照を取り零して気付いた)。
    #   `run_mut "名前" "$MODELS" …` の様に変数を関数へ渡すと、書き換えの行に
    #   変数名は出ない。宣言が在って、其の台本のどこかで「その場で書き換える」道具を
    #   使っているなら、書き換え先は其の宣言しか無い。
    #   ★写しの上で撃つ台本(`mutation-deferral-control.sh` の `mkcopy`)は、
    #     `VAR="…Sources/….swift"` の宣言を持たないので当たらない —— 実測で確認済み。
    # ★但し**写しを作る台本は外す**。`fixture-label-parity-controls.sh` は
    #   `$WORK/` の下(複製)を撃つので、宣言と道具が同居していても木は触らない。
    #   間接参照を当てる枝は広いので、此処で狭めないと**正しい台本まで借金に数える**。
    # ★共通の砂場を source する台本も此処で外す。**per-var の除外だけでは足りない** ——
    #   下の間接参照の枝が `sed -i` を見て先に `return 0` するので、
    #   除外が素通りする(2026-08-30、対照 G9 が掴んだ。実物の対照は偶々 `WORK=` を
    #   持っていた為に**別の理由で**外れており、砂場の判定は一度も発火していなかった)。
    printf '%s\n' "$body" | grep -qE '(\.|source)[[:space:]]+.*mutation-sandbox\.sh' \
        && ! printf '%s\n' "$body" | grep -qE '^[[:space:]]*MS_(TREE|ROOT)=' && return 1
    printf '%s\n' "$body" | grep -qE '(WORK=|mkcopy|cp -R|rsync)' && return 1
    printf '%s\n' "$body" | grep -qE "$INPLACE_RE" && return 0
    printf '%s\n' "$body" | grep -qE 'python3?[[:space:]]+-([[:space:]]|$)|python3?[[:space:]]+-c' && return 0
    return 1
}

# ── 触るのが不可避な物(借金とは別枠)──────────────────────────────────────
# ★借金 = 「砂場へ移すべきだがまだ移していない」。此処は「**移せない**」——
#   移すと測る物が消える。理由を書かせ、毎回表示させる事で抜け道にしない。
#   ★1本増やす前に問う事: 本当に本物の木でなければ測れないのか。
#     「面倒だから」は理由にならない。移行の 7 本はどれも移せた。
MUST_TOUCH="mutation-deferral-control.sh"
must_touch_reason() {
    case "$1" in
        mutation-deferral-control.sh)
            printf '%s' "digest が**本物の木**の file 群から出ているかを測る。砂場に探りを置くと digest は動かず、検査が何も測らなくなる(一時 file を置いて即 rm する形)" ;;
        *) printf '' ;;
    esac
}
in_must_touch() { case " $(printf '%s' "$MUST_TOUCH" | tr '\n' ' ') " in *" $1 "*) return 0 ;; esac; return 1; }

in_debt() { case " $(printf '%s' "$DEBT" | tr '\n' ' ') " in *" $1 "*) return 0 ;; esac; return 1; }

offenders=""; n_scanned=0
for d in $SCAN_DIRS; do
    [ -d "$d" ] || continue
    for f in "$d"/*control*.sh; do
        [ -f "$f" ] || continue
        n_scanned=$((n_scanned + 1))
        writes_live_tree "$f" && offenders="$offenders $(basename "$f")"
    done
done

if [ "$n_scanned" -eq 0 ]; then
    echo "mutation-worktree-gate: 走査対象が 0 本 = 測定不成立(綴りか置き場を疑う事)" >&2
    exit 2
fi

# ★1本だけ問う口(2026-08-30、CF-21)。`mutation-residue-check.sh` が此処へ委ねる為に在る。
#   規則を2箇所に書くと、片方だけ直る日が来る —— 実際、検知器は 4 本、門は 10 本と
#   食い違ったまま動いていた。判定は此の file にだけ在る。
if [ "${1:-}" = "--is-mutator" ]; then
    [ -n "${2:-}" ] && [ -f "$2" ] || exit 2
    writes_live_tree "$2" && exit 0 || exit 1
fi

if [ "${1:-}" = "--list" ]; then
    echo "== 今 木を直接書き換えている対照($n_scanned 本を走査)=="
    for o in $offenders; do
        in_debt "$o" && echo "  借金 $o" || echo "  ★未宣言 $o"
    done
    echo "== 宣言だけ在って もう書き換えていない(消せる)=="
    for dbt in $DEBT; do
        case " $offenders " in *" $dbt "*) ;; *) echo "  消せる $dbt" ;; esac
    done
    exit 0
fi

fail=0

# (a) 未宣言の新顔 = **増えた**
new=""
for o in $offenders; do
    in_debt "$o" && continue
    in_must_touch "$o" && continue
    new="$new $o"
done
if [ -n "${new// /}" ]; then
    echo "mutation-worktree-gate: ★作業中の木を直接書き換える対照が**増えた**:$new" >&2
    echo "  変異は使い捨ての worktree(`git worktree add`)か、mktemp した写しの上で撃つ事。" >&2
    echo "  木に残った変異は、単体も UI も緑のまま Tom の電話へ載る(CF-12 で3分前に気付いた)。" >&2
    fail=1
fi

# (b) 借金の側が「もう書き換えていない」のに宣言が残っている = 宣言を消せる
#     ★之を赤にする。放っておくと宣言が実態から離れ、門が何も守らなくなる。
# 触るのが不可避な物は、**毎回 理由ごと出す**。黙って許すと抜け道になる。
for mt in $MUST_TOUCH; do
    case " $offenders " in
        *" $mt "*) echo "  触るのが不可避: $mt — $(must_touch_reason "$mt")" ;;
        *) echo "mutation-worktree-gate: 「不可避」に挙げた $mt が、もう木を触っていない。一覧から消す事" >&2
           fail=1 ;;
    esac
done

stale=""
for dbt in $DEBT; do
    case " $offenders " in *" $dbt "*) ;; *) stale="$stale $dbt" ;; esac
done
if [ -n "${stale// /}" ]; then
    echo "mutation-worktree-gate: 宣言が実態より古い(もう書き換えていない):$stale" >&2
    echo "  借金の一覧から消す事。宣言が実態から離れると、門は何も守らなくなる。" >&2
    fail=1
fi

if [ "$fail" -eq 0 ]; then
    # ★`grep -c .` は 0 件で**非ゼロ終了**するので `|| echo 0` が走り、"0\n0" になる
    #   (2026-08-30、借金が 0 になって初めて出た。0 を一度も通っていなかった)。
    # ★「不可避」は借金に数えない。数えると 0 に到達できず、
    #   「移行が終わった」を言えないまま門の文面が永久に途中のままになる。
    cnt=0
    for o in $offenders; do in_must_touch "$o" || cnt=$((cnt + 1)); done
    if [ "$cnt" -eq 0 ]; then
        # ★借金が 0 になった瞬間、此の門の意味が変わる ——
        #   「増えていない」から「**作業中の木を書き換える対照は1本も無い**」へ。
        #   CF-12(殺された掃引が3本の変異を残し、焼く3分前に気付いた)の再発路が閉じた。
        echo "mutation-worktree-gate: ★借金 0 —— **作業中の木を書き換える変異対照は1本も無い**"
        echo "  ($n_scanned 本を走査)。殺された走行が**変異**を木に残す道が閉じた。"
        echo "  ★但し『触るのが不可避』の一覧は別(上に理由ごと出ている)。0 が意味するのは"
        echo "    「移行すべき対照は残っていない」であって「誰も木に触らない」ではない。"
        echo "  ★足そうとしたら此の門が止める。止まったら砂場(ios/tools/mutation-sandbox.sh)を使う事。"
    else
        echo "mutation-worktree-gate: 増えていない($n_scanned 本を走査 / 借金 $cnt 本)"
        echo "  ★此の門は問題を解決しない。増えるのを止めるだけ。"
        echo "  借金を減らす = 其の対照を砂場か写しの上で撃つ様に直し、宣言から消す。"
    fi
fi
exit "$fail"
