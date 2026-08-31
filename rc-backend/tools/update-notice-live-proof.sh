#!/bin/bash
# no-operator: 人が撃つ。生きた机への鍵つき要求が要るので門からは回せない。
#   配った直後と、帯の経路を触った後に1発。挙動の対照は
#   `rc-backend/test/app-update-notice-controls.sh`(こちらは fixture で回る)。
#
# update-notice-live-proof.sh — 「机は新しい版を配っています」の帯が
# **本物の机に対して**出る事と、**出てはいけない時に出ない事**を、両方 実測する。
#
# ── なぜ要るか(2026-08-31)────────────────────────────────────────────────
# 帯の経路(`ota-published.mjs` → `wire.updateNotice` → `sessionsBody.display.update`)は
# 今まで **fixture に対してしか緑を取っていない**。fixture は「配っている版」も
# 「電話が名乗った版」も台本が渡すので、**本物の manifest を読めているか**も
# **本物の header を読めているか**も測っていない。
#
# 同じ日に其の穴の実物を踏んでいる: 要求ログの `build=` 欄は 2026-08-31 まで
# **UA が運ぶ売り物の版**(`CFBundleShortVersionString`)を書いており、build 番号では
# 無かった。fixture 側の検査は全部緑のままだった —— 台本が「正しい番号」を渡すから。
#
# ★測る中心は「出るか」ではなく **出す/出さないが版で切り替わるか**。
#   片方だけなら「常に出す」実装でも緑になる。
#
# 使い方:
#   bash rc-backend/tools/update-notice-live-proof.sh
#   RC_DESK_URL=https://desk.tailnet.example:9443 bash …   # 宛先を差す
# 終了コード:
#   0 = 両方 期待どおり(古い版に出る / 配布中の版に出ない)
#   1 = どちらかが期待と違う
#   2 = 測定不成立(鍵が無い / 机に届かない / 配っている版を読めない)
#       ★「測れなかった」を「出た」にも「出なかった」にも丸めない。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"     # = repo 根
URL="${RC_DESK_URL:-https://desk.tailnet.example:9443}"
HOST="${RC_DESK_SSH:-athenas}"
SSH_BIN="${RC_OTA_SSH:-ssh}"

# --- 鍵 -----------------------------------------------------------------------
# ★手元に写しを置かない。机の上の正本を其の都度読む(写すと、回した日から嘘になる)。
KEY="${RC_KEY:-}"
if [ -z "$KEY" ]; then
    KEY="$("$SSH_BIN" -o ConnectTimeout=10 -o BatchMode=yes "$HOST" \
           "cat \$HOME/.rc-backend/api.key 2>/dev/null" 2>/dev/null | tr -d '[:space:]')"
fi
if [ -z "$KEY" ]; then
    echo "update-notice-live-proof: 机の鍵を読めない(ssh か ~/.rc-backend/api.key)= 測定不成立" >&2
    exit 2
fi

# --- 配っている版(**机の manifest から**。手元の記録からではない)----------------
SECRET_FILE="${RC_OTA_SECRET_FILE:-$HERE/ios/build/adhoc/.ota-path-secret}"
OTA_SECRET="${RC_OTA_SECRET:-}"
[ -z "$OTA_SECRET" ] && [ -f "$SECRET_FILE" ] && OTA_SECRET="$(tr -d '[:space:]' < "$SECRET_FILE")"
case "$OTA_SECRET" in
    [0-9a-f][0-9a-f]*) ;;
    *) echo "update-notice-live-proof: 秘密の path を特定できない = 測定不成立" >&2; exit 2 ;;
esac
PUB="$("$SSH_BIN" -o ConnectTimeout=15 -o BatchMode=yes "$HOST" \
      "/usr/libexec/PlistBuddy -c 'Print :items:0:metadata:bundle-version' \"\$HOME/ota/$OTA_SECRET/manifest.plist\" 2>/dev/null" \
      2>/dev/null | tr -d '[:space:]')"
case "${PUB:-}" in
    ''|*[!0-9]*) echo "update-notice-live-proof: 配っている版を読めない(実測=[${PUB:-}])= 測定不成立" >&2; exit 2 ;;
esac
[ "$PUB" -gt 1 ] || { echo "update-notice-live-proof: 配布 $PUB では古い版を作れない = 測定不成立" >&2; exit 2; }
OLD=$((PUB - 1))

