#!/bin/bash
# no-operator: 渡米前に人が撃つ(PRE-DEPARTURE-2026-08-20.md の最後の手順)。生きた edith と
#   tailnet が要るので門からは回せない —— 回線が落ちている日の commit が全部止まる
# departure-survivability-check.sh — 「3週間、誰も触らない edith は生き延びるか」を
# **Jervis から1回で**測る。渡米直前に撃つ。
#
# ★この道具が測らない7項目(FileVault / 自動ログイン / plist の在処 / RunAtLoad /
#   KeepAlive / autorestart / sleep)は `tools/coldboot-chain.sh` が既に測っている。
#   写しを作らず、**edith の上のそれを呼んで結果を引き取る**。
#   (2026-08-07: 一度そこを手で作り直しかけた。同じ物を2つ持つと、片方だけ直る)
#   ★委ねる以上、**どの版が測ったのか**を名乗る必要が在る。向こうの写しと手元の
#     sha を突き合わせ、違えば未測定へ倒す(赤ではない —— edith が壊れている訳ではなく、
#     「上の緑をこの repo のコードの緑として読めない」だけ)。deploy の半端な失敗が
#     古い道具の緑を新しい保証に見せるのを止める。
#
# ここが足すのは、冷起動の鎖の外に在って**渡米すると触れなくなる** 9 つ:
#   (1) tailnet の鍵の期限 … 切れると tailnet から落ち、復旧用の ssh も同じ経路なので同時に死ぬ
#   (2) job が今この瞬間 動いている事 … plist が正しくても、落ちて再起動を繰り返す形は別問題
#   (3) 面が 401 を返す事      … 200 は鍵が外れている印。tailnet 内の誰でも読める状態
#   (4) 空き容量               … 3週間分のログと OS 更新の置き場
#   (5) 鎖②③を戻す物が在る事 … com.tom.work-tmux と com.edith.rc-phone-window が
#         launchctl に居るか。①(rc-backend)だけ見て「電話が使える」と読むのが
#         DESIGN §6 が名指しで警告している誤読。サーバが上がっても、tmux と
#         その中の会話が戻らなければ「読めるが送れない」で止まる
#   (6) 今この瞬間、tmux 経路で話せる相手が居る事 … /api/sessions?scope=registered を
#         **本番の判定コードそのもの**に数えさせる(生死判定を此処で作り直さない)。
#         0 件 = 「読めるが送れない」(DESIGN §6 の表)
#   (7) その会話が**返事を返せる**事 … ①〜④が全部緑でも「認証が切れていて返事だけ
#         来ない」形は作れる。心拍を書く statusLine は認証と無関係に走るので、(6) の
#         件数は**画面が描けている**証拠であって**返事が返る**証拠ではない。DESIGN §6
#         の誤読の、一段奥に在る同じ型。電話が使うのと同じ**対話 shell 文脈**で
#         `claude auth status --json` を読む(鍵は出さない = loggedIn と authMethod だけ)。
#         今日の緑が旅程25日目の保証にならない事は承知の上で、**出発時点で既に
#         切れている**形だけは潰す
#   (8) **電話にアプリが入っている事** … (1)〜(7) は全部 edith 側で、旅程で使う2台の
#         うち電話を誰も数えていなかった。2026-08-09 に測ったら**入っていなかった**
#         (机の上は 527 件全緑、文書は「実機到達済み」)。載る先を数えない緑は、
#         #56(edith が古い版で走っていた)と同じ型 —— 向きが違うだけ
#   (9) **見張りそのものが生きている事** … (1)〜(8) が全部落ちた事を Tom へ知らせるのは
#         athenas の rc-health-observer だけ。それが死ぬと**沈黙が健康と見分けが付かない**
#         (yoda が 46 時間気付けなかった形)。ログの最新の刻みの齢を向こうの時計で測り、
#         閾値は向こうの plist の StartInterval から導く —— 秒数を此処へ書き写すと、
#         刻みを変えた日に此処が黙って嘘になる
#
# 使い方:
#   bash rc-backend/tools/departure-survivability-check.sh [--days N] [--host user@host]
#
# 終了コード(この repo の三色):
#   0 = 緑     渡米に耐える
#   1 = 赤     1つ以上が耐えない(各行に直し方が出る)
#   2 = 未測定  edith に届かない等で判定が付かない。**緑にも赤にも丸めない**
#
# 出さない物: 会話 id / 機器名 / 鍵。tailnet は**台数と残日数だけ**を出す。
set -u

HOST="${RC_EDITH_HOST:mail-redacted@example.invalid}"
# 旅程。帰国が延びた時に「余裕がある」と嘘を吐かない為、上書きできる
TRIP_DAYS="${RC_TRIP_DAYS:-30}"

while [ $# -gt 0 ]; do
    case "$1" in
        # ★`shift 2` を裸で書かない。引数が1つしか残っていない時 `shift 2` は**失敗して
        #   $# を減らさない**ので、`--days` を値無しで渡すと此処が無限ループする
        #   (2026-08-07、対照 N2 が実際に捕まえた)。値の有無を先に見る。
        --days) [ $# -ge 2 ] || { echo "--days に値が無い" >&2; exit 2; }
                TRIP_DAYS="$2"; shift 2 ;;
        --host) [ $# -ge 2 ] || { echo "--host に値が無い" >&2; exit 2; }
                HOST="$2"; shift 2 ;;
        # 行番号を書かない。2026-08-09 に鎖(8)(9)を足した時、此処の `2,48p` を
        # 直し忘れて説明が途中で切れた —— 説明の長さを2箇所に持つのが原因なので、
        # 数える側を消す。冒頭の解説 = 2行目から `set -u` の手前まで。
        -h|--help) awk 'NR>1 { if ($0 == "set -u") exit; print }' "$0"; exit 0 ;;
        *) echo "知らない引数: $1" >&2; exit 2 ;;
    esac
