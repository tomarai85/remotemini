#!/bin/bash
# controls-for: tools/disposable-session.mjs
#
# この道具は 2026-08-05 に Sprint 5 DoD 9行目を閉じた計器で、結論はそのまま
# 「電話の送信路は本物に当たる」の唯一の根拠になっている。計器そのものが正しい事を
# 別の口で測っていないと、結論は「道具がそう言った」以上にならない。
#
# 特に守りたいのは**破壊側**: down は tmux セッションを殺し file を消す。名前の検査が
# 緩めば Tom の実セッション(work 等)を殺せてしまう。だから「殺さない事」を、
# 偽の tmux に記録を取らせて**呼ばれていない事**として測る(戻り値ではなく行為で測る)。
#
# 三値の落とし穴: grep -c は 0 件で終了コード 1 を返す。set -e の下に置くと
# 「0 件だった(正しい)」が「検査が壊れた」と混ざるので、set -e は使わない。
#
# 終了コード: 0 = 全て緑 / 1 = 赤(道具が壊れている) / 2 = 測れていない(node が無い等)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$HERE/../tools/disposable-session.mjs"
[ -f "$TOOL" ] || { echo "測れていない: 道具が無い"; exit 2; }
command -v node >/dev/null || { echo "測れていない: node が無い"; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
ng()  { FAIL=$((FAIL+1)); printf '  NG   %s\n' "$1"; }
chk() { if [ "$2" = "$3" ]; then ok "$1"; else ng "$1 (得た値=$2 / 欲しい値=$3)"; fi; }

SID="0123abcd-4567-89ef-0123-456789abcdef"
DECOY_SID="fedcba98-7654-3210-fedc-ba9876543210"
BODY="rc-controls probe 本文 A"
ABSENT="rc-controls probe 本文 B(送っていない)"

# --- 砂場を建てる。実物の ~/.rc-backend にも ~/.claude にも触らない -----------------
mk_sandbox() {
  SB="$(mktemp -d)"
  mkdir -p "$SB/rc/panes" "$SB/rc/heads" "$SB/projects/slug-x" "$SB/bin"
  printf '%s\n' '{"type":"meta"}' > "$SB/projects/slug-x/$SID.jsonl"
  printf '%s\n' "{\"type\":\"user\",\"text\":\"$BODY\"}" >> "$SB/projects/slug-x/$SID.jsonl"
  printf '\n' >> "$SB/projects/slug-x/$SID.jsonl"          # 空行は数えない事の確認用
  printf '%s\n' "{\"type\":\"assistant\",\"text\":\"$BODY\"}" >> "$SB/projects/slug-x/$SID.jsonl"
  printf '%s\n' "{\"pane\":\"%9\"}" > "$SB/rc/panes/$SID.json"
  printf '%s\n' "{\"head\":1}"      > "$SB/rc/heads/$SID.json"
  printf '%s\n' "{\"pane\":\"%8\"}" > "$SB/rc/panes/$DECOY_SID.json"
  printf '%s\n' '{"projects":{"/private/tmp":{"hasTrustDialogAccepted":true}}}' > "$SB/trust.json"
  # 偽の tmux: 呼ばれた引数を記録する。has-session は「居ない」= 終了コード 1。
  cat > "$SB/bin/tmux" <<'FAKE'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_TMUX_LOG"
case "$1" in
  has-session) exit 1 ;;
  new-session) exit 1 ;;
  *) exit 0 ;;
esac
FAKE
  chmod +x "$SB/bin/tmux"
  export FAKE_TMUX_LOG="$SB/tmux.log"
  : > "$FAKE_TMUX_LOG"
}
run() { # run <道具> <引数...> -- 砂場の環境で走らせ、stdout だけ返す
  local t="$1"; shift
  RC_TMUX_BIN="$SB/bin/tmux" \
  RC_KEY_DIR="$SB/rc" RC_PANE_DIR="$SB/rc/panes" \
  RC_PROJECTS_DIR="$SB/projects" RC_PHONE_TRUST_FILE="$SB/trust.json" \
    node "$t" "$@" 2>/dev/null
}
rc() { # 直前の run の終了コードが要る時用
  local t="$1"; shift
  RC_TMUX_BIN="$SB/bin/tmux" \
  RC_KEY_DIR="$SB/rc" RC_PANE_DIR="$SB/rc/panes" \
  RC_PROJECTS_DIR="$SB/projects" RC_PHONE_TRUST_FILE="$SB/trust.json" \
    node "$t" "$@" >/dev/null 2>&1
  echo $?
}

echo "=== 数える口(contains / lines) ==="
mk_sandbox
chk "① 錨: 居る本文を 2 件 数える(数える口が生きている)" "$(run "$TOOL" contains "$SID" "$BODY")" "2"
chk "② 対照: 送っていない本文は 0 件"                      "$(run "$TOOL" contains "$SID" "$ABSENT")" "0"
chk "③ lines は空行を数えない"                              "$(run "$TOOL" lines "$SID")" "3"
chk "④ 形の壊れた id は断る(黙って 0 を返さない)"          "$(rc "$TOOL" contains "not-a-session-id" "$BODY")" "1"
chk "⑤ 転写が無い id は断る"                                "$(rc "$TOOL" lines "99999999-0000-0000-0000-000000000000")" "1"
/bin/rm -rf "$SB"

