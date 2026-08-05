#!/bin/bash
# controls-for: tools/pre-commit-gates.sh
# commit 前の門を**呼ぶ側**(絞り込みと順番)を測る。
#
# ── なぜ絞り込みを測るのか ──────────────────────────────────────────────
# この repo は**同じ形の穴を4回**踏んでいる(本体の注釈に全部書いてある):
#   2026-08-02 `tools/` が絞り込みに無く、門の本体を書き換える commit で門が動かなかった
#   2026-08-05 朝 `ios/` が無く、Sprint 3 の成果物は門を1つも通らずに入る所だった
#   2026-08-05 昼 `.harness/*.sh` が無く、同じ事が起きかけた
#   (+ 下流の `staged-controls-gate.sh` が同じ一覧を3箇所持っていた件)
# 共通の形は1つ: **下流に能力を足しても、上流の絞り込みがそれを知らなければ守りは伸びない**。
# 人が2本の一覧を手で同期する限り必ずまた起きるので、乖離を**赤**にして機械に見張らせる。
#
# ── なぜ本物の commit では測れないか ────────────────────────────────────
# 絞り込みの向こう側には本物の門(最長 200 秒、`npm test` を含む)が在る。枝を6通り
# 測るのに本物を回すと 20 分かかる上、木の状態に結果が左右されて計器にならない。
# だから偽の repo を `git init` し、門を**名前を書くだけの偽物**に差し替えて、
# 「どの門が / どの順で / 何本呼ばれたか」だけを見る。
#
# ── 測る10通り(判定 12 本)─────────────────────────────────────────────
#   1 書類だけ(`WORKLOG.md`)      → **書類の門だけ**を呼ぶ / code の門は0本(exit 0)
#   2 `rc-backend/src/`             → 本体が呼ぶ門を**全部**呼ぶ
#   3 `ios/Sources/`                → 呼ぶ(3件目の穴への回帰防止)
#   4 `.harness/*.sh`               → 呼ぶ(4件目の穴への回帰防止)
#   5 `.harness/*.md`               → code の門へ行かない(4 が「.harness なら何でも」でない)
#   6 `ios/*.md`                    → code の門へ行かない(3 が「ios なら何でも」でない)
#   7 門が赤 → そこで止まり、後ろの門は呼ばれない(その門の exit を返す)
#   8 ★下流 `staged-controls-gate.sh` の `SCAN_SPECS` の木が**全部**絞り込みに掛かる
#   8c 絞り込みから 1 本抜くと 8b が赤くなる(緑が既定値でない事)
#   9 最後の門が `exec` で呼ばれる(前の門が exec だと後ろが永久に走らない)
#
# ★5 と 6 が無いと 3/4 は「何でも通す絞り込み」と見分けが付かない。
#   絞り込みの値打ちは**通す事と止める事の両方**に在る。
#
# ★2026-08-05 に 1/5/6 の期待値を「0 本」から「書類の門だけ」へ変えた。緩めたのではない:
#   同日、`.md` を対象にしたラチェットを足したのに絞り込みが `.md` を素通しするので
#   **追跡 .md 36/36 が門ゼロ**だった(実測)= その検査が在る理由の場面で走らない。
#   だから「自分の対象は自分で決める門」を絞り込みの前に置いた。守るべき値打ち
#   (走行中の 85 分に書類を残せる = code の重い門を書類に当てない)はそのまま生きており、
#   `only_doc_gates` が**その群ちょうど**である事を順序込みで見ている。
set -u
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SUBJECT="$REPO_ROOT/rc-backend/tools/pre-commit-gates.sh"
DOWNSTREAM="$REPO_ROOT/rc-backend/tools/staged-controls-gate.sh"

pass=0; fail=0
ok() { pass=$((pass+1)); echo "PASS  $1"; }
ng() { fail=$((fail+1)); echo "FAIL  $1  ($2)"; }

T="$(mktemp -d)"
cleanup() {
    [ -n "${T:-}" ] || return 0
    [ -d "$T" ] || return 0
    find "$T" -type f -print0 2>/dev/null | xargs -0 /bin/rm -f 2>/dev/null
    find "$T" -type d -depth -print 2>/dev/null | while read -r d; do /bin/rmdir "$d" 2>/dev/null; done
}
trap cleanup EXIT

if [ ! -f "$SUBJECT" ]; then
    echo "FAIL  対象が無い: $SUBJECT"
    echo "--- 合計: PASS 0 / FAIL 1 ---"
    exit 1
