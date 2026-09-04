#!/bin/bash
# controls-for: tools/digest-notify.sh
#
# 完了の遷移を**記録するだけ**の仕掛け(2026-09-04、対照表 #32)の対照。
#
# ── 何を測るか ────────────────────────────────────────────────────────────
# 設計 = `research/notification-push-type-split-2026-09-04.md`。公式の 2 種のうち
# 「判断待ち」は既に在り、「完了」は**存在しない**。完了は画面の状態ではなく**遷移**
# (前の刻みで動いていた → 今は止まっている)なので、刻みを跨ぐ状態を持つ digest-notify に
# しか置けない。既定で**測り**、既定で**鳴らさない**。
#
# ★此の対照の主眼は文面でも頻度でもなく、**鳴らす経路を汚していないか**。
#   2026-09-01 に此の台本は `--dry-run` が指紋台帳へ `alerted: true` を書き、
#   **本物の通知を 1 回食べた**。「記録するだけ」と名乗る仕掛けは、同じ形の 2 度目に
#   なり得る。だから C3/C4 は「完了を記録した回に、鳴る筈の物が鳴るか」を直接見る。
#
# 測らない物 = 通知が端末へ届くか(配達の話)/ 完了の閾値が妥当か(其れは測って決める事で、
#              測る前に決めたら設計書が禁じた「当て推量の既定」になる)。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SH="$HERE/../tools/digest-notify.sh"
PY_BIN="$(command -v python3 || echo /usr/bin/python3)"

SB="$(mktemp -d "${TMPDIR:-/tmp}/dnc-controls.XXXXXX")"
DESK_PID=""
cleanup() { [ -n "$DESK_PID" ] && kill "$DESK_PID" 2>/dev/null; rm -rf "$SB"; }
trap cleanup EXIT

PASS=0; FAIL=0
chk() { # chk <名前> <期待> <実測>
    if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf 'PASS  %s\n' "$1"
    else FAIL=$((FAIL+1)); printf 'FAIL  %s\n        期待=[%s] 実測=[%s]\n' "$1" "$2" "$3"; fi
}

# ── 偽の机。`RC_TEST_PHASE` の file を読んで、刻みごとに別の digest を返す ──────
#    (遷移を測るので、1 回の走行で固定の応答を返す机では足りない)
cat > "$SB/desk.py" <<'DESK'
import http.server, json, socketserver, sys, os
sb = sys.argv[1]
SID = "sess-fixture-0001"
LIST = {"sessions": [{"id": SID, "title": "fixture"}]}

def digest():
    phase = ""
    try:
        phase = open(os.path.join(sb, "phase")).read().strip()
    except Exception:
        pass
    # working = 動いている(attention none)/ done = 止まった(input)+ 実のある窓
    if phase == "working":
        return {"attention": "none", "action": {"level": "none"},
                "line": "still working",
                "digest": {"lastAt": 1000, "complete": True,
                           "window": {"minutes": 47}, "counts": {"assistant": 9, "tool": 20},
                           "writeTargetsTotal": 3}}
    if phase == "done":
        return {"attention": "input", "action": {"level": "soon"},
                "line": "stopped",
                "digest": {"lastAt": 2000, "complete": True,
                           "window": {"minutes": 47}, "counts": {"assistant": 9, "tool": 20},
                           "writeTargetsTotal": 3}}
    if phase == "done-empty":     # 止まったが窓に中身が無い = 完了ではない
        return {"attention": "input", "action": {"level": "soon"},
                "line": "stopped",
                "digest": {"lastAt": 2000, "complete": True,
                           "window": {"minutes": 47}, "counts": {"assistant": 0, "tool": 0},
                           "writeTargetsTotal": 0}}
    if phase == "done-partial":   # 止まったが窓を読み切れていない = 完了と言わない
        return {"attention": "input", "action": {"level": "soon"},
                "line": "stopped",
                "digest": {"lastAt": 2000, "complete": False,
                           "window": {"minutes": 47}, "counts": {"assistant": 9, "tool": 20},
                           "writeTargetsTotal": 3}}
    if phase == "waiting-unknown":   # 画面が読めない = 鳴らす対象外。台帳に載ってはいけない
        return {"attention": "unknown", "action": {"level": "unknown"},
                "line": "unreadable",
                "digest": {"lastAt": 4000, "complete": False,
                           "window": {"minutes": 1}, "counts": {"assistant": 0, "tool": 0},
                           "writeTargetsTotal": 0}}
    # waiting = 人を待っている(鳴る側の経路)
    return {"attention": "choice", "action": {"level": "now"},
            "line": "Waiting on you",
            "digest": {"lastAt": 3000, "complete": True,
                       "window": {"minutes": 5}, "counts": {"assistant": 1, "tool": 0},
                       "writeTargetsTotal": 0}}

