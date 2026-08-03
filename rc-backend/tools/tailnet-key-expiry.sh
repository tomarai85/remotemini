#!/bin/bash
# tailnet-key-expiry.sh — tailnet 鍵があと何日で切れるかを言う。
#   宛先: rc-backend/tools/tailnet-key-expiry.sh(= edith 上では /Users/edith/rc-backend/tools/)
#
# なぜ独立した file なのか:
#   呼ぶ側が3つ在る(起動ラッパ / deploy 台本 / 外向きの生存監視)。同じ計算を3箇所に書くと
#   **一番古い1箇所だけが残る**。DESIGN.md §2.13 で表の再掲を禁じたのと同じ話。
#
# なぜこれが要るのか(2026-08-02 実測):
#   edith の鍵は 2026-12-25 に切れる。Tom の渡米は 8/20。切れると edith は tailnet から落ち、
#   電話の面と**復旧用の ssh を同時に失う**。無人の機械に物理で触れない場所から戻す手が無くなる
#   = 単一障害点(Codex 2026-08-02)。
#
# ── ★2026-08-03: 鎖には鍵が **2本** ある ──────────────────────────────
#   外向きの監視は「edith を、別のノードから」叩く形なので、鍵は監視される側と**監視する側**の
#   2本が効く。実測(2026-08-03、Jervis から `tailscale status --json`):
#       Self(観測者 = Jervis)  残り  46 日 = 2026-09-19  ← **先に切れる。しかも渡米中**
#       Peer edith             残り 143 日 = 2026-12-25
#   観測者の鍵が切れると観測者が tailnet から落ち、edith は無事なのに `/healthz` へ届かなくなる
#   = **本物の障害と区別が付かない偽の警報**が出るか、監視ごと黙るか、のどちらか。
#   遠い方(edith)だけ見ていると、**先に壊れる方を一度も見ない**。だから `--chain` を足した。
#
# 使い方:
#   tailnet-key-expiry.sh                この機械の鍵だけ(既定。呼び口の互換を壊さない)
#   tailnet-key-expiry.sh --peer <名>    指定した相手の鍵だけ
#   tailnet-key-expiry.sh --chain <名>   この機械と相手の**両方**。判定は近い方で決める
#   <名> は HostName でも DNS 名でも良い(`edith` / `desk.tailnet.example` のどちらでも)
#   --porcelain                          人向けの文でなく機械向けの1行/対象を出す:
#                                          KEY <self|peer> <残り日数|-> <期限日|-|none>
#     ★何故これが要るか: 呼ぶ側(health-observer)は Discord へ文を出す。そこへ**此処の散文を
#       そのまま流すと、通知の文面が此方の表現に引きずられる**。観測者が要るのは「どちら側が
#       何日か」の2値だけなので、それだけを固い形で渡し、Tom が読む文は観測者が自分で組む。
#
# 終了コード:
#   0 = 期限なし、または閾値より遠い
#   1 = 閾値より近い(**警告であって門ではない** — 下記)
#   2 = 測れなかった(「切れない」とは**言わない**。相手が見つからない時もここ)
#
# ★1 を門にしない理由: 鍵が 40 日後に切れる事は、コードを配る事の妨げにならない。
#   ここで deploy を止めても被害は1つも減らず、出来る仕事だけが止まる。fail-closed は
#   「送信」や「本番反映」の判断に効かせる物で、警報を門に化けさせる為の物ではない。
#   → 呼ぶ側は `|| true` で受け、**大きな声で出す**。止めるかは人が決める。

set -u

TS="${RC_TAILSCALE_BIN:-/Applications/Tailscale.app/Contents/MacOS/Tailscale}"
WARN_DAYS="${RC_KEY_WARN_DAYS:-45}"

SCOPE="self"; TARGET=""; PORCELAIN=0
while [ $# -gt 0 ]; do
    case "$1" in
        --peer|--chain)
            # ★`shift 2` は残りが1個の時に**失敗し、しかも shift しない**。while がそのまま
            #   回り続ける = 無限ループ。2026-08-03 に実際に回してしまい、CPU を焼いて
            #   裏で走っていた変異試験の計時まで汚した。値の有無を shift の**前**に見る。
            [ $# -ge 2 ] || { echo "鍵の期限: 測れない($1 に相手の名前が無い)" >&2; exit 2; }
            case "$1" in --peer) SCOPE="peer" ;; *) SCOPE="chain" ;; esac
            TARGET="$2"; shift 2 ;;
        --porcelain) PORCELAIN=1; shift ;;
        *) echo "不明な引数: $1" >&2; exit 2 ;;
    esac
