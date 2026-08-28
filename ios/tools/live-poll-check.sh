#!/bin/bash
# controls-for: ios/Sources/Core/PollClient.swift ios/Sources/Core/ReadablePoll.swift
#
# live-poll-check.sh — 電話の**受け取り**(`PollClient`)を、本物の rc-backend に当てる。
# ★名前が被覆を誇張しない様に、測る範囲を最初に書く(Codex 2026-08-27:「初回 poll の検査で
#   あって、状態を持つ受け取り経路の検査ではない」— その通りだったので2回目を足した)。
# 2026-08-27 新設。`live-send-check.sh` / `live-interrupt-check.sh` と同じ型。
#
# ★なぜ要るか: 電話の主要な経路のうち、読み・書き・割り込みは本番へ当てた事が在るのに、
#   **受け取りだけ一度も無かった**。Tom が Claude の答えを見るのは此の経路で、単体では
#   `MockURLProtocol` としか繋がっていない。
#
# ★測る物と測らない物を先に書く:
#   測る   = ① 使い捨ての本物の会話に対し、電話の `PollClient` が **読める応答**を受け取る事
#            (二段読み `ReadablePoll.check` → 型付き decode を通った物だけが success)。
#            ② **サーバが返した cursor をそのまま撃ち返して、サーバが受け取る事**。
#            ②が無いと「一度は読めるが二度目から進まない」(= 電話が最初の1画面で固まる)が
#            緑のまま通る。①だけなら実質「200 が JSON の形で返る」しか言っていない。
#          ③ **壊れた cursor を撃った時に、取りこぼしの印(gap)が付いて返る**事(2026-08-28)。
#            エラーが返る事ではない —— `pollDecision` は 200 のまま gap を1件混ぜる設計。
#            印が消えると電話は取りこぼしを黙って捨て、画面は正常に見えたまま出力が抜ける。
#   測らない = ・「送った物への返事が来る」事(`live-send-check.sh` が転写の行数と本文の
#              一致で押さえている)。
#            ・cursor の**進み方**の正しさ(重複 / 取りこぼし / 並べ替え / 再生)。
#            ・待ち受け中に出力が来た時の起こされ方(long-poll の起床)。
#            ・中身の意味(古い出力 / 別の会話の出力 / 途中で切れた本文)。
#            ★Codex 2026-08-27 が「捕まえられない物」として列挙した物を、そのまま書き写す。
#              **測っていない事を名前の隣に置く**のが、この台本の存在理由の半分。
#
# ★陰性対照を3本持つ。A/B だけでは「本物のサーバに当たっているか」しか言えず、
#   C(壊れた cursor)だけが**取りこぼしの印が生きているか**を測る。
#
# 終了コード: 0 = 全部通った / 1 = 測って赤い(直す物が在る) / 2 = 準備段で中断(何も測れていない)
#            3 = 運ぶ層は通ったが相手が答えていない(**利用上限**。直す物は無い、待つ)
#   意味と順序(2 > 1 > 3 > 0)の正本は `rc-backend/tools/exit-codes.mjs`。
#   ★3 が要るのは、上限の日に赤を出すと「製品が壊れた」に見え、**次の本物の赤が
#     読まれなくなる**から。3 は「測れていない」であって「通った」でも「壊れた」でもない。
set -uo pipefail
IOS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

URL="${RC_LIVE_URL:-https://desk.tailnet.example:9443}"
# ★短い別名を使う(艦隊の他の全経路と同じ)。機体の解決先は ~/.ssh/config の1箇所に閉じ込める。
SSH_HOST="${RC_LIVE_SSH:-athenas}"
REMOTE_TOOLS="${RC_LIVE_REMOTE:-\$HOME/rc-backend/tools}"
# ★相手の node は**実行時に訊く**。path を焼き込むと、機体が変わった日に静かに腐る
#   (2026-08-27 に live-send-check.sh で実際に踏んだ)。
REMOTE_NODE="${RC_LIVE_NODE:-}"
KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --url) URL="$2"; shift 2 ;;
    --host) SSH_HOST="$2"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    # 判定だけを撃つ入口。引数はそのまま残して輪を抜ける(受けるのは ok/bad の定義の下)。
    --verdict-cursor|--verdict-session) break ;;
    *) echo "usage: $0 [--url URL] [--host SSH] [--keep] [--verdict-cursor <出力> <期待> <題>] [--verdict-session <up の出力>]" >&2; exit 2 ;;
  esac