fi

# ★門の一覧は**本体から取る**。ここで手打ちすると、この file 自体が
#   「手で同期する3本目の一覧」になり、門を1本足した日に静かに古くなる ——
#   この対照が見張っているのと同じ形の穴を、対照の中に作る事になる。
GATES="$(grep -oE 'bash "\$ROOT/rc-backend/tools/[a-z-]+\.sh"' "$SUBJECT" \
         | sed -E 's#.*/([a-z-]+)\.sh"#\1#')"
NGATES="$(printf '%s\n' "$GATES" | grep -c . )"

# ★門は2群に分かれる(2026-08-05)。**絞り込みより前**に無条件で呼ぶ門と、
#   絞り込みを通った後に呼ぶ code の門。前者は「自分の対象は自分で決める」門で、
#   `doc-linerefs-gate.sh`(`.md` が staged の時だけ働く)がその第1号。
#   ★ここも**本体の行の並びから**取る。手で「書類の門はこれ」と書いた瞬間に、
#     この対照が見張っているのと同じ「手で同期する一覧」がまた1本増える。
NARROW_LN="$(grep -nE '^if ! echo "\$staged" \| grep -qE' "$SUBJECT" | head -1 | cut -d: -f1)"
DOC_GATES="$(awk -v n="${NARROW_LN:-0}" 'NR < n' "$SUBJECT" \
             | grep -oE 'bash "\$ROOT/rc-backend/tools/[a-z-]+\.sh"' \
             | sed -E 's#.*/([a-z-]+)\.sh"#\1#')"
NDOC="$(printf '%s\n' "$DOC_GATES" | grep -c . )"

# 呼ばれた門が「絞り込み前の群」ちょうどか。順序も込みで見る。
only_doc_gates() {
    [ "$(ncalled)" = "$NDOC" ] || return 1
    diff -q <(printf '%s\n' "$DOC_GATES" | grep .) <(grep . "$T/called.log") >/dev/null 2>&1
}

if [ "$NGATES" -lt 2 ]; then
    echo "FAIL  本体から門の一覧を取り出せない(呼び方が変わった = この対照が古い)"
    echo "--- 合計: PASS 0 / FAIL 1 ---"
    exit 1
fi

# 偽の repo: 本体をそのまま置き、門だけ「名前を書く偽物」に差し替える。
mk_repo() {  # $1=根 $2=赤にする門の名前(空なら全部緑)
    local r="$1" red="${2:-}" g
    mkdir -p "$r/rc-backend/tools" "$r/rc-backend/src" "$r/ios/Sources" "$r/.harness"
    git -C "$r" init -q 2>/dev/null || return 1
    git -C "$r" config user.email "c@example.invalid"
    git -C "$r" config user.name "controls"
    cp "$SUBJECT" "$r/rc-backend/tools/pre-commit-gates.sh"
    for g in $GATES; do
        if [ "$g" = "$red" ]; then
            printf '#!/bin/bash\necho "%s" >> "$RCLOG"\nexit 7\n' "$g" > "$r/rc-backend/tools/$g.sh"
        else
            printf '#!/bin/bash\necho "%s" >> "$RCLOG"\nexit 0\n' "$g" > "$r/rc-backend/tools/$g.sh"
        fi
        chmod +x "$r/rc-backend/tools/$g.sh"
    done
}

# $1=根 $2..=stage する path。呼ばれた門を $T/called.log に残す。
run_with() {
    local r="$1"; shift
    local p
    for p in "$@"; do
        mkdir -p "$r/$(dirname "$p")"
        echo "x" > "$r/$p"
        git -C "$r" add -- "$p"
    done
    : > "$T/called.log"
    RCLOG="$T/called.log" bash "$r/rc-backend/tools/pre-commit-gates.sh" > "$T/out.log" 2>&1
    echo $?
}
ncalled() { wc -l < "$T/called.log" | tr -d ' '; }

# ── 1: 書類だけ → 門を1本も呼ばない ───────────────────────────────────────
mk_repo "$T/docs" || { echo "FAIL  偽 repo を作れない"; exit 1; }
rc="$(run_with "$T/docs" "WORKLOG.md")"
if [ "$rc" = "0" ] && only_doc_gates; then
    ok "1 書類だけの commit は書類の門だけを呼ぶ(code の門は0本 = 走行中も書類は残せる)"
