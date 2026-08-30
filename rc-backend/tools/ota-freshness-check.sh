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
# ★**配布してよいと決めた版**の記録(2026-08-30、Codex の指摘4)。
#   此れが無い間、検査は「配布 vs 最後に署名した物」しか見ておらず、
#   **両方が 96 で HEAD が 99 でも緑**になる —— 「古くない」と言いながら、
#   出来ている物が届いていない状態を通す。
#   記録は `ios/tools/adhoc-ota.sh` が配り終わりに書く: **配った事が、承認した事**。
#   人が別に承認の儀式をする形にすると、儀式を忘れた日から記録が嘘になる。
APPROVED_FILE="${RC_OTA_APPROVED_FILE:-$HERE/.ota-approved-build}"

num_or_empty() {  # 数字だけを通す。空や文字混じりは空にして「読めなかった」に落とす
    case "$1" in ''|*[!0-9]*) printf '' ;; *) printf '%s' "$1" ;; esac
}

# --- 配っている版 -------------------------------------------------------------
# ★**秘密の path を名指しする**(2026-08-30、Codex の指摘4)。`$HOME/ota/*` の glob は、
#   dir が2つ在る時に「どれを読んだか」が判らないまま数字を1つ返す ——
#   古い秘密の残骸が並んだ日に、**配っていない方の版**を「配布中」として読みうる。
#   秘密は `ios/build/adhoc/.ota-path-secret` が正本(`ios/tools/adhoc-ota.sh` が作って変えない)。
# ── `--local`: **配っている機体の上で**、ssh も repo も使わずに測る(2026-08-30)──
# なぜ要るか: 観測器は friday に居るが、此の検査が読む材料(署名済み plist と
#   承認の記録)は**焼いた機体(Jervis)にしか無かった**。だから CF-16 では
#   friday の枝を `RC_HEALTH_OTA_CHECK=` で切るしかなく、**配布口が7ビルド遅れたまま
#   2日誰も赤くならなかった穴(CF-11)がそのまま開いていた**。
#
# 局所で答えられる問いは1つ ——「**配っている版が、配ってよいと決めた版より古くないか**」。
#   両方 friday の disk に在る(manifest.plist と `.approved-build`)。
#   ★答えられない問い =「承認が HEAD に追いついているか」(rc=3)。木が要るので
#     Jervis の担当のまま。局所では**測らない**と言う —— 測れない物を緑にしない為に、
#     測っていない事を文面に出す。
if [ "${1:-}" = "--local" ]; then
    OTA_DIR_ROOT="${RC_OTA_DIR_ROOT:-$HOME/ota}"
    # 秘密の dir は**ちょうど1つ**の時だけ採る。2つ在る時に選ぶと、古い秘密の残骸を
    # 「配布中」として読みうる —— 下の ssh 経路が glob を避けているのと同じ理由。
    n=0; dir=""
    for cand in "$OTA_DIR_ROOT"/*/; do
        [ -d "$cand" ] || continue
        n=$((n + 1)); dir="${cand%/}"
    done
    if [ "$n" -ne 1 ]; then
        echo "ota-freshness: $OTA_DIR_ROOT の下に配布 dir が $n 個 = 測定不成立(1つの時だけ測る)" >&2
        exit 2
    fi
    pub_raw="$(/usr/libexec/PlistBuddy -c 'Print :items:0:metadata:bundle-version' "$dir/manifest.plist" 2>/dev/null | tr -d '[:space:]')"
    case "${pub_raw:-}" in ''|*[!0-9]*) pub_raw='' ;; esac
    if [ -z "$pub_raw" ]; then
        echo "ota-freshness: 配っている版を読めない($dir/manifest.plist)= 測定不成立" >&2
        exit 2
    fi
    # ★`tr ... < file` の `2>/dev/null` では**シェルが出すリダイレクト失敗**は消えない
    #   (tr が走る前に落ちる)。存在を先に見る。
    app_raw=""
    [ -f "$dir/.approved-build" ] && app_raw="$(tr -d '[:space:]' < "$dir/.approved-build" 2>/dev/null)"
    case "${app_raw:-}" in ''|*[!0-9]*) app_raw='' ;; esac
    if [ -z "$app_raw" ]; then
        # ★ssh 経路と違い、署名済みで代用**しない**。此処に署名済みの成果物は無いので、
        #   代用元が無い。無い物を 0 や緑に丸めず、測定不成立と言う。
        echo "ota-freshness: 配ってよいと決めた版の記録が無い($dir/.approved-build)= 測定不成立" >&2
        echo "  ★次に ios/tools/adhoc-ota.sh で配れば置かれる(束と同じ原子的な置き方)" >&2
        exit 2
    fi
    if [ "$pub_raw" -lt "$app_raw" ]; then
        echo "ota-freshness: ★配布 $pub_raw < 承認済み $app_raw = **栞を叩くと $((app_raw - pub_raw)) ビルド巻き戻る**" >&2
        exit 1
    fi
    echo "ota-freshness: 配布 $pub_raw >= 承認済み $app_raw(栞は巻き戻さない)"
    echo "  ★局所では**承認が HEAD に追いついているか**は測っていない(木が要る = Jervis の担当)"
    exit 0
fi

SECRET_FILE="${RC_OTA_SECRET_FILE:-$HERE/ios/build/adhoc/.ota-path-secret}"
OTA_SECRET="${RC_OTA_SECRET:-}"
if [ -z "$OTA_SECRET" ] && [ -f "$SECRET_FILE" ]; then
    OTA_SECRET="$(tr -d '[:space:]' < "$SECRET_FILE")"
fi
case "$OTA_SECRET" in
    [0-9a-f][0-9a-f]*) ;;
    *) echo "ota-freshness: 秘密の path を特定できない($SECRET_FILE)= 測定不成立" >&2; exit 2 ;;
esac
pub_raw="$("$SSH_BIN" -o ConnectTimeout=15 -o BatchMode=yes "$HOST" \
    "/usr/libexec/PlistBuddy -c 'Print :items:0:metadata:bundle-version' \"\$HOME/ota/$OTA_SECRET/manifest.plist\" 2>/dev/null" \
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

# --- 配布してよいと決めた版 ---------------------------------------------------
approved=""
if [ -f "$APPROVED_FILE" ]; then
    approved="$(num_or_empty "$(tr -d '[:space:]' < "$APPROVED_FILE")")"
fi

# 比べる相手は**承認済みの版**。記録がまだ無い時だけ、署名済みで代用する
# (初回の配布より前 = 承認という出来事がまだ起きていない)。
target="${approved:-$loc}"
src="$([ -n "$approved" ] && echo "承認済み" || echo "署名済み(承認の記録がまだ無い)")"

if [ "$pub" -lt "$target" ]; then
    echo "ota-freshness: ★配布 $pub < $src $target = **栞を叩くと $((target - pub)) ビルド巻き戻る**" >&2
    echo "  直す手: cd ios && ./tools/adhoc-ota.sh(秘密の path は変えない = 栞が生き続ける)" >&2
    exit 1
fi

# --- 承認済みの版が HEAD に追いついているか -----------------------------------
# ★配布が承認に追いついていても、**承認そのものが古い**事が在る ——
#   「配った物は最新の承認と一致している。ただし其の承認は3日前の木の話」。
#   緑でも赤でもない第三の状態なので、**別の番号(3)**で出す。
#   0 に混ぜると「届いている」と読まれ、1 に混ぜると巻き戻りと区別が付かない。
head_num=""
if [ -x "$HERE/ios/tools/build.sh" ]; then
    head_num="$(num_or_empty "$(bash "$HERE/ios/tools/build.sh" --print-build-num 2>/dev/null | tr -d '[:space:]')")"
fi
if [ -n "$approved" ] && [ -n "$head_num" ] && [ "$approved" -lt "$head_num" ]; then
    echo "ota-freshness: 配布 $pub は承認済み $approved に追いついている" 
    echo "★ただし承認 $approved が HEAD $head_num より $((head_num - approved)) ビルド古い" >&2
    echo "  = 出来ている物が、まだ配る対象になっていない。焼き直すなら: cd ios && ./tools/adhoc-ota.sh" >&2
    exit 3
fi

echo "ota-freshness: 配布 $pub >= $src $target(栞は巻き戻さない)"
exit 0