done
if [ "$SCOPE" != "self" ] && [ -z "$TARGET" ]; then
    echo "鍵の期限: 測れない(--$SCOPE に相手の名前が無い)" >&2
    exit 2
fi

if [ ! -x "$TS" ]; then
    # porcelain は機械が読む面なので、散文を混ぜず終了コードだけで言う。
    if [ "$PORCELAIN" -eq 1 ]; then echo "鍵の期限: 測れない(${TS} が無い)" >&2
    else echo "鍵の期限: 測れない(${TS} が無い)"; fi
    exit 2
fi

"$TS" status --json 2>/dev/null \
  | WARN_DAYS="$WARN_DAYS" KEY_SCOPE="$SCOPE" KEY_TARGET="$TARGET" KEY_PORCELAIN="$PORCELAIN" \
    /usr/bin/python3 -c '
import sys, os, json, datetime

warn   = int(os.environ.get("WARN_DAYS", "45"))
scope  = os.environ.get("KEY_SCOPE", "self")
target = os.environ.get("KEY_TARGET", "")
porc   = os.environ.get("KEY_PORCELAIN", "0") == "1"

try:
    st = json.load(sys.stdin)
except Exception:
    if not porc:
        print("鍵の期限: 取得できなかった(status --json が読めない)")
    raise SystemExit(2)

def names(node):
    """HostName でも DNS 名でも当たる様にする。DNS 名は末尾の . を落とし、先頭ラベルも見る。"""
    out = []
    h = node.get("HostName")
    if h: out.append(h)
    d = (node.get("DNSName") or "").rstrip(".")
    if d:
        out.append(d)
        out.append(d.split(".")[0])
    return out

def find_peer(name):
    for v in (st.get("Peer") or {}).values():
        if name in names(v):
            return v
    return None

# (side, 見出し, ノード) の列を作る。見つからない相手は None のまま持ち回って 2 で落とす。
# side は porcelain 用の固い語(self / peer)。見出しは人が読む面だけに使う。
targets = []
self_node = st.get("Self") or {}
if scope in ("self", "chain"):
    label = (self_node.get("HostName") or "この機械")
    targets.append(("self", f"観測側 {label}" if scope == "chain" else "鍵の期限", self_node))
if scope in ("peer", "chain"):
    targets.append(("peer", f"相手 {target}" if scope == "chain" else "鍵の期限", find_peer(target)))

now = datetime.datetime.now(datetime.timezone.utc)
worst = 0          # 0 遠い / 1 近い / 2 測れない。大きい方を採る
nearest = None     # 近い方の (日数, 見出し, 日付)

for side, label, node in targets:
    if node is None:
        print(f"KEY {side} - -" if porc else f"{label}: 測れない(tailnet の一覧に見つからない)")
        worst = max(worst, 2)
        continue
    e = node.get("KeyExpiry")
    if not e:
        # 期限を無効化すると KeyExpiry ごと消える。= Tom の操作が効いた事の確認にもなる。
        print(f"KEY {side} - none" if porc else f"{label}: なし(無効化済み)")
        continue
    t = datetime.datetime.fromisoformat(e.replace("Z", "+00:00"))
    d = (t - now).days
    # ★この python は shell の **単引用符**の中に在る。ここに `\x27` を書くと文字列が其処で
    #   終わり、後は shell が食う(2026-08-03 に踏んだ: `f"{\x27★\x27 if ...}"` が
    #   `(★ if d < warn else )` に化けて SyntaxError)。引用符は二重だけを使う事。
    mark = "★" if d < warn else ""
    if porc:
        print(f"KEY {side} {d} {t:%Y-%m-%d}")
    else:
        print(f"{mark}{label}: {t:%Y-%m-%d} (残り {d} 日)")
    if d < warn:
        worst = max(worst, 1)
        if nearest is None or d < nearest[0]:
            nearest = (d, label, t)

if nearest is not None and not porc:
    print(f"★一番近いのは {nearest[1]} = 残り {nearest[0]} 日(閾値 {warn} 日)")
    print("★切れると tailnet から落ちる。電話の面も、復旧用の ssh も、同時に失う")
    print("★直す = Tailscale admin console → Machines → 該当機 → Disable key expiry")

raise SystemExit(worst)
'
exit "${PIPESTATUS[1]}"
