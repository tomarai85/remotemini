#!/bin/bash
# 停電 / 強制再起動の後、この機械が**誰も触らずに** rc-backend を上げ直せるか。
# 走らせる場所 = 見たい機械そのもの(edith なら edith の上)。ssh 越しの遠隔測定はしない
# —— `defaults` も `pmset` も `$HOME` も、走った場所の物しか答えないので。
#
# なぜ切り出したか(2026-08-03):
#   元は `tools/deploy-to-edith.sh` の 9b に heredoc で直に書いてあった。そこには
#   **注釈が 7 つの性質を名指ししているのに、コードは 4 つしか測っていない**という
#   ずれが在った(KeepAlive と `sleep 0` が文章にだけ在る)。
#   heredoc は対照を書けないので、ずれが在っても誰も気付けない。
#   これは DESIGN (19)「規則は、それを回す物が無いと効かない」の測定版 ——
#   「見張っている」と書いた物が本当に見張っているかを、見張る物が要る。
#
# 測る 7 つ。どれか 1 つ落ちるだけで「停電 = 二度と戻らない」に変わる:
#   (1) FileVault が Off      … On だと起動時に解錠する人を待つ。渡米後は誰も居ない
#   (2) 自動ログインが $CB_USER … GUI session が立たないと gui/501 の job が load されない
#   (3) plist が $CB_PLIST に在る … login 時に load される物が無ければ何も起きない
#   (4) RunAtLoad = true      … load されても起動しない
#   (5) KeepAlive = true      … 落ちた時に戻らない(冷起動で tailscaled が後から来る形に効く)
#   (6) pmset autorestart = 1 … 通電しても電源が入らない
#   (7) pmset sleep = 0       … 眠ると tailnet から消える(= 電話から届かない)
#
# 終了コード: 0=鎖が繋がっている / 1=切れている / **2=測れなかった**。
#   2 を 0 に丸めない。「測れなかった」を「異常なし」と読み替えるのが一番危ない ——
#   この道具は渡米後に**物理で直せない**物を見張るので、沈黙は最悪の答え。
#   ★呼び側(deploy 9b)は `|| true` で受ける。**門ではなく警告**である事は変えない:
#     自動ログインが切れている事は、コードを配る妨げにならない。
#
# 継ぎ目(対照が偽物を差し込む口。既定は本物):
#   CB_FDESETUP CB_DEFAULTS CB_PMSET CB_PLISTBUDDY CB_PLIST CB_USER
#   → 手元(Jervis)で全部偽物にして測れるので、対照は edith に一切触らない。
set -uo pipefail

FDESETUP="${CB_FDESETUP:-/usr/bin/fdesetup}"
DEFAULTS="${CB_DEFAULTS:-/usr/bin/defaults}"
PMSET="${CB_PMSET:-/usr/bin/pmset}"
PLISTBUDDY="${CB_PLISTBUDDY:-/usr/libexec/PlistBuddy}"
PLIST="${CB_PLIST:-$HOME/Library/LaunchAgents/com.edith.rc-backend.plist}"
WANT_USER="${CB_USER:-edith}"

broken=0; unmeasured=0; ok=0
ng()  { echo "★NG   $*" >&2; broken=$((broken+1)); }
unm() { echo "?     $*" >&2; unmeasured=$((unmeasured+1)); }
good(){ echo "OK    $*";     ok=$((ok+1)); }

# ── (1) FileVault ─────────────────────────────────────────────────────────
# 取れない事と Off である事は違う。取れない = 未測定(前の版は「不明」を壊れ扱いにしていた)
if fv="$("$FDESETUP" status 2>/dev/null)" && [ -n "$fv" ]; then
    case "$fv" in
        *"is Off"*) good "FileVault: Off(起動時に解錠を人に求めない)" ;;
        *"is On"*)  ng   "FileVault: On = 停電の後、解錠する人が居ないと戻らない" ;;
        *)          unm  "FileVault: 判らない形の返事 [${fv}]" ;;
    esac
else
    unm "FileVault: ${FDESETUP} が答えない = 測れていない(Off だとは言えない)"
fi

# ── (2) 自動ログイン ──────────────────────────────────────────────────────
# `defaults read` は鍵が無い時に空 + 非ゼロ。空 = 無効 = **壊れている**(未測定ではない):
# 「自動ログインが設定されていない」は、測れなかったのではなく、はっきり切れている。
al="$("$DEFAULTS" read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null)"
if [ "$al" = "$WANT_USER" ]; then
    good "自動ログイン: $al"
