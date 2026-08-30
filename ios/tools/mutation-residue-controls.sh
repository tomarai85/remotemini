#!/bin/bash
# controls-for: ios/tools/mutation-residue-check.sh
#
# 殺された変異走行の残骸を名指しして戻す道具の**挙動**対照。
#
# ★測る中心は「残骸を見つけるか」ではない。それは1行の `git diff` でも通る。
#   測るのは **見えていない対照を『綺麗』と報告しないか**。
#   初版は `REL_TARGETS=` だけを拾い、**5 本中 1 本**しか見えていなかった ——
#   他の対照は `VM=` / `LV=` / `AS=` と別の名前で宣言している。
#   其の版は、今日実際に残った `ConversationView` の変異を「残骸なし」と言う。
#   **此の道具が防ぐ筈の物を、此の道具自身が作っていた。**
#
#   C1 明示の対: 差が在れば 1、無ければ 0
#   C2 明示の対: --restore が戻し、**0 で帰る**(修理の経路が失敗を返さない)
#   C3 ★宣言を読めない対照が1本でも在れば **緑を出さず 2**
#   C4 ★相対化できない path が在れば 2(照合から静かに抜けるのを止める)
#   C5 木を書き換える対照が 0 本なら 2(綴りが変わった時に黙って緑にならない)
#   C6 本物の repo: 今日残骸が出た file が**実際に見えている範囲に入っている**
#
# 使い方: bash ios/tools/mutation-residue-controls.sh
# 終了コード: 0=全部緑 / 1=1本でも赤
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"      # = ios/tools
ROOT="$(cd "$HERE/../.." && pwd)"
SUT="$HERE/mutation-residue-check.sh"
[ -f "$SUT" ] || { echo "測る対象が無い: $SUT"; exit 1; }

pass=0; fail=0
ok() { echo "PASS  $1"; pass=$((pass + 1)); }
ng() { echo "FAIL  $1  ($2)"; fail=$((fail + 1)); }
SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT

# ── C1 / C2 明示の対 ───────────────────────────────────────────────────────
printf 'ORIGINAL\n' > "$SB/snap.swift"
printf 'MUTATED\n'  > "$SB/target.swift"
printf '%s\t%s\n' "$SB/target.swift" "$SB/snap.swift" > "$SB/inflight.tsv"

RC_IOS_INFLIGHT="$SB/inflight.tsv" bash "$SUT" >/dev/null 2>&1
[ $? -eq 1 ] && ok "C1 差が在れば 1 で帰る" || ng "C1 差の検知" "rc=$?"

RC_IOS_INFLIGHT="$SB/inflight.tsv" bash "$SUT" --restore >/dev/null 2>&1
rrc=$?
if [ "$rrc" -eq 0 ] && cmp -s "$SB/target.swift" "$SB/snap.swift"; then
    ok "C2 --restore が戻し、0 で帰る(鎖に繋げる)"
else
    ng "C2 --restore" "rc=$rrc / 中身が戻っていない"
fi
# 戻した後は差が無いので 0。
RC_IOS_INFLIGHT="$SB/inflight.tsv" bash "$SUT" >/dev/null 2>&1
[ $? -eq 0 ] && ok "C1b 差が無ければ 0" || ng "C1b 差なし" "rc=$?"

# ── C3 宣言を読めない対照が在る時 ─────────────────────────────────────────
# 砂場に「復元はするが宣言の綴りが読めない」対照を1本置く。
FAKE="$SB/fakeios"; mkdir -p "$FAKE/tools" "$FAKE/../.harness" 2>/dev/null
mkdir -p "$SB/repo/ios/tools" "$SB/repo/.harness"
cp "$SUT" "$SB/repo/ios/tools/"
( cd "$SB/repo" && git init -q && git config user.email t@e.invalid && git config user.name t )
# 読める1本
# ★綴りを**連結で組み立てる**(2026-08-30、書いた直後に踏んだ)。生の literal を此の file に
#   置くと、此の file 自身が `ios/tools/*control*.sh` の走査に当たり、細工が
#   **本物の宣言として拾われて**、実 repo の測定が不成立になる。
#   `mutation-freeze-controls.sh` が 2026-08-03 に同じ結論を書いている。
CO="git check""out --"
printf '#!/bin/bash\nREL_TARGETS="$IOS/Sour""ces/Good.swift"\n%s $REL_TARGETS\n' "$CO" \
    > "$SB/repo/ios/tools/a-control.sh" 
