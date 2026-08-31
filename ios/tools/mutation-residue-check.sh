#!/bin/bash
# mutation-residue-check.sh — 殺された変異走行が木に残した変異を、**何もビルドせずに**
# 名指しして、1コマンドで戻す。
#
# ── なぜ要るか(2026-08-30、実際に配る寸前まで行った)──────────────────────
# 変異対照は `ios/Sources/**` を**その場で書き換えて**測り、`trap` で戻す。走行が
# 殺されると trap は走らず、変異が木に残る。同日、全対照の掃引を止めた直後に
# 実際に残っていた:
#
#   ConversationView.swift   `inFlight == key` -> `inFlight != nil`   (全ボタンが一斉に回る)
#   AccountBar.swift         `.task { await load() }` -> `.task { }`  (口座が永久に出ない)
#   SettingsView.swift       `ForEach(state.accounts)` -> `…filter{}`
#
# 焼く直前に `git status` を見て気付いた。**気付かなければ其の版が Tom の電話に入っていた。**
# 気付く仕掛けは当時「次に同じ対照を回した時」だけで(`account-ui-control.sh` の
# `require_clean_tree`)、焼く側も、人も、見る物が無かった。
#
# ── なぜ `git status` で足りないか ────────────────────────────────────────
# `git status` は**意図した編集と変異の残骸を区別しない**。作業中の木では常に何か出る。
# 此処は「**変異対照が自分で書き換えると宣言している file**」だけに絞る ——
# その一覧は既に各対照の `REL_TARGETS=` に在る。新しい台帳は作らない
# (作れば、対照が file を1本足した日に台帳だけ古くなる)。
#
# ★見るのは `git diff --name-only`(**索引との差**)で `git status --porcelain` ではない。
#   復元先が索引なので、staged なだけの変更は「復元元」であって汚れではない ——
#   `account-ui-control.sh` が 2026-08-12 に同じ結論へ到達して註記に残している。
#   `git status` を使うと、commit 直前(全部 staged)に全部が汚れに見える。
#
# 使い方:
#   bash ios/tools/mutation-residue-check.sh            # 名指しするだけ
#   bash ios/tools/mutation-residue-check.sh --restore  # 索引の版へ戻す
#   RC_IOS_INFLIGHT=<tsv> bash …                        # 明示の対(検査の継ぎ目/退避が在る時)
#
# `RC_IOS_INFLIGHT` = `<書き換えられた file>\t<退避>` の TSV。git を要らない経路で、
# 対照が此の道具自身を測れる様にする為の口でもある。
#
# 終了コード: 0=残骸なし / 1=**残骸あり**(名前を出す) / 2=測れない
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # = ios/
ROOT="$(cd "$HERE/.." && pwd)"                            # = repo 根
RESTORE=0
[ "${1:-}" = "--restore" ] && RESTORE=1

# ── 経路A: 明示の対が渡された時 ────────────────────────────────────────────
if [ -n "${RC_IOS_INFLIGHT:-}" ]; then
    [ -f "$RC_IOS_INFLIGHT" ] || { echo "mutation-residue: $RC_IOS_INFLIGHT が無い = 測定不成立" >&2; exit 2; }
    found=0
    while IFS=$'\t' read -r target snap; do
        [ -n "${target:-}" ] && [ -n "${snap:-}" ] || continue
        [ -f "$target" ] && [ -f "$snap" ] || continue
        if ! cmp -s "$target" "$snap"; then
            found=1
            echo "  残骸 $target"
            [ "$RESTORE" -eq 1 ] && { cp -f "$snap" "$target" && echo "    戻した(退避 $snap)"; }
        fi
    done < "$RC_IOS_INFLIGHT"
    if [ "$found" -eq 0 ]; then echo "mutation-residue: 残骸なし(明示の対)"; exit 0; fi
    # ★終了コードの意味は**モードで変える**。検知だけの時は「残骸が在ったか」、
    #   `--restore` の時は「戻せたか」。
    #   初版は戻した後も 1 を返していた(「残骸が在ったのは事実で、戻した事が消さない」)。
    #   それは文面の仕事で、終了コードの仕事ではない —— 修理の経路が常に失敗を返す道具は、
    #   鎖に繋げず、いずれ使われなくなる。事実は下の行が残す。
    echo "mutation-residue: ★残骸が在った(明示の対)"
    [ "$RESTORE" -eq 1 ] && { echo "  (戻し済み。此の走行が残骸を見た事は上の行が記録)"; exit 0; }
    exit 1
fi

# ── 経路B: 対照の宣言から集める(本来の使い方)─────────────────────────────
git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    echo "mutation-residue: git repo ではない = 測定不成立" >&2; exit 2; }

