#!/bin/bash
# Sprint 6 DoD 9行目 —— **電話の割り込み路を、本物の rc-backend へ実際に当てる**。
#
# 何を確かめるか(全部**観測**で):
#   1. 製品の `InterruptClient` が本物のサーバから `display` を受け取る(モックではなく)
#   2. その `display` が「Stopped (generation confirmed stopped).」= サーバ側 `stopped:"verified"`
#      ★電話は `stopped` を**読まない**(`InterruptClient` の見出し ★ 参照)。だから此処でも
#        生フィールドは見ない。`view.mjs` の `interruptResult` が `"verified"` の時にだけ
#        書く文を、電話が受け取った事で確かめる —— 四択の他の3つは全部**別の文**になる。
#   3. 撃つ瞬間に**本当に生成中だった**事(`disposable-session.mjs busy` で観測してから撃つ)
#   4. 陰性対照A: 止まった後の同じ会話へもう一度撃つと、**verified の文は出ない**
#      ★これが無いと 2 は「この口はいつでも止めましたと言う」の可能性を排除できない。
#   5. 陰性対照B: でたらめな鍵で撃つと 401
#      ★これが無いと「本物のサーバに当たっている」事自体が、返事の顔だけの主張になる。
#
# 走る場所: 撃つ側 = この機械(Jervis、swiftc がある)。建てる側 = edith(rc-backend の本番)。
# 経路: tailnet の https。`tailscale serve` が 127.0.0.1:8787 へ渡している。
#
# ★鍵の扱いは `live-send-check.sh` と同じ: 変数に取って**標準入力へ流すだけ**。
#   argv に置かない(`ps` に出る)/ 環境変数に置かない(`ps -E` と子に漏れる)/ 印字しない。
# ★会話 id も出さない。
#
# 終了コード: 0 = 観測で閉じた / 1 = 閉じていない(経路の側) / 2 = **測れていない**(仕込みの側)
#            3 = 運ぶ層は通ったが相手が答えていない(**利用上限**。直す物は無い、待つ)
#   意味と順序(2 > 1 > 3 > 0)の正本は `rc-backend/tools/exit-codes.mjs`。
#   ★shell の台本2本が 3 を持っていなかったのを 2026-08-06 に揃えた —— 同じ日に
#     `.mjs` 4本を数えて直した時、census が `tools/live-*.mjs` しか見ておらず
#     `ios/tools/live-*.sh` を数え落としていた(教訓を N 箇所のうち一部にしか運ばない型が、
#     其れを直す道具自身にも出た)。
#   ★2 を 1 に丸めない。「生成中に撃てなかった」は割り込みが壊れている事の証拠ではないので、
#     同じ色にすると、次に読む人が原因を検査の側と経路の側で取り違える。
#
# 使い方: ios/tools/live-interrupt-check.sh [--url URL] [--host SSH先] [--keep]
#   --keep = 終わってもセッションを畳まない(人が画面を見たい時だけ)
set -uo pipefail

# サーバが `stopped:"verified"` の時にだけ書く文(`src/view.mjs` の `interruptResult`)。
VERIFIED_TEXT="Stopped (generation confirmed stopped)."

# 割り込みの返り文を四択のどれかに名付ける。**純粋な文字列判定**(通信もしない)。
#
# ★関数に切り出してあるのは、`--classify` から呼べる様にする為。此処が此の script の
#   判定の全てで、実機を1回走らせただけでは **verified の枝しか通らない**。残り3枝は
#   「仕込みが甘かった走行」を名指しする側なので、通らないまま置くと
#   「壊れている」と「測れていない」を取り違える口が**無検査で残る**。
#   対照は `.harness/live-interrupt-wording-controls.sh`。
classify_interrupt_text() {
    case "$1" in
        *"$VERIFIED_TEXT"*) echo verified ;;
        *"It had already finished"*) echo already-done ;;
        *"Nothing was running to stop ("*) echo not-in-flight ;;
        *"has not stopped yet"*) echo unverified ;;
        *) echo unknown ;;
    esac
}