done
# 判定だけを撃つ時は机に触らない(ssh も node も要らない)。
case "${1:-}" in
  --verdict-*) : ;;
  *)
    if [ -z "$REMOTE_NODE" ]; then
      REMOTE_NODE="$(ssh "$SSH_HOST" 'command -v node || ls /opt/homebrew/bin/node 2>/dev/null' 2>/dev/null | head -1)"
    fi
    if [ -z "$REMOTE_NODE" ]; then
      echo "相手の機械($SSH_HOST)で node が見つからない。RC_LIVE_NODE=/path/to/node で渡せる" >&2
      exit 2
    fi
    ;;
esac

WORK="$(mktemp -d)"
BIN="$WORK/rc-live-poll"
SESSION=""
SID=""
PASS=0; FAIL=0
ok(){ printf '  \033[32mok  \033[0m: %s\n' "$1"; PASS=$((PASS+1)); }
bad(){ printf '  \033[31mNG  \033[0m: %s\n' "$1"; FAIL=$((FAIL+1)); }

# ★判定を関数へ出す(2026-08-28)。此処は `live-send-check.sh` が `--verdict` で
#   先にやった事と同じ理由 —— 判定の分岐は**本物の会話と ssh が要る**位置に埋まっていて、
#   書いた通りに動くかを一度も測れないまま出荷される。切り出せば、観測値の全通りを
#   `live-poll-check-control.sh` が机も電話も無しで撃てる。
# 名前の決め方は3本で共有する(写しを作らない)。理由は向こうの頭に在る。
. "$IOS_DIR/tools/disposable-session-name.sh"

judge_cursor_gap() {  # judge_cursor_gap <観測した出力> <期待する印> <題>
  local out="$1" want="$2" what="$3"
  case "$out" in
    *gaps=*"$want"*)
        ok "$what: **$want の印付きで**返る(取りこぼしが黙って消えない)" ;;
    injected=success*gaps=)
        bad "$what: 200 で**印無し**に化けた = 取りこぼしが黙って消える形($out)" ;;
    injected=success*gaps=*)
        bad "$what: 印は付いたが $want ではない($out) = 2つの理由が混ざっている" ;;
    injected=unreadable*)
        bad "$what: 電話の二段読みが拒んだ = 良性の合図が偽の警報になっている($out)" ;;
    injected=unreachable*)
        bad "$what: unreachable に化けた(= 人を電波の確認へ走らせる形)($out)" ;;
    *)  bad "$what: 扱いが想定外($out)" ;;
  esac
}

# 判定だけを撃つ入口(対照が使う)。机も電話も触らずに分岐を全通り回せる。
if [ "${1:-}" = "--verdict-session" ]; then
  shift
  printf '%s\n' "$(session_from_up "${1:-}")"
  exit 0
fi
if [ "${1:-}" = "--verdict-cursor" ]; then
  shift
  judge_cursor_gap "${1:-}" "${2:-}" "${3:-観測}"
  [ "$FAIL" -gt 0 ] && exit 1
  exit 0
fi

cleanup() {
  if [ -n "$SESSION" ] && [ "$KEEP" = "0" ]; then
    echo "--- 畳む ---"
    PURGE=""
    [ "$FAIL" = "0" ] && PURGE=" --purge-transcript"
    [ "$FAIL" = "0" ] || echo "(判定が緑でないので転写は残す)"
    ssh "$SSH_HOST" "$REMOTE_NODE $REMOTE_TOOLS/disposable-session.mjs down '$SESSION' '$SID'$PURGE" 2>&1 |
      sed "s#$SID#<会話 id>#g"
  elif [ -n "$SESSION" ]; then
    echo "--keep: セッションを残した(畳むのは人の手)"
  fi
  /bin/rm -rf "$WORK"
}
trap cleanup EXIT