# 各対照が**自分が書き換える file** を宣言している行を集める。
#
# ★宣言の綴りは1つではない(2026-08-30 実測)。`account-ui-control.sh` は `REL_TARGETS=` だが、
#   他は `VM=` / `LV=` / `AS=` と**それぞれ違う名前**で `"$IOS/Sources/....swift"` を持つ。
#   `REL_TARGETS=` だけを見た初版は **5 本中 1 本**しか拾えず、他の対照の残骸を
#   「綺麗」と報告する = 此の道具が防ぐ筈の物を、此の道具自身が作っていた。
#
# ★だから拾い方を広げた上で、**拾えなかった対照を数える**。
#   「変異させる対照」= 復元の為に `git checkout --` を持つ台本、で数える(自己申告)。
#   拾えた数がそれに足りなければ、緑を出さず**測定不成立**にする ——
#   沈黙する穴は、声を出す穴に変えなければ穴のままになる。
mutators=0; covered=0; targets=""; uncovered=""
for f in "$HERE"/tools/*control*.sh "$ROOT"/.harness/*controls.sh; do
    [ -f "$f" ] || continue
    # ★**註記と実行を分ける**(2026-08-30)。`git checkout --` は「戻し方を人に伝える」
    #   文としても書かれる。註記で数えると、木を一度も触らない台本まで「変異対照」に
    #   数え、其れが宣言を持たない事を「拾い方が壊れている」と読んで**測定不成立**にする
    #   —— 実際に `mutation-worktree-gate-controls.sh`(其の話題を説明した file)で
    #   起きた。此の file の対照 N10b は同じ結論を先に書いている。
    # ★数え方を **`mutation-worktree-gate.sh` と揃える**(2026-08-30、CF-21)。
    #   `git checkout --` を持つ事だけで数えていた版は **4 本**しか拾わなかった。
    #   門は書き換え先の変数で数えて **10 本**。差の 6 本は**写しから戻す**台本で、
    #   此の検知器は其の書き換え先を一度も走査していなかった ——
    #   つまり其の 6 本が殺されて木に変異を残しても「残骸なし」と報告していた。
    #   CF-12 で実際に残った 3 file のうち `ConversationView` と `SettingsView` が其の側。
    #   判定そのものは門に委ねる(同じ規則が2箇所に在ると、片方だけ直る日が来る)。
    # ★`bash` で呼ぶ。直接実行にすると実行権が落ちた日に **126 で全部弾かれ**、
    #   此処が「0 本 = 測定不成立」になる(2026-08-30 に実際に踏んだ。
    #   黙って緑にならなかったのは fail-closed が効いた証拠だが、原因は判りにくい)。
    #   ★但し門の判定**だけ**にはしない。門は「宣言が読めるか」で変異対照かを決めるので、
    #     委譲一本にすると「**変異するが何を触るか読めない**」台本が
    #     「変異対照ではない」に化け、此の file の C3 が守っていた状態が消える
    #     (2026-08-30 実測で発覚。安全側の性質を1つ失う所だった)。
    #     だから**和集合**にする: 門が挙げる物 + 実行される `git checkout --` を持つ物。
    #     前者が写しから戻す 6 本を拾い、後者が「読めない宣言」の見張りを残す。
    if ! bash "$HERE/tools/mutation-worktree-gate.sh" --is-mutator "$f" >/dev/null 2>&1; then
        grep -v '^[[:space:]]*#' "$f" 2>/dev/null | grep -v -E '(echo|printf)[[:space:]]' \
            | grep -q 'git checkout --' || continue
    fi
    mutators=$((mutators + 1))
    # `<なんらかの名前>="…Sources/….swift…"` の右辺を集め、**repo 根からの相対**へ直す。
    # ★sed の連鎖は使わない(2026-08-30、書いて壊した)。`#` を区切りに `$` や `\` を
    #   混ぜると綴りが読めなくなり、壊れた時に**何が抜けたかが出力に出ない**。
    #   shell の展開で1本ずつ潰す方が、読めるし、抜けたら下の判定に当たる。
    raw="$(grep -hoE '^[A-Za-z_]+="[^"]*Sources/[^"]*"' "$f" 2>/dev/null \
           | sed 's/^[A-Za-z_]*="//' | sed 's/"$//' | tr ' ' '\n' | grep -E '\.swift$' || true)"
    got=""
    for t in $raw; do
        case "$t" in
            '$IOS/'*)  t="ios/${t#\$IOS/}" ;;
            '$ROOT/'*) t="${t#\$ROOT/}" ;;
            "$HERE"/*) t="ios/${t#$HERE/}" ;;
            "$ROOT"/*) t="${t#$ROOT/}" ;;
        esac
        got="$got $t"
    done
    if [ -n "${got// /}" ]; then
        covered=$((covered + 1))
        targets="$targets $got"
    else
        uncovered="$uncovered $(basename "$f")"
    fi
done

if [ "$mutators" -eq 0 ]; then
    # ★0 本を「残骸なし」と読ませない。綴りが変わった時に此処が黙って緑になる。
    echo "mutation-residue: 木を書き換える対照が 0 本 = 測定不成立(綴りを疑う事)" >&2
    exit 2
fi
if [ "$covered" -ne "$mutators" ]; then
    echo "mutation-residue: 宣言を読めない対照が在る = **測定不成立**($covered/$mutators)" >&2
    echo "  読めない:$uncovered" >&2
    echo "  ★此処で緑を出すと、その対照の残骸が「綺麗」として通る。拾い方を直す事。" >&2
    exit 2
fi

# 重複を落とす(複数の対照が同じ file を触る)。
uniq_targets="$(printf '%s\n' $targets | sort -u)"
# ★剥がし損ねた path を黙って通さない。`$ROOT/...` のまま残ると `git diff -- <path>` に
#   当たらず、**その file だけ照合から静かに抜ける**。抜けた事は出力に出ないので、
#   気付く道が無い —— 数える側で止める。
bad="$(printf '%s\n' $uniq_targets | grep -E '^[$/]' || true)"
# ★**写しを指す宣言は追跡対象から外す**(2026-08-30)。数える対象を門と揃えた事で、
#   `$MUT/...`(= `mktemp -d`)や `$SCRATCH/...` の様な**作業中の木ではない** path が
#   混ざる様になった。之を「相対化できない」として止めると、正しく写しの上で撃つ
#   台本が在るだけで検知器全体が測定不成立になる。
#   ★但し**黙って落とさない**。落としてよいのは「其の変数が `mktemp` / `TMPDIR` で
#     作られている」と file の中で確かめられた時だけ。確かめられない物は今まで通り止める
#     —— 静かに照合から抜ける path を作らない、が此の検査の一線。
if [ -n "$bad" ]; then
    still_bad=""
    for b in $bad; do
        var="${b#\$}"; var="${var%%/*}"
        if [ -n "$var" ] && grep -hE "^[[:space:]]*$var=" "$HERE"/tools/*control*.sh "$ROOT"/.harness/*controls.sh 2>/dev/null \
             | grep -qE 'mktemp|TMPDIR'; then
            scratch_dropped="${scratch_dropped:-} $b"
            continue
        fi
        still_bad="$still_bad $b"
    done
    if [ -n "${still_bad// /}" ]; then
        echo "mutation-residue: 相対化できない path が在る = **測定不成立**" >&2
        printf '%s\n' $still_bad | sed 's/^/  /' >&2
        echo "  (写しなら其の変数を mktemp / TMPDIR で作る事。確かめられない物は止める)" >&2
        exit 2
    fi
    uniq_targets="$(printf '%s\n' $uniq_targets | grep -vE '^[$/]' || true)"
fi
dirty="$( cd "$ROOT" && git diff --name-only -- $uniq_targets 2>/dev/null )"

if [ -z "$dirty" ]; then
    echo "mutation-residue: 残骸なし($mutators 本の対照が宣言する $(printf '%s\n' $uniq_targets | wc -l | tr -d ' ') file を見た)"
    [ -n "${scratch_dropped:-}" ] && echo "  (写しを指す宣言は外した:$scratch_dropped)"
    exit 0
fi

echo "mutation-residue: ★変異対照が触る file に索引との差が在る"
printf '%s\n' "$dirty" | sed 's/^/  /'
if [ "$RESTORE" -eq 1 ]; then
    ( cd "$ROOT" && git checkout -- $dirty ) || { echo "戻せない" >&2; exit 2; }
    echo "  戻した(索引の版へ)"
    still="$( cd "$ROOT" && git diff --name-only -- $uniq_targets 2>/dev/null )"
    if [ -n "$still" ]; then
        echo "★戻したのに差が残っている:"; printf '%s\n' "$still" | sed 's/^/  /'
        exit 1   # 戻せていない = 修理は失敗
    fi
    exit 0       # 戻せた。「残骸が在った」は上の行が残す
else
    echo "  戻す: bash ios/tools/mutation-residue-check.sh --restore"
    echo "  ★意図した編集なら先に commit か stash を(索引に在る物は汚れとして出ない)"
fi
exit 1
