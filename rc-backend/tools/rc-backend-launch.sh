#!/bin/bash
# rc-backend-launch.sh — launchd が呼ぶ起動ラッパ(edith 常設)。
#
# なぜ plist から直接 node を呼ばないか:
#   1. 起動のたびに `tailscale serve` を**冪等に入れ直す**必要がある(下)
#   2. 版の食い違う tailscale が2本在るので、**絶対パス**で選ばないと警告が出る
#   3. 起動時の観測(node の版・鍵の有無)をログの先頭に残したい
#
# launchd は `~` を展開しない。全部絶対パス。

set -u

# ★既定値は edith の実物。env で差し替えられるのは**駆動できるようにする為**であって、
#   運用で変える為ではない。launchd は plist に書いた物しか渡さないので、常用経路では
#   必ず既定値が効く(= 下の 3 行を読めば本番の姿が分かる、という性質を壊していない)。
#   これが無いと、この台本は「読んで正しそう」以上の証明が一生取れない。症状が
#   「ローカルは全部緑、電話からだけ永久に到達できない」= 一番気付けない形なので、
#   駆動できない事そのものが危険側。検査は `tools/rc-backend-launch-check.sh`。
NODE="${RC_NODE_BIN:-/opt/homebrew/bin/node}"
APP="${RC_APP_DIR:-/Users/edith/rc-backend}"
TS="${RC_TAILSCALE_BIN:-/Applications/Tailscale.app/Contents/MacOS/Tailscale}"
                                                            # ★Homebrew 版(1.94.2)ではない。
                                                            #   daemon は 1.98.5。混ぜると警告が出る
PORT="${RC_PORT:-8787}"
LOG_DIR="${RC_LOG_DIR:-/Users/edith/Library/Logs/rc-backend}"
KEY_FILE="${RC_KEY_FILE:-/Users/edith/.rc-backend/api.key}"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1"; }

log "起動 — node $($NODE -v 2>&1), port ${PORT}"

# --- 鍵 ---------------------------------------------------------------------
# ★作り直さない。server.mjs が無ければ作るが、在れば読むだけ。
# ここで消したり再生成したりすると、電話に貼ってある鍵が黙って失効する。
if [ -f "$KEY_FILE" ]; then
    log "鍵: 既存を使う (${KEY_FILE})"
else
    log "鍵: 無いので server.mjs が生成する"
fi

# --- ログの上限(sudo 無しで出来る範囲) --------------------------------------
# launchd はローテーションしない。`KeepAlive` + bind 失敗が続くと 15 秒ごとに
# 起動を繰り返してログだけが伸びる。世代は1つで十分(20MB で頭打ち)。
# ★正直な注記: launchd は起動時に StandardOutPath を開いてから exec する。だから
#   ここで rename すると、**この回の出力は rename 後の file に行く**。それでも
#   disk が青天井にならないという目的は達する。閾値を大きめにしてあるのは、
#   crash loop 中に毎回 rename して直前の診断を潰さない為(実測ペースで約10日分)。
LOGF="${LOG_DIR}/rc-backend.log"
if [ -f "$LOGF" ] && [ "$(stat -f %z "$LOGF" 2>/dev/null || echo 0)" -gt 10485760 ]; then
    mv -f "$LOGF" "${LOGF}.1" 2>/dev/null && log "ログを退避した(10MB 超): ${LOGF}.1"
fi

