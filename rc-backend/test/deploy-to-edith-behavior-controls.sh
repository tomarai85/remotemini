#!/bin/bash
# `tools/deploy-to-edith.sh` の対照・第2弾 —— **実際に走らせて**制御の流れを測る。
#
# 第1弾(`deploy-to-edith-controls.sh`)は台本の文字列を読む構造検査で、
# 「除外の旗が書いてあるか」までしか言えなかった。ここで測るのはそれでは届かない性質:
#
#   ★**赤い検査の後、本番の木に触る呼び出しが 1 本も出ない事。**
#
# これは台本を読んでも判らない。`set -e` の抜け / `|| true` の置き所 / 段の並び替えの
# どれか1つで壊れ、壊れた事は**本番で初めて判る**(= 一番高い所で判る)。
#
# 仕掛け: 砂場に台本を置き、PATH の先頭に**偽の ssh / 偽の rsync**を据える。
# 偽物は呼ばれた引数を全部 log に書き、筋書きに従って成否を返す。判定は log を読む =
# 「何をしたか」で見る。出力の文言ではなく**呼び出しの有無**で見るので、
# 文言を変えても対照は壊れないし、段を消せば必ず落ちる。
#
# ★本物の edith には一切触らない: 相手は `RC_EDITH_HOST=fake@fake`、
#   経路も `/fake/...` に差し替える。仮に偽物をすり抜けても実在しない宛先。
#   (継ぎ目は台本が最初から持っていた `RC_EDITH_*` / `RC_DEPLOY_*` の環境変数)
#
# ★この対照でも言えない事: 偽の rsync は**転送しない**ので、除外の旗が本当に
#   `.git/` を守るかは測っていない(それは第1弾の E1-E3 が文字列で見ている)。
#   両方合わせても「本物の rsync が旗の通りに振る舞う」は仮定のまま。
#
# 型 = 差替型。`${DEPLOY_SCRIPT:-…}` の継ぎ目から旧版を差し込める。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPLOY="${DEPLOY_SCRIPT:-$ROOT/tools/deploy-to-edith.sh}"
[ -f "$DEPLOY" ] || { echo "★台本が読めない: $DEPLOY = 測定不成立"; exit 2; }

pass=0; fail=0
chk() { # chk <名前> <期待> <実際>
  local name=$1 want=$2 got=$3
  if [ "$want" = "$got" ]; then echo "OK  $name"; pass=$((pass+1))
  else echo "NG  $name"; echo "      期待=$want 実際=$got"; fail=$((fail+1)); fi
}

SB="$(/usr/bin/mktemp -d /tmp/rc-deploybeh.XXXXXX)"
cleanup() {
  /usr/bin/find "$SB" -type f -print0 2>/dev/null | /usr/bin/xargs -0 /bin/rm -f 2>/dev/null
  /usr/bin/find "$SB" -type d -depth -print0 2>/dev/null | /usr/bin/xargs -0 /bin/rmdir 2>/dev/null
}
trap cleanup EXIT

/bin/mkdir -p "$SB/bin" "$SB/tools" "$SB/src" "$SB/test"
/bin/cp "$DEPLOY" "$SB/tools/deploy-to-edith.sh"
/bin/cp "$ROOT/tools/warn-ledger.sh" "$SB/tools/" 2>/dev/null || { echo "★warn-ledger.sh が無い = 測定不成立"; exit 2; }
/bin/cp "$ROOT/tools/deploy-dirt.sh" "$SB/tools/" 2>/dev/null || { echo "★deploy-dirt.sh が無い = 測定不成立"; exit 2; }

# 変異の走行の判定は差し替える。本物を呼ぶと**この対照の結果が今走っている変異に依存する**
# = 同じ台本が日によって違う答えを出す(対照としては失格)。
/bin/cat > "$SB/tools/mutation-run-live.sh" <<'MUT'
#!/bin/bash
# 偽: 既定は「走っていない」(exit 1)。RC_FAKE_MUT_LIVE=1 で「走っている」に倒す。
[ "${RC_FAKE_MUT_LIVE:-0}" = "1" ] && exit 0
exit 1
MUT