else
    ng "1 書類だけの commit は書類の門だけを呼ぶ" "exit=$rc 呼ばれた門=$(ncalled)本(期待 $NDOC 本: $(printf '%s' "$DOC_GATES" | tr '\n' ' '))"
fi

# ── 2: rc-backend/src → 4本とも呼ぶ ───────────────────────────────────────
mk_repo "$T/src" || { echo "FAIL  偽 repo を作れない"; exit 1; }
rc="$(run_with "$T/src" "rc-backend/src/view.mjs")"
if [ "$rc" = "0" ] && [ "$(ncalled)" = "$NGATES" ]; then
    ok "2 code を触れば本体が呼ぶ門を全部呼ぶ($NGATES 本)"
else
    ng "2 code を触れば本体が呼ぶ門を全部呼ぶ($NGATES 本)" \
       "exit=$rc 呼ばれた門=$(ncalled)本: $(tr '\n' ' ' < "$T/called.log")"
fi

# ── 9: 最後の門が exec で呼ばれる(= 最後まで届く事の別角度)────────────────
LAST_GATE="$(printf '%s\n' "$GATES" | tail -1)"
if [ "$(tail -1 "$T/called.log" 2>/dev/null)" = "$LAST_GATE" ]; then
    ok "9 最後まで届く(前の門が exec で後ろを潰していない)"
else
    ng "9 最後まで届く" "最後に呼ばれたのは $(tail -1 "$T/called.log" 2>/dev/null)"
fi

# ── 3: ios/Sources → 呼ぶ ─────────────────────────────────────────────────
mk_repo "$T/ios" || { echo "FAIL  偽 repo を作れない"; exit 1; }
rc="$(run_with "$T/ios" "ios/Sources/RootView.swift")"
if [ "$(ncalled)" -ge 1 ]; then
    ok "3 ios/Sources を触れば門へ進む(2026-08-05 の穴への回帰防止)"
else
    ng "3 ios/Sources を触れば門へ進む" "門を1本も呼ばない = Sprint の成果物が素通りする"
fi

# ── 4: .harness/*.sh → 呼ぶ ───────────────────────────────────────────────
mk_repo "$T/harness" || { echo "FAIL  偽 repo を作れない"; exit 1; }
rc="$(run_with "$T/harness" ".harness/dod-sprint-3.sh")"
if [ "$(ncalled)" -ge 1 ]; then
    ok "4 .harness/*.sh を触れば門へ進む(同日2件目の穴への回帰防止)"
else
    ng "4 .harness/*.sh を触れば門へ進む" "検査の本体を .harness に置くと素通りする"
fi

# ── 5: .harness/*.md → 呼ばない ───────────────────────────────────────────
mk_repo "$T/hmd" || { echo "FAIL  偽 repo を作れない"; exit 1; }
rc="$(run_with "$T/hmd" ".harness/progress.md")"
if [ "$rc" = "0" ] && only_doc_gates; then
    ok "5 .harness の書類は code の門へ行かない(4 が『.harness なら何でも』でない)"
else
    ng "5 .harness の書類は code の門へ行かない" "exit=$rc 呼ばれた門=$(ncalled)本(期待 $NDOC 本)"
fi

# ── 6: ios/*.md → 呼ばない ────────────────────────────────────────────────
mk_repo "$T/iosmd" || { echo "FAIL  偽 repo を作れない"; exit 1; }
rc="$(run_with "$T/iosmd" "ios/README.md")"
if [ "$rc" = "0" ] && only_doc_gates; then
    ok "6 ios の書類は code の門へ行かない(3 が『ios なら何でも』でない)"
else
    ng "6 ios の書類は code の門へ行かない" "exit=$rc 呼ばれた門=$(ncalled)本(期待 $NDOC 本)"
fi

# ── 7: 門が赤 → そこで止まり、後ろは呼ばれない ────────────────────────────
RED_GATE="$(printf '%s\n' "$GATES" | sed -n '2p')"   # 後ろに必ず門が残る位置を選ぶ
mk_repo "$T/red" "$RED_GATE" || { echo "FAIL  偽 repo を作れない"; exit 1; }
rc="$(run_with "$T/red" "rc-backend/src/view.mjs")"
if [ "$rc" = "7" ]; then
    ok "7 門が返した exit をそのまま返す(赤を緑に丸めない)"
