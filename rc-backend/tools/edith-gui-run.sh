#!/bin/bash
# edith の **launchd(gui/501)の中で** コマンドを1回走らせ、終了コードと出力を持ち帰る。
# 走らせた物は必ず畳んで消し、**不在を確認**してから終わる(edith に常設物を置かない)。
#
# ── なぜ ssh で直接測ってはいけないか(2026-08-02 実測、HANDOFF §1-G-2) ──────
# `ssh edith claude -p …` は**必ず** `Not logged in` を返す。未ログインだからではない:
#   security find-generic-password -w  を **ssh から** → exit 36(interaction not allowed)
#   同じ物を **launchd gui/501 の中から**   → exit 0
# ssh の非対話セッションは login keychain を開けない。つまり ssh 越しに `claude` を
# 含む検査を書くと、**製品の状態と無関係な赤**が出る。計器が製品と違う経路を測っている。
#   ★同じ型を一晩で3回踏んでいる(locale / runStrict / これ)。だからこの台本が在る。
#
# ── この台本が「本当に launchd の中に居る」事の測り方(2026-08-02 実測) ──────
# 使える判別子は2つ。どちらも**両方向で違う値が出る**事を確かめてある:
#     test -z "$SSH_CONNECTION"                          → 中 0 / ssh 直 1
#     security show-keychain-info …/login.keychain-db     → 中 0 / ssh 直 36
#   後者が本命(製品が要るのは「keychain が**解錠**されている事」そのもの)。しかも
#   秘密を1バイトも読まない = 安全弁と喧嘩しない。
# ★使えない判別子: `security find-generic-password -s <名前>`(`-w` 無し)は
#   **ssh 越しでも 0 を返す**。最初これで測って緑を得たが、対照を撃ったら ssh 側も
#   0 だった —— 何も判別していなかった。錠を開ける必要が在るのは**中身を読む時だけ**で、
#   在るかどうかを聞くだけなら錠は要らない。
#   型: 片側しか測らない緑は「差が在る」の証拠にならない。必ず反対側も撃つ事。
#
# ── ★この台本を**要らない場面で使わない**(2026-08-02 深夜、範囲の訂正) ────────
# 上の「ssh では keychain が開かない」は **`claude` を直接 exec する時の話**であって、
# **tmux の pane に `claude` と打ち込む時には当てはまらない**。pane の環境は
# **先に立っている tmux server** から来る(edith の server は 7/28 起動・Tom の `work`)ので、
# ログインシェルの PATH と keychain 文脈をそのまま持っている。実測:
#     pane の PATH → /opt/homebrew/bin:/Users/edith/.local/bin:… で `claude` が解決する
#     8/02 05:48 の ssh 経由の走行 → 4/4 delivered、画面は **`You've hit your weekly limit`**
#       = `Not logged in` ではない = **あの時点で認証は通っていた**
# だから `tools/live-inject-check.mjs`(pane に打ち込む方式)は ssh 越しでも正しく測れる。
#   ★この台本が本当に要るのは **`claude` を直接 exec する検査**(`-p` 系 / `live-http-check`)。
#   証拠の在り処 = `test/fixtures/screens/limit-reached-edith.txt`
#
# ── 使い方 ─────────────────────────────────────────────────────────────
#   bash tools/edith-gui-run.sh -- /usr/bin/true
#   bash tools/edith-gui-run.sh --timeout 300 -- node /path/live-inject-check.mjs --cases A
# 終了コード: 中で走ったコマンドの終了コードをそのまま返す。
#   ただし 90-94 は**この台本自身**の失敗(下の EXIT_* 参照)。中のコマンドが 90 台を
#   返す設計なら、この台本は使わない事。
#
# ── 決して破らない事 ───────────────────────────────────────────────────
#   - `bootout` するのは**自分で作った使い捨て label だけ**。本番 `com.edith.rc-backend`
#     には触れない(そもそも label の接頭辞で機械的に弾く)。
#   - 秘密を印字しない。keychain の**中身**を読む形(`-w`)は受け付けない = fail-closed。
#   - remote へ渡す物は base64 で運ぶ。二重引用符で組み立てると**送る前に手元の shell に
#     食われる**(2026-08-01 の run7 が実際に踏んだ。逆引用符がこちらで実行された)。
set -u