class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        b = json.dumps(digest() if self.path.endswith("/digest") else LIST).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)
    def log_message(self, *a):
        pass

srv = socketserver.TCPServer(("127.0.0.1", 0), H)
open(os.path.join(sb, "port"), "w").write(str(srv.server_address[1]))
srv.serve_forever()
DESK

"$PY_BIN" "$SB/desk.py" "$SB" >/dev/null 2>&1 &
DESK_PID=$!
# ★job 制御の通知を切る(2026-09-04)。切らないと後片付けの `kill` が
#   `Terminated: 15` を**合計行より後ろ**へ出す。登録 verifier は `tail -1` で
#   合計行を読むので、雑音が最終行に来た瞬間に緑の対照が赤に見える ——
#   機械が読む出力の最後は、結論以外の物が来てはいけない。
disown "$DESK_PID" 2>/dev/null || true
for _ in $(seq 1 60); do [ -s "$SB/port" ] && break; sleep 0.1; done
PORT="$(cat "$SB/port" 2>/dev/null)"
[ -n "$PORT" ] || { echo "FAIL  偽の机が立たなかった(以下は何も測っていない)"; echo "--- 合計: PASS 0 / FAIL 1"; exit 2; }

echo "fixture-key" > "$SB/api.key"
cat > "$SB/notify" <<'EOS'
#!/bin/bash
cat >> "$RC_TEST_NOTIFY_MARK"
printf '\n---\n' >> "$RC_TEST_NOTIFY_MARK"
EOS
chmod +x "$SB/notify"

phase() { printf '%s' "$1" > "$SB/phase"; }

run() { # run <state> <completion-log> <notify-mark> [--dry-run]
    RC_DIGEST_API="http://127.0.0.1:$PORT" \
    RC_DIGEST_KEY="$SB/api.key" \
    RC_DIGEST_STATE="$1" \
    RC_DIGEST_COMPLETION_LOG="$2" \
    RC_DIGEST_LOG="$SB/log" \
    RC_DIGEST_NOTIFY="$SB/notify" \
    RC_DIGEST_NOW_OBS=1 \
    RC_TEST_NOTIFY_MARK="$3" \
    RC_PRESENCE_FILE="$SB/absent-on-purpose" \
        bash "$SH" ${4:-} >/dev/null 2>&1
}

comp_lines() { grep -c 'completion' "$1" 2>/dev/null || echo 0; }

# ── C0: 錨。遷移を作れば 1 行記録される(以下の「0 行」が空虚でない事の証)────
ST="$SB/s0.json"; printf '{}' > "$ST"; CL="$SB/c0.log"
phase working; run "$ST" "$CL" "$SB/m0"
phase done;    run "$ST" "$CL" "$SB/m0"
chk "C0 動いていた→止まった の遷移が 1 行記録される" "1" "$(comp_lines "$CL")"
chk "C0b 記録した行が3つの数を持つ" "1" "$(grep -c 'window_min=47.*assistant=9.*writes=3' "$CL" 2>/dev/null || echo 0)"
chk "C0c 在席かどうかも持つ(3つ目の数)" "1" "$(grep -c 'presence_fresh=0' "$CL" 2>/dev/null || echo 0)"

# ── C1: 遷移でなければ記録しない(止まった画面が続くだけでは完了ではない)────
ST="$SB/s1.json"; printf '{}' > "$ST"; CL="$SB/c1.log"
phase done; run "$ST" "$CL" "$SB/m1"
phase done; run "$ST" "$CL" "$SB/m1"
chk "C1 止まった状態が続くだけでは記録しない" "0" "$(comp_lines "$CL")"

# ── C2: 中身の無い窓 / 読み切れていない窓では「終わった」と言わない ──────────
ST="$SB/s2.json"; printf '{}' > "$ST"; CL="$SB/c2.log"
phase working;    run "$ST" "$CL" "$SB/m2"
phase done-empty; run "$ST" "$CL" "$SB/m2"
chk "C2 窓に中身が無ければ記録しない" "0" "$(comp_lines "$CL")"