done

case "$TRIP_DAYS" in
    ''|*[!0-9]*) echo "--days は正の整数で: ${TRIP_DAYS:-(空)}" >&2; exit 2 ;;
esac

red=0; unmeasured=0
say_ok()  { printf '  緑    %s\n' "$1"; }
say_bad() { printf '  赤    %s\n' "$1"; red=$((red+1)); }
say_unm() { printf '  未測定 %s\n' "$1"; unmeasured=$((unmeasured+1)); }
say_note(){ printf '  --    %s\n' "$1"; }

echo "3週間の無人耐久(旅程 ${TRIP_DAYS} 日で判定)"
echo

# ---------------------------------------------------------------------------
# ssh は1回だけ。項目ごとに張ると、途中で切れた時に「一部だけ緑」という
# 一番読み違えやすい中間状態が出る。
# 冷起動の鎖は edith の上の coldboot-chain.sh に**そのまま**やらせて、
# 出力と終了コードを持ち帰る(判定を此処で作り直さない = 写しを作らない)。
# ---------------------------------------------------------------------------
RAW=$(ssh -o ConnectTimeout=10 -o BatchMode=yes "$HOST" '
    p() { printf "%s=%s\n" "$1" "$2"; }

    CB="$HOME/rc-backend/tools/coldboot-chain.sh"
    if [ -f "$CB" ]; then
        out=$(bash "$CB" 2>&1); rc=$?
        p cb_rc "$rc"
        printf "cb_out<<\n%s\ncb_out>>\n" "$out"
        # ★どの版が測ったのかを名乗る。判定を向こうの道具に委ねている以上、
        #   「緑だった」だけでは**どの道具の緑か**が言えない(写しが2つ問題)。
        p cb_sha "$(shasum -a 256 "$CB" 2>/dev/null | awk "{print \$1}")"
    else
        p cb_rc missing
    fi
    p pw_sha "$(shasum -a 256 "$HOME/rc-backend/tools/ensure-phone-window.sh" 2>/dev/null | awk "{print \$1}")"

    p job_rc  "$(launchctl list 2>/dev/null | awk "\$3 == \"com.edith.rc-backend\" { print \$2; exit }")"
    p job_pid "$(launchctl list 2>/dev/null | awk "\$3 == \"com.edith.rc-backend\" { print \$1; exit }")"

    # 鎖②③を戻す物。値の意味: 空=居ない / - =まだ終了コードが無い(走行中) / 数字=最後の終了コード
    p tmux_job  "$(launchctl list 2>/dev/null | awk "\$3 == \"com.tom.work-tmux\" { print \$2; exit }")"
    p phone_job "$(launchctl list 2>/dev/null | awk "\$3 == \"com.edith.rc-phone-window\" { print \$2; exit }")"

    # 鎖④。生死判定は**本番の /api/sessions にやらせる**(此処で aliveKind を作り直さない)。
    # 鍵は argv にも env にも置かない(ps から見える)。python が鍵ファイルを直接読む。
    #
    # ★`limit` を付けない。一度 `limit=50` と書いて、根拠を「生きた会話は心拍で先頭に
    #   留まる」と説明したが**間違い**だった(2026-08-07、実コードを読んで自分で撤回)。
    #   `scanSessions` の並び基準は登録簿の心拍ではなく **jsonl の mtime**(最終発言 =
    #   `sortMs`)で、打ち切りはその `found.sort` の**後**に「出した件数」で掛かる。
    #   = **生きているが暫く発言していない会話は下に沈んで切り落とされる**。
    #   登録簿は伸びる一方(prune が無い)ので、上限を持つと**渡米中にこそ**
    #   「生きているのに 0 件」= 偽の赤が出る。
    #   外して良い理由: `scope=registered` で走査は登録簿の件数に縛られ、`scanSessions`
    #   冒頭のコメントが持つ実測値が「edith 642本の全 meta 読みで 30ms」。上限を発明しない。
    /usr/bin/python3 -c "
