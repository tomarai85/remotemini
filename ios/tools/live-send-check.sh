#!/bin/bash
# Sprint 5 DoD 9行目 —— **電話の送信路を、本物の rc-backend へ実際に当てる**。
#
# 何を確かめるか(3つ、全部**観測**で):
#   1. 製品の `SendClient` が本物のサーバから `display` を受け取る(モックではなく)
#   2. その `display` が `kind=ok` / `keepText=false` = サーバ側 `delivered:"verified"` の顔
#   3. 送った本文が**転写(jsonl)に着いている** = 行数が増える
#      ★2 だけでは足りない。サーバが「取り込まれた」と言った事と、Claude Code が実際に
#        受け取った事は別の主張。3 が無いと前者を後者として読む型になる。
#
# 走る場所: 送る側 = この機械(Jervis、swiftc がある)。建てる側 = edith(rc-backend の本番)。
# 経路: tailnet の https。`tailscale serve` が 127.0.0.1:8787 へ渡している。
#
# ★鍵の扱い: `ssh edith 'cat ~/.rc-backend/api.key'` を**変数に取って標準入力へ流すだけ**。
#   - argv に置かない(`ps` に出る)/ 環境変数に置かない(`ps -E` と子に漏れる)
#   - 印字しない / log に残さない。`printf` は bash の組込みなのでプロセスにならない。
# ★会話 id も出さない(`live-http-check.mjs` と同じ理由で、id は持ち出さない)。
#
# 使い方: ios/tools/live-send-check.sh [--url URL] [--host SSH先] [--keep]
#   --keep = 終わってもセッションを畳まない(人が画面を見たい時だけ)
#
# 終了コード: 0 = 全部通った / 1 = 測って赤い(直す物が在る) / 2 = 準備段で中断(何も測れていない)
#            3 = 運ぶ層は通ったが相手が答えていない(**利用上限**。直す物は無い、待つ)
#   意味と順序(2 > 1 > 3 > 0)の正本は `rc-backend/tools/exit-codes.mjs`。
#   ★3 を足したのは 2026-08-06。同じ日に `.mjs` の計器4本を揃えた時、census が
#     `tools/live-*.mjs` しか数えておらず shell の2本を落としていた —— 教訓を一部にしか
#     運ばない型が、其れを直す為の道具自身に出た。census は `test/live-exit-codes.test.mjs`。
set -uo pipefail

# ★2026-08-27: 既定を edith から friday へ。edith は 2026-08-20 に譲渡され艦隊機ではない。
#   port が要るのは friday の 443 が別サービス(resonance-os)で 404 を返す為 —— rc-backend の
#   tailnet 側の入口は 9443(deploy-to-friday.sh の注記と一致、同日実測)。
#   この既定が古いままだった間、**この道具は起動すらできなかった**(電話の製品コードを
#   実サーバへ当てる唯一の道具が、7日間使えない状態で放置されていた)。
URL="${RC_LIVE_URL:-https://desk.tailnet.example:9443}"
# ★短い別名を使う理由(2026-08-27): `athenas` は ~/.ssh/config に在り、艦隊の他の全経路も
#   これを使う。機体の解決先(IP か MagicDNS か)を config の1箇所に閉じ込める為で、
#   逆に `desk.tailnet.example` は known_hosts に無く弾かれる(同日実測)。
#   Tom の `~/.ssh/config` に Host エントリが入るまでは名前を全部書く方が動く。
SSH_HOST="${RC_LIVE_SSH:-athenas}"
REMOTE_TOOLS="${RC_LIVE_REMOTE:-\$HOME/rc-backend/tools}"
# ★2026-08-27: 相手の機械の `node` を**実行時に訊く**。パスを焼き込まない。
#   friday の非対話 ssh の PATH には homebrew が入っておらず(実測: `command -v node` が空、
#   実体は /opt/homebrew/bin/node)、素の `node` を打つ全ての段が
#   `command not found` で落ちていた。edith には `~/.zshenv` の手当てが在ったので、
#   機体が変わって初めて露出した種類の依存。
#   ★既定値として path を書かないのは、次に機体が変わった時に**また同じ形で腐る**から。
#   見つからなければ**大声で落ちる**(黙って素の `node` に倒すと、原因が3段先で出る)。
REMOTE_NODE="${RC_LIVE_NODE:-}"
KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --url) URL="$2"; shift 2 ;;
    --host) SSH_HOST="$2"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    # 判定だけを撃つ入口。引数はそのまま残して輪を抜ける(受けるのは send_verdict の下)。
    --verdict) break ;;
    *) echo "知らない引数: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$REMOTE_NODE" ]; then
  REMOTE_NODE="$(ssh "$SSH_HOST" 'command -v node || ls /opt/homebrew/bin/node 2>/dev/null' 2>/dev/null | head -1)"
fi
if [ -z "$REMOTE_NODE" ]; then
  echo "相手の機械($SSH_HOST)で node が見つからない。RC_LIVE_NODE=/path/to/node で渡せる" >&2
  exit 2