# --- 机へ2回 訊く -------------------------------------------------------------
# ★違うのは `X-App-Build` の1欄だけ。他を変えると、何が切り替えたのか判らなくなる。
ask() {  # ask <名乗る build> → display.update の有無を yes/no で返す(読めなければ空)
    local build="$1" body code
    # ★**状態番号も採る**(2026-08-31、陰性対照で踏んだ)。鍵が違うと机は 401 と
    #   `display` の無い本文を返す。其れを素直に読むと両方 "no" になり、
    #   道具は「古い版に帯が出ない = 更新の経路が死んでいる」と**間違った犯人**を名指す。
    #   実測: `RC_KEY=wrong-key` で rc=1(1 は「壊れている」の意)。認証の失敗は
    #   **測れなかった**であって、帯の状態ではない。
    body="$(curl -s --max-time 20 -w '\n%{http_code}' -H "Authorization: Bearer $KEY" \
            -H "X-App-Build: $build" "$URL/api/sessions" 2>/dev/null)" || return 1
    code="${body##*$'\n'}"
    body="${body%$'\n'*}"
    [ "$code" = "200" ] || return 1
    printf '%s' "$body" | /usr/bin/python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
# ★`display` が無い本文は会話一覧の封筒ではない = 測れていない。
#   欄が無い事を「帯が出ない」と読むと、形が変わった日に静かに緑/赤が反転する。
if not isinstance(d, dict) or "display" not in d:
    sys.exit(1)
disp = d.get("display") or {}
u = disp.get("update")
# ★**中身も返す**(2026-08-31、Codex の指摘3)。「帯が在るか」だけを見ると、
#   別の理由で出た帯を「更新の帯」と読む。文面が両方の番号を名乗る事と、
#   `updateBuild` が机の manifest の数と一致する事まで確かめられる様に、
#   3つを1行で返す: 有無 / 文面 / updateBuild。
print("%s\t%s\t%s" % ("yes" if u else "no", (u or "").replace("\t", " "), disp.get("updateBuild") or "-"))
' 2>/dev/null
}

OLD_ROW="$(ask "$OLD")"
CUR_ROW="$(ask "$PUB")"
# ★名乗らない client も測る(Codex の指摘2)。2026-08-31 に UA から版を採る経路を
#   消したので、`X-App-Build` を持たない古い版には**帯が出ない**のが今の仕様。
#   仕様なら検査に書く —— 書かないと、後で「出ないのは壊れているから」と読む人が出る。
NOHDR_ROW="$(ask "")"
if [ -z "$OLD_ROW" ] || [ -z "$CUR_ROW" ] || [ -z "$NOHDR_ROW" ]; then
    echo "update-notice-live-proof: 机の応答を読めない(鍵 / 届かない / 形が違う)= 測定不成立" >&2
    exit 2
fi

OLD_ANS="${OLD_ROW%%$'\t'*}"; rest="${OLD_ROW#*$'\t'}"
OLD_TEXT="${rest%%$'\t'*}"; OLD_BUILD="${rest#*$'\t'}"
CUR_ANS="${CUR_ROW%%$'\t'*}"
NOHDR_ANS="${NOHDR_ROW%%$'\t'*}"

echo "update-notice-live-proof: old-build=$OLD notice=$OLD_ANS / current-build=$PUB notice=$CUR_ANS / no-header notice=$NOHDR_ANS"

rc=0
if [ "$OLD_ANS" != "yes" ]; then
    echo "  ★古い版($OLD)を名乗ったのに帯が出ない = 更新を知らせる経路が死んでいる" >&2
    rc=1
else
    # ★**在る事**ではなく**其の帯である事**を測る(Codex の指摘3)。
    #   別の理由で出た帯を「更新の帯」と読まない為に、文面が両方の番号を名乗る事を要求する。
    case "$OLD_TEXT" in
        *"$OLD"*) : ;;
        *) echo "  ★帯は出たが文面が手元の版($OLD)を名乗っていない: [$OLD_TEXT]" >&2; rc=1 ;;
    esac
    case "$OLD_TEXT" in
        *"$PUB"*) : ;;
        *) echo "  ★帯は出たが文面が配布中の版($PUB)を名乗っていない: [$OLD_TEXT]" >&2; rc=1 ;;
    esac
    # ★机が**本当に manifest を読んだか**。`display.updateBuild` は机が自分で導いた数なので、
    #   私が ssh で読んだ manifest の数と一致すれば「同じ物を見ている」。
    #   固定値や別 channel の残骸を掴んでいれば此処でずれる。
    if [ "$OLD_BUILD" != "$PUB" ]; then
        echo "  ★机の updateBuild($OLD_BUILD)が manifest の版($PUB)と違う = 別の物を読んでいる" >&2
        rc=1
    fi
fi
if [ "$CUR_ANS" != "no" ]; then
    echo "  ★配布中の版($PUB)を名乗ったのに帯が出る = 叩いても何も変わらない帯 = 二度と読まれない" >&2
    rc=1
fi
if [ "$NOHDR_ANS" != "no" ]; then
    echo "  ★版を名乗らない client に帯が出た = 版が判らないのに新旧を断じている" >&2
    rc=1
fi

# ★之が証明する範囲を、道具自身が言う(Codex の指摘1/2)。
echo "  範囲: 之は**机側の境界の挙動**しか証明しない。電話が header を送るか / 応答を描くか /"
echo "        帯を叩いて実際に入るかは、電話が要る。P-1 は番号の境界であって実在の古い版ではない。"
exit "$rc"