import json, os, urllib.request
kp = os.path.expanduser(\"~/.rc-backend/api.key\")
try:
    key = open(kp).read().strip()
except Exception:
    print(\"alive=nokey\"); raise SystemExit
req = urllib.request.Request(
    \"http://127.0.0.1:8787/api/sessions?scope=registered\",
    headers={\"authorization\": \"Bearer \" + key})
try:
    with urllib.request.urlopen(req, timeout=8) as r:
        d = json.load(r)
except Exception as e:
    print(\"alive=unreachable\"); print(\"why=%s\" % type(e).__name__); raise SystemExit
ss = d.get(\"sessions\") or []
print(\"alive=%d\" % sum(1 for s in ss if ((s.get(\"live\") or {}).get(\"route\") == \"tmux\")))
print(\"alive_total=%d\" % len(ss))
"

    # 鎖⑤。**対話 shell 文脈**で測るのが要点 —— tmux の pane は対話 shell なので
    # ~/.zshrc を読む。launchd 側(非対話)は同じ変数を持たないので、非対話で測ると
    # 「電話の経路が死んでいる」という**嘘の赤**が出る(2026-08-07 に実際に一度出した)。
    # 鍵は出さない: python が読むのは loggedIn と authMethod の2つだけで、
    # 生の出力は一度も印字しない(apiKey 系の値が混ざる可能性を構造で潰す)。
    # timeout を python 側に持たせているのは、対話 zsh の起動が固まった時に
    # **この検査ごと**止まるのを防ぐ為(macOS の /bin/sh に timeout が無い)。
    if command -v zsh >/dev/null 2>&1; then
        /usr/bin/python3 -c "
import json, subprocess
try:
    r = subprocess.run([\"zsh\", \"-ic\", \"claude auth status --json\"],
                       capture_output=True, text=True, timeout=25)
except Exception:
    print(\"auth=timeout\"); raise SystemExit
s = r.stdout
i, j = s.find(\"{\"), s.rfind(\"}\")
try:
    d = json.loads(s[i:j+1])
except Exception:
    print(\"auth=unparsed\"); raise SystemExit
print(\"auth=%s\" % (\"yes\" if d.get(\"loggedIn\") else \"no\"))
print(\"auth_method=%s\" % (d.get(\"authMethod\") or \"-\"))
" < /dev/null
    else
        echo "auth=nozsh"
    fi

    # claude 本体の版と自動更新の設定。**判定は付けない**(正しい版という物が無い)。
    # 記録する理由は1つ —— 自動更新が入っているので、旅程の途中で版が黙って変わる。
    # 帰ってから「いつ壊れたか」を突き合わせられる様に、出発時点の数字を残す。
    p cli_ver "$(PATH="$HOME/.local/bin:$PATH" claude --version 2>/dev/null | awk "{print \$1}")"
    p cli_auto "$(grep -oE "\"autoUpdates\"[^,}]*" "$HOME/.claude.json" 2>/dev/null | grep -oE "true|false" | head -1)"

    # 401 が正。200 = 鍵が外れている、それ以外 = 面が応答していない。
    p http "$(curl -sS -m 5 -o /dev/null -w "%{http_code}" http://127.0.0.1:8787/api/sessions 2>/dev/null || echo 000)"

    p freeg "$(df -g / 2>/dev/null | awk "NR==2 { print \$4 }")"

    # tailnet: **機器名は一切出さない**。期限が付いている台数と最小残日数だけ。
    TS=/Applications/Tailscale.app/Contents/MacOS/Tailscale
    [ -x "$TS" ] || TS=$(command -v tailscale 2>/dev/null)
    if [ -n "${TS:-}" ] && [ -x "$TS" ]; then
        "$TS" status --json 2>/dev/null | /usr/bin/python3 -c "
import json,sys,datetime
try: d = json.load(sys.stdin)
except Exception: print(\"ts_state=unreadable\"); sys.exit(0)
now = datetime.datetime.now(datetime.timezone.utc)
nodes = [d.get(\"Self\") or {}] + list((d.get(\"Peer\") or {}).values())
days = []
for n in nodes:
    e = n.get(\"KeyExpiry\")
    if not e: continue          # 期限なし = 望ましい形
    try: t = datetime.datetime.fromisoformat(e.replace(\"Z\", \"+00:00\"))
    except Exception: continue
    days.append(int((t - now).total_seconds() // 86400))
print(\"ts_state=ok\")
print(\"ts_total=%d\" % len(nodes))
print(\"ts_expiring=%d\" % len(days))
print(\"ts_min_days=%s\" % (min(days) if days else \"-\"))
"
    else
        echo "ts_state=absent"
    fi
' 2>/dev/null)

if [ -z "$RAW" ]; then
    echo "  未測定 edith に届かない($HOST)。**赤ではない** —— こちらの回線かもしれず、"
    echo "         「向こうが死んでいる」とは言えない。回線を変えて測り直す。"
    exit 2
fi

g() { printf '%s\n' "$RAW" | awk -F= -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); print; exit }'; }

# --- 冷起動の鎖(判定は向こうの道具の物をそのまま使う)-----------------------
echo "停電・強制再起動から独りで戻る鎖(coldboot-chain.sh @ edith)"
cb=$(g cb_rc)
case "$cb" in
    0) say_ok "7/7 繋がっている" ;;
    1) say_bad "鎖が切れている —— 下がその出力"
       printf '%s\n' "$RAW" | awk '/^cb_out<</{f=1;next} /^cb_out>>/{f=0} f' | sed 's/^/        /' ;;
    2) say_unm "coldboot-chain が測れなかった(2)。緑と読まない"
       printf '%s\n' "$RAW" | awk '/^cb_out<</{f=1;next} /^cb_out>>/{f=0} f' | sed 's/^/        /' ;;
    missing) say_bad "edith に coldboot-chain.sh が無い —— deploy-to-edith.sh を先に回す" ;;
    *) say_unm "coldboot-chain の終了コードが読めない(${cb:-空})" ;;
esac

# 上の判定は**向こうの写し**が出した物。手元の版と違えば、緑をこの repo の
# コードの緑として読めない。赤ではない(edith が壊れている訳ではない)ので未測定へ倒す。
sha_line() {   # sha_line <表示名> <手元の path> <向こうの sha>
    local mine
    mine=$(shasum -a 256 "$2" 2>/dev/null | awk '{print $1}')
    if [ -z "$mine" ]; then say_unm "$1 が手元に無く、版を突き合わせられない"
    elif [ -z "$3" ]; then say_unm "$1 の版が edith 側で読めない"
    elif [ "$mine" = "$3" ]; then say_note "$1 の版は手元と一致(${3:0:12})"
    else say_unm "$1 が手元と違う版(手元 ${mine:0:12} / edith ${3:0:12})—— 上の緑をこの repo の緑として読めない。deploy-to-edith.sh を回して測り直す"
    fi
}
HERE=$(cd "$(dirname "$0")" && pwd)
[ "$cb" = "missing" ] || sha_line "coldboot-chain.sh"      "$HERE/coldboot-chain.sh"      "$(g cb_sha)"
sha_line "ensure-phone-window.sh" "$HERE/ensure-phone-window.sh" "$(g pw_sha)"

# --- 今この瞬間 上がっているか -----------------------------------------------
echo
echo "面が上がっている事(冷起動の鎖とは別の問い = 今の状態)"
if [ -z "$(g job_pid)" ]; then
    say_bad "com.edith.rc-backend が launchctl に居ない"
elif [ "$(g job_rc)" = "0" ]; then
    say_ok "稼働中(最後の終了コード 0)"
else
    say_bad "最後の終了コードが $(g job_rc) —— 落ちて再起動を繰り返している疑い"
fi

case "$(g http)" in
    401) say_ok "/api/sessions が 401(生きている、かつ鍵が効いている)" ;;
    200) say_bad "/api/sessions が 200 —— **鍵が外れている**。tailnet 内の誰でも読める" ;;
    000) say_unm "/api/sessions に届かなかった(curl が答えを返さない)" ;;
    *)   say_bad "/api/sessions が $(g http)(面が応答していない)" ;;
esac

# --- 鎖②③ を戻す物 -----------------------------------------------------------
# 面が上がっただけでは電話は使えない。tmux と その中の会話が戻って初めて
# 「打ち込む / 割り込む」が成立する(DESIGN §6 の鎖4本)。
echo
echo "再起動の後、鎖②③ を戻す物(此処が空だと「読めるが送れない」で止まる)"
job_line() {   # job_line <表示名> <値> <終了コードの読み方の在処>
    case "$2" in
        '')  say_bad "$1 が launchctl に居ない —— 再起動の後、鎖を戻す物が誰も居ない" ;;
        -)   say_unm "$1 の終了コードがまだ無い(走っている最中に見た)。測り直す" ;;
        0)   say_ok  "$1(最後の終了コード 0)" ;;
        *)   say_bad "$1 の最後の終了コードが $2 —— 読み方は $3" ;;
    esac
}
job_line "com.tom.work-tmux"          "$(g tmux_job)"  "tmux の session work を作る側"
job_line "com.edith.rc-phone-window"  "$(g phone_job)" "tools/ensure-phone-window.sh の冒頭の終了コード表"

# --- 鎖④(今この瞬間、話せる相手が居るか)------------------------------------
echo
echo "電話から打ち込める相手(本番の /api/sessions に数えさせている)"
a=$(g alive)
case "$a" in
    nokey)       say_unm "鍵ファイルが読めず数えられなかった(判定を付けない)" ;;
    unreachable) say_unm "面に届かず数えられなかった($(g why))。上の 401 と併せて読む" ;;
    ''|*[!0-9]*) say_unm "件数が読めない(${a:-空})" ;;
    0)           say_bad "tmux 経路の相手が 0 件 —— phone 窓が戻っていない。一覧と履歴は読めるが打ち込めない" ;;
    *)           say_ok  "tmux 経路 ${a} 件 / 登録簿 $(g alive_total) 件" ;;
esac

# --- 鎖⑤(その相手が返事を返せるか)------------------------------------------
# 上の件数が緑でも此処が赤なら「見えて、打ち込めて、返事だけ来ない」。
# 一段奥の同じ誤読を潰す為に、件数とは**別の行**として出す。
echo
echo "その相手が返事を返せるか(電話と同じ対話 shell 文脈の claude auth status)"
case "$(g auth)" in
    yes)
        m=$(g auth_method)
        case "$m" in
            api_key) say_ok "認証は生きている(従量課金の API キー)"
                     say_note "この経路はサブスクの週次上限に当たらない代わりに、"
                     say_note "token-failover.sh の予備アカウントに**守られていない**(切れたら手で戻す)" ;;
            oauth|*) say_ok "認証は生きている(方式 ${m})"
                     say_note "この経路は週次上限に当たり得る。token-failover.sh が2時間毎に予備へ回す" ;;
        esac
        say_note "今日の緑は旅程25日目の保証にならない。切れた時の検知器は「電話から毎日触る」事"
        ;;
    no)      say_bad "認証が切れている —— 一覧と履歴は読めるが**返事が返らない**。edith で claude を開いて /login" ;;
    timeout) say_unm "対話 shell の起動が 25 秒で返らなかった(判定を付けない)" ;;
    nozsh)   say_unm "edith に zsh が無く、電話と同じ文脈を再現できない" ;;
    ''|unparsed|*) say_unm "claude auth status が JSON を返さない(claude が PATH に無い等)" ;;
