#!/bin/bash
# controls-for: tools/verify-on-edith.sh
# tools/verify-on-edith.sh **そのもの**に対する対照。
#
# 見張っている欠陥(2026-08-01 に実測):
#   remote へ渡す台本を「ローカルの二重引用符の中」で組み立てると、その中身は
#   **一度こちらの機械の shell に食われる**。バッククォートはローカルでコマンド置換として
#   実行され、`$` も展開される。run7 の記録に出た
#     tools/verify-on-edith.sh: line 57: -u: command not found
#   は、remote 台本のコメントに書いた `-u` が **Jervis 上で実行された**という意味だった。
#   ★当時この現象を「bash がバイト位置で読むので走行中の編集でずれた」と診断して
#     台本に書き残したが、それは誤り。今夜12件目の「正しい観測を、それが支えていない
#     結論に貼る」型。再現は 2 行で取れる(この台本の C3/C4 がその再現そのもの)。
#
# 被害の型: コメントに書いただけの文字列がローカルで実行される。今回は `-u` で無害だったが、
#   同じ場所に `rm` や `git` を含む説明を書いた瞬間にそれが走る。**検査台本ほど危ない**。
#
# 直し: remote 台本は引用符付きヒアドキュメント `<<'REMOTE'` で書き、値は
#   `bash -s -- "$値"` の引数で渡す。ヒアドキュメントの区切り語を引用すると一切展開されない。
#
# 使い方: bash test/verify-script-controls.sh   (ssh / rsync は全て偽物。ネットワークに出ない)
set -u

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
TARGET="$SELF_DIR/../tools/verify-on-edith.sh"
[ -f "$TARGET" ] || { echo "検査対象が無い: $TARGET" >&2; exit 2; }

PASS=0; FAIL=0
chk() { # chk <名前> <期待> <実際>
  if [ "$2" = "$3" ]; then printf 'OK  %s\n' "$1"; PASS=$((PASS+1))
  else printf 'NG  %s\n      期待=%s / 実際=%s\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi
}

WORK=$(mktemp -d /tmp/rc-vsc.XXXXXX)
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# --- 偽の ssh / rsync -------------------------------------------------------
# ssh は「remote に何が届いたか」を丸ごと記録する。届いた文字列こそが検査対象で、
# **書いたはずの物と届いた物が一致するか**を見る(ローカルで食われていれば一致しない)。
mk_stubs() { # mk_stubs <capture_dir>
  local cap=$1
  mkdir -p "$cap/bin"
  cat > "$cap/bin/ssh" <<EOF
#!/bin/bash
cap="$cap"
n=\$(cat "\$cap/n" 2>/dev/null || echo 0); n=\$((n+1)); echo "\$n" > "\$cap/n"
printf '%s\n' "\$@" > "\$cap/argv.\$n"
uses_stdin=0
for a in "\$@"; do [ "\$a" = "-s" ] && uses_stdin=1; done
if [ "\$uses_stdin" = 1 ]; then cat > "\$cap/remote.\$n"; echo STUB-OK; exit 0; fi
last=\${!#}
printf '%s' "\$last" > "\$cap/remote.\$n"
case "\$last" in
  *mktemp*) d="\$cap/rc-verify.stub"; mkdir -p "\$d"; echo "\$d" ;;
  *) echo STUB-OK ;;
esac
exit 0
EOF
  printf '#!/bin/bash\nexit 0\n' > "$cap/bin/rsync"
  chmod +x "$cap/bin/ssh" "$cap/bin/rsync"
}

run_target() { # run_target <台本> <capture_dir> -> stdout+stderr を返す
  local script=$1 cap=$2
  mk_stubs "$cap"
  # RC_VERIFY_SELFTEST=1 = 検査対象側の自己検査段を止める合図(これが無いと無限再帰する)
  PATH="$cap/bin:$PATH" RC_VERIFY_SELFTEST=1 RC_EDITH_HOST=stub@invalid \
    bash "$script" 2>&1
}

find_cap() { # find_cap <capture_dir> <目印> -> その文字列を含む remote.N の path
  local cap=$1 needle=$2 f
  for f in "$cap"/remote.*; do
    [ -f "$f" ] || continue
    grep -qF -- "$needle" "$f" && { printf '%s' "$f"; return 0; }
  done
  return 1
}