# --- tailscale が上がるのを待つ ----------------------------------------------
# ★2026-08-02 Codex 指摘の本命。冷起動で tailscaled がまだ準備できていない瞬間に
#   ここへ来ると `serve` は失敗する。`set -e` を張っていないので node は上がり、
#   **KeepAlive が node を生かし続けるので、このラッパは二度と走らない**。
#   = tailscaled が後から復旧しても serve は入らないまま。ローカルでは全部緑、
#   電話からだけ永久に到達できない = 渡米中に一番起きてほしくない形。
#   → 待つ。待っても駄目なら**そう言って**、node は上げる(ssh で診断できる方が良い)。
TS_READY=no
if [ -x "$TS" ]; then
    for i in $(seq 1 30); do   # 2 秒 x 30 = 最大 60 秒
        state=$("$TS" status --json 2>/dev/null | /usr/bin/python3 -c \
            'import sys,json
try: print(json.load(sys.stdin).get("BackendState",""))
except Exception: print("")' 2>/dev/null)
        if [ "$state" = "Running" ]; then TS_READY=yes; log "tailscale: Running(${i} 回目で確認)"; break; fi
        sleep 2
    done
    [ "$TS_READY" = yes ] || log "★tailscale: 60 秒待っても BackendState=Running にならない(直前の値: ${state:-取得不可})"
else
    log "★serve: ${TS} が無い。電話からは到達できない状態で起動する"
fi

# --- 鍵の有効期限を起動ログに残す --------------------------------------------
# ★この行が守る物と守らない物を先に書く。
#   守る: 「今この機械の tailnet 鍵はいつ切れるのか」を、再起動のたびに観測値で残す。
#         期限を無効化した後は `期限なし` に変わるので、**Tom の操作が効いた事の確認**にもなる。
#   守らない: **期限が近づいた時に自分から知らせる事**。これは起動時にしか出ない。
#         4ヶ月先に切れる鍵に対して、起動時の1行は警報ではない。恒久的な見張りは
#         外部への生存通知(HANDOFF §3-P の候補)側の仕事。ここで代用したと読まない事。
#   計算の本体は `tools/tailnet-key-expiry.sh` に置いてある(deploy 台本からも同じ物を呼ぶ。
#   同じ計算を2箇所に書くと片方だけ古くなる)。ここでは呼んで log に流すだけ。
#   `$TS` を渡すのは、この機械に tailscale が2本在って**版が違う**から(冒頭の注記)。
if [ "$TS_READY" = yes ]; then
    RC_TAILSCALE_BIN="$TS" /bin/bash "${APP}/tools/tailnet-key-expiry.sh" 2>&1 \
        | while IFS= read -r l; do log "$l"; done
fi

# --- tailscale serve ---------------------------------------------------------
# ★冪等性の取り方を変えた(Codex 指摘)。旧版は `serve status` の**散文**を
#   `grep "127.0.0.1:8787"` していたが、これは (a) 別の経路に同じ文字列が載っても
#   一致し (b) CLI の出力形式が変わると黙って外れる。
#   `serve` は宣言的なので、**同じ設定を二度入れても no-op**。判定を捨てて毎回入れる。
#   唯一守るのは「他人の 443 設定を黙って上書きしない」事 = 設定が在って、かつ
#   自分の宛先を含まないなら**触らずに大声で言う**(fail-closed)。
# ★宿題を済ませた(2026-08-02 05:xx)。設定を入れた後の実物を edith で見た:
#     {"TCP":{"443":{"HTTPS":true}},"Web":{"desk.tailnet.example:443":
#      {"Handlers":{"/":{"Proxy":"http://127.0.0.1:8787"}}}}}
#   旧判定 `grep "127.0.0.1:${PORT}"` には**実害のある穴**が在った: `/` が他人の宛先で
#   `/x` だけが自分に向いている設定でも「自分の物」と言う → ここが「もう入っている」と
#   判断して触らず、**電話は他人の宛先に着く**。新判定は経路ごと見る。
# ★判定を `tools/serve-decision.sh` に**切り出した**。ラッパに埋めると駆動できず、
#   間違えた時の症状が「ローカルは全部緑、電話からだけ永久に到達できない」= 一番
#   気付けない形になる。19ケース(うち負の対照・使い方エラー含む)+ 旧判定との対比を
#   `tools/serve-decision-check.sh` が回す。
# ★判定は 4 語になった(v2): apply / ok / foreign / unknown。
#   **`foreign` と `unknown` を分けたのは、人が取る次の手が違うから**。
#   他人が 443 を持っている = 見て退ける。状態が読めない = 待つ / tailscaled を見る。
#   旧版はこの2つを1つの `*` に畳んでいたので、ログは常に「他人の設定が在る」と言った。
#   状態が読めなかっただけの時に**居もしない他人を探させる**メッセージ = 誤診の誘導。
if [ "$TS_READY" = yes ]; then
    # ★スナップショットは**1回だけ**取って使い回す。旧版は判定用に1回、失敗ログ用に
    #   もう1回 `serve status` を撃っていた。両者は別の瞬間の状態なので、「判定は
    #   foreign と言ったのに、ログに載っている現状は空」という**説明のつかない証拠**が
    #   残りうる。事故の後で読むのはこのログなので、判定した現物そのものを載せる。
    # ★`serve status` をパイプへ直結しない。パイプの終了状態は右端の物なので、
    #   status が落ちた事(rc≠0)が黙って消える。stderr も捨てない — 捨てると
    #   「読めなかった」までは分かって「なぜ読めなかったか」が永久に残らない。
    serr=$(/usr/bin/mktemp /tmp/rc-serve-err.XXXXXX)
    snap=$("$TS" serve status --json 2>"$serr"); srrc=$?
    serrtxt=$(tr -d '\r' < "$serr" | tr '\n' ' '); rm -f "$serr"
    [ "$srrc" = 0 ] || log "★serve status が rc=${srrc} で終わった: ${serrtxt:-(stderr なし)}"

    dec=$(printf '%s' "$snap" | /bin/bash "${APP}/tools/serve-decision.sh" "${PORT}" 2>/dev/null); decrc=$?
    snap1=$(printf '%s' "$snap" | tr -d ' \n')
    case "$dec" in
        apply)
            log "serve: 443 は未使用なので入れる --https=443 -> http://127.0.0.1:${PORT}"
            "$TS" serve --bg --https=443 "http://127.0.0.1:${PORT}" 2>&1 | sed 's/^/  serve: /'
            ;;
        ok)
            log "serve: 443 の / が既に自分に向いている(入れ直しても no-op なので触らない)"
            ;;
        foreign)
            log "★serve: 443 に**自分以外の設定**が在る。上書きしない = 電話からは到達できない"
            log "  判定した現物: ${snap1:-(空)}"
            log "  次の手: ${TS} serve status で誰が 443 を持っているか見て、手で退けてから再起動"
            ;;
        unknown)
            log "★serve: 443 の状態が**読めない**(status rc=${srrc})。読めない物には書かない"
            log "  判定した現物: ${snap1:-(空)}"
            log "  次の手: ${TS} serve status --json が JSON を返すか / /usr/bin/jq が在るかを見る"
            ;;
        *)
            # 4 語のどれでもない = 設定の話ではなく**判定台本側の不具合**。
            # ここを `foreign` と同じ枝に落とすと、自分の bug を他人のせいにしたログが残る。
            log "★serve: 判定台本が 1 語を返さなかった(rc=${decrc} 出力=${dec:-(空)})。触らない"
            log "  次の手: printf '%s' '<status の JSON>' | ${APP}/tools/serve-decision.sh ${PORT}"
            ;;
    esac
fi

# --- 本体 -------------------------------------------------------------------
# exec = launchd の KeepAlive が本物の node プロセスを見張る(ラッパを見張らない)。
cd "$APP" || { log "★${APP} が無い"; exit 1; }
log "exec node src/server.mjs"
exec "$NODE" src/server.mjs
