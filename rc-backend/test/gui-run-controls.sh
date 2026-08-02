#!/bin/bash
# `tools/edith-gui-run.sh` が**計器として壊れていないか**を測る対照。
#
# ── なぜ要るか(2026-08-02、実物で踏んだ) ────────────────────────────────
# この台本の仕事は「edith の launchd の中で1回走らせて、**終了コードを持ち帰る**」。
# 最初の版は `CMD="$*"` で argv を1本の文字列に潰していた。すると
#     -- /bin/sh -c 'exit 7'   →   /bin/sh -c exit 7   →  `sh -c exit`(7 は $0)
# となり、**何を渡しても 0 が返る**。終了コードを運ぶ道具が、常に緑を返していた。
#   ★計器の壊れ方として最悪の形。緑は「異常なし」ではなく「何も測っていない」だった。
# だから、この対照が見るのは主に **0 以外がちゃんと 0 以外で返るか**。
#
# ── 終了コード ─────────────────────────────────────────────────────────
#   0 = 緑 / 1 = 赤 / **2 = 測っていない**(edith に届かない)。
#   2 を緑に丸めない。`run-controls.sh` は 2 を「未測定(緑ではない)」として表示する。
#
# 網越しの対照。実測 6秒(ssh 往復 6回。ControlMaster が効いているので速い)。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# 陰性対照が「壊した写し」を指すための差し替え口。既定は本体。
RUN="${RC_GUI_RUN_BIN:-$ROOT/tools/edith-gui-run.sh}"
HOST="${RC_EDITH_HOST:-edith@10.0.0.0}"

pass=0; fail=0
ok() { pass=$((pass+1)); echo "PASS  $1"; }
ng() { fail=$((fail+1)); echo "FAIL  $1  ($2)"; }

if [ ! -f "$RUN" ]; then
    echo "FAIL  G0 $RUN が無い"
    echo "GUI-RUN-CONTROLS: pass=0 fail=1"
    exit 1
fi

# ── G0) 届かないなら**測っていない**と言って降りる ────────────────────────
if ! ssh -o ConnectTimeout=8 -o BatchMode=yes "$HOST" true >/dev/null 2>&1; then
    echo "UNMEASURED  edith ($HOST) に届かない — 網が要る対照なので測っていない"
    echo "GUI-RUN-CONTROLS: 未測定"
    exit 2
fi
ok "G0 edith に届く"

# ── G1) 0 以外の終了コードが**素通しで**返るか ────────────────────────────
# ここが赤い時、この台本を使った測定は全部信用できない(常に緑を返す病気)。
bash "$RUN" --timeout 60 -- /bin/sh -c 'exit 7' >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 7 ]; then
    ok "G1 終了コード 7 がそのまま返る"
else
    ng "G1 終了コードの素通し" "7 を期待して $rc — argv を潰していないか(\$* で繋ぐと壊れる)"
fi

# ── G2) 空白を含む引数が**1本のまま**着くか ──────────────────────────────
# `$#` を終了コードにして数える。潰れていれば 'a b' が2本に割れて 3 が返る。
bash "$RUN" --timeout 60 -- /bin/sh -c 'exit $#' sh 'a b' c >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ]; then
    ok "G2 空白入りの引数が割れずに着く(引数 2本)"
else
    ng "G2 引数の引用符" "2 を期待して $rc — 3 なら 'a b' が割れている / 0 なら文字列に潰れている"
fi

# ── G3) 安全弁: keychain の**中身**を読む形を弾き、しかも中身を印字しない ──
out="$(bash "$RUN" -- security find-generic-password -w -s "Claude Code-credentials" 2>&1)"; rc=$?
if [ "$rc" -eq 91 ]; then
    ok "G3a 安全弁が -w の形を拒否する(91)"
else
    ng "G3a 安全弁" "91 を期待して $rc — keychain の中身を読む形が通ってしまう"
fi
# ★秘密を守る検査が、その秘密を晒しては本末転倒。何が引っ掛かったかは言うが、
#   引数そのものは出さない(2026-08-02 に立てた規則)。
if printf '%s' "$out" | grep -q 'Claude Code-credentials'; then
    ng "G3b 拒否の言い方" "拒否文に引数がそのまま出ている — 秘密を守る検査が秘密を晒している"
else
    ok "G3b 拒否文に引数を印字していない"
fi

# ── G4) 走った後、edith に残骸が無い ─────────────────────────────────────
# 台本は自分で不在確認して DIRT=94 を返す設計だが、**その確認自体を外から**見る。
bash "$RUN" --timeout 60 -- /usr/bin/true >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ]; then
    ok "G4a 素通し(true)が 0 で返り、後片付けの確認も通った"
else
    ng "G4a 素通し" "0 を期待して $rc(94 なら後片付けの確認が取れていない)"
fi
resid="$(ssh -o ConnectTimeout=8 "$HOST" 'ls -d /tmp/rcprobe.* 2>/dev/null | wc -l | tr -d " "; launchctl list 2>/dev/null | grep -c com.edith.rcprobe' 2>/dev/null | tr '\n' '/')"
if [ "$resid" = "0/0/" ]; then
    ok "G4b edith に残骸が無い(dir 0件 / job 0件)"
else
    ng "G4b 残骸" "dir/job の数が [$resid] — 0/0/ を期待。/tmp/rcprobe.* と com.edith.rcprobe-* を見る事"
fi

# ── G5) そもそも launchd の中に居るか(**両方向**測る) ─────────────────────
# 片側だけ緑でも「差が在る」の証拠にはならない。ssh 直で違う値が出て初めて判別子。
#   ★`find-generic-password`(-w 無し)を使わない事: **ssh 越しでも 0 を返す**ので
#     何も判別しない。要るのは「解錠されているか」であって「在るか」ではない。
KC='security show-keychain-info ~/Library/Keychains/login.keychain-db >/dev/null 2>&1'
bash "$RUN" --timeout 60 -- /bin/sh -c "$KC" >/dev/null 2>&1; inside=$?
ssh -o ConnectTimeout=8 "$HOST" "$KC" >/dev/null 2>&1; outside=$?
if [ "$inside" -eq 0 ] && [ "$outside" -ne 0 ]; then
    ok "G5 keychain 解錠が中 0 / ssh 直 $outside — 別の文脈に居る事が両方向で取れた"
elif [ "$inside" -eq 0 ] && [ "$outside" -eq 0 ]; then
    ng "G5 判別子" "中も ssh 直も 0 — **判別していない**。ssh 側の keychain が解錠済みか、判別子が弱い"
else
    ng "G5 launchd 文脈" "中=$inside / ssh直=$outside — 中で解錠に手が届いていない。claude を走らせても Not logged in になる"
fi

echo ""
echo "GUI-RUN-CONTROLS: pass=$pass fail=$fail"
exit $(( fail > 0 ))