echo
echo "=== 破壊側(down)—— 戻り値ではなく**行為**で測る ==="
mk_sandbox
DOWN_RC="$(rc "$TOOL" down "work" "$SID")"
KILLED="$(grep -c "kill-session" "$FAKE_TMUX_LOG")"
chk "⑥ 使い捨ての名前でなければ断る"                        "$DOWN_RC" "1"
chk "⑦ ★その時 kill-session を**一度も呼んでいない**"      "$KILLED" "0"
chk "⑧ 断った時、登録簿にも手を付けていない"                "$([ -f "$SB/rc/panes/$SID.json" ] && echo 在 || echo 無)" "在"
/bin/rm -rf "$SB"

mk_sandbox
run "$TOOL" down "rc-e2e-20260805110403" "$SID" >/dev/null
chk "⑨ 使い捨ての名前なら自分の登録だけ消す"                "$([ -f "$SB/rc/panes/$SID.json" ] && echo 在 || echo 無)" "無"
chk "⑩ heads も消す"                                        "$([ -f "$SB/rc/heads/$SID.json" ] && echo 在 || echo 無)" "無"
chk "⑪ ★他人の登録は完全一致でないので残る"                "$([ -f "$SB/rc/panes/$DECOY_SID.json" ] && echo 在 || echo 無)" "在"
# ★2026-08-14 に主張を入れ替えた。旧: 「既定では転写を**消さない**」——
#   其の守り方が製品の一覧を私の残骸で埋めた(実測 43 件、Tom の仕事は0件)。
#   新: 「転んだ走行の読み物は守るが、**製品の一覧からは必ず退かす**」= 退避先へ移す。
chk "⑫ 既定では転写を製品の一覧から退かす"                  "$([ -f "$SB/projects/slug-x/$SID.jsonl" ] && echo 在 || echo 無)" "無"
chk "⑫-b ★退かした物は読める場所に在る(消してはいない)"    "$([ -f "$SB/projects-attic/rc-e2e/$SID.jsonl" ] && echo 在 || echo 無)" "在"
/bin/rm -rf "$SB"

mk_sandbox
run "$TOOL" down "rc-e2e-20260805110403" "$SID" --purge-transcript >/dev/null
chk "⑬ 旗を渡した時だけ転写を消す"                          "$([ -f "$SB/projects/slug-x/$SID.jsonl" ] && echo 在 || echo 無)" "無"
/bin/rm -rf "$SB"

echo
echo "=== 信頼は読むだけ(与えない) ==="
mk_sandbox
BEFORE_TRUST="$(shasum -a 256 "$SB/trust.json" | cut -d' ' -f1)"
rc "$TOOL" up --cwd "/no/such/dir" >/dev/null
AFTER_TRUST="$(shasum -a 256 "$SB/trust.json" | cut -d' ' -f1)"
chk "⑭ up を走らせても信頼の記録は 1 byte も変わらない"     "$AFTER_TRUST" "$BEFORE_TRUST"
GRANT="$(grep -c "hasTrustDialogAccepted" "$TOOL")"
chk "⑮ 道具の中に信頼を**書く**道が無い(読む所 1 箇所だけ)" "$GRANT" "1"
/bin/rm -rf "$SB"

echo
echo "=== ★この対照が赤を出せる事の確認(陰性対照) ==="
# 名前の検査を緩めた写しを作り、⑦ と同じ測り方をする。**落ちなければ**この対照は
# 何も測っていない事になるので、その時こそ赤にする。
mk_sandbox
BROKEN="$SB/broken.mjs"
# ★写しは砂場に置くので、道具が読む ../src/inject.mjs は**絶対パスに書き換える**
#   (書き換えないと写しは読み込みで死に、tmux を一度も呼ばないまま「呼ばれていない」に
#    見える —— 2026-08-05 に実際にそうなって、対照が偽の緑を出しかけた)。
INJECT_ABS="$(cd "$HERE/../src" && pwd)/inject.mjs"
sed -e 's#^  if (!/\^rc-e2e-\[0-9\]{6,}\$/.test(session)) {#  if (false) {#' \
    -e "s#\"../src/inject.mjs\"#\"$INJECT_ABS\"#" "$TOOL" > "$BROKEN"
if [ "$(grep -c "if (false) {" "$BROKEN")" -lt 1 ] || [ "$(grep -c "$INJECT_ABS" "$BROKEN")" -lt 1 ]; then
  ng "⑯ 陰性対照を作れなかった(道具の書き方が変わった。この対照の書き換えが要る)"
else
  rc "$BROKEN" down "work" "$SID" >/dev/null
  BROKEN_KILLED="$(grep -c "kill-session" "$FAKE_TMUX_LOG")"
  if [ "$BROKEN_KILLED" -ge 1 ]; then
    ok "⑯ 名前の検査を外すと ⑦ は赤になる(= ⑦ は本当に検査を測っている)"
  else
    ng "⑯ 検査を外しても ⑦ が緑のまま = ⑦ は何も測っていない"
  fi
fi
/bin/rm -rf "$SB"

echo
echo "PASS $PASS / FAIL $FAIL"
[ "$FAIL" = "0" ] || exit 1
exit 0