echo "=== 1. 電話側の殻を建てる(製品の Swift をそのまま使う) ==="
swiftc -O -o "$BIN" \
  "$IOS_DIR/tools/live-poll-main.swift" \
  "$IOS_DIR/Sources/Core/PollClient.swift" \
  "$IOS_DIR/Sources/Core/PollCursor.swift" \
  "$IOS_DIR/Sources/Core/ReadablePoll.swift" \
  "$IOS_DIR/Sources/Core/PollModels.swift" \
  "$IOS_DIR/Sources/Core/HistoryModels.swift" \
  "$IOS_DIR/Sources/Core/ResultDisplay.swift" \
  "$IOS_DIR/Sources/Core/BackendSession.swift" 2>&1 | tail -20 || { echo "swiftc が通らない"; exit 2; }
[ -x "$BIN" ] || { echo "swiftc が通らない(束が出来ていない)"; exit 2; }
echo "ok: $(/usr/bin/stat -f %z "$BIN") bytes"

echo
echo "=== 2. 使い捨ての本物 TUI を建てる ==="
UP="$(ssh "$SSH_HOST" "$REMOTE_NODE $REMOTE_TOOLS/disposable-session.mjs up")" || { echo "建たなかった"; exit 2; }
SID="$(printf '%s' "$UP" | tail -1 | tr -d '[:space:]')"
# ★推測をやめた(2026-08-28)。初版は向こうの tmux を
#   `list-sessions | grep '^rc-e2e-' | tail -1` で引いていた —— **自分が建てた物を
#   名前の接頭辞で当てに行く**形で、Codex 2026-08-27 が名指しした ABA/TOCTOU そのもの。
#   前の走行が SIGKILL や停電で落ちると孤児が残り(2026-08-28 に実際に1件見つけた)、
#   `tail -1` が其れを掴む。掴んだ物は cleanup で kill される。
#   `up` の stdout は**セッション名と会話 id の2行だけ**(disposable-session.mjs の
#   `process.stdout.write` に「余計な字を混ぜない」と書いてある)。姉家族2本
#   (live-send / live-interrupt)は最初から1行目を読んでいた。此処だけがずれていた。
SESSION="$(session_from_up "$UP")"
[ -n "$SESSION" ] || { echo "up がセッション名を名乗らない(建った物を特定できないので畳まない)"; exit 2; }
[ -n "$SID" ] || { echo "会話 id が取れない"; exit 2; }
echo "ok: 建った(会話 id は伏せる)"

KEY="$(ssh "$SSH_HOST" 'cat ~/.rc-backend/api.key')" || { echo "鍵が読めない"; exit 2; }

echo
echo "=== 3. 電話のコードで受け取る ==="
OUT="$(printf '%s\n%s\n%s\n' "$URL" "$SID" "$KEY" | "$BIN")"; RC=$?
echo "$OUT"
echo "終了コード = $RC"
# ★判定は**2回目まで**を要求する。`outcome=success*` だけで一致させると、
#   1回目が成功して2回目が落ちた行(`outcome=success ... second=<失敗>`)も
#   前方一致で緑になる —— 書いた直後に自分で踏んだ穴。
case "$OUT" in
  *second=success*) ok "電話の PollClient が読める応答を受け取り、**返ってきた cursor でもう一度通った**" ;;
  outcome=success*second=*) bad "1回目は読めたが2回目が落ちた($OUT) = 最初の1画面で固まる形" ;;
  outcome=unreadable*) bad "200 は来たが電話の二段読みが拒んだ(= 見せてよい形ではない)" ;;
  *) bad "受け取れていない($OUT)" ;;
esac

echo
echo "=== 4. 陰性対照A: でたらめな鍵(401 が返ること) ==="
OUT_A="$(printf '%s\n%s\n%s\n' "$URL" "$SID" "not-a-real-key" | "$BIN")"
echo "$OUT_A"
case "$OUT_A" in
  outcome=unauthorized*) ok "でたらめな鍵は 401 = **本物のサーバに当たっている**" ;;
  *) bad "でたらめな鍵が 401 にならない($OUT_A) = 当たっている相手が本物か言えない" ;;