ST="$SB/s2b.json"; printf '{}' > "$ST"; CL="$SB/c2b.log"
phase working;      run "$ST" "$CL" "$SB/m2b"
phase done-partial; run "$ST" "$CL" "$SB/m2b"
chk "C2b 読み切れていない窓では記録しない" "0" "$(comp_lines "$CL")"

# ── C3: ★鳴らさない。完了を記録した回に通知は 1 通も出ない ─────────────────
ST="$SB/s3.json"; printf '{}' > "$ST"; CL="$SB/c3.log"; MK="$SB/m3"
phase working; run "$ST" "$CL" "$MK"
phase done;    run "$ST" "$CL" "$MK"
chk "C3 完了を記録した(前提)" "1" "$(comp_lines "$CL")"
chk "C3b 完了では 1 通も鳴らさない" "0" "$([ -s "$MK" ] && echo 1 || echo 0)"

# ── C4: ★鳴る筈の物を食べない。完了の記録を挟んでも判断待ちは鳴る ───────────
#    2026-09-01 の `--dry-run` 事故と同じ形を、新しい仕掛けで作っていないか。
ST="$SB/s4.json"; printf '{}' > "$ST"; CL="$SB/c4.log"; MK="$SB/m4"
phase working; run "$ST" "$CL" "$MK"
phase done;    run "$ST" "$CL" "$MK"          # 完了を記録する回
phase waiting; run "$ST" "$CL" "$MK"          # 其の直後の判断待ち
chk "C4 完了を挟んでも判断待ちは鳴る(通知を食べていない)" "1" "$([ -s "$MK" ] && echo 1 || echo 0)"

# ── C5: dry-run は**書く側も**止まる(記録は書き込みであって観測ではない)────
ST="$SB/s5.json"; printf '{}' > "$ST"; CL="$SB/c5.log"
phase working; run "$ST" "$CL" "$SB/m5"
phase done;    run "$ST" "$CL" "$SB/m5" --dry-run
chk "C5 dry-run では完了を記録しない" "0" "$(comp_lines "$CL")"

# ── C6: 陰性対照。記録の判定が常に真でない(机を止めても行が増え続けない)──
ST="$SB/s6.json"; printf '{}' > "$ST"; CL="$SB/c6.log"
phase working; run "$ST" "$CL" "$SB/m6"
phase working; run "$ST" "$CL" "$SB/m6"
phase working; run "$ST" "$CL" "$SB/m6"
chk "C6 動き続けている間は 1 行も記録しない" "0" "$(comp_lines "$CL")"

# ── C7: ★F1(Codex 2026-09-04)。判定層の標準出力に「鳴らす行ではない物」が出ても配達しない。
#    完了の記録という 2 つ目の書き手を足した時点で、配達の loop の素通しは欠陥になった。
#    ★対照は**記録の行き先を標準出力に向ける**(実際の誤設定の形)。直す前は Discord が呼ばれた。
ST="$SB/s7.json"; printf '{}' > "$ST"; MK="$SB/m7"
phase working; RC_DIGEST_COMPLETION_LOG=/dev/stdout run "$ST" /dev/stdout "$MK"
phase done;    RC_DIGEST_COMPLETION_LOG=/dev/stdout run "$ST" /dev/stdout "$MK"
chk "C7 記録が標準出力へ紛れ込んでも通知しない" "0" "$([ -s "$MK" ] && echo 1 || echo 0)"
chk "C7b 捨てた事を記録に残す(黙って落とさない)" "1" "$(grep -c '配達しない' "$SB/log" 2>/dev/null || echo 0)"

# ── C8: ★F2(Codex 2026-09-04)。鳴らす対象でない会話の記録を**永久に生かさない**。
#    初版は見た会話を全部 `seen` 更新つきで台帳へ載せ、刈り込みの条件を素通りしていた。
#    `unknown`(画面が読めない)の会話を刻んでも、台帳に新しい鍵が生えない事を測る。
ST="$SB/s8.json"; printf '{}' > "$ST"
phase waiting-unknown; run "$ST" "$SB/c8.log" "$SB/m8"
KEYS="$("$PY_BIN" -c 'import json,sys;print(len(json.load(open(sys.argv[1]))))' "$ST" 2>/dev/null || echo -1)"
chk "C8 鳴らす対象でない会話は台帳に鍵を作らない" "0" "$KEYS"

echo "--- 合計: PASS $PASS / FAIL $FAIL"
[ "$FAIL" = 0 ]