esac
# ★此処は**必ず記録だけ**。正しい版という物が存在しないので赤にも未測定にもしない
#   (判定を付けると「更新された = 異常」になり、嘘の赤で検査ごと無視される)。
cv=$(g cli_ver); ca=$(g cli_auto)
if [ "$ca" = "true" ]; then
    say_note "claude 本体は ${cv:-版が読めない} / **自動更新が入っている** —— 旅程の途中で版が黙って変わる。"
    say_note "  壊れた日に此処を撃ち直せば、版が動いたのかを突き合わせられる(Jervis は持って出る)"
else
    say_note "claude 本体は ${cv:-版が読めない}(自動更新 ${ca:-不明})"
fi

# --- 余白 --------------------------------------------------------------------
echo
echo "余白"
v=$(g freeg)
case "$v" in
    ''|*[!0-9]*) say_unm "空き容量が読めない" ;;
    *) if [ "$v" -ge 20 ]; then say_ok "空き ${v}GB"
       else say_bad "空き ${v}GB —— 3週間分のログと OS 更新に足りない恐れ"; fi ;;
esac

# --- tailnet の鍵 ------------------------------------------------------------
echo
echo "tailnet の鍵(切れると復旧用の ssh も同じ経路なので同時に死ぬ)"
case "$(g ts_state)" in
    ok)
        n=$(g ts_expiring); m=$(g ts_min_days)
        if [ "$n" = "0" ]; then
            say_ok "期限付き 0 台 / 全 $(g ts_total) 台(失効しない形になっている)"
        else
            say_bad "期限付き ${n} 台、最短 残り ${m} 日(旅程 ${TRIP_DAYS} 日)—— admin console → Machines → Disable key expiry"
            say_note "機器名は出さない。どの台かは admin console 側で見る"
        fi
        ;;
    absent)     say_bad "tailscale CLI が見付からない —— 経路そのものを測れていない" ;;
    unreadable) say_bad "tailscale status が JSON を返さない(tailscaled が落ちている疑い)" ;;
    *)          say_unm "tailnet の状態が読めない" ;;