# ── 偽の ssh ──────────────────────────────────────────────────────────────
# 引数を全部 log に残し、筋書き(`RC_FAKE_FAIL` に含まれる文字列)に当たったら非零。
# 返す出力は**本物と同じ形**だけを真似る(刻印の読み戻し / SNAPSHOT= の行 / 錠の札)。
/bin/cat > "$SB/bin/ssh" <<'FAKESSH'
#!/bin/bash
args="$*"
printf 'SSH %s\n' "$args" >> "$RC_FAKE_LOG"
case "$args" in *"bash -s"*) /bin/cat >> "$RC_FAKE_LOG" ;; esac

if [ -n "${RC_FAKE_FAIL:-}" ]; then
  case "$args" in
    *"$RC_FAKE_FAIL"*) echo "★偽 ssh: 筋書きにより失敗 (${RC_FAKE_FAIL})" >&2; exit 1 ;;
  esac
fi

case "$args" in
  # 錠を外す(release_lock)。`rmdir` を含むのはこの呼び出しだけ。
  *rmdir*)
      printf 'TAG release-lock\n' >> "$RC_FAKE_LOG" ;;
  # 錠を取る。位置引数の 1 本目が錠の path、3 本目が持ち主の札。
  *"bash -s"*"$RC_FAKE_LOCK"*)
      printf 'TAG acquire-lock\n' >> "$RC_FAKE_LOG"
      printf '%s' "$args" | /usr/bin/tr "'" '\n' | /usr/bin/sed -n '6p' > "$RC_FAKE_SB/lock-owner"
      echo "錠を取った(偽)" ;;
  # 錠の札を読む(assert_lock_owner)。取った時の札をそのまま返す。
  *"cat '$RC_FAKE_LOCK/owner'"*)
      printf 'TAG read-lock-owner\n' >> "$RC_FAKE_LOG"
      /bin/cat "$RC_FAKE_SB/lock-owner" 2>/dev/null ;;
  # 刻印を仮置きに書く。書かれた版を控えて、step 7 の読み戻しで返す。
  *"printf '%s"*"$RC_FAKE_STAGE/DEPLOYED-REV"*)
      printf 'TAG stamp-stage\n' >> "$RC_FAKE_LOG"
      printf '%s' "$args" | /usr/bin/tr "'" '\n' | /usr/bin/sed -n '4p' > "$RC_FAKE_SB/live-rev" ;;
  # 刻印の読み戻し(step 7)。
  *"head -1 '$RC_FAKE_LIVE/DEPLOYED-REV'"*)
      printf 'TAG read-live-rev\n' >> "$RC_FAKE_LOG"
      if [ -n "${RC_FAKE_LIVE_REV_OVERRIDE:-}" ]; then echo "$RC_FAKE_LIVE_REV_OVERRIDE"
      else /bin/cat "$RC_FAKE_SB/live-rev" 2>/dev/null; fi ;;
  # 入れ替え(step 6)。**本番の木に触る最初の呼び出し**。仮置きと複製置き場の両方を持つ。
  *"bash -s"*"$RC_FAKE_STAGE"*"$RC_FAKE_RELEASES"*)
      printf 'TAG swap-live\n' >> "$RC_FAKE_LOG"
      echo "配備中の印を立てた(偽)"
      echo "SNAPSHOT=$RC_FAKE_RELEASES/snap-1" ;;
  # 入れ替え後の再起動(step 8)。
  *"bash -s"*"$RC_FAKE_RELEASES/snap-1"*)
      printf 'TAG restart\n' >> "$RC_FAKE_LOG"
      echo "常設なし(偽)。入れ替えだけで終わり" ;;
  *)  echo "偽 ssh ok" ;;
esac
exit 0
FAKESSH

