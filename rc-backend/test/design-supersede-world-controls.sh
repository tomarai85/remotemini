#!/bin/bash
# `test/design-supersede.test.mjs` の **世界の見分け**(`designOrSkip`)が、緑にも赤にも
# なる事の確認。
#
# なぜ書くか: 2026-08-04、`tools/deploy-to-edith.sh` が edith 側の `npm test` で止まった。
#   止めたのは私のコードではなく**検査の側**で、原因は `designOrSkip` が世界を
#   「1つ上に .git が在るか」という**代理**で見分けていた事だった。edith の配備用の写しは
#   `/Users/edith/rc-staging` に置かれ、親の `/Users/edith` には 2026-08-03 の艦隊衛生作業が
#   作った `.git` が在る。代理は「repo の中」と答え、DESIGN.md は無いので赤になった。
#
#   ★そして此処が本題: あの file には**検出器**の陰性対照が5つ在るのに、
#   **世界の見分けを撃つ対照は1つも無かった**。差し替え口 `RC_DESIGN_REPO` は宣言だけ
#   されていて、repo 全体を grep しても**使う側が居ない**。つまり
#   「新しい門を足したら、まずそれを落とす手を書く」(DESIGN §2.37)が、検出器には
#   徹底されていて、見分けには一度も適用されていなかった。壊れたのは正にそちらである。
#
# 本物の木は一切触らない。`RC_DESIGN_REPO` に使い捨ての木を渡して世界を作る
# (`test/pii-controls.sh` / `test/mutation-target-controls.sh` と同じ型)。
#
# ★**10 本とも、実際に赤くする手を見てから置いた**(2026-08-04、`RC_DESIGN_SUT` に
#   壊した写しを渡して実測)。一度も赤を見ていない対照は、対照である事を証明していない。
#
#   | 壊し方                                          | 赤くなった対照 |
#   |-------------------------------------------------|----------------|
#   | 1 の代理(`.git` が1つ上に在るか)へ戻す        | 3, 7           |
#   | 子から `GIT_DIR` を落とすのをやめる             | 5              |
#   | 子から `GIT_INDEX_FILE` **だけ**落とすのをやめる | 8              |
#   | 常に「版管理下でない」と答える                  | 2, 8, 9, 10    |
#   | 常に「版管理だ」と答える                        | 3, 4, 5, 7     |
#   | 本物の木でも DESIGN.md を読まない               | 1, 6           |
#   | 非 0 を全部「写し」に丸める(旧実装)           | 9              |
#   | `HEAD` の後戻りを外す                           | 10             |
#
#   ★8 は 7 本を書いた**後**に、「全部を生き延びる変異は何か」を探して見つけた穴である
#     (詳細は 8 の直前)。門を足したら対照を書く(§2.37)の次に要るのは、
#     **対照の集合を生き延びる手を探す**事だと分かった。
#
#   ★表の 4 行目は 2026-08-04 に**一度書き間違えている**。当初は
#     「`if (idx.status === 0) return true;` を殺す」で「常に版管理下でないと答える」を
#     測ったつもりでいたが、**10 本とも緑のまま**だった —— `HEAD` の後戻り(10 が守る枝)が
#     そのまま true を返すので、其の変異は「常に false」になっていない。
#     関数の入口で `return false` に倒して測り直したら 2/8/9/10 の 4 本が赤くなった。
#     教訓: 変異は「書いた場所」でなく「**関数の出す答え**」で確かめる。
#
# 終了コードは repo の作法どおり: 0=緑 / 1=赤 / 2=測っていない。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# ★対照そのものを落とせる様にしておく。緑しか出した事の無い対照は、対照である事を
#   証明していない。差し替え先は `test/` の中に置く事(file の中の `ROOT` は
#   `import.meta.url` から出るので、外へ出すと「本物の木」の世界が作れなくなる)。
SUT="${RC_DESIGN_SUT:-$ROOT/test/design-supersede.test.mjs}"
NODE="$(command -v node || true)"
[ -z "$NODE" ] && { echo "SKIP  node が無い — 測っていない"; exit 2; }
[ -f "$SUT" ] && [ -x "$(command -v git || echo /nonexistent)" ] || { echo "SKIP  前提が無い — 測っていない"; exit 2; }

SB="$(mktemp -d /tmp/dsworld-ctl.XXXXXX)"
cleanup() { [ -n "${SB:-}" ] && [ -d "$SB" ] && /bin/rm -rf -- "$SB"; }
trap cleanup EXIT INT TERM