esac

# --- 電話の側 ----------------------------------------------------------------
# ★2026-08-09 追加。此処が無かったせいで「Sprint 5 で実機到達済み」と書かれた文書が
#   2日間残り、その間ずっと **アプリは Tom の電話に入っていなかった**。
#   #56(edith が古い版を走らせていた)と同じ型で、向きだけが違う ——
#   机の上の緑は、**それが載る先**を一度も数えていない。
#   鎖①〜⑦は全部 edith 側で、旅程で使う2台のうち**電話を誰も見ていなかった**。
#   出さない物: 機器名・識別子。出すのは在否だけ(この file の他の項目と同じ規律)。
#
#   三色の割り当て(丸めない):
#     電話が繋がっていない = **未測定**。渡米前に一度繋いで撃つのが此処の使い方で、
#       繋がっていない事は「入っていない」の証拠ではない。
#     繋がっていて 0 件     = **赤**。直し方は1行(`bash ios/tools/build.sh`)。
#   ★2026-08-10: 版も測る様になった(Codex 指摘②)。此処には元々
#     「版の一致は電話の画面(DESIGN §8-8)でしか見えない」と書いてあり、**人の目にしか
#     出来ない事へ機械の仕事を預けていた**。#56(edith が 5 commit 古い版で走っていた)
#     と同じ穴が電話側に開いたままだった。
#     やり方: `ios/tools/build.sh` が CFBundleVersion に commit の通算数を刻み、此処が
#     devicectl の `bundleVersion` と突き合わせる。期待値は **build.sh に訊く**
#     (`--print-build-num`)—— 此処で `git rev-list --count` を書き直すと片方だけ腐る。
#     三色: 一致 = 緑 / 不一致 = **赤**(古い物が電話に載っている、直し方は1行) /
#     どちらかが読めない = **未測定**(在否の緑は据え置き、版だけ未測定)。
#     ★これでも判らない物 = 汚れた木で焼いた事。番号は commit しないと動かないので、
#       同じ番号で中身の違う app が焼ける。其れは画面の rev(RCBuildRev)の役 = §8-8 は
#       まだ要る。**測れる様になったのは「どの commit か」まで**。
echo
echo "電話の側(この木で署名した RemoteMini が Tom の iPhone に入っているか)"
PHONE_BUNDLE="com.tomarai.remotemini"
# 対照が「道具そのものが無い」枝を測れる様に、名前だけ差し替えられる継ぎ目を置く
# (ssh を PATH で偽装する此処の流儀と同じ理由。既定は素の xcrun)。
PHONE_XCRUN="${RC_PHONE_XCRUN:-xcrun}"
if ! command -v "$PHONE_XCRUN" >/dev/null 2>&1; then
    say_unm "xcrun が無い —— 電話の側は測れていない"