/bin/cat > "$SB/bin/rsync" <<'FAKERSYNC'
#!/bin/bash
printf 'RSYNC %s\n' "$*" >> "$RC_FAKE_LOG"
[ "${RC_FAKE_RSYNC_FAIL:-0}" = "1" ] && exit 23
exit 0
FAKERSYNC
/bin/chmod +x "$SB/bin/ssh" "$SB/bin/rsync" "$SB/tools/mutation-run-live.sh"

# ── 走らせる ───────────────────────────────────────────────────────────────
LOG="$SB/calls.log"; OUT="$SB/out.txt"; DEP_RC=0
run() { # run [--dry-run] ; 環境は呼ぶ側が前置きする
  : > "$LOG"; : > "$OUT"
  PATH="$SB/bin:$PATH" \
  RC_FAKE_LOG="$LOG" RC_FAKE_SB="$SB" \
  RC_FAKE_LOCK=/fake/lock RC_FAKE_STAGE=/fake/stage \
  RC_FAKE_RELEASES=/fake/releases RC_FAKE_LIVE=/fake/live \
  RC_EDITH_HOST=fake@fake RC_EDITH_DIR=/fake/live RC_EDITH_STAGE=/fake/stage \
  RC_EDITH_RELEASES=/fake/releases RC_DEPLOY_MARK=/fake/mark RC_DEPLOY_LOCK=/fake/lock \
  /bin/bash "$SB/tools/deploy-to-edith.sh" "$@" > "$OUT" 2>&1
  DEP_RC=$?
}
tags() { /usr/bin/grep -c "^TAG $1\$" "$LOG"; }   # 段が何回走ったか
touched_live() { # 本番の木に触る呼び出しの本数(入れ替え + 再起動 + 刻印の読み戻し)
  /usr/bin/grep -cE '^TAG (swap-live|restart|read-live-rev)$' "$LOG"
}

# ── 陽性: 全部緑なら最後まで通る ──────────────────────────────────────────
run
chk "B0a 全部緑なら 0 で終わる"            0 "$DEP_RC"
chk "B0b 最後に「完了」を出す"            1 "$(/usr/bin/grep -c '=== 完了 ===' "$OUT")"
# ★これが **B1-B4 の空振り防止**。log がいつも空なら「触っていない」は自明に緑になる。
chk "B0c ★陽性: 通れば本番の木に触っている" 1 "$(tags swap-live)"
chk "B0d 錠を取って、外して終わる"        "1 1" "$(tags acquire-lock) $(tags release-lock)"

# ── B1-B3 ★赤い検査は本番の木に到達させない ──────────────────────────────
#   3 段それぞれで測る。1 段だけ見ると「たまたまその段の後ろに exit が在る」でも通る。
for spec in "npm test:B1:単体" "e2e-local.mjs:B2:e2e" "rc-backend-launch-check.sh:B3:起動ラッパ"; do
  pat="${spec%%:*}"; rest="${spec#*:}"; id="${rest%%:*}"; label="${rest#*:}"
  RC_FAKE_FAIL="$pat" run
  chk "${id}a $label が赤 -> 非零で終わる"                 1 "$([ "$DEP_RC" -ne 0 ] && echo 1 || echo 0)"
  chk "${id}b $label が赤 -> ★本番の木に触る呼び出しが 0"  0 "$(touched_live)"
  chk "${id}c $label が赤 -> それでも錠は外す"             1 "$(tags release-lock)"
done

# ── B4 --dry-run は仮置きまで ─────────────────────────────────────────────
run --dry-run
chk "B4a dry-run は 0 で終わる"                   0 "$DEP_RC"
chk "B4b dry-run でも本番の木には触らない"        0 "$(touched_live)"
chk "B4c dry-run の rsync は --dry-run を持つ"    1 "$(/usr/bin/grep -c '^RSYNC .*--dry-run' "$LOG")"
chk "B4d dry-run では刻印すら書かない"            0 "$(tags stamp-stage)"

