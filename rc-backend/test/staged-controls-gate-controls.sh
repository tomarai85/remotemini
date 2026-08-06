#!/bin/bash
# controls-for: tools/staged-controls-gate.sh
# `tools/staged-controls-gate.sh` の対照。
#
# なぜ要るか: これは「対照を回し忘れる」を塞ぐ門なので、壊れ方が **一段ぶん意地悪**に
# なる —— 回し忘れを塞ぐ物が、自分を回し忘れさせる形で壊れる。
# 一番危ないのは「選び方が空振りして、いつも『触れた対照は無い』と言う」。
# 普段(対照を触らない commit)では区別が付かないので、**選ばれる事**を正面から測る。
#
# 継ぎ目:
#   $STAGED_GATE     = 測る対象そのもの(prove-control.sh が旧版を差し込む口)
#   $RC_GATE_ROOT    = 偽の repo の根(本物の repo にも git にも触らない)
#   $STAGED_LIST_CMD = staged 一覧の代わり(本物の `git diff --cached` を撃たない)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="${STAGED_GATE:-$ROOT/tools/staged-controls-gate.sh}"

pass=0; fail=0
chk() { # chk <名前> <期待rc> <実rc> <含むべき> <含んではいけない> <出力>
  local name=$1 want=$2 got=$3 must=$4 mustnot=$5 out=$6 bad=""
  [ "$got" = "$want" ] || bad="rc=$got (期待 $want)"
  # 日本語が直後に来る展開は必ず `${...}`(この repo で既に踏んでいる)
  [ -z "$must" ]    || printf '%s' "$out" | grep -qF -- "$must"    || bad="${bad}; 「${must}」が無い"
  [ -z "$mustnot" ] || ! printf '%s' "$out" | grep -qF -- "$mustnot" || bad="${bad}; 「${mustnot}」が出ている"
  if [ -n "$bad" ]; then echo "NG  $name -- $bad"; fail=$((fail+1)); else echo "OK  $name"; pass=$((pass+1)); fi
}

SB="$(/usr/bin/mktemp -d -t stagedgate)" || exit 2
trap '/bin/rm -rf "$SB" 2>/dev/null' EXIT INT TERM HUP

# ── 偽の repo。本物と同じ木の形(rc-backend/{src,test,tools})にする ──────────
R="$SB/repo"
/bin/mkdir -p "$R/rc-backend/test" "$R/rc-backend/tools" "$R/rc-backend/src"
mkctl() { # mkctl <相対パス> <終了コード> <最後の1行> [<controls-for の中身>]
  # ★2026-08-05: 偽の子も**宣言**を持つ。門が名前ではなく宣言から選ぶ様になったので、
  #   宣言の無い偽の子を並べると「選び方が壊れている」のか「入力が古い」のか判らなくなる。
  if [ -n "${4:-}" ]; then
    printf '#!/bin/bash\n# controls-for: %s\necho "%s"\nexit %s\n' "$4" "$3" "$2" > "$R/$1"
  else
    printf '#!/bin/bash\necho "%s"\nexit %s\n' "$3" "$2" > "$R/$1"
  fi
  /bin/chmod +x "$R/$1"
}
mkctl rc-backend/test/aa-controls.sh 0 "--- 合計: PASS 5 / FAIL 0 ---" "tools/zz-odd-name.sh"
mkctl rc-backend/test/bb-controls.sh 1 "NG  B2 何かが倒れた"          "tools/bb.sh"
mkctl rc-backend/test/cc-controls.sh 2 "CC: 未測定(走行中)= **緑ではない**" "tools/cc.sh"
mkctl rc-backend/test/dd-controls.sh 0 "--- 合計: PASS 2 / FAIL 0 ---" "tools/dd.sh"
# ★同じ道具を見張る**2 本目**。旧実装(名前から導く)では原理的に届かなかった側。
mkctl rc-backend/test/dd2-controls.sh 0 "--- 合計: PASS 3 / FAIL 0 ---" "tools/dd.sh"
# glob の宣言 + 宣言先が実在しない宣言(注記に出るが止めない)
mkctl rc-backend/test/ee-controls.sh 0 "--- 合計: PASS 1 / FAIL 0 ---" "tools/*.plist"
mkctl rc-backend/test/ff-controls.sh 0 "--- 合計: PASS 1 / FAIL 0 ---" "tools/gone-away.sh"
# 宣言を持たない対照(= 静かに回らない対照になる形)。staged になった時だけ止める
mkctl rc-backend/test/nodecl-controls.sh 0 "--- 合計: PASS 1 / FAIL 0 ---"
: > "$R/rc-backend/tools/dd.sh"          # dd.sh を見張る対照は 2 本
: > "$R/rc-backend/tools/bb.sh"
: > "$R/rc-backend/tools/cc.sh"
: > "$R/rc-backend/tools/zz-odd-name.sh" # 名前が対照と一致しない道具
: > "$R/rc-backend/tools/lonely.sh"      # 誰も宣言していない道具
: > "$R/rc-backend/tools/a.plist"        # glob の宣言が当たる先
: > "$R/rc-backend/src/server.mjs"
: > "$R/rc-backend/test/plain.test.mjs"  # `npm test` 側の物。ここでは選ばない