else
    _dj=$(mktemp); _aj=$(mktemp)
    if ! "$PHONE_XCRUN" devicectl list devices --timeout 30 --json-output "$_dj" >/dev/null 2>&1; then
        say_unm "devicectl が機器一覧を返さない —— 電話の側は測れていない"
    else
        _dev=$(/usr/bin/python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
for x in d.get("result", {}).get("devices", []):
    h = x.get("hardwareProperties", {}) or {}
    c = x.get("connectionProperties", {}) or {}
    if h.get("platform") == "iOS" and c.get("pairingState") == "paired":
        print(x.get("identifier", ""))
        break
' "$_dj")
        if [ -z "$_dev" ]; then
            say_unm "iPhone が此処から見えない —— 繋いでから撃つ(繋がっていない事は「入っていない」の証拠にならない)"
        elif ! "$PHONE_XCRUN" devicectl device info apps --device "$_dev" \
                  --bundle-id "$PHONE_BUNDLE" --timeout 60 \
                  --json-output "$_aj" >/dev/null 2>&1; then
            say_unm "電話は見えるが一覧を返さない(tunnel が落ちた疑い)—— 測り直す"
        else
            # ★件数だけ数えない。`--bundle-id` で絞って問い合わせてはいるが、
            #   **絞り込みが効いている事**まで此処で確かめる(Codex 2026-08-09 指摘①:
            #   「1件以上」は対象アプリが在る事の証明になっていない)。名前の一致を
            #   数える = 絞りが壊れて全アプリが返っても緑にならない。
            #   版の突き合わせに使う `bundleVersion` も**同じ一問**で取る(2度引くと、
            #   その間に入れ替わった物を「在る」と「どの版か」で別々に見る事になる)。
            _info=$(/usr/bin/python3 -c '
import json, sys
try:
    apps = json.load(open(sys.argv[1])).get("result", {}).get("apps", [])
except Exception:
    print("x -"); sys.exit(0)
hit = [a for a in apps if a.get("bundleIdentifier") == sys.argv[2]]
ver = "-"
for a in hit:
    b = a.get("bundleVersion")
    if isinstance(b, str) and b.strip():
        ver = b.strip().replace(" ", "_")   # 空白は下の語分割を壊すので潰す
        break
print("%d %s" % (len(hit), ver))
' "$_aj" "$PHONE_BUNDLE")
            _n=${_info%% *}; _ver=${_info##* }
            case "$_n" in
                0)  say_bad "電話に RemoteMini が入っていない —— \`bash ios/tools/build.sh\`(引数無し = build + 署名 + install)"
                    say_note "此処が赤の間、受け入れ表の 5-c / 6-c(電話の側の体感)は永久に未測定のまま" ;;
                ''|*[!0-9]*) say_unm "一覧の中身が読めない —— 電話の側は測れていない" ;;
                *)  say_ok "電話に RemoteMini が入っている(${_n} 件)"
                    # ★期待値は **build.sh に訊く**。此処で `git rev-list --count` を
                    #   書き直すと、数える範囲を変えた日に片方だけ腐る(写しが2つ問題)。
                    _bsh="${RC_BUILD_SH:-$HERE/../../ios/tools/build.sh}"
                    if [ ! -f "$_bsh" ]; then
                        say_unm "版: 番号を出す道具が見付からない($_bsh)—— 期待値が作れない"
                    else
                        _want="$(bash "$_bsh" --print-build-num 2>/dev/null || true)"
                        case "$_want" in
                            # 0 = build.sh が git から数えられなかった時の値。緑にも赤にも丸めない
                            ''|0|*[!0-9]*)
                                say_unm "版: この木の番号が出せない(--print-build-num = [${_want:-空}])" ;;
                            *)
                                case "$_ver" in
                                    -|'') say_unm "版: 電話側の bundleVersion が一覧に無い" ;;
                                    "$_want")
                                        say_ok "版: 電話 ${_ver} = この木 ${_want}(ios/ を触った commit の通算数)"
                                        say_note "同じ番号でも汚れた木で焼いた物は見分けられない —— そこは画面の rev(DESIGN §8-8)の役" ;;
                                    *)  say_bad "版: 電話は ${_ver}、この木は ${_want} —— 古い物が載っている。\`bash ios/tools/build.sh\` で焼き直す"
                                        say_note "番号が \"1\" なら build.sh を通さずに焼いた物(project.yml の直値のまま)" ;;
                                esac ;;
                        esac
                    fi ;;
            esac

            # ★電話の在庫の照合(2026-08-10 に足した)。
            # 足した理由: 此処までは RemoteMini **1本だけ**を見ていた。1本を厳しく測る
            #   検査は、**載っている物の総数を一度も数えない**。実際、Tom 本人が何のアプリか
            #   判らない物(com.tomiees.utsurundesu / TestFlight 経由 / 持ち主不明)が
            #   2ヶ月以上電話に載っていて、其の間ずっと机の上の検査は全部緑だった。
            #   #56 と同じ型の3つ目 —— 見ている1点は正しく、**見ていない面**が在る。
            # 出さない物: 機器名・識別子(此処も同じ規律)。出すのは bundle id だけ。
            # 三色: 想定表の req が無い = 赤 / opt が無い = 注記 / 表に無い物が載って
            #   いる = **注記**(増えた事は旅程を壊さない。此処を赤にすると嘘の赤が出て、
            #   検査ごと信用されなくなる)/ 表か一覧が読めない = 未測定。
            # **消しはしない。此処は報告だけ**(Tom 2026-08-10「別の AI が作った作成物
            #   までは消さないでね」= 検査が電話から物を消す造りは作らない)。
            _exp="${RC_PHONE_EXPECTED:-$HERE/phone-expected-apps.txt}"
            _ij=$(mktemp)
            if [ ! -f "$_exp" ]; then
                say_unm "在庫: 想定表が無い($_exp)—— 何が載っているべきかを誰も書いていない"
            elif ! "$PHONE_XCRUN" devicectl device info apps --device "$_dev" \
                      --timeout 60 --json-output "$_ij" >/dev/null 2>&1; then
                say_unm "在庫: 絞り無しの一覧が引けない —— 電話に何が載っているかは測れていない"
            else
                # 一覧と想定表の差だけを行で吐く。判定(色)は shell 側が持つ。
                _inv=$(/usr/bin/python3 -c '
import json, sys
try:
    apps = json.load(open(sys.argv[1]))["result"]["apps"]
except Exception:
    print("BAD 一覧が読めない"); sys.exit(0)
got = sorted({a.get("bundleIdentifier") for a in apps if a.get("bundleIdentifier")})
want = {}
for line in open(sys.argv[2], encoding="utf-8"):
    line = line.split("#", 1)[0].strip()
    if not line:
        continue
    f = line.split()
    if len(f) < 2 or f[1] not in ("req", "opt"):
        print("BAD 想定表の行が読めない: " + f[0]); sys.exit(0)
    want[f[0]] = f[1]
if not want:
    print("BAD 想定表に1行も無い"); sys.exit(0)
# 絞り有りの問いには答えた電話が、絞り無しで空を返すのは**道具の矛盾**。
# 「全部消えた」と読むと嘘の赤になるので未測定へ倒す。
if not got:
    print("BAD 一覧が空で返った(絞り有りでは答えたのに)"); sys.exit(0)
print("TOTAL %d %d" % (len(got), len(want)))
for b in sorted(want):
    if b not in got:
        print(("MISSREQ " if want[b] == "req" else "MISSOPT ") + b)
for b in got:
    if b not in want:
        print("EXTRA " + b)
' "$_ij" "$_exp")
                case "$_inv" in
                    '')    say_unm "在庫: 突き合わせが何も返さなかった —— 測れていない" ;;
                    BAD*)  say_unm "在庫: ${_inv#BAD }" ;;
                    *)
                        _tot=""; _diff=0
                        while read -r _k _v _w; do
                            case "$_k" in
                                TOTAL)   _tot="$_v" ;;
                                MISSREQ) say_bad "在庫: ${_v} が電話に無い(想定表で req)—— 旅程で使う物が消えている"
                                         _diff=$((_diff+1)) ;;
                                MISSOPT) say_note "在庫: ${_v} が電話に無い(想定表で opt = 消えていて構わない)"
                                         _diff=$((_diff+1)) ;;
                                EXTRA)   say_note "在庫: 想定表に無い物が載っている —— ${_v}(出所を説明できるなら $_exp へ1行足す)"
                                         _diff=$((_diff+1)) ;;
                            esac
                        done <<EOF_INV