pass=0; fail=0
ok() { pass=$((pass+1)); echo "PASS  $1"; }
ng() { fail=$((fail+1)); echo "FAIL  $1  ($2)"; }

# 走らせて「落ちた数 / 飛ばした数」を返す。判定は数で行う —— exit code だけだと
# 「飛ばした」と「そもそも走っていない」が同じ 0 に潰れる。
run_world() { # $1=RC_DESIGN_REPO(空なら本物) $2..=前置きの環境変数
    local repo="$1"; shift
    local out
    if [ -z "$repo" ]; then
        out="$(env "$@" "$NODE" --test "$SUT" 2>&1)"
    else
        out="$(env "$@" RC_DESIGN_REPO="$repo" "$NODE" --test "$SUT" 2>&1)"
    fi
    local f s p
    f="$(printf '%s\n' "$out" | /usr/bin/sed -n 's/^# fail \([0-9][0-9]*\)$/\1/p' | /usr/bin/tail -1)"
    s="$(printf '%s\n' "$out" | /usr/bin/sed -n 's/^# skipped \([0-9][0-9]*\)$/\1/p' | /usr/bin/tail -1)"
    p="$(printf '%s\n' "$out" | /usr/bin/sed -n 's/^# pass \([0-9][0-9]*\)$/\1/p' | /usr/bin/tail -1)"
    printf '%s %s %s' "${f:--}" "${s:--}" "${p:--}"
}

# ── 世界を作る ────────────────────────────────────────────────────────────────
# A' 版管理下だが作業木の実体が無い(= 消しても赤が保たれる事の証明)
A="$SB/tracked"; mkdir -p "$A"
( cd "$A" && git init -q . && printf '# design\n' > DESIGN.md && git add DESIGN.md ) >/dev/null 2>&1
/bin/rm -f "$A/DESIGN.md"
# B  edith の配備用の写しの形: .git は在るが、此処の DESIGN.md は版管理下に無い
B="$SB/staging"; mkdir -p "$B/.git"
# C  変異走行の写しの形: どちらも無い
C="$SB/copy"; mkdir -p "$C"

# ── 1) 本物の木は今までどおり全部走る(対照が世界を壊していない事の確認)──────────
read -r f s p <<<"$(run_world "")"
if [ "$f" = "0" ] && [ "$s" = "0" ] && [ "${p:-0}" -gt 0 ]; then ok "本物の木: 全部走って緑 (pass=$p)"
else ng "本物の木: 全部走って緑" "fail=$f skipped=$s pass=$p"; fi

# ── 2) ★本体: 版管理下なのに読めなければ**赤**(fail-open していない)────────────
read -r f s p <<<"$(run_world "$A")"
if [ "${f:-0}" -gt 0 ]; then ok "版管理下で DESIGN.md が消えたら赤 (fail=$f)"
else ng "版管理下で DESIGN.md が消えたら赤" "fail=$f — **消しても緑 = 見分けが fail-open**"; fi

# ── 3) edith の配備用の写しは飛ばす(これが 2026-08-04 に配備を止めた世界)────────
read -r f s p <<<"$(run_world "$B")"
if [ "$f" = "0" ] && [ "${s:-0}" -gt 0 ]; then ok "配備用の写し(.git だけ在る)は飛ばす (skipped=$s)"
else ng "配備用の写しは飛ばす" "fail=$f skipped=$s — 配備が止まる側に戻っている"; fi

# ── 4) 変異走行の写しも飛ばす(此処を誤ると 241 件の変異が丸ごと走らなくなる)───────
read -r f s p <<<"$(run_world "$C")"
if [ "$f" = "0" ] && [ "${s:-0}" -gt 0 ]; then ok "変異走行の写しは飛ばす (skipped=$s)"
else ng "変異走行の写しは飛ばす" "fail=$f skipped=$s — 変異走行が起動しなくなる"; fi

# ── 5) 環境変数に引きずられない事。GIT_DIR が別の repo を指していると、素の temp dir が
#      「版管理下」と答える(実測)。子から GIT_* を落としていないと此処が赤くなる。────
read -r f s p <<<"$(run_world "$C" "GIT_DIR=$ROOT/../.git")"
if [ "$f" = "0" ] && [ "${s:-0}" -gt 0 ]; then ok "GIT_DIR が他所を指していても写しは写し (skipped=$s)"
else ng "GIT_DIR が他所を指していても写しは写し" "fail=$f skipped=$s — 子に GIT_* が漏れている"; fi

