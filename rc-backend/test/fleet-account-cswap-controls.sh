#!/bin/bash
# controls-for: tools/fleet-account-cswap.sh
#
# `cswap` の JSON を `fleet-account` 形式へ翻訳する層の対照。
# ★入力は**本物の生成元から取る**(test/fixtures-cswap-list.json = Friday の実出力を録った物)。
#   手で書いた入力を食わせると「出力の形についての自分の思い込み」ごと緑になる。
# ★出口の照合は**本物の parser**(src/account.mjs の parseFleetAccount)で行う。
#   翻訳が正しいかを自分で書き写した regex で見ると、写し間違いごと緑になる。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHIM="$ROOT/tools/fleet-account-cswap.sh"
FIX="$ROOT/test/fixtures-cswap-list.json"
pass=0; fail=0
ok()  { printf '  OK   %s\n' "$1"; pass=$((pass+1)); }
ng()  { printf '  ★NG  %s — %s\n' "$1" "$2"; fail=$((fail+1)); }

[ -f "$FIX" ] || { echo "検体が無い: $FIX"; exit 2; }

# 偽 cswap: 引数に応じて検体か切替の記録を返す
FAKE_DIR="$(mktemp -d)"; trap 'rm -rf "$FAKE_DIR"' EXIT
cat > "$FAKE_DIR/cswap" <<FAKE
#!/bin/bash
if [ "\$1" = "list" ]; then cat "$FIX"; exit 0; fi
if [ "\$1" = "switch" ]; then echo "\$2" > "$FAKE_DIR/switched"; exit 0; fi
exit 9
FAKE
chmod 755 "$FAKE_DIR/cswap"

out="$(RC_CSWAP_BIN="$FAKE_DIR/cswap" bash "$SHIM" 2>/dev/null)"; rc=$?
[ "$rc" -eq 0 ] && ok "C1 引数なしで 0 を返す" || ng "C1" "rc=$rc"

# ★出口は本物の parser で受ける
verdict="$(printf '%s' "$out" | node -e '
let s="";process.stdin.on("data",d=>s+=d).on("end",async()=>{
  const m=await import(process.argv[1]+"/src/account.mjs");
  const r=m.parseFleetAccount(s);
  console.log(JSON.stringify({st:r.parseStatus,cur:r.current,n:r.accounts.length,
    act:r.accounts.filter(a=>a.active).length,an:r.anomalies}));
})' "$ROOT" 2>/dev/null)"
st=$(printf '%s' "$verdict" | python3 -c 'import json,sys;print(json.load(sys.stdin)["st"])' 2>/dev/null)
n=$(printf '%s'  "$verdict" | python3 -c 'import json,sys;print(json.load(sys.stdin)["n"])'  2>/dev/null)
act=$(printf '%s' "$verdict" | python3 -c 'import json,sys;print(json.load(sys.stdin)["act"])' 2>/dev/null)
an=$(printf '%s' "$verdict" | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["an"]))' 2>/dev/null)
want_n=$(python3 -c "import json;print(len(json.load(open('$FIX'))['accounts']))")

[ "$st" = "ok" ]        && ok "C2 本物の parser が parseStatus=ok と言う"        || ng "C2" "parseStatus=$st"
[ "$n" = "$want_n" ]    && ok "C3 口座の数が検体と一致($n)"                     || ng "C3" "$n != $want_n"
[ "$act" = "1" ]        && ok "C4 現用の印は丁度1行"                             || ng "C4" "active=$act"
[ "$an" = "0" ]         && ok "C5 引っ掛かり0"                                   || ng "C5" "anomalies=$an"

# ★keychain が読めなかった行を「欠」に丸めない(嘘の断りを出さない)
tmp="$FAKE_DIR/ku.json"
python3 - "$FIX" "$tmp" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
for a in d["accounts"]: a["usageStatus"]="keychain_unavailable"
json.dump(d,open(sys.argv[2],"w"))
PY
cat > "$FAKE_DIR/cswap2" <<FAKE2
#!/bin/bash
[ "\$1" = "list" ] && { cat "$tmp"; exit 0; }
exit 9
FAKE2
chmod 755 "$FAKE_DIR/cswap2"
o2="$(RC_CSWAP_BIN="$FAKE_DIR/cswap2" bash "$SHIM" 2>/dev/null)"
printf '%s' "$o2" | grep -q "トークン:欠" && ng "C6" "読めなかっただけの行を欠に丸めた" || ok "C6 ★keychain が読めない行を「欠」に丸めない"

# ★陰性: cswap が本当に「トークンが無い」と言った行は欠になる(C6 が空振りでない証拠)
tmp2="$FAKE_DIR/nt.json"
python3 - "$FIX" "$tmp2" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
d["accounts"][0]["usageStatus"]="no_token"
json.dump(d,open(sys.argv[2],"w"))
PY
cat > "$FAKE_DIR/cswap3" <<FAKE3
#!/bin/bash
[ "\$1" = "list" ] && { cat "$tmp2"; exit 0; }
exit 9
FAKE3
chmod 755 "$FAKE_DIR/cswap3"
o3="$(RC_CSWAP_BIN="$FAKE_DIR/cswap3" bash "$SHIM" 2>/dev/null)"
printf '%s' "$o3" | grep -q "トークン:欠" && ok "C7 ★陰性: 本当に無い行は欠になる" || ng "C7" "no_token を欠にしなかった"