# 生成中を1度も観測できずに輪が尽きた時の判定。
# 引数: <busy の最後の答え> <limited の答え>
# 戻り: 3 = 上限(運ぶ層は通った。直す物は無い、待つ)/ 2 = 測れていない(仕込みの側)
#
# ★2026-08-06: 上限だと仕込みの番は投げられても生成が始まらないので、輪は必ず尽きる。
#   元の文面は「仕込みの側の失敗」と断じていて、読み手を在りもしない欠陥へ送っていた。
busy_exhausted_verdict() {
    local busy="${1:-}" lim="${2:-}"
    echo "60 秒回しても生成中を1度も観測できなかった(最後の答え: ${busy:-無})"
    if [ "$lim" = "limited" ]; then
        echo "→ 画面に**利用上限の告知**が出ている。仕込みも割り込みも壊れていない。"
        echo "   運ぶ層は通った(仕込みの送信は終了コード 0)が、相手が答えていないだけ。"
        echo "   **直す物は無い。解除を待って回し直す事。**"
        return 3
    fi
    echo "→ **測れていない**。割り込みが壊れている証拠ではない(仕込みの側の失敗)"
    echo "   (上限の告知は出ていない: limited の答え = ${lim:-訊けなかった})"
    return 2
}

# 最後の判定。4つの足を観測値として受け、0/1/2/3 を決める。
# 引数: <割り込みの終了コード> <分類語> <陰性対照A> <陰性対照B> <limited の答え> [B の終了コード]
#   陰性対照A: clean(verified の文は出なかった)/ verified-again / empty
#   陰性対照B: 401 / no
#
# ★順序が `rc-backend/tools/exit-codes.mjs` の `2 > 1 > 3 > 0` と**違って見える**理由:
#   此処の 2 は prepAbort(準備段で中断)ではない。準備段の中断は上の 1-4 節が
#   その場で 2 を返して此処へ来ない。此処の 2 は「主の足が着地しなかった」で、
#   陰性対照の2本は**それとは独立に測れている** —— だから其処に赤が在るなら
#   本物の欠陥で、1 が勝つ。同じ数字が2つの意味を持つので、順序も別になる。
interrupt_verdict() {
    local rc="${1:-}" kind="${2:-}" ctrl_a="${3:-}" ctrl_b="${4:-}" lim="${5:-}" b_rc="${6:--}"
    local fail=0 unmea=0
    if [ "$rc" = "0" ]; then
        echo "  ok  : 電話のコードが display を受け取った"
    else
        echo "  NG  : display が届いていない(終了コード $rc)"; fail=1
    fi
    case "$kind" in
      verified)      echo "  ok  : サーバ側 stopped=verified の文が届いた" ;;
      already-done)  echo "  --  : already-done(撃つ前に番が自力で終わっていた)= **測れていない**"; unmea=1 ;;
      not-in-flight) echo "  --  : 止める対象なし(生成中の観測と撃鍵の間に終わった)= **測れていない**"; unmea=1 ;;
      unverified)    echo "  NG  : unverified(動いていたが期限内に止まりを観測できない)"; fail=1 ;;
      *)             echo "  NG  : 想定していない文だった($kind)"; fail=1 ;;
    esac
    case "$ctrl_a" in
      clean)          echo "  ok  : 陰性対照A —— verified の文は出なかった" ;;
      verified-again) echo "  NG  : 陰性対照A —— 止まった後の会話にも verified の文が出た(上の緑は測定ではない)"; fail=1 ;;
      *)              echo "  NG  : 陰性対照A —— 何も返っていない(対照が成立していない)"; fail=1 ;;
    esac
    if [ "$ctrl_b" = "401" ]; then
        echo "  ok  : 陰性対照B —— でたらめな鍵は 401(本物のサーバに当たっている)"
    else
        echo "  NG  : 陰性対照B —— でたらめな鍵が 401 にならない(終了コード $b_rc)"; fail=1
    fi
    if [ "$fail" != "0" ]; then
        echo "→ DoD 9行目: 閉じていない"
        return 1
    fi
    if [ "$unmea" != "0" ]; then
        if [ "$lim" = "limited" ]; then
            echo "→ DoD 9行目: **測れていない**が、画面に**利用上限の告知**が出ている。"
            echo "   仕込みの番が上限で途中終了した = 直す物は無い。解除を待って回し直す事。"
            return 3
        fi
        echo "→ DoD 9行目: **測れていない**(仕込みが生成中を保てなかった。回し直す)"
        return 2
    fi
    echo "→ DoD 9行目: 観測で閉じた"
    return 0
}

# `--classify <文>` = 通信も build もせず、判定だけを1語で出して終わる(対照から呼ぶ口)。
# `--busy-verdict` / `--verdict` も同じ趣旨 —— 実機の会話なしに判定だけを撃つ。
# ★引数の輪**より前**に置く。輪の既定は「知らない引数は 2 で落とす」なので、
#   後ろに置くと此の口は永久に届かない(2026-08-06、対照が 5/5 赤で捕まえた)。
if [ "${1:-}" = "--classify" ]; then
    classify_interrupt_text "${2:-}"
    exit 0
