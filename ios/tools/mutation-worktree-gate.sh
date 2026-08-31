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
DEBT="
account-ui-control.sh
bar-material-control.sh
conversation-ui-control.sh
inflight-sentence-control.sh
list-return-refresh-control.sh
signout-notice-control.sh
update-notice-ui-control.sh
"
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
#   3回目(今): **書き換え先の変数を追う**。`VAR="…Sources/….swift"` を集め、
#          其の変数が `sed -i` / `perl -i` の対象や `cp` の宛先、`>` の先に出るかを見る。
#          復元の仕方(git か写しか)に依存しない = 主犯を取り零さない。
#   ★註記と `echo` の行は落としてから当てる(false positive も欠陥。
#     `mutation-residue-controls.sh` の N10b が同じ結論を先に書いている)。
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
    vars="$(printf '%s\n' "$body" | grep -oE '^[[:space:]]*[A-Za-z_][A-Za-z_0-9]*="[^"]*Sources/[^"]*"' \
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
        fi
        # ★literal を先に組み、**固定文字列**で行を絞る。正規表現に変数名を織り込むと
        #   `\$$v` が後方参照に化けて grep が全滅する(2026-08-30 実測)。
        tgt="\"\$$v\""
        hits="$(printf '%s\n' "$body" | grep -F -- "$tgt")"
        [ -n "$hits" ] || continue
        printf '%s\n' "$hits" | grep -qE '(sed|perl|ed)[[:space:]]+-i' && return 0
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
    printf '%s\n' "$body" | grep -qE '(WORK=|mkcopy|cp -R|rsync)' && return 1
    printf '%s\n' "$body" | grep -qE '(sed|perl|ed)[[:space:]]+-i' && return 0
    printf '%s\n' "$body" | grep -qE 'python3?[[:space:]]+-([[:space:]]|$)|python3?[[:space:]]+-c' && return 0
    return 1
}

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
for o in $offenders; do in_debt "$o" || new="$new $o"; done
if [ -n "${new// /}" ]; then
    echo "mutation-worktree-gate: ★作業中の木を直接書き換える対照が**増えた**:$new" >&2
    echo "  変異は使い捨ての worktree(`git worktree add`)か、mktemp した写しの上で撃つ事。" >&2
    echo "  木に残った変異は、単体も UI も緑のまま Tom の電話へ載る(CF-12 で3分前に気付いた)。" >&2
    fail=1
fi

# (b) 借金の側が「もう書き換えていない」のに宣言が残っている = 宣言を消せる
#     ★之を赤にする。放っておくと宣言が実態から離れ、門が何も守らなくなる。
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
    cnt="$(printf '%s\n' $offenders | grep -c . || echo 0)"
    echo "mutation-worktree-gate: 増えていない($n_scanned 本を走査 / 借金 $cnt 本)"
    echo "  ★此の門は問題を解決しない。増えるのを止めるだけ。"
    echo "  借金を減らす = 其の対照を worktree か写しの上で撃つ様に直し、宣言から消す。"
fi
exit "$fail"