$_inv
EOF_INV
                        # 差が1つも無い時だけ緑。**両方の本数を名乗る** ——
                        # 片方だけ出す緑は、突き合わせる相手を間違えていても同じ顔をする。
                        if [ "$_diff" -eq 0 ]; then
                            say_ok "在庫: 電話の ${_tot} 本が想定表と一致"
                        fi ;;
                esac
            fi
            rm -f "$_ij"
        fi
    fi
    rm -f "$_dj" "$_aj"
fi

# --- 電話の道(tailnet)-----------------------------------------------------------
# ★2026-08-14 追加。前夜、Tom の iPhone の Tailscale が **1日落ちたまま**誰も気付かず、
#   Remote Mini も Blink も「未完成品」に見えた(Tom 逐語「何もかも全くなにもUiとかも
#   簡潔していない」)。アプリ側は全部生きていて、**道が無かった**。
#   上の在否・版・在庫は「電話に何が載っているか」で、**電話が何処かに届くか**は
#   誰も見ていなかった —— 鎖の各段は見ていたのに、鎖の**反対側の端**が抜けていた。
#   出さない物: 機器名・IP(此の file の規律)。見るのは observer 自身の tailscale status。
echo
echo "電話の道(iPhone が tailnet に居るか。切れていると全アプリが空っぽに見える)"
PHONE_TS="${RC_PHONE_TS:-/Applications/Tailscale.app/Contents/MacOS/Tailscale}"
[ -x "$PHONE_TS" ] || PHONE_TS=tailscale
if ! command -v "$PHONE_TS" >/dev/null 2>&1; then
    say_unm "tailscale が無い —— 電話の道は測れていない"
else
    _ts_line="$("$PHONE_TS" status 2>/dev/null | grep -i "iphone" | head -1)"
    if [ -z "$_ts_line" ]; then
        say_unm "tailnet の一覧に iPhone が居ない —— 道の生死は測れていない(machines 一覧を見る)"
    else
        case "$_ts_line" in
            *offline*)
                say_bad "iPhone が tailnet から落ちている —— 電話の Tailscale アプリを開いてスイッチを ON"
                say_note "この赤の間、Remote Mini も Blink も**実装と無関係に**全部死んで見える" ;;
            *)
                say_ok "iPhone が tailnet に居る" ;;
        esac
    fi
fi