# --- C1 / C2: 本物の台本 ----------------------------------------------------
cap1="$WORK/real"; mkdir -p "$cap1"
out1=$(run_target "$TARGET" "$cap1")

stage4=$(find_cap "$cap1" '--- 単体 ---' || true)
if [ -z "$stage4" ]; then
  echo "NG  C1/C2 検査段の台本が remote に届いていない(偽 ssh が受け取っていない)"; FAIL=$((FAIL+2))
else
  # 書いた通りの文字列が届いているか。バッククォートが生き残っていれば、
  # ローカルの shell はこの中身に触れていない。
  got_bt=$(grep -cF -- '`-u`' "$stage4" || true)
  chk "C1 remote 台本が書いた通りに届く(バッククォートがローカルで食われない)" "1" "$([ "$got_bt" -ge 1 ] && echo 1 || echo 0)"
  chk "C2 組み立て中にローカルで何も実行されない(command not found が出ない)" \
      "0" "$(printf '%s' "$out1" | grep -c 'command not found' || true)"
fi

# --- C3 / C4: 負の対照(旧形式の見本)--------------------------------------
# 「この対照が、壊れている物を実際に赤にできるか」を見る。見本は本物と同じ書き方
# (二重引用符の中に remote 台本 + コメントにバッククォート)で最小に再現する。
cat > "$WORK/old-form.sh" <<'OLD'
#!/bin/bash
set -u
main() {
  HOST="${RC_EDITH_HOST:-stub@invalid}"
  D=$(ssh "$HOST" 'mktemp -d') || exit 2
  rsync -a ./ "$HOST:$D"/ || exit 2
  ssh "$HOST" "cd '$D' && rc=0
    echo '--- 単体 ---'
    # `-u` を付けるのは、ssh 越しだと python の stdout が塊単位になる為。
    exit \$rc"
}
main "$@"
OLD
cap2="$WORK/old"; mkdir -p "$cap2"
out2=$(run_target "$WORK/old-form.sh" "$cap2")
stage4o=$(find_cap "$cap2" '--- 単体 ---' || true)
if [ -z "$stage4o" ]; then
  echo "NG  C3/C4 見本の台本が remote に届いていない"; FAIL=$((FAIL+2))
else
  chk "C3 負の対照: 旧形式ではバッククォートの中身が消える" \
      "0" "$(grep -cF -- '`-u`' "$stage4o" || true)"
  chk "C4 負の対照: 旧形式ではローカルで実行されて command not found が出る" \
      "1" "$([ "$(printf '%s' "$out2" | grep -c 'command not found' || true)" -ge 1 ] && echo 1 || echo 0)"
fi

# --- C5 / C6: 片付けの `rm -rf` の宛先ガード --------------------------------
# 実運用機で `rm -rf "$1"` を撃つ台本なので、**渡された宛先が想定の形でなければ撃たない**事を
# 現物で確かめる。届いた台本をそのまま走らせ、自分で作った捨て dir を宛先に与える。
clean=$(find_cap "$cap1" 'rm -rf' || true)
if [ -z "$clean" ]; then
  echo "NG  C5/C6 片付けの台本が remote に届いていない"; FAIL=$((FAIL+2))
else
  victim="$WORK/not-ours"; mkdir -p "$victim"
  bash "$clean" "$victim" >/dev/null 2>&1; rc5=$?
  chk "C5 想定外の宛先には撃たない(exit 2 で止まり、dir は残る)" \
      "2-残る" "$rc5-$([ -d "$victim" ] && echo 残る || echo 消えた)"

  # 負の対照: ガードの行だけを抜くと、同じ宛先が実際に消える(= C5 は空振りではない)
  sed '/^case "\$1" in/d' "$clean" > "$WORK/clean-noguard.sh"
  victim2="$WORK/not-ours-2"; mkdir -p "$victim2"
  bash "$WORK/clean-noguard.sh" "$victim2" >/dev/null 2>&1
  chk "C6 負の対照: ガードを外すと同じ宛先が消える" \
      "消えた" "$([ -d "$victim2" ] && echo 残る || echo 消えた)"
fi

printf -- '--- 合計: PASS %d / FAIL %d ---\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