esac

echo
echo "=== 5. 陰性対照B: 居ない会話(404 SESSION_NOT_FOUND が返ること) ==="
OUT_B="$(printf '%s\n%s\n%s\n' "$URL" "00000000-0000-0000-0000-000000000000" "$KEY" | "$BIN")"
echo "$OUT_B"
case "$OUT_B" in
  outcome=sessionNotFound*) ok "居ない会話は 404 を**網の障害と混ぜずに**名乗る" ;;
  outcome=unreachable*) bad "居ない会話が unreachable に化けた(= 人を電波の確認へ走らせる形)" ;;
  *) bad "居ない会話の扱いが想定外($OUT_B)" ;;
esac

echo
echo "=== 6. 陰性対照C: 壊れた cursor(**200 の gap** として返る事) ==="
# ★期待は「エラー」ではない。`src/tail.mjs` の `pollDecision` は形の合わない cursor に
#   `{ kind: "gap", why: "cursor-malformed" }` を返す設計で、サーバは 200 のまま
#   **gap の印**を1件混ぜて寄越す。電話側も `GapWhy` に同名の枝を持っている。
#   だから測るのは「約束が生きた経路で保たれているか」。
#
# ★破れた時の症状が一番危ない形をしている: gap が消えると、電話は
#   **取りこぼしを黙って捨てて 200 を受け取る** —— 画面は正常に見えるのに
#   出力が抜ける。使う人には気付く手掛かりが1つも無い。
#   だから「エラーが返る」ではなく「**印が付いて返る**」を要求する。
# ★2本に割る。初版は `t.not-a-number.x.y` 1本で「形が壊れている」を測ったつもりだったが、
#   実測すると `epochMismatch` が返った —— `pollDecision` は**世代の照合を形の照合より先に**
#   行うので、部品数が4本ある限り形の枝には届かない。合わせに行って matcher を緩めると
#   「どちらでも緑」になり、2つの理由が混ざっている事を測れなくなる。入力の方を直す。
#
# ★2つを分けて測る理由: `cursor-malformed` は「電話が出鱈目を送った」、
#   `epoch-mismatch` は「会話が建て直された」= **実際に起きる出来事**。
#   混ざると、出力が飛んだ時に原因を辿る手掛かりが消える。
for pair in "not-a-cursor|cursorMalformed|部品の数が合わない" "t.999999999.0.0|epochMismatch|形は合うが世代が違う"; do
  BAD="${pair%%|*}"; rest="${pair#*|}"; WANT="${rest%%|*}"; WHAT="${rest#*|}"
  OUT_C="$(printf '%s\n%s\n%s\n%s\n' "$URL" "$SID" "$KEY" "$BAD" | "$BIN")"
  echo "  $WHAT -> $OUT_C"
  judge_cursor_gap "$OUT_C" "$WANT" "$WHAT"
done

echo
echo "=== 7. 相手が上限で答えられない状態か(赤の意味が変わるので判定の前に訊く) ==="
# ★`live-*` の計器は**上限で 3 を返す**のが契約(test/live-exit-codes.test.mjs)。
#   上限の日に赤を出すと「製品が壊れた」に見え、次の本物の赤が読まれなくなる。
#   3 は「測れていない」であって「通った」でも「壊れた」でもない。
LIMITED="$(ssh "$SSH_HOST" "$REMOTE_NODE $REMOTE_TOOLS/disposable-session.mjs limited '$SID'" 2>/dev/null || echo "")"
echo "利用上限の告知 = ${LIMITED:-unknown}"

echo
echo "=== 判定 ==="
echo "LIVE-POLL-CHECK: pass=$PASS fail=$FAIL"
if [ "$FAIL" -ne 0 ] && [ "$LIMITED" = "limited" ]; then
  echo "→ 上限で答えられない机だった。**赤の意味が付かない**ので 3(測れていない)で降りる"
  exit 3
fi
[ "$FAIL" -eq 0 ]