EXIT_UNREACHABLE=90   # ssh が通らない
EXIT_REFUSED=91       # こちらの安全弁で拒否した
EXIT_BOOTSTRAP=92     # launchd に載せられなかった
EXIT_TIMEOUT=93       # 時間内に終わらなかった
EXIT_DIRT=94          # 後片付けの確認が取れなかった(★緑にしない)

HOST="${RC_EDITH_HOST:-edith@10.0.0.0}"
TIMEOUT=180
LABEL_PREFIX="com.edith.rcprobe"

while [ $# -gt 0 ]; do
  case "$1" in
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --host)    HOST="$2";    shift 2 ;;
    --)        shift; break ;;
    *) echo "使い方: $0 [--timeout 秒] [--host user@addr] -- <コマンド…>" >&2; exit "$EXIT_REFUSED" ;;
  esac
done
if [ $# -eq 0 ]; then
  # ★ここに逆引用符を書かない(二重引用符の中ではコマンド置換として実行される)。
  echo '走らせるコマンドが無い。ハイフン2つの後ろに書く。' >&2; exit "$EXIT_REFUSED"
fi

# ★引数を1本の文字列に潰さない。`"$*"` で繋ぐと**引用符が消える**:
#   `-- /bin/sh -c 'exit 7'` が `/bin/sh -c exit 7` になり、`7` が $0 に落ちて **exit 0**。
#   2026-08-02、最初の版が実際にこれで「終了コードを持ち帰る台本」なのに常に 0 を返した。
#   計器としては最悪の壊れ方(いつも緑)なので、argv のまま base64 で1本ずつ運ぶ。
CMD="$*"          # 安全弁の検査**だけ**に使う。実行には使わない。
ARGS_B64="$(for a in "$@"; do printf '%s' "$a" | base64 | tr -d '\n'; printf '\n'; done | base64 | tr -d '\n')"

# ── 安全弁: keychain の中身を読む形を受け付けない ────────────────────────
# ★何が引っ掛かったかは言うが、**コマンドそのものは印字しない**(秘密を守る検査が
#   秘密を晒しては本末転倒。2026-08-02 に立てた規則)。
if printf '%s' "$CMD" | grep -q 'find-generic-password.*-w'; then
  echo "拒否: keychain の**中身**を読む形(find-generic-password の -w)は通さない。" >&2
  echo "      在る事だけ確かめたいなら -w を外す(メタ情報だけなら exit 0 で判る)。" >&2
  exit "$EXIT_REFUSED"
fi

# ★remote 台本は**一度ファイルに落としてから**標準入力で渡す。
#   `OUT="$(ssh … <<'REMOTE' … )"` と書くと bash が終端語の後ろの `)` を読めず
#   `syntax error near unexpected token ')'` になる(2026-08-02 実測)。
#   引用符付きヒアドキュメントである事(= 一切展開しない)は変わらない。
REMOTE_SCRIPT="$(mktemp /tmp/edith-gui-run-remote.XXXXXX)"
trap '/bin/rm -f -- "$REMOTE_SCRIPT"' EXIT INT TERM
cat > "$REMOTE_SCRIPT" <<'REMOTE'
set -u
ARGS64="$1"; TIMEOUT="$2"; PREFIX="$3"   # ★argv の一覧(1本ずつ base64)であってコマンド文字列ではない
UID_N="$(id -u)"
LABEL="${PREFIX}-$$-$(date +%s)"
DIR="$(mktemp -d /tmp/rcprobe.XXXXXX)"
PLIST="$DIR/$LABEL.plist"
CMDFILE="$DIR/cmd.sh"
RCFILE="$DIR/rc"

# 安全弁(remote 側にも置く。手元だけの検査は、手元を迂回されると効かない)
if [ "${LABEL#com.edith.rcprobe-}" = "$LABEL" ]; then
  echo "REMOTE-REFUSED label 接頭辞が違う"; exit 91
fi

D64() { printf '%s' "$1" | base64 -D 2>/dev/null || printf '%s' "$1" | base64 -d; }
D64 "$ARGS64" > "$DIR/args.list"
{
  echo '#!/bin/bash'
  echo 'set -u'
  echo 'D="$(dirname "$0")"'
  # argv を**1本ずつ**復号して配列へ戻す。ここで文字列に潰すと引用符が失われる。
  echo 'argv=()'
  echo 'while IFS= read -r l; do'
  echo '  [ -z "$l" ] && continue'
  echo '  argv+=("$(printf %s "$l" | base64 -D 2>/dev/null || printf %s "$l" | base64 -d)")'
  echo 'done < "$D/args.list"'
  # ★終了コードは**パイプを通さずに**掴む。パイプの最後段の値を読むと嘘になる。
  echo '"${argv[@]}"'
  echo 'echo "$?" > "$D/rc"'
} > "$CMDFILE"
chmod +x "$CMDFILE"

cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array><string>/bin/bash</string><string>$CMDFILE</string></array>
    <key>RunAtLoad</key><true/>
    <key>StandardOutPath</key><string>$DIR/out</string>
    <key>StandardErrorPath</key><string>$DIR/err</string>
</dict>
</plist>
PL

cleanup() {
  launchctl bootout "gui/$UID_N/$LABEL" 2>/dev/null
  # ★消す物の**一覧を書き写さない**。写しを持つと、後で file を1つ足した時に必ず
  #   片方だけ置き去りになる —— 2026-08-02、最初の版が実際にこれで転んだ:
  #   `args.list` を足したのに消す側に書き足さず、rmdir が落ちて DIRT=94 になった。
  #   (救われたのは「不在を確認する」検査が在ったから。消したつもりで終わっていたら
  #    edith に残骸が溜まり続けていた)
  #   自分で mktemp した木の中だけを、再帰なしで畳む。
  find "$DIR" -type f -print0 2>/dev/null | xargs -0 /bin/rm -f 2>/dev/null
  rmdir "$DIR" 2>/dev/null
  # ★不在を**確認**する。消したつもりで終わらない。
  if [ -e "$DIR" ]; then echo "DIRT $DIR が残っている"; fi
  if launchctl print "gui/$UID_N/$LABEL" >/dev/null 2>&1; then echo "DIRT job $LABEL が残っている"; fi
}

if ! launchctl bootstrap "gui/$UID_N" "$PLIST" 2>/dev/null; then
  echo "BOOTSTRAP-FAILED"; cleanup; exit 92
fi

waited=0
while [ ! -f "$RCFILE" ] && [ "$waited" -lt "$TIMEOUT" ]; do
  sleep 1; waited=$((waited+1))
done

if [ ! -f "$RCFILE" ]; then
  echo "TIMEOUT ${TIMEOUT}秒"; echo "--- 出力(途中) ---"; cat "$DIR/out" 2>/dev/null; cat "$DIR/err" 2>/dev/null
  cleanup; exit 93
fi

rc="$(cat "$RCFILE")"
echo "REMOTE-EXIT=$rc"
echo "REMOTE-ELAPSED=${waited}秒"
echo "--- stdout ---"; cat "$DIR/out" 2>/dev/null
echo "--- stderr ---"; cat "$DIR/err" 2>/dev/null
dirt="$(cleanup)"
[ -n "$dirt" ] && echo "$dirt"
exit "$rc"
REMOTE

OUT="$(ssh -o ConnectTimeout=10 "$HOST" bash -s -- "$ARGS_B64" "$TIMEOUT" "$LABEL_PREFIX" < "$REMOTE_SCRIPT" 2>&1)"
SSH_RC=$?

if [ "$SSH_RC" -eq 255 ]; then
  echo "$OUT"; echo "★edith に届かない(ssh)"; exit "$EXIT_UNREACHABLE"
fi

printf '%s\n' "$OUT"

# 後片付けの確認が取れていなければ、中身が緑でも**緑にしない**。
if printf '%s' "$OUT" | grep -q '^DIRT '; then
  echo "★後片付けが確認できていない。上の DIRT 行を手で片付ける事。"
  exit "$EXIT_DIRT"
fi
exit "$SSH_RC"
