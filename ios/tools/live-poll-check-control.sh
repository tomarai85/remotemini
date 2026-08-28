#!/bin/bash
# controls-for: ios/tools/live-poll-check.sh ios/tools/live-poll-main.swift ios/tools/disposable-session-name.sh
#
# `live-poll-check.sh` の**壊れた cursor の判定だけ**を、観測値の全通りで撃つ。
#
# なぜ要るか(2026-08-28): 此の判定は「机に本物の会話が建っていて、電話の Swift が
# 建っている」位置に埋まっている。だから書いた通りに動くかを**一度も測れないまま**
# 出荷される —— `live-send-check-control.sh` が 2026-08-06 に同じ理由で建てられた。
#
# ★此の対照が在る理由の本体は、書いた当日に踏んだ穴そのもの:
#   初版は `t.not-a-number.x.y` を「形が壊れた cursor」として撃ったが、実測は
#   `epochMismatch` を返した。`pollDecision` は**世代の照合を形の照合より先に**やるので、
#   部品が4つ在る限り形の枝には届かない。此処で matcher を緩めて両方を通していたら、
#   「取りこぼしの理由が2つとも同じに見える」状態を緑で固定していた。
#
# ★測る物 = 観測した出力 → 緑/赤 の対応。
#   測らない物 = ssh / 机 / Swift の側 / サーバが実際に何を返すか。
#     其れは `live-poll-check.sh` を本当に回す時の話で、実際に回した実測は
#     `.harness/evidence-2026-08-28/` に在る。
#
# 終了コード: 0 = 全通り期待通り / 1 = ずれが在る
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$HERE/live-poll-check.sh"
[ -f "$TOOL" ] || { echo "対象が無い: $TOOL"; exit 2; }

PASS=0; FAIL=0

chk() {  # chk <期待 rc> <題> <観測した出力> <期待する印>
    local want="$1" title="$2" out="$3" mark="$4"
    local got body
    body="$(bash "$TOOL" --verdict-cursor "$out" "$mark" "$title" 2>&1)"; got=$?
    if [ "$got" = "$want" ]; then
        PASS=$((PASS+1)); printf 'PASS  %-46s → %s\n' "$title" "$got"
    else
        FAIL=$((FAIL+1)); printf 'FAIL  %-46s → %s(期待 %s)\n' "$title" "$got" "$want"
        printf '%s\n' "$body" | /usr/bin/sed 's/^/        /'
    fi
}

# --- 緑になるべき物 ----------------------------------------------------------
chk 0 "印が期待通り(形が壊れた)" "injected=success items=1 gaps=cursorMalformed" "cursorMalformed"
chk 0 "印が期待通り(世代違い)"   "injected=success items=1 gaps=epochMismatch"   "epochMismatch"
chk 0 "印が複数でも目的の物が在る" "injected=success items=2 gaps=cursorMalformed,ringOverflow" "cursorMalformed"

# --- 赤になるべき物(此処が本体)----------------------------------------------
# ★一番危ない形。200 で印が消えると、電話は取りこぼしを黙って捨て、
#   画面は正常に見えたまま出力が抜ける。使う人に手掛かりが1つも残らない。
chk 1 "印が消えた(黙って取りこぼす形)" "injected=success items=0 gaps=" "cursorMalformed"
# ★2 つの理由が混ざる形。緑にすると「なぜ出力が飛んだか」を辿れなくなる。
chk 1 "別の印にすり替わった"           "injected=success items=1 gaps=epochMismatch" "cursorMalformed"
chk 1 "二段読みが良性の合図を拒んだ"   "injected=unreadable" "cursorMalformed"
chk 1 "網の障害に化けた"               "injected=unreachable" "cursorMalformed"
chk 1 "401 に化けた"                   "injected=unauthorized(401)" "cursorMalformed"
chk 1 "空の出力(殻が落ちた)"           "" "cursorMalformed"
chk 1 "見た事の無い形"                 "outcome=???" "cursorMalformed"

# --- 自分が建てた会話をどう特定するか(crash-orphan / ABA)-----------------------
# ★守る物: 名前の接頭辞で自分の物を**当てに行かない**事。
#   `live-poll-check.sh` は初版で `tmux list-sessions | grep '^rc-e2e-' | tail -1` を
#   使っていた —— 前の走行が SIGKILL や停電で落ちると孤児が残り(2026-08-28 に実在を
#   確認)、`tail -1` が其れを掴んで cleanup で殺す。Codex 2026-08-27 が名指しした形。
sess() {  # sess <題> <up の stdout> <期待する名前(空 = 止まるべき)>
    local title="$1" up="$2" want="$3" got
    got="$(bash "$TOOL" --verdict-session "$up" 2>&1 | tr -d '\n')"
    if [ "$got" = "$want" ]; then
        PASS=$((PASS+1)); printf 'PASS  %-46s → %s\n' "$title" "${got:-(空 = 止まる)}"
    else
        FAIL=$((FAIL+1)); printf 'FAIL  %-46s → "%s"(期待 "%s")\n' "$title" "$got" "$want"
    fi
}

sess "1行目の名前を取る"            "$(printf 'rc-e2e-9001\nabc-def\n')"      "rc-e2e-9001"
sess "2行目の会話 id を名前にしない" "$(printf 'rc-e2e-9001\nrc-e2e-9002\n')" "rc-e2e-9001"
# ★一番危ない足。孤児の名前が出力のどこかに紛れても、1行目でなければ取らない。
sess "孤児が2行目に居ても取らない"   "$(printf 'work\nrc-e2e-orphan\n')"      ""
sess "本物の会話名は取らない"        "$(printf 'work\n')"                     ""
sess "up が何も出さなければ止まる"   ""                                        ""
sess "空白だけでも止まる"            "$(printf '   \n')"                       ""
sess "接頭辞が惜しいだけでは取らない" "$(printf 'rc-e2f-9001\n')"              ""
sess "前後の空白は落として取る"      "$(printf '  rc-e2e-9001  \nid\n')"      "rc-e2e-9001"

echo
echo "live-poll-check-control: PASS $PASS / FAIL $FAIL"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