# ── B5 錠が取れなければ何も始めない ───────────────────────────────────────
RC_FAKE_FAIL="/fake/lock" run
chk "B5a 錠が取れない -> 非零"                     1 "$([ "$DEP_RC" -ne 0 ] && echo 1 || echo 0)"
chk "B5b 錠が取れない -> rsync を 1 本も撃たない"  0 "$(/usr/bin/grep -c '^RSYNC ' "$LOG")"

# ── B6 変異の走行中は何も始めない ─────────────────────────────────────────
RC_FAKE_MUT_LIVE=1 run
chk "B6a 走行中 -> 非零"                           1 "$([ "$DEP_RC" -ne 0 ] && echo 1 || echo 0)"
chk "B6b 走行中 -> ssh を 1 本も撃たない"          0 "$(/usr/bin/grep -c '^SSH ' "$LOG")"
# ★断り文句の**中身**を測る。ここは 2026-08-02 に一度書き間違えて訂正した所で、
#   「木が壊れているから配備しない」は事実と違う(台本は複製を壊すので本物の src/ は無傷)。
#   本当の理由は「配備を正当化する検査が、まだ答えを出していない」。
#   文言が元の誤りへ戻ったら赤くする。**肯定形2本で見る**(否定形の述語は自分が読み違える)。
chk "B6c 断りの理由が「検査がまだ答えを出していない」" 1 \
    "$(/usr/bin/grep -c '検査がまだ答えを出していない' "$OUT")"
chk "B6d 断りに「木が壊れている訳ではない」が付く"      1 \
    "$(/usr/bin/grep -c '木が壊れている訳ではない' "$OUT")"

# ── B7 刻印が食い違えば止まる ─────────────────────────────────────────────
#   ここは**本番の木に触った後**なので防げない段。防げない段は fail-closed である事を測る。
RC_FAKE_LIVE_REV_OVERRIDE=deadbeef run
chk "B7a 刻印の不一致 -> 非零"                     1 "$([ "$DEP_RC" -ne 0 ] && echo 1 || echo 0)"
chk "B7b 不一致 -> 入れ替え済みだが再起動はしない" "1 0" "$(tags swap-live) $(tags restart)"

# ── B8 仮置きへの転送が失敗したら本番へ進まない ───────────────────────────
RC_FAKE_RSYNC_FAIL=1 run
chk "B8a 仮置きへの転送が赤 -> 非零"               1 "$([ "$DEP_RC" -ne 0 ] && echo 1 || echo 0)"
chk "B8b 仮置きへの転送が赤 -> 本番の木に触らない" 0 "$(touched_live)"

# ── B9 ★この計器が成り立つ前提そのものを測る ─────────────────────────────
# 上の全部は「PATH の先頭に置いた偽物が本物の代わりに呼ばれる」事に乗っている。
# 台本が `ssh` を `/usr/bin/ssh` と絶対 path で呼び始めた瞬間、偽物は迂回され、
# **この対照の 28 本が一斉に意味を失う**(しかも赤ではなく「宛先に届かない」形で
# 崩れるので、原因が計器側だと気付きにくい)。前提が消えたら**ここが落ちる**。
#
# ★これは構造検査だが、置き場所は第2弾が正しい —— 守っているのは配備台本の性質では
#   なく**この計器の有効性**だから。第1弾へ移すと「何を守る対照か」が判らなくなる。
#
# ★注記を数に入れない。自分の説明文にこの綴りが出るので、素の grep だと**この注記自身**に
#   当たって恒久的に赤くなる(第1弾で逆向きの同じ事故 = 注記に当たって恒久的に緑、を踏んだ)。
abs_calls() { # abs_calls <file> -> 絶対 path で ssh/rsync を呼んでいる**コード行**の本数
  /usr/bin/grep -vE '^[[:space:]]*#' "$1" \
    | /usr/bin/grep -cE '(/usr/bin|/bin|/opt/homebrew/bin)/(ssh|rsync)[[:space:]]'
}
chk "B9 ★ssh/rsync を素の名前で呼ぶ(絶対 path は偽物を迂回して測定を無効にする)" 0 "$(abs_calls "$DEPLOY")"