else
    ng "7 門が返した exit をそのまま返す" "exit=$rc(門の判定が呼び出し側で潰れている)"
fi
if ! grep -q "$LAST_GATE" "$T/called.log" 2>/dev/null; then
    ok "7b 赤の後ろの門は呼ばない(止まっている)"
else
    ng "7b 赤の後ろの門は呼ばない" "赤の後も走り続けている"
fi

# ── 8: ★下流の SCAN_SPECS の木が全部この絞り込みに掛かる ───────────────────
#     2本の一覧を人が手で同期する形が4回続いた真因。乖離を赤にして機械に見張らせる。
#
#     ★8c が要る理由: この判定は**掛からない木の一覧が空**の時に緑になる。式を取り
#       出せずに空文字になった時も、木の一覧を取り出せずに走らなかった時も、字面は
#       同じ「緑」に見える。だから絞り込みから 1 本抜いた**変異体**を同じ判定に食わせ、
#       赤くなる事を測る。赤に出来ない検査は、緑を主張する資格が無い。

# 掛からない木を標準出力へ並べる(空 = 全部掛かる)。exit 2 = 測れない。
uncovered() {  # $1=絞り込みを読む file
    local subj="$1" narrow specs d probe miss=""
    # ★`head -1` で「最初の grep -qE」を取ると、絞り込みの**手前**に別の grep を
    #   1 行足した日に静かにすり替わる(2026-08-05 に実際に起きて、この 8b が偽陽性を
    #   出した)。取り出す行は**中身で**名指しする。
    narrow="$(grep -oE "grep -qE '[^']+'" "$subj" | grep -F 'rc-backend/' | head -1 \
              | sed -E "s/^grep -qE '//; s/'$//")"
    [ -n "$narrow" ] || return 2
    specs="$(sed -n '/^SCAN_SPECS=(/,/^)/p' "$DOWNSTREAM" | sed -n 's/^ *"\([^|"]*\)|.*/\1/p')"
    [ -n "$specs" ] || return 2
    for d in $specs; do
        case "$d" in
            .harness) probe=".harness/some-tool.sh" ;;
            *)        probe="$d/some-file.mjs" ;;
        esac
        printf '%s\n' "$probe" | grep -qE "$narrow" || miss="$miss $d"
    done
    printf '%s' "$miss"
    return 0
}

if [ ! -f "$DOWNSTREAM" ]; then
    ng "8 下流の SCAN_SPECS を読める" "$DOWNSTREAM が無い = 乖離を測れない"
else
    miss="$(uncovered "$SUBJECT")"; urc=$?
    if [ "$urc" = "2" ]; then
        ng "8 絞り込みと木の一覧を取り出せる" "どちらかが読めない = 以下の判定が空回りする"
    else
        ok "8 絞り込みと木の一覧を両方取り出せた(空回りしていない)"
        if [ -z "$miss" ]; then
            ok "8b 下流が走査する木は全部この絞り込みに掛かる"
        else
            ng "8b 下流が走査する木は全部この絞り込みに掛かる" \
               "掛からない木:$miss —— 下流は見られるのに呼び出し側が知らない = 4回続いた形の5回目"
        fi
        # ── 8c: 絞り込みから .harness を抜いた変異体で、同じ判定が赤くなるか ──
        sed -E 's#\|\^\\\.harness/\[\^/\]\*\\\.sh\$##' "$SUBJECT" > "$T/mutant-narrow.sh"
        if cmp -s "$SUBJECT" "$T/mutant-narrow.sh"; then
            ng "8c 絞り込みを狭めると 8b が赤くなる" \
               "変異の的が消えている = この対照が古い(絞り込みの書き方が変わった)"
        else
            mmiss="$(uncovered "$T/mutant-narrow.sh")"; murc=$?
            if [ "$murc" = "0" ] && [ -n "$mmiss" ]; then
                ok "8c 絞り込みから 1 本抜くと 8b が赤くなる(緑が既定値でない)"
            else
                ng "8c 絞り込みから 1 本抜くと 8b が赤くなる" \
                   "抜いても緑(rc=$murc 掛からない木='$mmiss')= 8b は何も測っていない"
            fi
        fi
    fi
fi

cleanup
if [ -d "$T" ]; then
    ng "後始末" "細工した木が残っている: $T"
fi

echo "--- 合計: PASS $pass / FAIL $fail ---"
echo "PRE-COMMIT-GATES-CONTROLS: pass=$pass fail=$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
