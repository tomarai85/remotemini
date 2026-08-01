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

NODE="/opt/homebrew/bin/node"
APP="/Users/edith/rc-backend"
TS="/Applications/Tailscale.app/Contents/MacOS/Tailscale"   # ★Homebrew 版(1.94.2)ではない。
                                                            #   daemon は 1.98.5。混ぜると警告が出る
PORT="${RC_PORT:-8787}"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1"; }

log "起動 — node $($NODE -v 2>&1), port ${PORT}"

# --- 鍵 ---------------------------------------------------------------------
# ★作り直さない。server.mjs が無ければ作るが、在れば読むだけ。
# ここで消したり再生成したりすると、電話に貼ってある鍵が黙って失効する。
if [ -f /Users/edith/.rc-backend/api.key ]; then
    log "鍵: 既存を使う (/Users/edith/.rc-backend/api.key)"
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
LOGF="/Users/edith/Library/Logs/rc-backend/rc-backend.log"
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
# ★測った事(2026-08-02 edith): 今は `serve status --json` が `{}` = 設定ゼロ。
#   設定が入った後の JSON の形は**まだ見ていない**ので、下の判定は compact JSON への
#   部分一致に留めてある。初回適用後に実物の形を見て締め直す事(次セッションの宿題)。
if [ "$TS_READY" = yes ]; then
    cur=$("$TS" serve status --json 2>/dev/null | tr -d ' \n')
    if [ -z "$cur" ] || [ "$cur" = "{}" ]; then
        log "serve: 設定が無いので入れる --https=443 -> http://127.0.0.1:${PORT}"
        "$TS" serve --bg --https=443 "http://127.0.0.1:${PORT}" 2>&1 | sed 's/^/  serve: /'
    elif printf '%s' "$cur" | grep -q "127.0.0.1:${PORT}"; then
        log "serve: 既に自分の宛先が入っている(入れ直しても no-op なので触らない)"
    else
        log "★serve: 443 に**自分以外の設定**が在る。上書きしない。電話からは到達できない"
        log "  現状: ${cur}"
        log "  直すなら: ${TS} serve status を見てから手で決める"
    fi
fi

# --- 本体 -------------------------------------------------------------------
# exec = launchd の KeepAlive が本物の node プロセスを見張る(ラッパを見張らない)。
cd "$APP" || { log "★${APP} が無い"; exit 1; }
log "exec node src/server.mjs"
exec "$NODE" src/server.mjs
