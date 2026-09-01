#!/bin/bash
# controls-for: rc-backend/tools/digest-notify.sh
#
# `digest-notify.sh --dry-run` の**副作用**の対照。文面ではなく「何を書き換えたか」を測る。
#
# ── なぜ此れが要るか(2026-09-01 実測)──────────────────────────────────────
# `--dry-run` は「鳴らさずに判定だけ出す」と名乗りながら、**指紋台帳に
# `alerted: true` を書き込んでいた**。台帳は「一度鳴らした指紋では二度と鳴らさない」の
# 根拠なので、dry を 1 回撃つと **本物の通知が 1 回消える**。
#
# 機序: `DRY` は shell の変数で、判定を行う python には**渡されていなかった**
#   (引数 6 個: feed/state/now/soon/now_obs/stale)。旗は「鳴らす層」だけで見られ、
#   「書く層」には届いていない。★**旗が守るのは見える側だけで、書く側は別に止まらない。**
#
# ★同型の前科が 2 件在る(2026-08-31): dry-run が実在のカードを食べた件と、
#   「消失を通知しない」旗が締切をカレンダーから消した件。**3 度目なので対照を置く。**
#
# 測る物   = dry が台帳の**バイト列**を変えないか / 本番は変えるか / dry でも判定は出るか
# 測らない物 = 通知が実際に端末へ届くか(端末と配達先の話で、此処の責務ではない)
#
# ★偽の机は **2 経路**を返し分ける。実装は `/api/sessions`(id の列挙と名前引き)と
#   `/api/sessions/<id>/digest`(判定の本体)を別々に叩くので、1 種類だけ返す机だと
#   digest の復号が落ちて**判定が一度も発火しない**。其の時 V1/V2 は「何も書かれて
#   いない/鳴っていない」で緑になるが、守りを 1 つも測っていない —— 空虚な緑。
#   (此の対照を書いた初版が実際に其れを出した。順序ごと記録として残す。)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SH="$HERE/../tools/digest-notify.sh"
PY_BIN="$(command -v python3 || echo /usr/bin/python3)"

SB="$(mktemp -d "${TMPDIR:-/tmp}/dnd-controls.XXXXXX")"
DESK_PID=""
cleanup() { [ -n "$DESK_PID" ] && kill "$DESK_PID" 2>/dev/null; rm -rf "$SB"; }
trap cleanup EXIT

PASS=0; FAIL=0
chk() { # chk <名前> <期待> <実測>
    if [ "$2" = "$3" ]; then
        PASS=$((PASS+1)); printf 'PASS  %s\n' "$1"
    else
        FAIL=$((FAIL+1)); printf 'FAIL  %s\n        期待=[%s] 実測=[%s]\n' "$1" "$2" "$3"
    fi
}

# ── 偽の机(経路で返し分ける)────────────────────────────────────────────
cat > "$SB/desk.py" <<'DESK'
import http.server, json, socketserver, sys, os
sb, mode = sys.argv[1], sys.argv[2]
waiting = mode == "waiting"
SID = "sess-fixture-0001"
LIST = {"sessions": [{"id": SID, "title": "fixture waiting"}]}
DIGEST = {
    "attention": "choice" if waiting else "none",
    "action": {"level": "now" if waiting else "none"},
    "line": "Waiting on you",
    "digest": {"lastAt": 1000},
}
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = DIGEST if self.path.endswith("/digest") else LIST
        b = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)
    def log_message(self, *a):
        pass
srv = socketserver.TCPServer(("127.0.0.1", 0), H)
open(os.path.join(sb, "port-" + mode), "w").write(str(srv.server_address[1]))
srv.serve_forever()
DESK

start_desk() { # start_desk <waiting|quiet> -> echo "<port> <pid>"
    # ★`>/dev/null 2>&1` が要る。此の関数は `$(…)` で呼ばれるが、コマンド置換は
    #   **背後に回した子の stdout が閉じるまで返らない**。机は serve_forever で
    #   永久に閉じないので、書かないと対照ごと固まる(実測: 2 分で timeout)。
    "$PY_BIN" "$SB/desk.py" "$SB" "$1" >/dev/null 2>&1 &
    local pid=$! i
    for i in $(seq 1 60); do [ -s "$SB/port-$1" ] && break; sleep 0.1; done
    printf '%s %s' "$(cat "$SB/port-$1" 2>/dev/null)" "$pid"
}

read -r PORT DESK_PID <<< "$(start_desk waiting)"
if [ -z "${PORT:-}" ]; then
    echo "FAIL  偽の机が立たなかった(以下は何も測っていない)"; exit 2
fi

echo "fixture-key" > "$SB/api.key"
# 鳴らす先は「呼ばれたら印を置くだけ」の偽物。実際の通知は飛ばさない。
cat > "$SB/notify" <<'EOS'
#!/bin/bash
cat >> "$RC_TEST_NOTIFY_MARK"
printf '\n---\n' >> "$RC_TEST_NOTIFY_MARK"
EOS
chmod +x "$SB/notify"