fi

# ── 判定 ──────────────────────────────────────────────────────────────────────
# 観測値だけを受け取って終了コードを決める。**実機に一切触らない**ので、対照
# (`live-send-check-control.sh`)から真理値表で直に駆動できる。
#
# なぜ関数に切ったか(2026-08-06): 此処は 0/1/3 を決める分岐なのに、edith が要るせいで
# **一度も走った事が無い**まま書かれていた。この session で `.mjs` 側の
# `exitCodeFor` に真理値表を当てた(`rc-backend/test/live-exit-codes.test.mjs`)のと
# 同じ物が shell 側にも要る —— shell からは正本を import 出来ないので、写しの側が
# 黙ってずれる余地が此処にだけ残る。
#
# 引数: <RC> <MISS> <K1 kind=ok> <K2 keepText> <K3 転写に居る> <limited の答え> [転写の詳細]
# 戻り: 0 = 全部通った / 1 = 測って赤い / 3 = 上限で測れていない
send_verdict() {
  local rc="$1" miss="$2" k1="$3" k2="$4" k3="$5" limited="$6" detail="${7:-}"
  local fail=0 lim=0
  [ "$limited" = "limited" ] && lim=1

  # 上限に依らない足 —— 此処が赤いなら上限では説明が付かない = 本物の欠陥(だから 1 > 3)。
  if [ "$rc" = "0" ]; then echo "  ok  : 電話のコードが display を受け取った"
  else echo "  NG  : display が届いていない(終了コード $rc)"; fail=1; fi
  if [ "$miss" = "0" ]; then echo "  ok  : 陰性対照 0 件(数える口は生きている)"
  else echo "  NG  : 陰性対照が $miss 件(上の一致は測定になっていない)"; fail=1; fi

  # 上限に依る足 —— 上限が観測されている回は赤ではなく **未測定** へ倒す。
  # ★倒し忘れると `rc-backend/tools/exit-codes.mjs` の順序が牙を剥く
  #   (「待てば直る物」を「直す物」として報告する計器になる)。
  # ★bash の動的スコープで、上の `fail` / `lim` は此の中から見える(local のまま書ける)。
  mark() { # mark <ok か> <本文>
    if [ "$1" = "1" ]; then echo "  ok  : $2"
    elif [ "$lim" = "1" ]; then echo "  --  : $2 —— **測っていない**(上限の告知が出ている)"
    else echo "  NG  : $2"; fail=1; fi
  }
  mark "$k1" "kind=ok"
  mark "$k2" "keepText=false(= サーバは verified と言っている)"
  mark "$k3" "送った本文が転写に居る(${detail:-増分は上の行})"

  if [ "$fail" != "0" ]; then echo "→ DoD 9行目: 閉じていない"; return 1; fi
  if [ "$lim" = "1" ] && [ "$k1$k2$k3" != "111" ]; then
    echo "→ DoD 9行目: **測れていない**。運ぶ層は通ったが相手が上限で答えていない。"
    echo "   直す物は無い。解除を待って回し直す事(転写は残す)。"
    return 3
  fi
  echo "→ DoD 9行目: 観測で閉じた"
  return 0
}

# 対照からの入口。実機も ssh も要らない —— 判定だけを撃つ。
if [ "${1:-}" = "--verdict" ]; then
  shift
  send_verdict "$@"
  exit $?
fi

IOS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
BIN="$WORK/rc-live-send"
SESSION=""
SID=""

VERDICT_OK=0
cleanup() {
  if [ -n "$SESSION" ] && [ "$KEEP" = "0" ]; then
    echo "--- 畳む ---"
    # ★転写を消すのは**緑だった時だけ**。転んだ走行の転写は、人が次に読む唯一の物なので残す。
    PURGE=""
    [ "$VERDICT_OK" = "1" ] && PURGE=" --purge-transcript"
    [ "$VERDICT_OK" = "1" ] || echo "(判定が緑でないので転写は残す)"
    ssh "$SSH_HOST" "$REMOTE_NODE $REMOTE_TOOLS/disposable-session.mjs down '$SESSION' '$SID'$PURGE" 2>&1 |
      sed "s#$SID#<会話 id>#g"
  elif [ -n "$SESSION" ]; then
    echo "--keep: セッションを残した(畳むのは人の手)"
  fi
  /bin/rm -rf "$WORK"
}
trap cleanup EXIT

echo "=== 1. 電話側の殻を建てる(製品の Swift をそのまま使う) ==="
# ★ここで建てるのは**製品コード**。`Sources/Core/` の3本は アプリの target と同じ file。
swiftc -O -o "$BIN" \
  "$IOS_DIR/tools/live-send-main.swift" \
  "$IOS_DIR/Sources/Core/SendClient.swift" \
  "$IOS_DIR/Sources/Core/ResultDisplay.swift" \
  "$IOS_DIR/Sources/Core/BackendSession.swift" || { echo "swiftc が通らない"; exit 2; }
echo "ok: $(/usr/bin/stat -f %z "$BIN") bytes"