# ── N1-N5 ★陰性対照 ───────────────────────────────────────────────────────
# 上が全部緑なのは、見分けているからか **何をしても緑になる書き方**だからか。
# 台本を壊した複製で自分を回し、狙った項**だけ**が落ちる事を見せる。
#
# ★壊す場所は中身で指す(行番号で指すと、注記を足しただけで sed が空振りし、
#   壊した版でも赤が出なくなる = 陰性対照が黙って無効化される。同日に第1弾で踏んだ)。
mutate_run() { # mutate_run <sed式> -> 壊した版で自分を回し、NG の名前を並べて返す
  local f="$SB/mutant.sh"
  /usr/bin/sed "$1" "$DEPLOY" > "$f"
  RC_DEPLOY_BEH_NEG=0 DEPLOY_SCRIPT="$f" /bin/bash "$ROOT/test/deploy-to-edith-behavior-controls.sh" 2>&1 \
    | /usr/bin/sed -n 's/^NG  \([A-Za-z0-9]*\) .*/\1/p' | /usr/bin/tr '\n' ' '
}

if [ "${RC_DEPLOY_BEH_NEG:-1}" = "1" ]; then
  # N1: 単体の段を門でなくする(`|| true`)。この lane が何度も作った型そのもの。
  #     → 赤い単体のまま本番の木を入れ替えてしまう。
  chk "N1 ★陰性: 単体を門でなくすると B1a/B1b だけが落ちる" "B1a B1b " \
      "$(mutate_run '/npm test --silent/s/$/ || true/')"

  # N2: 錠を外す trap を消す。配備は通るが、錠が残って**次の配備が 2 時間塞がる**。
  chk "N2 ★陰性: 錠の trap を消すと「外す」系だけが落ちる" "B0d B1c B2c B3c " \
      "$(mutate_run '/^trap release_lock EXIT$/d')"

  # N3: dry-run の脱出を潰す。「見るだけ」の積りが本番へ行く = 一番危ない壊れ方。
  chk "N3 ★陰性: dry-run の脱出を潰すと B4b/B4d が落ちる" "B4b B4d " \
      "$(mutate_run '/dry-run。ここで終わり/{n;s/exit 0/:/;}')"

  # N4: 刻印の一致を門でなくする。「rsync が黙って何もしていない」を通してしまう。
  chk "N4 ★陰性: 刻印の門を潰すと B7a/B7b が落ちる" "B7a B7b " \
      "$(mutate_run '/LIVE_REV" = "\$SRC_REV/s/exit 1/:/')"

  # N5: B9 だけは**式を単体で当てる**。理由 = 絶対 path 版の台本を suite で実走させると、
  #     偽物を迂回した本物の ssh が起動して**外へ名前解決を試みる**。この計器の売りは
  #     「何一つ本物に触らない」事なので、それを陰性対照の為に破るのは本末転倒。
  #     (壊れ方も予測しづらく、NG 集合が巨大になって陰性対照として読めない)
  /usr/bin/sed 's|^ssh "\$EDITH" bash -s -- |/usr/bin/ssh "$EDITH" bash -s -- |' "$DEPLOY" > "$SB/abs.sh"
  chk "N5 ★陰性: 呼び方を絶対 path に変えると B9 の式が拾う(実走はさせない)" 1 \
      "$([ "$(abs_calls "$SB/abs.sh")" -gt 0 ] && echo 1 || echo 0)"
  # ★空振り防止: そもそも sed が当たったか(当たらなければ上は常に 0 で、緑にも赤にもならない)
  chk "N5b ★陰性の空振り防止: 変異が本当に台本を変えている" 1 \
      "$(/usr/bin/diff -q "$DEPLOY" "$SB/abs.sh" >/dev/null 2>&1 && echo 0 || echo 1)"
fi

echo "--- 合計: PASS $pass / FAIL $fail ---"
[ "$fail" = 0 ]