# ── 6) pre-commit の中でも本物は本物。git の hook は GIT_INDEX_FILE=.git/index を渡す
#      (使い捨ての repo で commit して実測)。`npm test` はその中でも走る。──────────
read -r f s p <<<"$(run_world "" "GIT_INDEX_FILE=.git/index")"
if [ "$f" = "0" ] && [ "$s" = "0" ]; then ok "pre-commit の環境でも本物の木は全部走る"
else ng "pre-commit の環境でも本物の木は全部走る" "fail=$f skipped=$s — hook の中だけ挙動が変わる"; fi

# ── 7) git が起動できない時は**写し側に倒す**。取引を明文化して固定する。
#      逆に倒すと git の無い機械で変異走行が丸ごと死ぬ —— 前科の在る方の事故。──────
read -r f s p <<<"$(run_world "$A" "PATH=/nonexistent")"
if [ "$f" = "0" ] && [ "${s:-0}" -gt 0 ]; then ok "git が起動できない時は飛ばす(取引どおり) (skipped=$s)"
else ng "git が起動できない時は飛ばす" "fail=$f skipped=$s — 取引が変わっている。設計の注釈も直す事"; fi

# ── 8) GIT_INDEX_FILE が**別の索引**を指していても、版管理下は版管理下。
#      ★此の対照は後から足した(2026-08-04)。7 本を書いた直後に「全部を生き延びる変異」を
#      探したら、**`GIT_INDEX_FILE` を落とす行だけ消す**変異が 7 本とも素通りした。
#      理由: DESIGN.md が読める世界では `TRACKED` が参照されないので、対照 6 では差が出ない。
#      差が出るのは「版管理下なのに実体が無い」世界だけである。実測:
#        `env GIT_INDEX_FILE=<空の別索引> git -C <A> ls-files --error-unmatch DESIGN.md` -> exit 1
#      = 本当は版管理下なのに「されていない」と答える。git は rebase / stash / hook で
#      一時索引を渡す事があるので、これは机上の話ではない。落としていないと
#      **本物の repo で DESIGN.md を消しても飛ばす** —— 此の門が守る当のものが抜ける。
read -r f s p <<<"$(run_world "$A" "GIT_INDEX_FILE=$A/.git/alt-index")"
if [ "${f:-0}" -gt 0 ]; then ok "GIT_INDEX_FILE が別の索引でも版管理下は版管理下 (fail=$f)"
else ng "GIT_INDEX_FILE が別の索引でも版管理下は版管理下" "fail=$f skipped=$s — 子に GIT_INDEX_FILE が漏れている = 本物の repo で fail-open"; fi

# ── 9) git が「判定できなかった」時は**赤**。壊れた索引は 128 を返すが、その 128 は
#      「repo が無い」の 128 とは別物。全部の非 0 を「写しだ」と読むと、本物の repo で
#      DESIGN.md が消えていても静かに飛ぶ。実測した stderr:
#        `fatal: .git/index: index file smaller than expected`
D="$SB/broken"; /bin/mkdir -p "$D"
( cd "$D" && git init -q . && printf '# design\n' > DESIGN.md && git add DESIGN.md ) >/dev/null 2>&1
/bin/rm -f "$D/DESIGN.md"
printf 'GARBAGE-NOT-AN-INDEX' > "$D/.git/index"
read -r f s p <<<"$(run_world "$D")"
if [ "${f:-0}" -gt 0 ]; then ok "索引が壊れていて判定できない時は赤 (fail=$f)"
else ng "索引が壊れていて判定できない時は赤" "fail=$f skipped=$s — 判らない時に飛ばしている = fail-open"; fi

# ── 10) `git rm --cached`(staged deletion)は索引から消えるが、版管理から外した訳では
#       ない。索引だけを見ていると本物の repo が静かに飛ぶ。HEAD も見る事で赤が保たれる。
E="$SB/staged-del"; /bin/mkdir -p "$E"
( cd "$E" && git init -q -b main . && printf '# design\n' > DESIGN.md && git add DESIGN.md \
    && git -c user.email=c@c -c user.name=c commit -qm init \
    && git rm -q --cached DESIGN.md ) >/dev/null 2>&1
/bin/rm -f "$E/DESIGN.md"
read -r f s p <<<"$(run_world "$E")"
if [ "${f:-0}" -gt 0 ]; then ok "索引から外しただけ(HEAD に在る)なら赤 (fail=$f)"
else ng "索引から外しただけ(HEAD に在る)なら赤" "fail=$f skipped=$s — staged deletion で静かに飛んでいる"; fi

echo "----"
echo "design-supersede world controls: pass=$pass fail=$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
