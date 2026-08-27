#!/bin/bash
# controls-for: ios/Sources/Core/WaitEscalation.swift ios/Sources/Screens/List/ListView.swift
# ★宣言先は **repo ルートからの相対**(既存の `ios/tools/*-control.sh` が全部この形)。
#   2026-08-27 に2回外した: `Sources/...`(ios 相対)も `../ios/Sources/...`(rc-backend 相対)も
#   門に「宣言先が実在しない」と言われた。宣言が外れた対照は、その file **だけ**を直す
#   commit で静かに回らない —— 足したばかりの守りが、次に其処を触る人には無い状態になる。
#
# initial-load-narration-control.sh — 「注意の限界を超えた待ちで表現が切り替わる」を、
# 戻したら赤になる形で押さえる。2026-08-27 新設。
#
# ★2つ別々に測る。片方だけでは足りない:
#   (1) **規則** — `WaitEscalation` が 10 秒で段を変えるか。純関数なので単体で測れる。
#   (2) **画面が規則を使っているか** — 規則がいくら正しくても、`ListView` が呼んで
#       いなければ画面は無言のまま。ここは grep の錨で押さえる。
#       ★錨が弱い事を承知で書く: 呼び出しの有無しか見ておらず、「呼んでいるが結果を
#       捨てている」は捕まらない。それを捕まえるには UI 検査(`RC_WAIT_ESCALATE_S=1` で
#       起こして `list.loading.slow` を探す)が要る —— 未着手として WORKLOG に出す。
#
# ★変異で自分を検める。変異しても緑なら、この台本は何も測っていない。
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS="$(cd "$HERE/.." && pwd)"
RULE="$IOS/Sources/Core/WaitEscalation.swift"
VIEW="$IOS/Sources/Screens/List/ListView.swift"
DEST="${RC_SIM_DEST:-platform=iOS Simulator,name=iPhone-dogfood}"
PASS=0; FAIL=0
ok(){ printf '  \033[32mgreen\033[0m  %s\n' "$1"; PASS=$((PASS+1)); }
bad(){ printf '  \033[31mRED\033[0m    %s -- %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

run_rule_tests(){
  local tree="$1"
  ( cd "$tree" && timeout 500 xcodebuild test -project RemoteMini.xcodeproj -scheme RemoteMini \
      -destination "$DEST" -only-testing:RemoteMiniTests/WaitEscalationTests ) >/dev/null 2>&1
}

echo "initial-load narration controls"

# --- (1) 規則 -------------------------------------------------------------
if run_rule_tests "$IOS"; then ok "規則: 本物は緑"; else bad "規則" "本物が赤(先に単体を直す事)"; fi

# ★2026-08-27 に作り直した。**変異を本物の木へ当てない**。
#   最初の版は実 file を `sed -i` で書き換えて後から書き戻していた。1回でも書き戻しに
#   失敗すれば、壊れた実装が作業木に残る —— 実際に残り、次の `git add -A` で index に
#   載った(commit は門が止めたので履歴は無事)。**検査が製品を壊す道を、検査の中に
#   作ってはいけない。** 今は木ごと複製して、複製の側だけを変異させる。
MUT="$(mktemp -d)/ios"
mkdir -p "$MUT"
cp -R "$IOS/." "$MUT/" 2>/dev/null
# 生成物は要らない(重いだけ)。無ければ黙って続ける。
rm -rf "$MUT/build" "$MUT/RemoteMini.xcodeproj/project.xcworkspace/xcuserdata" 2>/dev/null
MUT_RULE="$MUT/Sources/Core/WaitEscalation.swift"
# 変異: 何秒経っても `.normal` を返す = 「切り替えを消した」旧状態。
/usr/bin/sed -i "" 's|elapsedSeconds >= attentionLimitSeconds ? .abnormal : .normal|.normal|' "$MUT_RULE"
if grep -q 'elapsedSeconds >= attentionLimitSeconds' "$MUT_RULE"; then
  bad "変異" "変異を当てられなかった(探し文が実装とずれている)"
else
  if run_rule_tests "$MUT"; then bad "変異" "切り替えを消しても緑 = この検査は何も測っていない"
  else ok "変異(切り替えを消す)で赤 — 規則の対照は効いている"; fi
fi
rm -rf "$(dirname "$MUT")"
# ★本物の木が変異していない事を、この台本自身が最後に確かめる(書き戻し漏れの再発防止)。
if grep -q 'elapsedSeconds >= attentionLimitSeconds ? .abnormal : .normal' "$RULE"; then
  ok "本物の木は無傷(変異は複製にしか当てていない)"
else
  bad "本物の木" "★実 file に変異が残っている。`git checkout HEAD -- $RULE` で戻す事"
fi

# --- (2) 画面が規則を使っているか -----------------------------------------
if grep -q 'WaitEscalation.stage' "$VIEW"; then
  ok "画面: 初回の待ちの描画が規則を呼んでいる"
else
  bad "画面" "ListView が WaitEscalation.stage を呼んでいない = 規則が正しくても画面は無言のまま"
fi
if grep -q 'list.loading.slow' "$VIEW"; then
  ok "画面: 異常段に固有の a11y 識別子が在る(UI 検査から見つけられる)"
else
  bad "画面" "異常段の a11y 識別子が無い = UI 検査から到達できない"
fi
# ★HIG の一線: 通常段のスピナーにラベルを付けない。付けた瞬間に赤にする。
if grep -n 'ProgressView()' "$VIEW" | grep -qi 'loading\|待って\|読み込み'; then
  bad "画面" "通常段のスピナーにラベルが付いた(HIG: Avoid labeling a spinning progress indicator)"
else
  ok "画面: 通常段のスピナーは無言のまま(HIG の指針どおり)"
fi

echo "NARRATION-CONTROLS: pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