# ── ★ios の木(2026-08-05 の第2波)──────────────────────────────────────────
#   門は木を2つ見る。宣言の基点が木ごとに違う所が肝:
#     rc-backend の対照 → 宣言は rc-backend からの相対(tools/dd.sh)
#     ios の対照        → 宣言は **repo の根からの相対**(`ios/Sources/Thing.swift`)
#   命名も違う(ios は単数形 -control.sh)ので、両方を偽の木に置いて測る。
/bin/mkdir -p "$R/ios/tools" "$R/ios/Sources"
mkctl ios/tools/ii-control.sh 0 "GREEN: ii" "ios/Sources/Thing.swift"
mkctl ios/tools/jj-control.sh 0 "GREEN: jj"          # 宣言なし = staged にした時だけ止める
mkctl ios/tools/kk-control.sh 0 "GREEN: kk" "ios/Sources/gone-away.swift"  # 宣言先が実在しない
: > "$R/ios/Sources/Thing.swift"
: > "$R/ios/tools/lonely-ios.sh"         # 誰も見張っていない ios の道具
: > "$R/ios/tools/dd.sh"                 # ★rc-backend の tools/dd.sh と**同名・別の木**

run_gate() { # run_gate <staged の中身(改行区切り)>
  RC_GATE_ROOT="$R" STAGED_LIST_CMD="printf '%s\n' '$1'" bash "$GATE" 2>&1
}

# ── S1 対照に触れていない commit は素通り ──────────────────────────────────
out=$(run_gate 'rc-backend/src/server.mjs')
chk "S1 対照に触れていなければ rc=0" 0 $? "触れた対照は無い" "★" "$out"

# ── S2 触れた対照が緑なら通す ──────────────────────────────────────────────
out=$(run_gate 'rc-backend/test/aa-controls.sh')
chk "S2 触れた対照が緑 -> rc=0" 0 $? "全部緑(1/1)" "★" "$out"

# ── S3 触れた対照が赤なら止める + 名指しする ───────────────────────────────
out=$(run_gate 'rc-backend/test/bb-controls.sh')
chk "S3 触れた対照が赤 -> rc=1" 1 $? "commit を止めた" "" "$out"
chk "S4 ★倒れた対照の名前を出す" 1 1 "bb-controls.sh" "" "$out"

# ── S5 ★測れない対照を緑に丸めない ────────────────────────────────────────
out=$(run_gate 'rc-backend/test/cc-controls.sh')
# ★禁止語に素の「緑」を使うと、正しい文面「**緑ではない**」に当たって偽の赤になる。
#   同じ罠を今夜 `commit-suite-gate-controls.sh` G8 で既に踏んでいる ——
#   **否定形を含む語を禁止語に使わない**。緑の判定でしか出ない前置きを狙う。
chk "S5 ★対照が未測定 -> rc=2(緑でも赤でもない)" 2 $? "測れなかった対照" "対照は全部緑" "$out"

# ── S6 ★★道具だけ触った commit でも、その対照を回す ──────────────────────
#     ここが本題。2026-08-03 に踏んだのはこの形 —— `tools/mutation-verdict.sh` を
#     直す時に対照 file には触らないので、「staged な対照」だけ見る実装は素通りする。
out=$(run_gate 'rc-backend/tools/dd.sh')
chk "S6 ★道具だけ staged でも対照を導いて回す" 0 $? "dd-controls.sh" "触れた対照は無い" "$out"

# ── S7 対照を導けない道具は**名前を出す**が、止めない ─────────────────────
out=$(run_gate 'rc-backend/tools/lonely.sh')
chk "S7 対照の無い道具 -> 名前を出すが rc=0" 0 $? "対照を導けない道具" "" "$out"
chk "S8 ★その名前が実際に出ている" 0 0 "lonely" "" "$out"