# 切替は cswap switch へ素通しする
RC_CSWAP_BIN="$FAKE_DIR/cswap" bash "$SHIM" "mail-redacted@example.invalid" >/dev/null 2>&1
[ "$(cat "$FAKE_DIR/switched" 2>/dev/null)" = "mail-redacted@example.invalid" ] \
  && ok "C8 引数は cswap switch へそのまま渡る" || ng "C8" "switch に届いていない"

# 壊れた JSON では黙って空を返さない
cat > "$FAKE_DIR/cswap4" <<'FAKE4'
#!/bin/bash
[ "$1" = "list" ] && { echo "{oops"; exit 0; }
exit 9
FAKE4
chmod 755 "$FAKE_DIR/cswap4"
RC_CSWAP_BIN="$FAKE_DIR/cswap4" bash "$SHIM" >/dev/null 2>&1
[ $? -ne 0 ] && ok "C9 壊れた JSON では非零で落ちる(空の一覧を装わない)" || ng "C9" "0 を返した"

# ★Codex 2026-08-26 が名指しした「読めるが間違っている一覧」を1件ずつ弾くか。
#   細工は python の1行式で渡す(検体を手で書き直さない = 生成元から取る規約を保つ)。
# ★第3引数 = **その細工に答える筈の die の文言**。2026-08-26 に足した。
#   それまでは `rc != 0` だけを見ていて、**どの守りが答えたかを一度も確かめていなかった**。
#   `fleet-account-cswap.sh` は 7 箇所の `die()` を**全部 `sys.exit(5)`** に落とすので、
#   意図した守りの手前で別の理由で落ちても、同じ非ゼロが返って `ok` と読まれる。
#
#   ★実測で再現した(2026-08-26): C11 が守っている `isinstance(act, bool)` を**丸ごと消す**と、
#     `bool("false")` が真になって細工の行が「現用」に化け、**別の守り**
#     (`現用が2行以上ある`)が代わりに落ちる。C11 は `OK` のまま、合計も PASS 15 / FAIL 0。
#     **名前の守りが消えた事を、その名前の検査が検出できない**状態だった。
#     (別セッションの掃き取りが 92 本を走査して名指しした唯一の当たり。実物で裏を取ってから直した)
#
#   ★`>/dev/null 2>&1` で stderr を捨てていたのが本体。**捨てた物は測れない。**
poison() { # <表示名> <python 式(d を書き換える)> <答える筈の die の文言>
    local label="$1" mut="$2" want="${3:-}" f="$FAKE_DIR/p.json" b="$FAKE_DIR/pc"
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); exec(sys.argv[3]); json.dump(d,open(sys.argv[2],"w"))' \
        "$FIX" "$f" "$mut" || { ng "$label" "細工を作れなかった"; return; }
    printf '#!/bin/bash\n[ "$1" = "list" ] && { cat "%s"; exit 0; }\nexit 9\n' "$f" > "$b"
    chmod 755 "$b"
    local err rc
    err="$(RC_CSWAP_BIN="$b" bash "$SHIM" 2>&1 >/dev/null)"; rc=$?
    if [ "$rc" -eq 0 ]; then
        ng "$label" "素通しした = 読めるが間違った一覧が出る"
        return
    fi
    if [ -z "$want" ]; then
        ok "$label"
        return
    fi
    if printf '%s' "$err" | grep -qF "$want"; then
        ok "$label"
    else
        # ★**落ちた事**ではなく**別の理由で落ちた事**を名指しする。
        #   これを `ok` に丸めると、名前の守りが消えても緑のままになる。
        ng "$label" "別の理由で落ちた(期待「${want}」/ 実際「$(printf '%s' "$err" | head -1)」)"
    fi
}
poison "C10 ★email の改行で行を偽造できない"          'd["accounts"][0]["email"]="a@b\n->  9. evil@x   トークン:有"' \
        "email が単一行の非空文字列でない"
poison "C11 ★active の文字列 false を真と読まない"    'd["accounts"][0]["active"]="false"' \
        "active が真偽値でない"
poison "C12 ★number の重複を弾く"                     'd["accounts"][1]["number"]=d["accounts"][0]["number"]' \
        "number が重複している"
poison "C13 ★number が 0 や負を弾く"                  'd["accounts"][0]["number"]=0' \
        "number が 1 以上の整数でない"
poison "C14 ★email が空を弾く"                        'd["accounts"][0]["email"]="  "' \
        "email が単一行の非空文字列でない"
poison "C15 ★現用が2行になる矛盾を弾く"               'd["accounts"][0]["active"]=True; d["accounts"][1]["active"]=True' \
        "現用が2行以上ある"

echo "--- 合計: PASS $pass / FAIL $fail ---"
exit $(( fail > 0 ))