# --- 見張りの側 --------------------------------------------------------------
# ★2026-08-09 追加(Codex 指摘③「載る先を全部数えたか」の残り1台)。
#   旅程中に edith が落ちた事を Tom へ知らせるのは athenas の監視だけで、
#   **その監視が死んだ時に誰も気付かない**。静かな事が健康と見分けが付かない
#   —— yoda が 46 時間気付けなかったのと同じ形。だから見張りを見張る。
#
#   測り方: ログの最新の刻みの齢。齢は **向こうの時計**で出す(此処と athenas の
#   時計がずれていても嘘にならない)。閾値は plist の StartInterval から導く ——
#   600 を此処へ書き写すと、向こうの刻みを変えた日に此処が黙って嘘になる。
#   読めなければ閾値が作れないので **未測定**(既定値へ落として緑にしない)。
echo
echo "見張りの側(edith が落ちた事を知らせる監視そのものが生きているか)"
MON_HOST="${RC_MONITOR_HOST:-athenas}"
MON_LABEL="com.fleet.rc-health-observer"
# ssh は host ごとに1本。edith の1本目と混ぜない = 向こうが落ちても此処までの判定は残る
MRAW=$(ssh -o ConnectTimeout=10 -o BatchMode=yes "$MON_HOST" '
    p() { printf "%s=%s\n" "$1" "$2"; }
    L="$HOME/.rc-backend/health-observer.log"
    PL="$HOME/Library/LaunchAgents/com.fleet.rc-health-observer.plist"

    if launchctl list com.fleet.rc-health-observer >/dev/null 2>&1; then
        p job loaded
    else
        p job absent
    fi

    # 刻みの設定。写しを作らない為、向こうの正本から読む
    if [ -f "$PL" ]; then
        iv=$(/usr/libexec/PlistBuddy -c "Print :StartInterval" "$PL" 2>/dev/null)
        p interval "${iv:-unreadable}"
    else
        p interval noplist
    fi

    if [ ! -f "$L" ]; then
        p log missing
    else
        p log present
        # 判定行(ok / ng)だけを刻みとして数える。警報や鍵の行は刻みではない
        last=$(grep -oE "^\[[0-9-]+ [0-9:]+\] (ok|ng)" "$L" | tail -1 \
               | sed "s/^\[//; s/\].*//")
        if [ -z "$last" ]; then
            p age noticks
        else
            le=$(date -j -f "%Y-%m-%d %H:%M:%S" "$last" +%s 2>/dev/null)
            if [ -z "$le" ]; then p age unparsed
            else p age "$(( $(date +%s) - le ))"; fi
        fi
        p ticks "$(grep -cE "^\[[0-9-]+ [0-9:]+\] (ok|ng)" "$L" 2>/dev/null)"
    fi
' 2>/dev/null)

mg() { printf '%s\n' "$MRAW" | sed -n "s/^$1=//p" | head -1; }

if [ -z "$MRAW" ]; then
    say_unm "監視の居る機械に届かない(${MON_HOST})—— **赤ではない**。此処の回線かもしれず、"
    say_note "  届かない事は「監視が死んでいる」の証拠にならない。繋がる所で測り直す"
else
    case "$(mg job)" in
        absent) say_bad "${MON_LABEL} が launchctl に居ない —— 旅程中ずっと黙る。据え直す" ;;
        loaded) say_note "${MON_LABEL} は launchctl に居る(居る事と回っている事は別。下で測る)" ;;
        *)      say_unm "監視の登録状態が読めない" ;;
    esac

    iv=$(mg interval); age=$(mg age)
    case "$(mg log)" in
        missing)
            say_bad "監視のログが1本も無い —— 据えたが一度も書いていない疑い。手で1回撃って見る" ;;
        present)
            case "$iv" in
                ''|*[!0-9]*)
                    say_unm "刻みの設定(StartInterval)が読めない(${iv:-空})—— 何秒で古いと言えるのか決まらない" ;;
                *)
                    # 2刻み落とすまでは待つ。実測の最大ずれは 602 秒(2026-08-09、195 刻み)
                    # なので、この余裕は観測されたぶれの倍以上ある
                    lim=$(( iv * 2 + 300 ))
                    case "$age" in
                        noticks)  say_bad "ログに判定の行が1本も無い —— 回っていない" ;;
                        unparsed) say_unm "最新の刻みの時刻が読めない —— 齢を出せない" ;;
                        ''|*[!0-9]*) say_unm "最新の刻みの齢が読めない(${age:-空})" ;;
                        *)
                            if [ "$age" -le "$lim" ]; then
                                say_ok "回っている(最新の刻みは ${age} 秒前 / 刻み ${iv} 秒 / 通算 $(mg ticks) 回)"
                                say_note "此処の緑が言うのは「監視が動いている」まで。**Discord まで出るか**は"
                                say_note "  此処では測れない(据付日に注入した失敗で経路は通っている、が最後)"
                            else
                                say_bad "監視が止まっている —— 最新の刻みが ${age} 秒前(上限 ${lim} 秒 = 刻み ${iv} の2回分+余裕)"
                                say_note "  此処が赤の間、旅程中の沈黙は「無事」と区別が付かない。"
                                say_note "  直す = ${MON_HOST} で launchctl kickstart -k gui/\$(id -u)/${MON_LABEL}"
                            fi ;;
                    esac ;;
            esac ;;
        *) say_unm "監視のログの在否が読めない" ;;
    esac
fi

# --- 判定 --------------------------------------------------------------------
# 順序が要点: 赤が1つでも在れば赤。無ければ未測定を緑に丸めない。
echo
if [ "$red" -gt 0 ]; then
    echo "赤 ${red} 件(未測定 ${unmeasured} 件)—— 各行に直し方が書いてある。渡米前に潰す。"
    exit 1
fi
if [ "$unmeasured" -gt 0 ]; then
    echo "未測定 ${unmeasured} 件 —— 赤は無いが、**全部通ったとは言えない**。測り直す。"
    exit 2
fi
echo "緑 —— 測れる範囲は全部通った。"
echo "     測っていないのは「更新の再起動が自動ログインを解除しない事」(実績が無い)。"
exit 0
