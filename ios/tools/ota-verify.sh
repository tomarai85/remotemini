#!/usr/bin/env bash
# ★`controls-for:` を**意図的に持たない**。此の台本は生きた机と tailnet が要るので、
#   commit の門に入れると線が瞬いた commit が赤くなる —— 2026-08-28 に其の偽の赤を
#   実際に見た(1.8MB を置いた直後に `000`)。門で回す物は網に依存しない物だけにする。
#   此の台本自身の判定の検査は `ota-server-controls.sh` が持つ(あちらは 127.0.0.1 だけで完結)。
# OTA の導線が**外から**成立しているかを測る(2026-08-28)。
#
# ★測る対象は「file を置いた」ではなく「電話が取りに行ける」。この二つは別物で、
#   前者だけ確かめて済ませると、tailscale の serve の handler が付いていない状態で
#   「置いた」と報告する事になる —— 実際に置き場を作った日に踏みかけた。
#
# ★否定の対照を3本持つ。置いた物が 200 で返るのは緑の必要条件でしかない:
#   N1 秘密のひとつ手前(`/ota/`)が**一覧を返さない**。返すなら秘密は秘密でない。
#   N2 出鱈目な秘密が 200 で返らない。返るなら path が効いていない。
#   N3 manifest の中の .ipa の URL が、**今測っている host** を指している。
#      指していなければ、電話は古い机へ取りに行って永久に入らない(移設で必ず腐る所)。
#
# 終了コード: 0=全部緑 / 1=赤 / 2=測れなかった(網が届かない等)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # = ios/
STAGE="$HERE/build/adhoc"
SECRET_FILE="$STAGE/.ota-path-secret"

DESK_HOST="${RC_DESK_HOST:desk.tailnet.example}"
DESK_PORT="${RC_DESK_PORT:-9443}"
SERVE_PATH="${RC_OTA_SERVE_PATH:-/ota}"
ROOT="https://$DESK_HOST:$DESK_PORT$SERVE_PATH"

PASS=0; FAIL=0; UNMEASURED=0
ok() { printf '  緑    %s\n' "$1"; PASS=$((PASS+1)); }
ng() { printf '  赤    %s\n' "$1"; FAIL=$((FAIL+1)); }
un() { printf '  未測定 %s\n' "$1"; UNMEASURED=$((UNMEASURED+1)); }

[ -f "$SECRET_FILE" ] || { echo "秘密の一段が無い($SECRET_FILE)= まだ一度も配っていない" >&2; exit 2; }
SECRET="$(cat "$SECRET_FILE")"
BASE="$ROOT/$SECRET"

# ★`000` は**応答ではない**(繋がらなかった / 途中で切れた)。2026-08-28 に此処で
#   偽の赤と偽の緑を同時に作った: 1.8MB を置いた直後の走行で線が瞬いて、
#   「導線の頁が 000」= 赤、しかも「出鱈目な秘密は通らない(000)」= **緑**になった。
#   後者が悪質 —— 繋がらなかった事を「正しく拒んだ」と読んでいる。
#   Jervis の回線は不定期が仕様なので、此れは必ず再発する。
#   一度だけ撃ち直し、それでも 000 なら **未測定**に落とす(赤にも緑にもしない)。
code() {
  local c
  c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 25 "$1" 2>/dev/null)
  if [ "$c" = "000" ]; then
    sleep 2
    c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 25 "$1" 2>/dev/null)
  fi
  printf '%s' "$c"
}

echo "配る面($DESK_HOST:${DESK_PORT}、tailnet 限定)"

# 網そのものが届かないなら、以下の赤は全部意味を持たない。先に切り分ける。
if [ "$(code "https://$DESK_HOST:$DESK_PORT/healthz")" = "000" ]; then
    un "机の $DESK_PORT に届かない = tailnet か serve が落ちている。以下は測れない"
    echo "  未測定 $UNMEASURED 件"
    exit 2
fi

# --- 本体 -------------------------------------------------------------------
want200() {  # want200 <URL> <題>
  local c; c=$(code "$1")
  case "$c" in
    200) ok "$2" ;;
    000) un "$2: 2度撃っても繋がらない = **測れていない**(線か serve。赤ではない)" ;;
    *)   ng "$2: $c(200 でない)" ;;
  esac
}
want200 "$BASE/manifest.plist" "manifest が返る"
want200 "$BASE/RemoteMini.ipa" "束(.ipa)が返る"
want200 "$BASE/" "導線の頁が返る(itms-services はリンクの tap からしか動かない)"

# --- N1 秘密のひとつ手前が一覧を返さない -------------------------------------
body=$(curl -s --max-time 25 "$ROOT/" 2>/dev/null || true)
if printf '%s' "$body" | grep -q "$SECRET"; then
    ng "N1 $ROOT/ が秘密の名前を一覧に出している = 秘密が秘密でない"
else
    ok "N1 秘密のひとつ手前が中身を一覧しない"
fi

# --- N2 出鱈目な秘密は通らない -----------------------------------------------
# ★`404` を要求する。「200 でない」で緑にすると、繋がらなかった 000 まで
#   「正しく拒んだ」に化ける —— 2026-08-28 に実際に化けた。
c=$(code "$ROOT/0000000000000000000000ff/manifest.plist")
case "$c" in
  404) ok "N2 出鱈目な秘密は 404 で拒まれる" ;;
  200) ng "N2 出鱈目な秘密でも 200 = path が効いていない" ;;
  000) un "N2 2度撃っても繋がらない = 拒めているかは**測れていない**" ;;
  *)   ng "N2 出鱈目な秘密が $c(404 でない)= 拒み方が想定と違う" ;;
esac

# --- N3 manifest の中の行き先が今測っている机を指す ---------------------------
# ★移設で必ず腐る所。file は置けているのに中身が古い host を指していれば、
#   電話は静かに古い机へ取りに行き、「入らない」だけが症状として出る。
man=$(curl -s --max-time 25 "$BASE/manifest.plist" 2>/dev/null || true)
if [ -z "$man" ]; then
    un "N3 manifest が読めない = 行き先を測れない"
elif printf '%s' "$man" | grep -q "https://$DESK_HOST:$DESK_PORT$SERVE_PATH/$SECRET/RemoteMini.ipa"; then
    ok "N3 manifest の行き先が今の机を指している"
else
    ng "N3 manifest の中の .ipa の URL が別の場所を指している(移設で腐った形)"
    printf '%s' "$man" | grep -A1 "<key>url</key>" | sed 's/^/        /'
fi

# --- 版が手元の束と一致するか -------------------------------------------------
if [ -d "$STAGE/Payload/RemoteMini.app" ]; then
    local_num=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" \
                "$STAGE/Payload/RemoteMini.app/Info.plist" 2>/dev/null || echo "?")
    served=$(printf '%s' "$man" | grep -A1 "bundle-version" | tail -1 | sed 's/.*<string>\(.*\)<\/string>.*/\1/')
    if [ "$local_num" = "$served" ]; then
        ok "配っている版 = 手元で焼いた版(build $served)"
    else
        ng "配っている版が手元と違う(机 $served / 手元 $local_num)= 置き忘れ"
    fi
else
    un "手元に束が無いので版の突合ができない"
fi

echo
echo "緑 $PASS / 赤 $FAIL / 未測定 $UNMEASURED"
[ "$FAIL" -gt 0 ] && exit 1
[ "$UNMEASURED" -gt 0 ] && exit 2
exit 0