fi
if [ "${1:-}" = "--busy-verdict" ]; then
    shift; busy_exhausted_verdict "$@"; exit $?
fi
if [ "${1:-}" = "--verdict" ]; then
    shift; interrupt_verdict "$@"; exit $?
fi

# ★2026-08-27: 既定を edith から friday へ。edith は 2026-08-20 に譲渡され艦隊機ではない。
#   port が要るのは friday の 443 が別サービス(resonance-os)で 404 を返す為 —— rc-backend の
#   tailnet 側の入口は 9443(deploy-to-friday.sh の注記と一致、同日実測)。
#   この既定が古いままだった間、**この道具は起動すらできなかった**(電話の製品コードを
#   実サーバへ当てる唯一の道具が、7日間使えない状態で放置されていた)。
URL="${RC_LIVE_URL:-https://desk.tailnet.example:9443}"
# ★短い別名を使う理由(2026-08-27): `athenas` は ~/.ssh/config に在り、艦隊の他の全経路も
#   これを使う。機体の解決先(IP か MagicDNS か)を config の1箇所に閉じ込める為で、
#   逆に `desk.tailnet.example` は known_hosts に無く弾かれる(同日実測)。
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

IOS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
SEND_BIN="$WORK/rc-live-send"
INTR_BIN="$WORK/rc-live-interrupt"
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

echo "=== 1. 電話側の殻を2本建てる(製品の Swift をそのまま使う) ==="
# ★ここで建てるのは**製品コード**。`Sources/Core/` の4本は アプリの target と同じ file。
#   `SendOutcome` / `ResultDisplay` は `SendClient.swift` 側に居るので、割り込みの殻にも要る。
CORE=(
  "$IOS_DIR/Sources/Core/SendClient.swift"
  "$IOS_DIR/Sources/Core/ResultDisplay.swift"
  "$IOS_DIR/Sources/Core/BackendSession.swift"
)
swiftc -O -o "$SEND_BIN" "$IOS_DIR/tools/live-send-main.swift" "${CORE[@]}" ||
  { echo "swiftc(送信の殻)が通らない"; exit 2; }
swiftc -O -o "$INTR_BIN" "$IOS_DIR/tools/live-interrupt-main.swift" \
  "$IOS_DIR/Sources/Core/InterruptClient.swift" "${CORE[@]}" ||
  { echo "swiftc(割り込みの殻)が通らない"; exit 2; }
echo "ok: 送信 $(/usr/bin/stat -f %z "$SEND_BIN") bytes / 割り込み $(/usr/bin/stat -f %z "$INTR_BIN") bytes"

echo
echo "=== 2. edith に使い捨ての本物 TUI を建てる ==="
UP="$(ssh "$SSH_HOST" "$REMOTE_NODE $REMOTE_TOOLS/disposable-session.mjs up")" || { echo "建たなかった"; exit 2; }
SESSION="$(printf '%s\n' "$UP" | sed -n 1p)"
SID="$(printf '%s\n' "$UP" | sed -n 2p)"
if [ -z "$SESSION" ] || [ -z "$SID" ]; then echo "up の出力が2行ではない"; exit 2; fi
echo "セッション: $SESSION(会話 id は出さない)"

KEY="$(ssh "$SSH_HOST" 'cat ~/.rc-backend/api.key')" || { echo "鍵が読めない"; exit 2; }
[ -n "$KEY" ] || { echo "鍵が空"; exit 2; }

echo
echo "=== 3. 止める対象を作る(長く喋る番を、電話の送信路で始めさせる) ==="
# ★答えを読むのが目的ではない。**止められる長さ**が要るだけ。本文は一意にして、
#   万一この検査が転んだ時に転写の中で見分けが付く様にする。
PRIME="1 から 400 まで、1行に1つずつ数字だけを書き出してください。前置きも説明も要りません。 [rc-live-interrupt $(date +%Y%m%d-%H%M%S)]"
SEND_OUT="$(printf '%s\n%s\n%s\n%s\n' "$URL" "$SID" "$KEY" "$PRIME" | "$SEND_BIN" 2>&1)"
SEND_RC=$?
printf '%s\n' "$SEND_OUT" | sed "s#$SID#<会話 id>#g"
if [ "$SEND_RC" != "0" ]; then echo "仕込みの送信が届いていない(終了コード $SEND_RC)"; exit 2; fi

