#!/bin/bash
# ota-freshness-check.sh — 配布口が配っている版が、手元の署名済みビルドより古くないかを測る。
#
# ── なぜ要るか(2026-08-30、実測で踏んだ)──────────────────────────────────
# 3つの数字が食い違っていた:
#   friday の `~/ota/*/manifest.plist`  = **89**(file は 08-28 17:05)
#   手元の `ios/build/signed/…/Info.plist` = **96**(08-29 14:01。Tom の電話が動かしている版)
#   HEAD から焼くと                      = **99**
# DESIGN §11 は `~/ota` を「机の LAN の外に居る時に Tom が**栞から自分で入れ直す**道」と
# 定めている。つまり**唯一の復旧経路が、彼の電話を 7 ビルド巻き戻す**状態だった ——
# 08-29/08-30 に出した物(4つの UI 指摘への対応・使用量の行・使用量の backoff)が
# 静かに消える形。
#
# ★もっと悪い事に、`1f5f8a9`(4つの UI 指摘に応えた commit)は **96 を焼いた 3 分後**に
#   入っている。つまり Tom の電話に載っている 96 にも其れは入っていない。
#   「配布口が古い」だけでなく「彼が待っている修正が、どの経路にも載っていない」。
#
# 誰も気付かなかったのは、**配った版と焼いた版を比べる物が木に1つも無かった**から。
# 2日間ずれたまま誰も赤くならなかった。
#
# 使い方:
#   bash rc-backend/tools/ota-freshness-check.sh
#   RC_DESK_SSH=athenas bash …          # 宛先を差す(検査の継ぎ目)
#
# 終了コード:
#   0 = 配っている版 >= 手元の署名済み版(古くない)
#   1 = **配っている方が古い**(= 栞を叩くと巻き戻る)
#   2 = 測定不成立(ssh が失敗 / どちらかの版番号を読めない)
#       ★「読めなかった」を「古くない」に丸めない。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"     # = repo 根
SSH_BIN="${RC_OTA_SSH:-ssh}"
HOST="${RC_DESK_SSH:-athenas}"
SIGNED_PLIST="${RC_SIGNED_PLIST:-$HERE/ios/build/signed/RemoteMini.app/Info.plist}"

num_or_empty() {  # 数字だけを通す。空や文字混じりは空にして「読めなかった」に落とす
    case "$1" in ''|*[!0-9]*) printf '' ;; *) printf '%s' "$1" ;; esac
}

# --- 配っている版 -------------------------------------------------------------
pub_raw="$("$SSH_BIN" -o ConnectTimeout=15 -o BatchMode=yes "$HOST" \
    '/usr/libexec/PlistBuddy -c "Print :items:0:metadata:bundle-version" $HOME/ota/*/manifest.plist 2>/dev/null' \
    2>/dev/null | tr -d '[:space:]')"
rc=$?
pub="$(num_or_empty "$pub_raw")"
if [ $rc -ne 0 ] || [ -z "$pub" ]; then
    echo "ota-freshness: 配っている版を読めない(ssh rc=$rc / 実測=[$pub_raw])= 測定不成立" >&2
    exit 2
fi

# --- 手元の署名済み版 ---------------------------------------------------------
if [ ! -f "$SIGNED_PLIST" ]; then
    echo "ota-freshness: 手元に署名済みビルドが無い($SIGNED_PLIST)= 測定不成立" >&2
    exit 2
fi
loc_raw="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$SIGNED_PLIST" 2>/dev/null | tr -d '[:space:]')"
# ★`PlistBuddy` は file が無い時に "File ... Will Create: <path>" を **stdout** へ出して
#   exit 0 する(同じ日に此の罠を1度踏んだ)。数字だけを通す事で塞がる。
loc="$(num_or_empty "$loc_raw")"
if [ -z "$loc" ]; then
    echo "ota-freshness: 手元の版番号を読めない(実測=[$loc_raw])= 測定不成立" >&2
    exit 2
fi

if [ "$pub" -ge "$loc" ]; then
    echo "ota-freshness: 配布 $pub >= 署名済み $loc(栞は巻き戻さない)"
    exit 0
fi
echo "ota-freshness: ★配布 $pub < 署名済み $loc = **栞を叩くと $((loc - pub)) ビルド巻き戻る**" >&2
echo "  直す手: cd ios && ./tools/adhoc-ota.sh(秘密の path は変えない = 栞が生き続ける)" >&2
exit 1