# ── S9 両方の道で同じ対照に届く時、二度回さない ────────────────────────────
#     偽の dd.sh は 2 本(dd / dd2)に見張られているので、畳んだ結果は **2 本**。
#     (逆引用符で囲まないのは砂場の偽物だから —— `no-linerefs` の検査は引いた名前が
#      repo に実在する事を要求する。実際にここで1本捕まった)
#     dd-controls.sh を足しても増えないのが「畳んでいる」の意味。
out=$(run_gate 'rc-backend/tools/dd.sh
rc-backend/test/dd-controls.sh')
chk "S9 重複は 1 回に畳む" 0 $? "触れた対照 2 本" "" "$out"

# ── S10 ★★staged の一覧が空 = 未測定。**素通りさせない** ──────────────────
#      「何も触っていない」と「何を触ったか判らない」は別。前者は hook 側が先に
#      弾く(範囲の絞り込み)ので、ここに空が来る = 一覧を取る道が壊れている。
out=$(run_gate '')
chk "S10 ★staged 一覧が空 -> 未測定(rc=2)" 2 $? "測れていない" "触れた対照は無い" "$out"

# ── S11 ★repo の根が無い時も未測定 ────────────────────────────────────────
out=$(RC_GATE_ROOT="$SB/no-such-repo" STAGED_LIST_CMD="echo x" bash "$GATE" 2>&1)
chk "S11 ★根が判らない -> 未測定(rc=2)" 2 $? "測れていない" "" "$out"

# ── S12 削除された対照は回さない(存在確認をしている事)────────────────────
out=$(run_gate 'rc-backend/test/deleted-controls.sh')
chk "S12 削除された対照は回さない" 0 $? "触れた対照は無い" "" "$out"

# ── S13 `npm test` 側の file は選ばない(役割が違う。二重に回さない)────────
out=$(run_gate 'rc-backend/test/plain.test.mjs')
chk "S13 *.test.mjs は選ばない" 0 $? "触れた対照は無い" "" "$out"

# ── S14 ★赤と未測定が同時に在る時は**赤**が勝つ ───────────────────────────
out=$(run_gate 'rc-backend/test/bb-controls.sh
rc-backend/test/cc-controls.sh')
chk "S14 ★赤 + 未測定 -> 赤(1)。未測定に丸めない" 1 $? "commit を止めた" "" "$out"

# ── S15 陰性対照: 選び方が空振りしていない事 ───────────────────────────────
#     S1/S12/S13 が 0 を返すのは、正しく選ばなかったからか、**何も選べない**からか。
#     同じ道で 2 本が選ばれる事を見せて初めて「見分けている」と言える。
out=$(run_gate 'rc-backend/test/aa-controls.sh
rc-backend/test/dd-controls.sh')
chk "S15 陰性対照: 2 本 staged なら 2 本回る" 0 $? "触れた対照 2 本" "" "$out"

# ══ S16-S23 ★選び方を「名前」から「宣言」へ替えた分(2026-08-05)════════════
# 何を見張っているか: 旧実装は `tools/<名前>.sh` ↔ `test/<名前>-controls.sh` の
# **名前の一致**でしか届かなかった。実測した穴 —— 本物の repo で
#   tools/deploy-to-edith.sh を staged にすると 4 本在る対照の **1 本**だけが回り、
#   出力は「触れた対照は全部緑(1/1)」。分母が「在る対照」でなく「導けた対照」なので、
#   導出が痩せると比は満点のまま痩せる(DESIGN §2.18-10 と同じ族)。

# ── S16 名前が一致しない道具でも、宣言していれば回る ───────────────────────
out=$(run_gate 'rc-backend/tools/zz-odd-name.sh')
chk "S16 ★名前が違っても宣言で届く" 0 $? "aa-controls.sh" "触れた対照は無い" "$out"

# ── S17 ★★1つの道具を 2 本が見張るなら **2 本とも**回る + 分母が 2 ────────
#     これが今夜の穴そのもの。旧実装ではここが 1/1 の緑になる。
out=$(run_gate 'rc-backend/tools/dd.sh')
chk "S17 ★2 本目の対照も回る"        0 $? "dd2-controls.sh" "" "$out"
chk "S17b ★★分母が導出でなく本数(2/2)" 0 0 "全部緑(2/2)"   "全部緑(1/1)" "$out"

# ── S18 glob の宣言が当たる ────────────────────────────────────────────────
out=$(run_gate 'rc-backend/tools/a.plist')
chk "S18 glob の宣言(tools/*.plist)で届く" 0 $? "ee-controls.sh" "触れた対照は無い" "$out"

# ── S19 ★宣言の無い対照を staged にしたら**止める** ───────────────────────
#     宣言を忘れた対照 = その道具だけを直す commit で静かに回らない対照。
#     書いた瞬間(= staged になる唯一の機会)に止めれば、corpus に穴が入る道が塞がる。
out=$(run_gate 'rc-backend/test/nodecl-controls.sh')
chk "S19 ★宣言の無い対照 -> rc=1" 1 $? "宣言していない対照" "" "$out"
# ★名前が「どこかに」出ているだけでは駄目 —— 旧版でも走行報告に名前は出る(実測で緑になった)。
chk "S20 ★止めた文の中で名指しする" 1 1 "宣言していない対照: nodecl-controls.sh" "" "$out"

# ── S21 宣言先が実在しない対照は**名前を出すが止めない** ──────────────────
#     道具の改名で宣言が古くなる形。止めると無関係な commit が全部通らなくなる。
out=$(run_gate 'rc-backend/src/server.mjs')
chk "S21 宣言先が実在しない -> 注記のみ(rc=0)" 0 $? "宣言先が実在しない対照" "" "$out"
chk "S22 ★その組を名指しする"                  0 0 "ff-controls.sh→tools/gone-away.sh" "" "$out"

# ── S23 ★陰性対照: 宣言を消すと**選ばれなくなる** ─────────────────────────
#     S16-S18 が緑なのは「宣言で選んでいる」からか、「何でも選んでいる」からか。
#     同じ入力で宣言だけ抜いて、届かなくなる事を見せて初めて見分けたと言える。
/usr/bin/sed -i '' '/^# controls-for: tools\/zz-odd-name.sh$/d' "$R/rc-backend/test/aa-controls.sh"
out=$(run_gate 'rc-backend/tools/zz-odd-name.sh')
chk "S23 ★宣言を消すと届かない(選び方が宣言に依っている)" 0 $? "触れた対照は無い" "aa-controls.sh" "$out"

# ── S24 ★edith 側の対照は手元で回さず、**名前を出す** ─────────────────────
#     宣言から選ぶ様にした副作用で `test/e2e-local.mjs` の commit が env-death を
#     引き込み、ssh が無い所(= 移動中)では 2 = commit が止まる形になっていた。
#     落とす事自体は正しいが、**黙って落とすと分母がまた痩せる**ので名前を出す。
/bin/cat > "$R/rc-backend/tools/run-controls.sh" <<'RCEOF'
EDITH_CTLS=(
    test/cc-controls.sh
)
RCEOF
out=$(run_gate 'rc-backend/test/cc-controls.sh')
chk "S24 ★edith 側は回さない(未測定で止めない)" 0 $? "此処では回さない" "測れなかった対照" "$out"
# 同上。旧版は cc を**回して** UNMEA 行に名前を出すので、素の名前では見分けない。
chk "S25 ★落とした文の中で名指しする"           0 0 "回さない(edith 側の対照): cc-controls.sh" "" "$out"
/bin/rm -f "$R/rc-backend/tools/run-controls.sh"

# ══ S26-S34 ★木を2つ見る様にした分(2026-08-05 の第2波)════════════════════════
#   旧版は `rc-backend/` の中だけを見ていたので、**`ios/` が丸ごと見えなかった**。
#   実害は commit `c1617f7`: ios の file を3本 staged にした commit が
#   「触れた対照 1 本を回す … 全部緑(1/1)」と印字した(選ばれた1本は ios と無関係)。
#   S16-S23 が塞いだのと同じ形が、名前ではなく**木の軸**で再発した物。
#   Sprint 3-6 は全部 ios なので、此処が塞がっていないと残り全部の対照が
#   commit 時に一度も回らない。
#
# ★実測(2026-08-05、3通りの旧版/壊した版を `$STAGED_GATE` から差した):
#   | 差した物                                   | 倒れた assertion            |
#   |---|---|
#   | HEAD(木を1本しか見ない版)                 | S26 S27 S28 S31 S32 S33     |
#   | `_key` が基点を見ず先頭の木を剥がすだけの版 | S29 S30(← **これだけ**)   |
#   | stale の基点を `rc-backend` 固定にした版    | S34(← **これだけ**)       |
#   S29/S30/S34 は HEAD では倒れない。旧版は ios を1本も選ばないので「別の木の物を
#   選ばない」は自動的に真になるからで、**これらは旧版でなく雑な直し方を見分ける**。
#   3本とも狙った変異でだけ倒れる事を上の表で確かめてある(倒れない対照は、その欠陥に
#   ついて何も測っていない —— 此処を測らずに置くと assertion の数だけが増える)。

# ── S26 ★★ios の道具を触ったら ios の対照が回る(欠陥の本体)──────────────────
out=$(run_gate 'ios/Sources/Thing.swift')
chk "S26 ★★ios の file を触ったら ios の対照が回る" 0 $? "ii-control.sh" "触れた対照は無い" "$out"

# ── S27 ios の対照そのものが staged でも回る(命名が単数形 -control.sh)───────
out=$(run_gate 'ios/tools/ii-control.sh')
chk "S27 ★ios の対照そのものが staged -> 回る" 0 $? "GREEN: ii" "触れた対照は無い" "$out"

# ── S28 宣言の無い ios の対照も止める(rc-backend と同じ扱い)──────────────────
out=$(run_gate 'ios/tools/jj-control.sh')
chk "S28 ★宣言の無い ios の対照 -> rc=1" 1 $? "宣言していない対照: jj-control.sh" "" "$out"

# ── S29/S30 ★同名・別の木。基点の剥がし方が雑だと**他の木の対照**を選んでしまう ──
#     ios/tools/dd.sh と rc-backend/tools/dd.sh は同名。rc-backend 側の対照2本は
#     tools/dd.sh を宣言しているので、基点を見ずに末尾だけで照合すると ios の方でも
#     当たる = **ios の道具を触ると backend の対照が回る**(緑になるので気付けない)。
out=$(run_gate 'ios/tools/dd.sh')
chk "S29 ★別の木の同名 file で dd-controls.sh を選ばない"  0 $? "触れた対照は無い" "dd-controls.sh"  "$out"
chk "S30 ★同上(2 本目)"                                   0 0 "触れた対照は無い" "dd2-controls.sh" "$out"

# ── S31/S32 見張る物の無い ios の道具は**名前を出すが止めない**(rc-backend と同じ)─
out=$(run_gate 'ios/tools/lonely-ios.sh')
chk "S31 ★対照の無い ios の道具 -> 注記のみ(rc=0)" 0 $? "対照を導けない道具" "" "$out"
chk "S32 ★その名前が実際に出ている"                0 0 "lonely-ios.sh"        "" "$out"

# ── S33/S34 ★宣言の**基点**が木ごとに違う事を見分ける ─────────────────────────
#     ios の宣言は repo の根から(`ios/Sources/…`)、rc-backend の宣言は rc-backend から
#     (`tools/…`)。基点を間違えて ios の宣言も `rc-backend/` の下で探すと、
#     **実在する宣言先まで「実在しない」と報告する**。
#     S33 だけでは見分けられない —— 実在しない path は基点を間違えても実在しないので、
#     どちらの実装でも注記に出る。**実在する側(S34)が discriminator**。
out=$(run_gate 'rc-backend/src/server.mjs')
chk "S33 ★ios の対照の宣言先が実在しなければ名指しする" 0 $? "kk-control.sh→ios/Sources/gone-away.swift" "" "$out"
chk "S34 ★★実在する ios の宣言を stale に出さない(基点が効いている)" 0 0 "" "ii-control.sh→" "$out"

# ══ S35-S41 ★木の一覧を**1本**にした分(2026-08-05 の第3波)══════════════════════
#   第2波(S26-S34)で `ios/` を足した時、広げたのは走査 dir だけだった。同じ一覧が
#   ①走査の呼び出し ②「見る木か」の case ③「対照そのものか」の case と**手で同期
#   する形で3箇所**在ったので、`.harness/` を足そうとして初めて判った ——
#   ① だけ足すと対照は**発見されるが一度も選ばれない**(実測: 「触れた対照は無い」)。
#   今は SCAN_SPECS が唯一の出所で ②③ はそこから導出する。
#   S35-S38 は `.harness` が本当に届く事、**S39-S41 が導出そのものの対照**。
#
# ★実測(2026-08-05。4通りを `$STAGED_GATE` から差した。素の版は 44/44):
#   | 差した物                                    | 倒れた assertion                     |
#   |---|---|
#   | HEAD(木を2本しか見ない版)                  | S35 S36 S37 S38 S40-prep S40 S41     |
#   | ①走査 dir だけ広げた版(今夜の実際の途中形) | 同上(= ①だけでは何も変わらない)   |
#   | 導出①`_in_tree` を手書きの一覧に戻した版    | S35 S36 S37 S38 S40 S41              |
#   | 導出②`_is_ctl` を手書きの pattern に戻した版 | S36 S37 **S41**(← これだけ)       |
#   読み方: S41 は 導出② が痩せた時だけ倒れ、S40 は倒れない —— **2本は別の物を測って
#   いる**。HEAD/①だけの版で S40-prep が倒れるのは正しい: そこには SCAN_SPECS が無く、
#   差し込みが空振りするので S40/S41 の赤は「導出」でなく「sed」を測った赤になる。
/bin/mkdir -p "$R/.harness"
mkctl .harness/hh-control.sh 0 "GREEN: hh" ".harness/dod-x.sh"
mkctl .harness/nodecl-control.sh 0 "GREEN: nodecl"      # 宣言なし
: > "$R/.harness/dod-x.sh"
: > "$R/.harness/lonely-harness.sh"   # 誰も見張っていない harness の道具
: > "$R/.harness/notes.md"            # 書類は道具ではない(注記に出さない)

# ── S35 ★.harness の道具を触ったら .harness の対照が回る ─────────────────────
out=$(run_gate '.harness/dod-x.sh')
chk "S35 ★.harness の file を触ったら .harness の対照が回る" 0 $? "hh-control.sh" "触れた対照は無い" "$out"

# ── S36 .harness の対照そのものが staged でも回る(導出②が効いている事)───────
#     ここが今夜の穴の**本体**。①だけ広げた版はこの入力で「触れた対照は無い」を出す。
out=$(run_gate '.harness/hh-control.sh')
chk "S36 ★.harness の対照そのものが staged -> 回る" 0 $? "GREEN: hh" "触れた対照は無い" "$out"

# ── S37 宣言の無い .harness の対照も止める ────────────────────────────────────
out=$(run_gate '.harness/nodecl-control.sh')
chk "S37 ★宣言の無い .harness の対照 -> rc=1" 1 $? "宣言していない対照: nodecl-control.sh" "" "$out"

# ── S38 見張る物の無い .harness の道具は名前を出す / 書類は出さない ───────────
out=$(run_gate '.harness/lonely-harness.sh')
chk "S38 ★対照の無い .harness の道具 -> 注記に名前(rc=0)" 0 $? "lonely-harness.sh" "" "$out"
out=$(run_gate '.harness/notes.md')
chk "S38b 書類(.md)は道具として注記しない" 0 $? "" "notes.md" "$out"

# ── S39-S41 ★★導出の対照: SCAN_SPECS に**1行足すだけ**で3つの道が全部届くか ──
#     これが4回続いた再発の再発を見張る唯一の assertion。もし誰かが将来
#     「見る木」や「対照の pattern」を手書きの一覧に戻したら、①(走査)は新しい木を
#     見つけるのに ②③ が知らない —— まさに今夜の形 —— ので S40/S41 が倒れる。
#     測り方: 門の**複製**の SCAN_SPECS に `newtree|` を1行だけ差し込む。他は触らない。
VARIANT="$SB/gate-with-4th-tree.sh"
/bin/cp "$GATE" "$VARIANT"
/usr/bin/sed -i '' 's|^    "\.harness|\    "newtree\|"                 # 対照 S39-S41 が差し込む4本目\
    "\.harness|' "$VARIANT"
/bin/mkdir -p "$R/newtree"
mkctl newtree/tt-control.sh 0 "GREEN: tt" "newtree/thing.txt"
: > "$R/newtree/thing.txt"
run_variant() { RC_GATE_ROOT="$R" STAGED_LIST_CMD="printf '%s\n' '$1'" bash "$VARIANT" 2>&1; }

# ★S40-prep: **差し込みが本当に当たったか**を先に測る。
#   当たらないと $VARIANT は門そのものと同一になり、S40/S41 は倒れる —— が、その赤は
#   「導出が壊れている」ではなく「対照が変異を掛けそこねた」。今日この形を DoD の
#   対照(行4)で既に踏んでいる。誤診する赤は、緑を装う赤より始末が悪い。
if grep -q '^    "newtree|"' "$VARIANT"; then
  chk "S40-prep 4本目の差し込みが当たっている" 0 0 "" "" ""
else
  echo "NG  S40-prep ★差し込みが当たっていない -- 以降の S40/S41 は導出でなく sed を測っている"
  fail=$((fail+1))
fi

# S39 陰性対照が先: **足す前**は届かない。これが無いと S40/S41 は「元から通る」と
#     区別が付かない(S26-S34 で `ios` を、S35-S38 で `.harness` を既に足してあるので、
#     木の一覧が導出でなく単に長いだけでも緑になり得る)。
out=$(run_gate 'newtree/thing.txt')
chk "S39 ★陰性対照: SCAN_SPECS に無い木は届かない" 0 $? "触れた対照は無い" "tt-control.sh" "$out"
# S40 1行足したら **導出①(見る木)+ 宣言経由**で届く
out=$(run_variant 'newtree/thing.txt')
chk "S40 ★★1行足すだけで新しい木の対照が回る(導出①)" 0 $? "tt-control.sh" "触れた対照は無い" "$out"
# S41 同じ1行で **導出②(対照そのもの)** も届く。①②を別々に持っていた版はここで倒れる
out=$(run_variant 'newtree/tt-control.sh')
chk "S41 ★★同じ1行で「対照そのもの」の道も届く(導出②)" 0 $? "GREEN: tt" "触れた対照は無い" "$out"

# ══ S42-S48 ★`--would-select`(呼ぶ側が「回る物は在るか」だけ聞く口)══════════
#   何故要るか: `pre-commit-gates.sh` の絞り込み regex が、この門の `SCAN_SPECS` と
#   **手で同期する2本目の一覧**になっていた(実測 2026-08-06: 宣言 75 本中 74 本は
#   届き、`rc-backend/package.json` の1本だけ届かない)。regex に1行足すのは
#   手書き同期の6個目なので、代わりに**一覧を持っている側に聞く**形にした。
#   ここで測るのはその口の**契約**4点:
#     ① 本番と同じ物を選ぶ(別実装を持たない)  ② 選んだ物を**回さない**
#     ③ **判断しない**(undecl でも止めない/注記も出さない)
#     ④ 選ぶ物が無ければ**空**(呼ぶ側は空か否かで分岐するので、喋ったら素通しになる)
run_dry()  { RC_GATE_ROOT="$R" STAGED_LIST_CMD="printf '%s\n' '$1'" bash "$GATE" --would-select 2>&1; }
run_list() { RC_GATE_ROOT="$R" STAGED_LIST_CMD="printf '%s\n' '$1'" bash "$GATE" --list 2>&1; }

# ── S42 選択を **path で** 1行ずつ答える(2本在る入力で) ──────────────────────
out=$(run_dry 'rc-backend/tools/dd.sh')
chk "S42 ★回る対照が在れば path を並べる" 0 $? "rc-backend/test/dd-controls.sh" "" "$out"
chk "S42b 同じ道具を見張る2本目も出る" 0 0 "rc-backend/test/dd2-controls.sh" "" "$out"

# ── S43 ★聞くだけ = **回さない**。本番が回す事を先に見せてから、口が回さない事を見る ──
#     片側だけでは意味を持たない: 「回っていない」は入力が外れていても成立する。
real=$(run_gate 'rc-backend/tools/dd.sh')
chk "S43-prep 本番はこの入力で対照を実際に回す(= 次行の判別子が効く)" 0 $? "--- 合計: PASS 2 / FAIL 0 ---" "" "$real"
chk "S43 ★口は同じ入力で対照を回さない" 0 0 "" "--- 合計: PASS 2 / FAIL 0 ---" "$out"

# ── S44 ★本番の選択と一致する(= 別実装を持っていない) ────────────────────────
#     `--list` は人向けに `  SEL   <名前>` で見せる。基点も装飾も違うので**名前で**
#     突き合わせる。ここが割れたら、どちらかが選択の道を自前で持ち始めた合図。
dry_names=$(printf '%s\n' "$out" | /usr/bin/sed 's#.*/##' | /usr/bin/sort | /usr/bin/tr '\n' ' ')
lst_names=$(run_list 'rc-backend/tools/dd.sh' | /usr/bin/grep '^  SEL ' \
            | /usr/bin/sed 's/^ *SEL *//' | /usr/bin/sort | /usr/bin/tr '\n' ' ')
if [ "$dry_names" = "$lst_names" ] && [ -n "$dry_names" ]; then
  chk "S44 ★選択が --list と一致(選択の道は1本)" 0 0 "" "" ""
else
  echo "NG  S44 ★選択が割れた -- dry=[${dry_names}] list=[${lst_names}]"
  fail=$((fail+1))
fi

# ── S45 ★**判断しない**: 宣言の無い対照が staged でも止めない ─────────────────
#     本番はこの入力で rc=1(S13 等で測り済)。口で止めると「聞いただけで commit が
#     落ちる」= 呼ぶ側が絞り込みを外した瞬間に、書類だけの commit が死ぬ。
out=$(run_dry 'rc-backend/test/nodecl-controls.sh')
chk "S45 ★宣言の無い対照でも rc=0(口は裁かない)" 0 $? "rc-backend/test/nodecl-controls.sh" "commit しない" "$out"

# ── S46 ★選ぶ物が無ければ**空**(注記も出さない)────────────────────────────────
#     呼ぶ側は `[ -z "$(…)" ]` で分岐する。1文字でも喋ると絞り込みが素通しに化ける。
#     偽の repo の lonely.sh(誰も宣言していない道具)は、本番なら「対照を導けない
#     道具」の注記が出る入力 —— そこが判別子。★名前を backtick で引かない事:
#     この repo の書類ラチェットは backtick の名前を**実在の主張**として検査するので、
#     砂場にしか無い偽の file を引くと単体が赤くなる(2026-08-06 に実際に止められた)。
out=$(run_dry 'rc-backend/tools/lonely.sh')
chk "S46-prep 本番はこの入力で注記を出す(= 次行の判別子が効く)" 0 0 "注記" "" "$(run_gate 'rc-backend/tools/lonely.sh')"
if [ -z "$out" ]; then
  chk "S46 ★★選ぶ物が無ければ完全に無言(注記も出さない)" 0 0 "" "" ""
else
  echo "NG  S46 ★無言でない -- [${out}]"; fail=$((fail+1))
fi

# ── S47 ★edith 側を**落とす前**の答えを返す(= `--list` の上位集合)────────────
#     `--list` は手元で回せない対照(ssh が要る物)を落としてから見せる。口はその前に
#     帰るので落とさない。**わざとの差**なので、latent にせず assertion にしておく。
#     何故その向きが正しいか: 呼ぶ側が要るのは「門へ進むべきか」で、落ちた結果が空だと
#     `commit-suite-gate`(npm test)まで飛ぶ。多めに答えて門へ進むのが安全側。
/bin/cat > "$R/rc-backend/tools/run-controls.sh" <<'EOF'
EDITH_CTLS=(
  test/dd-controls.sh
)
EOF
out=$(run_dry 'rc-backend/tools/dd.sh')
chk "S47 ★edith 側の対照も落とさずに答える" 0 $? "rc-backend/test/dd-controls.sh" "" "$out"
lst=$(run_list 'rc-backend/tools/dd.sh')
chk "S47b --list は同じ入力でそれを落とす(= 差が実在する)" 0 $? "此処では回さない" "  SEL   dd-controls.sh" "$lst"
/bin/rm -f "$R/rc-backend/tools/run-controls.sh"

# ── S48 ★陰性対照: 口を潰したら S46 が倒れる(= S42-S47 に歯が在る)─────────────
#     潰し方は「ブロックごと削る」。すると `--would-select` は未知の引数として素通りし、
#     門は**普通に走って喋る** —— 呼ぶ側から見ると「常に非空」= 絞り込みが素通しに
#     化ける、という本物の壊れ方そのもの。
MUT="$SB/gate-no-dry-mouth.sh"
/usr/bin/sed '/だけ答えて帰る口(ここから)/,/だけ答えて帰る口(ここまで)/d' "$GATE" > "$MUT"
if /usr/bin/cmp -s "$GATE" "$MUT"; then
  echo "NG  S48-prep ★変異が当たっていない(以降の赤は口でなく sed を測る)"
  fail=$((fail+1))
else
  mut_out=$(RC_GATE_ROOT="$R" STAGED_LIST_CMD="printf '%s\n' 'rc-backend/tools/lonely.sh'" \
            bash "$MUT" --would-select 2>&1)
  if [ -n "$mut_out" ]; then
    chk "S48 ★口を消すと無言でなくなる(= S46 に歯が在る)" 0 0 "" "" ""
  else
    echo "NG  S48 ★口を消しても無言のまま -- S46 は元から通る形で、何も測っていない"
    fail=$((fail+1))
  fi
fi

echo "--- 合計: PASS $pass / FAIL $fail ---"
[ "$fail" = 0 ]
