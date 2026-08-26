#!/bin/bash
# fleet-account-cswap.sh — `cswap` を `fleet-account` の出力形式へ翻訳する薄い層。
#
# なぜ要るか(2026-08-26 実測)
#   rc-backend の口座欄は `~/fleet-tools/fleet-account` を叩く。**Friday にはその台本が無い**
#   ので `/api/account` が `spawnSync ... ENOENT` で 500 を返し、アプリを開くと口座欄が
#   必ずエラーになっていた。台本の実体は edith にしか無く、edith は到達不能。
#   Friday の口座管理は後継の `cswap` が持っているが、出力形式が全く違う
#   (`現用:` も `優先順 (.order):` も持たない)。
#
# ★翻訳層を選んだ理由: 代わりに `src/account.mjs` の parser を cswap 形式へ寄せる案も在るが、
#   あちらは 60 本超の単体と変異の的が今の形式に釘付けになっていて、寄せると錨が全部外れる。
#   **形式を1箇所で吸収する方が、検査を1本も壊さずに済む。**
#
# 契約(server.mjs が期待する物):
#   引数なし  -> 標準出力に
#                 現用: <name>            (未設定なら「現用: (未設定)」)
#                 優先順 (.order):
#                 ->  1. <name>   トークン:有
#                     2. <name>   トークン:欠
#   引数1つ   -> その名前(または番号)へ切り替える。成否は終了コード。
#
# ★「トークン:有/欠」の意味づけ(ここが唯一の解釈):
#   cswap は `usageStatus` に `keychain_unavailable` を出す事が在る = **鍵が読めなかった**
#   だけで、トークンが無い訳ではない。これを「欠」に丸めると、電話には
#   「そのアカウントは切り替えられません」と**嘘の断り**が出る。よって
#   欠にするのは cswap が明確に「トークンが無い」と言った時だけで、
#   読めなかった時は「有」に倒す(= 切替を試させ、失敗はその時に正直に返す)。
#   fail-open に見えるが、ここでの fail-closed は**機能の誤停止**であって安全ではない。
set -uo pipefail

CSWAP="${RC_CSWAP_BIN:-$HOME/.local/bin/cswap}"
[ -x "$CSWAP" ] || { echo "cswap が無い: $CSWAP" >&2; exit 3; }

# --- 切替(引数あり)---------------------------------------------------------
if [ "$#" -gt 0 ]; then
    exec "$CSWAP" switch "$1"
fi

# --- 観測(引数なし)---------------------------------------------------------
raw="$("$CSWAP" list --json 2>/dev/null)" || { echo "cswap list --json が失敗" >&2; exit 4; }
[ -n "$raw" ] || { echo "cswap list --json が空" >&2; exit 4; }

printf '%s' "$raw" | /usr/bin/python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.stderr.write("cswap の JSON が読めない\n"); sys.exit(5)

accounts = d.get("accounts")
if not isinstance(accounts, list):
    sys.stderr.write("cswap の JSON に accounts が無い\n"); sys.exit(5)

# ★型と形を厳しく見る(Codex 2026-08-26)。ここを緩くすると、落ちる代わりに
#   **読めるが間違っている一覧**が出る —— 電話には正常な顔で届くので一番気付けない。
def die(msg):
    sys.stderr.write(msg + "\n"); sys.exit(5)

active_no = d.get("activeAccountNumber")
if active_no is not None and not isinstance(active_no, int) or isinstance(active_no, bool):
    die("activeAccountNumber が整数でない")

cur = None
rows = []
seen = set()
for a in accounts:
    if not isinstance(a, dict):
        die("accounts の行が object でない")
    name = a.get("email")
    # ★改行を弾く。1つ通すと、名前の中から**もう1行**を生やせる(行の偽造)。
    if not isinstance(name, str) or not name.strip() or any(c in name for c in "\r\n\x00"):
        die("email が単一行の非空文字列でない")
    name = name.strip()
    no = a.get("number")
    if not isinstance(no, int) or isinstance(no, bool) or no < 1:
        die("number が 1 以上の整数でない")
    if no in seen:
        die("number が重複している")
    seen.add(no)
    act = a.get("active")
    # 文字列の "false" は真になる。bool 以外は受け取らない。
    if act is not None and not isinstance(act, bool):
        die("active が真偽値でない")
    is_active = bool(act) or (no == active_no)
    # 「欠」は cswap が明確に無いと言った時だけ。読めなかった(keychain_unavailable)は「有」。
    status = a.get("usageStatus")
    missing = status in ("no_token", "missing_token", "token_missing")
    rows.append((is_active, no, name, "欠" if missing else "有"))

n_active = sum(1 for r in rows if r[0])
if n_active > 1:
    die("現用が2行以上ある(active と activeAccountNumber が食い違っている)")
cur = next((r[2] for r in rows if r[0]), None)

rows.sort(key=lambda r: r[1])
print("現用: %s" % (cur if cur else "(未設定)"))
print("優先順 (.order):")
for is_active, no, name, tok in rows:
    mark = "->" if is_active else "  "
    print("%s %2d. %s   トークン:%s" % (mark, no, name, tok))
'