echo
echo "=== 2. edith に使い捨ての本物 TUI を建てる ==="
UP="$(ssh "$SSH_HOST" "$REMOTE_NODE $REMOTE_TOOLS/disposable-session.mjs up")" || { echo "建たなかった"; exit 2; }
SESSION="$(printf '%s\n' "$UP" | sed -n 1p)"
SID="$(printf '%s\n' "$UP" | sed -n 2p)"
if [ -z "$SESSION" ] || [ -z "$SID" ]; then echo "up の出力が2行ではない"; exit 2; fi
echo "セッション: $SESSION(会話 id は出さない)"

echo
echo "=== 3. 送る前の転写の行数 ==="
BEFORE="$(ssh "$SSH_HOST" "$REMOTE_NODE $REMOTE_TOOLS/disposable-session.mjs lines '$SID'" 2>/dev/null || echo 0)"
BEFORE="${BEFORE:-0}"
echo "before = $BEFORE 行"

echo
echo "=== 4. 電話のコードで送る ==="
# 本文は一意にする(転写の増分が**この送信の物**だと言える様に)。id は混ぜない。
BODY="rc-live-send probe $(date +%Y%m%d-%H%M%S) —— 返事は要りません"
KEY="$(ssh "$SSH_HOST" 'cat ~/.rc-backend/api.key')" || { echo "鍵が読めない"; exit 2; }
[ -n "$KEY" ] || { echo "鍵が空"; exit 2; }
OUT="$(printf '%s\n%s\n%s\n%s\n' "$URL" "$SID" "$KEY" "$BODY" | "$BIN" 2>&1)"
RC=$?
KEY=""
printf '%s\n' "$OUT" | sed "s#$SID#<会話 id>#g"
echo "終了コード = $RC"

echo
echo "=== 5. 送った本文が転写に着いたか(サーバの言い分ではなく、file を数える) ==="
# ★行数の増分**では足りない**。使い捨ての会話は転写が無い所から始まるので、
#   「0 → 7 行」には起動そのものが書いた行が混ざる。増えた事は「私の本文が着いた事」を
#   意味しない。だから一意な本文そのものを数える(件数だけが返る)。
AFTER="$BEFORE"
HITS=0
for _ in $(seq 1 20); do
  sleep 3
  AFTER="$(ssh "$SSH_HOST" "$REMOTE_NODE $REMOTE_TOOLS/disposable-session.mjs lines '$SID'" 2>/dev/null || echo 0)"
  AFTER="${AFTER:-0}"
  HITS="$(ssh "$SSH_HOST" "$REMOTE_NODE $REMOTE_TOOLS/disposable-session.mjs contains '$SID' '$BODY'" 2>/dev/null || echo 0)"
  HITS="${HITS:-0}"
  [ "$HITS" -gt 0 ] && break
done
echo "行数 = $AFTER(送る前 $BEFORE) / 本文の一致 = $HITS 件"
# ★陰性対照。数える口が壊れて「いつでも1件以上」を返すなら、上の ok は何も測っていない。
#   送っていない本文が 0 件で返る事を、同じ口で確かめる。
DECOY="rc-live-send decoy $(date +%Y%m%d-%H%M%S)-not-sent"
MISS="$(ssh "$SSH_HOST" "$REMOTE_NODE $REMOTE_TOOLS/disposable-session.mjs contains '$SID' '$DECOY'" 2>/dev/null || echo -1)"
echo "陰性対照(送っていない本文)= $MISS 件"

echo
echo "=== 6. 相手が上限で答えられない状態か(赤の意味が変わるので判定の前に訊く)==="
# ★2026-08-06 に足した。上限だと画面が入力欄でなく告知になり得て、其の時サーバは
#   「送れない」と答える。それは**経路の欠陥ではない**のに、下の kind=ok / keepText /
#   転写の3行が揃って赤くなり、読み手は在りもしない欠陥を探しに行く。8/02 に
#   `live-inject-check.mjs` が解いた束ねと同じ形。分類器は最初から `limited` を立てている。
LIMITED="$(ssh "$SSH_HOST" "$REMOTE_NODE $REMOTE_TOOLS/disposable-session.mjs limited '$SID'" 2>/dev/null || echo "")"
echo "利用上限の告知 = ${LIMITED:-訊けなかった}"

echo
echo "=== 判定 ==="
printf '%s' "$OUT" | grep -q "kind=ok" && K1=1 || K1=0
printf '%s' "$OUT" | grep -q "keepText=false" && K2=1 || K2=0
[ "$HITS" -gt 0 ] && K3=1 || K3=0
send_verdict "$RC" "$MISS" "$K1" "$K2" "$K3" "$LIMITED" "$HITS 件 / 行数は $BEFORE → $AFTER"
CODE=$?
# ★VERDICT_OK は 0 の時だけ立てる = 上限で落ちた回の転写は**消さない**(後から読む物が要る)。
[ "$CODE" = "0" ] && VERDICT_OK=1
exit "$CODE"