# 読めない1本(path を組み立てて渡すので右辺に Sources/ が出ない)
printf '#!/bin/bash\nBASE="$IOS/Sour""ces"\nFILE="$BASE/Hidden.swift"\n%s "$FILE"\n' "$CO" \
    > "$SB/repo/ios/tools/b-control.sh" 
mkdir -p "$SB/repo/ios/Sources"; printf 'x\n' > "$SB/repo/ios/Sources/Good.swift"
( cd "$SB/repo" && git add -A && git commit -qm init )
out="$( cd "$SB/repo" && bash ios/tools/mutation-residue-check.sh 2>&1 )"; rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q "b-control.sh"; then
    ok "C3 宣言を読めない対照が在れば 2 で止まり、名前を出す"
else
    ng "C3 読めない対照" "rc=$rc / $(printf '%s' "$out" | tail -1)"
fi

# ── C5 書き換える対照が 0 本 ──────────────────────────────────────────────
rm -f "$SB/repo/ios/tools/a-control.sh" "$SB/repo/ios/tools/b-control.sh"
out="$( cd "$SB/repo" && bash ios/tools/mutation-residue-check.sh 2>&1 )"; rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q "0 本"; then
    ok "C5 書き換える対照が 0 本なら 2(黙って緑にしない)"
else ng "C5 0 本の時" "rc=$rc / $(printf '%s' "$out" | tail -1)"; fi

# ── C4 相対化できない path ────────────────────────────────────────────────
printf '#!/bin/bash\nT="/absolute/elsewhere/Sour""ces/Nope.swift"\n%s "$T"\n' "$CO" \
    > "$SB/repo/ios/tools/c-control.sh" 
out="$( cd "$SB/repo" && bash ios/tools/mutation-residue-check.sh 2>&1 )"; rc=$?
if [ "$rc" -eq 2 ]; then
    ok "C4 相対化できない path が在れば 2(照合から静かに抜けさせない)"
else ng "C4 絶対 path" "rc=$rc(緑や赤で通すと、その file だけ照合から消える)"; fi

# ── C6 本物の repo: 今日残骸が出た file が範囲に入っているか ────────────────
# ★此処だけ本物を見る。砂場でいくら緑でも、**本番の対照の綴りを拾えていなければ**
#   道具は役に立たない —— 初版はまさにそれだった。
# ★**振る舞いで測る**。一覧を読むだけだと、道具が其の file を実際に照合しているかは判らない
#   —— 初版は `-f` で存在を見ていただけで、註記の約束(「汚して名指しされるか」)を
#   コードが果たしていなかった。約束と実装がずれた検査は、読んだ人に嘘をつく。
PROBE="ios/Sources/Screens/Shared/AccountBar.swift"
probe_restore() { ( cd "$ROOT" && git checkout -- "$PROBE" ) 2>/dev/null; }
trap 'probe_restore; rm -rf "$SB"' EXIT

if [ ! -f "$ROOT/$PROBE" ]; then
    ng "C6 本物の repo" "$PROBE が無い(対照の当て先が動いた)"
elif [ -n "$( cd "$ROOT" && git diff --name-only -- "$PROBE" )" ]; then
    # 既に汚れている = 此の検査は前後を決められない。緑にも赤にもしない。
    echo "SKIP  C6 本物の repo($PROBE が既に汚れている = 測定不成立)"
else
    printf '\n// mutation-residue-controls probe\n' >> "$ROOT/$PROBE"
    out="$( cd "$ROOT" && bash ios/tools/mutation-residue-check.sh 2>&1 )"; rc=$?
    probe_restore
    still="$( cd "$ROOT" && git diff --name-only -- "$PROBE" )"
    if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "$PROBE"; then
        ok "C6 本物の repo で、実際に汚した file を名指しする"
    else
        ng "C6 本物の repo" "rc=$rc / 名指ししていない: $(printf '%s' "$out" | tail -1)"
    fi
    [ -z "$still" ] && ok "C6b 検査が木を汚したまま終わらない" \
                    || ng "C6b 木を戻せていない" "$still ← 手で git checkout -- する事"
fi

echo ""
echo "MUTATION-RESIDUE-CONTROLS: pass=$pass fail=$fail"
exit $(( fail > 0 ))