echo
echo "=== 4. 本当に生成中になるまで待つ(当て推量の n 秒では撃たない) ==="
# ★`busy` の 1 枚は当てにならない —— スピナーの被覆は 61-82%(`classifyScreen` の見出し)。
#   輪で回して、`observed` を**見たその周**で撃つ。
BUSY=""
BUSY_WAITED=0
for _ in $(seq 1 60); do
  BUSY="$(ssh "$SSH_HOST" "$REMOTE_NODE $REMOTE_TOOLS/disposable-session.mjs busy '$SID'" 2>/dev/null || echo "")"
  case "$BUSY" in
    observed*) break ;;
  esac
  BUSY_WAITED=$((BUSY_WAITED + 1))
  sleep 1
done
case "$BUSY" in
  observed*) echo "生成中を観測(${BUSY_WAITED}s 目 / 材料 = ${BUSY#observed })" ;;
  *)
    # 画面に上限の告知が出ているかは分類器が最初から知っている(`classifyScreen.limited`)。
    LIM="$(ssh "$SSH_HOST" "$REMOTE_NODE $REMOTE_TOOLS/disposable-session.mjs limited '$SID'" 2>/dev/null || echo "")"
    busy_exhausted_verdict "$BUSY" "$LIM"
    exit $?
    ;;
esac

echo
echo "=== 5. 電話のコードで割り込む ==="
INTR_OUT="$(printf '%s\n%s\n%s\n' "$URL" "$SID" "$KEY" | "$INTR_BIN" 2>&1)"
INTR_RC=$?
printf '%s\n' "$INTR_OUT" | sed "s#$SID#<会話 id>#g"
echo "終了コード = $INTR_RC"

echo
echo "=== 6. 陰性対照A: 止まった後にもう一度撃つ(verified の文が出ないこと) ==="
# ★この会話はもう動いていない。同じ口が同じ文を返すなら、上の緑は
#   「止まったのを見た」ではなく「この口はいつでもそう言う」の意味しか持たない。
sleep 3
CTRL_A_BUSY="$(ssh "$SSH_HOST" "$REMOTE_NODE $REMOTE_TOOLS/disposable-session.mjs busy '$SID'" 2>/dev/null || echo "")"
echo "撃つ前の状態 = ${CTRL_A_BUSY:-無}"
CTRL_A_OUT="$(printf '%s\n%s\n%s\n' "$URL" "$SID" "$KEY" | "$INTR_BIN" 2>&1)"
printf '%s\n' "$CTRL_A_OUT" | sed "s#$SID#<会話 id>#g"

echo
echo "=== 7. 陰性対照B: でたらめな鍵(401 が返ること) ==="
# ★鍵を混ぜない値を作る。長さも中身も本物と関係しない。
CTRL_B_OUT="$(printf '%s\n%s\n%s\n' "$URL" "$SID" "not-the-key-$(date +%s)" | "$INTR_BIN" 2>&1)"
CTRL_B_RC=$?
printf '%s\n' "$CTRL_B_OUT" | sed "s#$SID#<会話 id>#g"
KEY=""

echo
echo "=== 判定 ==="
# 観測値を語に落としてから判定へ渡す。判定は通信も grep もしない = 対照から撃てる。
if printf '%s' "$CTRL_A_OUT" | grep -qF "$VERIFIED_TEXT"; then CTRL_A=verified-again
elif [ -z "$CTRL_A_OUT" ]; then CTRL_A=empty
else CTRL_A=clean
fi
if printf '%s' "$CTRL_B_OUT" | grep -qF "outcome=unauthorized"; then CTRL_B=401; else CTRL_B=no; fi
# 主の足が着地しなかった時にだけ意味を持つので、其の時だけ訊く(毎回 ssh を1本増やさない)。
LIMITED=""
case "$(classify_interrupt_text "$INTR_OUT")" in
  already-done|not-in-flight)
    LIMITED="$(ssh "$SSH_HOST" "$REMOTE_NODE $REMOTE_TOOLS/disposable-session.mjs limited '$SID'" 2>/dev/null || echo "")" ;;
esac

interrupt_verdict "$INTR_RC" "$(classify_interrupt_text "$INTR_OUT")" \
  "$CTRL_A" "$CTRL_B" "$LIMITED" "$CTRL_B_RC"
CODE=$?
# ★VERDICT_OK は 0 の時だけ立てる = 転んだ回・上限の回の転写は**消さない**。
[ "$CODE" = "0" ] && VERDICT_OK=1
exit "$CODE"