# ★`NOW_OBS=1` に締める。既定の 2 は「2 回続けて同じ指紋なら鳴らす」で、
#   1 回撃って鳴らないのは**実装の正しい振る舞い**。回数の規則そのものは
#   此の対照の担当ではない(此処が測るのは dry の副作用)。
# ★心拍の変数名は `RC_PRESENCE_FILE`。**継ぐと本物の在席で黙って空虚な緑になる**
#   ので、必ず存在しない path を差す(初版で `RC_DIGEST_PRESENCE_FILE` と誤記した)。
run() { # run <dry|live> <state-file> <port> <notify-mark> [script]
    local mode="$1" st="$2" port="$3" mark="$4" script="${5:-$SH}" flag=""
    [ "$mode" = "dry" ] && flag="--dry-run"
    RC_DIGEST_API="http://127.0.0.1:$port" \
    RC_DIGEST_KEY="$SB/api.key" \
    RC_DIGEST_STATE="$st" \
    RC_DIGEST_LOG="$SB/log" \
    RC_DIGEST_NOTIFY="$SB/notify" \
    RC_DIGEST_NOW_OBS=1 \
    RC_TEST_NOTIFY_MARK="$mark" \
    RC_PRESENCE_FILE="$SB/absent-on-purpose" \
        bash "$script" $flag 2>&1
}

# ── V0: そもそも判定が発火する机か(以下が空虚でない事の錨)─────────────
ST0="$SB/state-probe.json"; printf '{}' > "$ST0"
run live "$ST0" "$PORT" "$SB/mark-probe" >/dev/null 2>&1
chk "V0 ★錨: 此の机で本番は鳴る(以下が空虚でない事の確認)" "yes" \
    "$([ -e "$SB/mark-probe" ] && echo yes || echo no)"

# ── V1: dry は台帳を 1 バイトも変えない ──────────────────────────────────
ST="$SB/state-dry.json"; printf '{}' > "$ST"
BEFORE="$(shasum -a 256 < "$ST")"
OUT_DRY="$(run dry "$ST" "$PORT" "$SB/mark-dry")"
AFTER="$(shasum -a 256 < "$ST")"
chk "V1 ★dry は指紋台帳を書き換えない" "$BEFORE" "$AFTER"

# ── V2: dry は鳴らさない ─────────────────────────────────────────────────
chk "V2 dry は通知先を呼ばない" "no" "$([ -e "$SB/mark-dry" ] && echo yes || echo no)"

# ── V3: dry でも判定は出す(黙る旗ではない)──────────────────────────────
chk "V3 dry は判定を出す(DRY: の行が在る)" "yes" \
    "$(printf '%s' "$OUT_DRY" | grep -q '^DRY: ' && echo yes || echo no)"

# ── V4: 本番は台帳を書く(V1 が「壊れて何も起きない」では無い事の対照)────
ST2="$SB/state-live.json"; printf '{}' > "$ST2"
B2="$(shasum -a 256 < "$ST2")"
run live "$ST2" "$PORT" "$SB/mark-live" >/dev/null 2>&1
A2="$(shasum -a 256 < "$ST2")"
chk "V4 ★本番は台帳を書く(V1 が空虚でない事の確認)" "changed" \
    "$([ "$B2" = "$A2" ] && echo same || echo changed)"

# ── N1(陰性): 書き込みの番人を外すと、dry が台帳を食う ──────────────────
# ★此処が本丸。V1 は「守りが在る」しか言えない。守りを外して**赤が出る**事を見て
#   初めて、V1 が守っている物を名指しできる。
BROKEN="$SB/digest-notify-broken.sh"
"$PY_BIN" - "$SH" "$BROKEN" <<'MUT'
import io, sys
src, dst = sys.argv[1], sys.argv[2]
s = io.open(src, encoding="utf-8").read()
a = 'if not dry:\n    json.dump(fresh, open(statep, "w"), ensure_ascii=False, indent=1)'
b = 'json.dump(fresh, open(statep, "w"), ensure_ascii=False, indent=1)'
assert a in s, "変異の錨が無い = N1 は空虚"
io.open(dst, "w", encoding="utf-8").write(s.replace(a, b, 1))
MUT
if [ ! -s "$BROKEN" ]; then
    echo "FAIL  N1 の変異体を作れなかった(錨が動いた = 対照が空虚)"; FAIL=$((FAIL+1))
else
    ST3="$SB/state-n1.json"; printf '{}' > "$ST3"
    B3="$(shasum -a 256 < "$ST3")"
    run dry "$ST3" "$PORT" "$SB/mark-n1" "$BROKEN" >/dev/null 2>&1
    A3="$(shasum -a 256 < "$ST3")"
    chk "N1 ★陰性: 番人を外すと dry が台帳を食う(欠陥が実在した証拠)" "changed" \
        "$([ "$B3" = "$A3" ] && echo same || echo changed)"
fi

# ── N2(陰性): 待っていない机では本番でも鳴らない ────────────────────────
# 「V0/V4 が発火した」が机の中身に依存している事の確認。何を撃っても鳴る台本なら空虚。
read -r PORT2 QUIET_PID <<< "$(start_desk quiet)"
if [ -z "${PORT2:-}" ]; then
    echo "FAIL  N2 の静かな机が立たなかった"; FAIL=$((FAIL+1))
else
    ST4="$SB/state-n2.json"; printf '{}' > "$ST4"
    run live "$ST4" "$PORT2" "$SB/mark-n2" >/dev/null 2>&1
    chk "N2 ★陰性: 待っていない机では本番でも鳴らない(V0/V4 が空虚でない)" "no" \
        "$([ -e "$SB/mark-n2" ] && echo yes || echo no)"
    kill "$QUIET_PID" 2>/dev/null
fi

echo "--- 合計: PASS $PASS / FAIL $FAIL ---"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
