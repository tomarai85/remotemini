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

# --- N4 机の上で秘密が他人に見えていないか -------------------------------------
# ★2026-08-28、敵対レビューが掴んだ本物の欠陥の再発検査。配る path の秘密の一段は
#   「推測できない」事が守りの全部なのに、初版の `adhoc-ota.sh` は `chmod -R a+rX` を
#   撃っていた。friday の実アカウントは athenas / tomtim / udagawa の3つで全員 staff、
#   `/Users/athenas` は drwxr-x--- なので、**秘密の hex は他の2人から一覧できた**。
#   HTTP の側だけ測っていると此処は永久に見えない —— N1〜N3 は全部 HTTP 層。
DESK_SSH="${RC_DESK_SSH:-athenas}"
DESK_DIR="${RC_OTA_DIR:-ota}"
perm=$(ssh -o ConnectTimeout=15 -o BatchMode=yes "$DESK_SSH" \
       "stat -f '%Sp' ~/$DESK_DIR 2>/dev/null; find ~/$DESK_DIR -maxdepth 2 \( -perm -g+r -o -perm -o+r \) 2>/dev/null | wc -l" 2>/dev/null)
top=$(printf '%s\n' "$perm" | sed -n 1p)
loose=$(printf '%s\n' "$perm" | sed -n 2p | tr -d '[:space:]')
if [ -z "$top" ]; then
    un "N4 机の権限を読めない = 秘密が他人に見えていないかは**測れていない**"
elif [ "$top" = "drwx------" ] && [ "${loose:-1}" = "0" ]; then
    ok "N4 配る木は所有者だけ($top / 他人が読める物 0 件)"
else
    ng "N4 配る木が他人から読める($top / 他人が読める物 ${loose:-?} 件)= 秘密の一段が無意味"
    say_fix="  直す手: ssh $DESK_SSH 'chmod 700 ~/$DESK_DIR && chmod -R go-rwx ~/$DESK_DIR'"
    printf '%s\n' "$say_fix"
fi

# --- N5 **配っているバイト**が其の電話に入る形か -------------------------------
# ★Codex 2026-08-28 の第1位の指摘。此処まで(N1〜N4 と手元の突合)が全部緑でも、
#   実際に配られている .ipa の `embedded.mobileprovision` に其の端末の UDID が
#   入っていなければ、電話は「インストールできません」としか言わない。
#   ★手元の束を見ても駄目 —— 測るべきは**机から降ってくるバイト**。
#   置き間違い・古い束の置き去り・署名し直し忘れは、全部此処にしか出ない。
tmp_ipa="$(mktemp -t rc-ota-check).ipa"
if curl -s --max-time 90 -o "$tmp_ipa" "$BASE/RemoteMini.ipa" && [ -s "$tmp_ipa" ]; then
    tmp_dir="$(mktemp -d -t rc-ota-x)"
    if /usr/bin/unzip -qq -o "$tmp_ipa" "Payload/*/embedded.mobileprovision" "Payload/*/Info.plist" -d "$tmp_dir" 2>/dev/null; then
        prov="$(find "$tmp_dir" -name embedded.mobileprovision | head -1)"
        info="$(find "$tmp_dir" -name Info.plist | head -1)"
        want_udid="${RC_PHONE_UDID:-}"
        if [ -z "$want_udid" ]; then
            # 端末の UDID は焼き込まない。**其の場で聞く**(機体が変われば当然変わる)。
            want_udid="$(xcrun devicectl list devices --json-output /dev/stdout 2>/dev/null \
                | /usr/bin/python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
for x in (d.get("result",{}).get("devices") or []):
    h=x.get("hardwareProperties",{})
    if h.get("deviceType")=="iPhone": print(h.get("udid") or ""); break' 2>/dev/null)"
        fi
        n_dev="$(security cms -D -i "$prov" 2>/dev/null | plutil -extract ProvisionedDevices xml1 -o - - 2>/dev/null | grep -c "<string>")"
        served_num="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$info" 2>/dev/null || echo "?")"
        if [ -z "$want_udid" ]; then
            un "N5 電話の UDID を今聞けない(ケーブル/tunnel)。profile に ${n_dev} 台在る事までは判る"
        elif security cms -D -i "$prov" 2>/dev/null | grep -q "$want_udid"; then
            ok "N5 配っているバイトの profile に**此の電話**が入っている(profile の端末 ${n_dev} 台 / build $served_num)"
        else
            ng "N5 配っているバイトの profile に**此の電話が入っていない**(端末 ${n_dev} 台)= 電話は「インストールできません」しか言わない"
        fi
        # 配っている物と manifest が同じ版・同じ id を名乗っているか。
        # ★**版だけ見ていた**(2026-08-28、Codex の2周目が掴んだ)。向こうの答え:
        #   「残る最有力は manifest の bundle-identifier か bundle-version が
        #    束の Info.plist と一致しない事。iOS は全部取れた上で、役に立たない
        #    文言でインストールを拒む」。id は初版が見ていなかった。
        #   古い束の置き去りも、bundle id を変えた日の刻み忘れも、此処にしか出ない。
        served_id="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$info" 2>/dev/null || echo "?")"
        if [ -n "$man" ] && [ "$served_num" != "?" ]; then
            m_num="$(printf '%s' "$man" | grep -A1 "bundle-version" | tail -1 | sed 's/.*<string>\(.*\)<\/string>.*/\1/')"
            [ "$m_num" = "$served_num" ] \
              && ok "N5b manifest と束が同じ版を名乗る(build $served_num)" \
              || ng "N5b manifest は build $m_num と言うのに束は $served_num = 置き間違い"
        fi
        if [ -n "$man" ] && [ "$served_id" != "?" ]; then
            m_id="$(printf '%s' "$man" | grep -A1 "bundle-identifier" | tail -1 | sed 's/.*<string>\(.*\)<\/string>.*/\1/')"
            [ "$m_id" = "$served_id" ] \
              && ok "N5c manifest と束が同じ bundle id を名乗る" \
              || ng "N5c manifest の bundle id が束と違う(manifest=$m_id / 束=$served_id)= iOS は役に立たない文言で拒む"
        fi
    else
        un "N5 配っている .ipa を開けない(壊れた zip か途中で切れた)"
    fi
    rm -rf "$tmp_dir"
else
    un "N5 配っている .ipa を取って来られない = バイトの中身は測れていない"
fi
rm -f "$tmp_ipa"

echo
echo "緑 $PASS / 赤 $FAIL / 未測定 $UNMEASURED"
[ "$FAIL" -gt 0 ] && exit 1
[ "$UNMEASURED" -gt 0 ] && exit 2
exit 0