elif [ -z "$al" ]; then
    ng "自動ログイン: 無効 = GUI の session が立たない → gui/501 の job も load されない"
else
    ng "自動ログイン: ${al}(欲しいのは ${WANT_USER})= 別の人の session が立つ"
fi

# ── (3)(4)(5) plist と、その中の 2 つ ─────────────────────────────────────
if [ -f "$PLIST" ]; then
    good "plist: $PLIST"

    ral="$("$PLISTBUDDY" -c 'Print :RunAtLoad' "$PLIST" 2>/dev/null)"
    case "$ral" in
        true)  good "RunAtLoad: true" ;;
        "")    ng   "RunAtLoad: 鍵が無い = login しても起きない" ;;
        *)     ng   "RunAtLoad: ${ral} = login しても起きない" ;;
    esac

    # KeepAlive は真偽値の他に辞書(SuccessfulExit 等)も取り得る。辞書は条件次第で
    # 正しくも誤りにもなるので、**自動では裁かない**(未測定にして人に出す)。
    # ここを「true でないなら壊れている」と書くと、正しい辞書の設定を毎回赤にする。
    ka="$("$PLISTBUDDY" -c 'Print :KeepAlive' "$PLIST" 2>/dev/null)"
    case "$ka" in
        true)    good "KeepAlive: true(落ちても戻る)" ;;
        Dict*)   unm  "KeepAlive: 辞書の形 = 条件付き。自動では裁かないので中身を人が見る事" ;;
        "")      ng   "KeepAlive: 鍵が無い = 一度落ちたら戻らない" ;;
        *)       ng   "KeepAlive: ${ka} = 一度落ちたら戻らない" ;;
    esac
else
    ng  "plist が $PLIST に無い = login 時に load される物が無い"
    unm "RunAtLoad: plist が無いので測れない"
    unm "KeepAlive: plist が無いので測れない"
fi

# ── (6)(7) pmset ──────────────────────────────────────────────────────────
# ★`awk '/autorestart/'` の様な部分一致で書かない。実物の `pmset -g` には
#   `disksleep` `displaysleep` `SleepDisabled` `Sleep On Power Button` が並ぶので、
#   `/sleep/` は 3 行以上に当たって値が複数出る(= 比較が壊れる)。第1欄の完全一致で取る。
#   値の後ろに註が付く事も在る —— 実測: ` sleep  1 (sleep prevented by powerd, ...)`。
#   だから「第2欄だけ」を取る($2)。行ごと取ると註まで比較してしまう。
pmout="$("$PMSET" -g 2>/dev/null)"
if [ -z "$pmout" ]; then
    unm "autorestart: ${PMSET} が答えない = 測れていない"
    unm "sleep: ${PMSET} が答えない = 測れていない"
else
    ar="$(printf '%s\n' "$pmout" | /usr/bin/awk '$1=="autorestart"{print $2; exit}')"
    case "$ar" in
        1)  good "autorestart: 1(通電で自動起動)" ;;
        "") unm  "autorestart: 一覧に無い = 測れていない(その機械が持たない設定かもしれない)" ;;
        *)  ng   "autorestart: ${ar} = 停電の後に電源が入らない" ;;
    esac

    sl="$(printf '%s\n' "$pmout" | /usr/bin/awk '$1=="sleep"{print $2; exit}')"
    case "$sl" in
        0)  good "sleep: 0(眠らない = tailnet から消えない)" ;;
        "") unm  "sleep: 一覧に無い = 測れていない" ;;
        *)  ng   "sleep: ${sl} 分で眠る = 電話から届かなくなる" ;;
    esac
fi

# ── 判定 ──────────────────────────────────────────────────────────────────
total=$((ok+broken+unmeasured))
if [ "$broken" -gt 0 ]; then
    echo "★→ 鎖が切れている(繋がり ${ok}/${total}、切れ ${broken}、測れない ${unmeasured})。渡米後は物理で直せない" >&2
    exit 1
fi
if [ "$unmeasured" -gt 0 ]; then
    echo "★→ ${unmeasured} 件を測れなかった = 「異常なし」ではない(繋がり ${ok}/${total})" >&2
    exit 2
fi
echo "→ 停電から自力で戻る鎖は繋がっている(${ok}/${total})"
exit 0
