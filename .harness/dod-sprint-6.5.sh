#!/bin/bash
# no-operator: sprint 6.5 を締める時に人が撃つ。DOD_FULL=1 で実機ビルドまで回るので門には置けない
# Sprint 6.5(spec §6 Day 7)の Definition of Done を機械で照合する。
#
# spec の Day 7 の行(逐語):
#   「4機能を実回線(Wi-Fi→セルラー切替、機内モード往復、rc-backend再起動を挟む)で通し。
#     REQUIREMENTS §5 のうち v1該当分(#1-3, #5-7, #9)を証跡付きで確認」
#
# ★この道具が証明する事と、しない事
#   証明する: 「その性質を測る検査が**在る**」「同じ1本の log で**通った**」
#             「実装側の経路が**其処に在る**」「引用した行き先が**実在する**」。
#   証明しない: 「Tom の iPhone で本当にそうなる」。実回線と実機の体感は電話が要る。
#   → 電話が要る行は自動で **未測定** に落ちる。緑に見せかけない事が此処の目的。
#
# ★Sprint 3/4 から持ち越した規律を全部そのまま使う:
#   ① 引用された検査名は**実在を照合する**(綴りだけの引用は腐りの初期段階)。
#   ② UI target の検査は**名前で**照合する。件数で見ると class 単位の
#      「Executed 3 tests」に当たって偽の緑が出る。
#   ③ 未測定(2)を緑(0)にも赤(1)にも丸めない。
#
# ★もう1つ、2026-08-07 に自分で踏んだ形を検査にした:
#   「実機の数字は §4 の E に合流させた」と書いた時、§4 に E は**存在しなかった**。
#   行き先を約束する文が、どこも指していない矢印のまま残っていた。
#   だから 6-b / 9 の行は、**引用先の節が実在する事**そのものを測る。
#
# 終了コード(repo 共通): 0=緑 / 1=赤 / 2=測っていない。
set -uo pipefail

HARNESS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HARNESS/.." && pwd)"
IOS="$ROOT/ios"
TESTS="$IOS/Tests"
UITESTS="$IOS/UITests"
SRC="$IOS/Sources"
SIMLOG="$IOS/build/xcodebuild-sim.log"
GREEN=0; RED=0; UNMEASURED=0
FULL=${DOD_FULL:-0}   # DOD_FULL=1 で重い行(単体一式の再実行 / 再起動対照)も実際に回す

# ★log を信じてよいか。0 行目が**緑になった時だけ** 1 に上がる。
#   下の `check_names` は「同じ1本の log に passed が在る」で緑を出すので、
#   その log が今の原稿の話でないなら、その緑は全部**古い木の話**になる。
#   2026-08-07 まで、これは 0 行目の頭に**註として書いてあるだけ**だった ——
#   0 行目が未測定でも下は緑を出し続ける造りで、
#   「指紋が違う」という 1 行の下に 緑 10 行が並ぶ形が実際に作れた。
#   註は守りではない。守りは此処に置く。
LOG_TRUSTED=0

row() {  # row <pass|fail|skip> <行の名前> <根拠>
    case "$1" in
        pass) GREEN=$((GREEN+1));      printf '  緑    %s\n        %s\n' "$2" "$3" ;;
        fail) RED=$((RED+1));          printf '  赤    %s\n        %s\n' "$2" "$3" ;;
        *)    UNMEASURED=$((UNMEASURED+1)); printf '  未測定 %s\n        %s\n' "$2" "$3" ;;
    esac
}

# 検査名が disk(単体 + UI の両方)に実在するか。完全一致で見る。
have_test() { grep -rqE "func $1\(" "$TESTS" "$UITESTS" 2>/dev/null; }

# 同じ1本の log で passed として名前が在るか。
log_has() { grep -qE "Test Case '-\[[A-Za-z0-9_.]+ $1\]' passed" "$SIMLOG" 2>/dev/null; }

# 名前の一覧を受け、disk 実在と log での passed を順に見て row を出す。
#   赤    = 名前が disk に無い(引用が腐っている)
#   未測定 = log が無い / 古い / その名前が log に無い
#   緑    = 全部が disk に在り、同じ log に passed として在る
check_names() {  # check_names <行の名前> <補足> <検査名...>
    local label="$1" note="$2"; shift 2
    local n=$# t miss_disk="" miss_log=""
    for t in "$@"; do have_test "$t" || miss_disk="$miss_disk $t"; done
    if [ -n "$miss_disk" ]; then
        row fail "$label" "実在しない検査名:$miss_disk"
        return
    fi
    if [ ! -f "$SIMLOG" ]; then
        row skip "$label" "$n 本とも disk に在るが、走った log が無い(DOD_FULL=1 で作られる)"
        return
    fi
    # ★0 行目が緑でないなら、此処の「同じ log に passed」は今の木の話だと言えない。
    #   名前が disk に在る事までは測れているので、そこまでを根拠に残して未測定にする。
    if [ "$LOG_TRUSTED" -ne 1 ]; then
        row skip "$label" "$n 本とも disk に在るが、log が今の木の話だと言えない(0 行目を見よ)"
        return
    fi
    for t in "$@"; do log_has "$t" || miss_log="$miss_log $t"; done
    if [ -n "$miss_log" ]; then
        row fail "$label" "同じ log で通ったと言えない検査:$miss_log"
    else
        row pass "$label" "$n 本、全部が disk に在り同じ log に passed。$note"
    fi
}

echo "=== Sprint 6.5(spec §6 Day 7)DoD 照合 ($(date '+%Y-%m-%d %H:%M:%S')) ==="
echo "  REQUIREMENTS §5 の v1 該当分 = #1-3 / #5-7 / #9"
echo "  (#4 = 通知は wildcard profile が entitlement を運べない、#8 = アカウント切替は v1 対象外。"
echo "   どちらも Tom 逐語の v1 4項目の外。spec §7 に v2 候補として在る)"
echo

# --- 0. 照合の土台: log が今の木を説明しているか ------------------------------
# ★此処が未測定なら、下の「同じ log に passed」は全部**古い木の話**になる。
#   1行目でそれを言わずに下だけ緑にすると、この道具自体が空振りの緑を出す。
if [ "$FULL" = 1 ]; then
    out=$(bash "$IOS/tools/build.sh" --sim 2>&1); simrc=$?
    case "$simrc" in
        0) : ;;
        2) row skip "0. 土台(単体一式)" "build.sh --sim が 2 = 測っていない。末尾: $(printf '%s' "$out" | tail -3 | tr '\n' ' ')" ;;
        *) row fail "0. 土台(単体一式)" "build.sh --sim 非ゼロ($simrc)。末尾: $(printf '%s' "$out" | tail -3 | tr '\n' ' ')" ;;
    esac
fi
if [ ! -f "$SIMLOG" ]; then
    row skip "0. 土台(単体一式)" "$SIMLOG が無い(DOD_FULL=1 で作られる)"
else
    logfail="$(grep -oE 'Executed [0-9]+ tests?, with [0-9]+ failures?' "$SIMLOG" \
              | awk '$(NF-1)+0 > 0' | grep -c . || true)"
    logmax="$(grep -oE 'Executed [0-9]+ tests?, with [0-9]+ failures?' "$SIMLOG" \
              | awk '{print $2}' | sort -n | tail -1)"
    logmax=${logmax:-0}
    # ★log が「今の原稿」の話かを、中身の指紋で見る。
    #   mtime も commit 時刻も中身の代理にならない事は測って確かめた(build.sh の註を参照)。
    #   指紋が無い log = 古い build.sh が作った物 = 対応を語れない = 未測定。
    SHAFILE="$IOS/build/xcodebuild-sim.sources.sha"
    now_sha="$( ( cd "$IOS" && find Sources Tests UITests -type f -name '*.swift' -print0 \
                  | sort -z | xargs -0 shasum -a 256 ) | shasum -a 256 | awk '{print $1}' )"
    log_sha="$(cat "$SHAFILE" 2>/dev/null || true)"
    if [ "${logfail:-0}" -ne 0 ]; then
        row fail "0. 土台(単体一式)" "log に失敗を含む Executed 行が $logfail 本"
    elif [ "$logmax" -eq 0 ]; then
        row skip "0. 土台(単体一式)" "log に Executed 行が1本も無い = 測れていない"
    elif [ -z "$log_sha" ]; then
        row skip "0. 土台(単体一式)" "log に原稿の指紋が無い = どの中身を測った log か言えない(DOD_FULL=1 で回すと付く)"
    elif [ "$log_sha" != "$now_sha" ]; then
        row skip "0. 土台(単体一式)" "log の指紋 ${log_sha:0:12} と今の原稿 ${now_sha:0:12} が違う = この log は今の木を説明していない"
    else
        LOG_TRUSTED=1   # ★此処だけが 1 に上げる口。下の log 頼りの行は全部これに従う。
        row pass "0. 土台(単体一式)" "log 最大 $logmax 件 / 失敗 0 / 原稿の指紋 ${now_sha:0:12} が一致"
    fi
fi

# --- 1. §5-1 開くとセッション一覧が出る(固定1部屋に直行しない) ---------------
# 実装側: 資格情報が在る通常経路が ListView を出し、ConversationView を**出さない**。
#         会話へは ListView の NavigationLink からしか行けない。
RV="$SRC/RootView.swift"
LV="$SRC/Screens/List/ListView.swift"
nf="$(awk '/private var normalFlow/{f=1} f{print} f && /^    \}$/{exit}' "$RV" 2>/dev/null || true)"
if [ ! -f "$RV" ] || [ ! -f "$LV" ]; then
    row skip "1-a. §5-1 一覧が先(実装経路)" "RootView.swift か ListView.swift が無い"
elif [ -z "$nf" ]; then
    # ★空振り防止。抜き出しに失敗した時に「含まない」を緑と読むと、この行は永久に緑になる。
    row skip "1-a. §5-1 一覧が先(実装経路)" "normalFlow の抜き出しが空 = 測れていない(RootView.swift の形が変わった)"
elif ! printf '%s' "$nf" | grep -q 'ListView('; then
    row fail "1-a. §5-1 一覧が先(実装経路)" "normalFlow が ListView を出していない"
elif printf '%s' "$nf" | grep -q 'ConversationView('; then
    row fail "1-a. §5-1 一覧が先(実装経路)" "normalFlow が ConversationView を直に出している = 固定1部屋への直行"
elif ! grep -q 'ConversationView(' "$LV"; then
    row fail "1-a. §5-1 一覧が先(実装経路)" "ListView から ConversationView への経路が無い = 一覧から会話へ行けない"
elif ! grep -q 'NavigationLink' "$LV"; then
    row fail "1-a. §5-1 一覧が先(実装経路)" "ListView に NavigationLink が無い = 一覧から選ぶ形になっていない"
else
    row pass "1-a. §5-1 一覧が先(実装経路)" "normalFlow は ListView のみ、会話は ListView の NavigationLink 経由だけ"
fi
check_names "1-b. §5-1 一覧が先(画面の検査)" "一覧の3状態(通常・障害・空)を画面ごと見ている" \
    testListNormalShowsTheListNotTheEmptyOrFaultBanner \
    testListPaneFaultShowsTheFaultBannerText \
    testListEmptyShowsTheNoConversationsMessage

# --- 2. §5-2 一覧から選ぶとその会話の続きが読める・打てる ---------------------
miss=""
for f in Core/HistoryClient.swift Core/MergeHistory.swift Core/SendClient.swift; do
    [ -f "$SRC/$f" ] || miss="$miss $f"
done
# ★錨は**具体型の綴りでなく性質**で置く(2026-08-09 に踏んだ)。元は
#   `grep -q 'SendClient(' ConversationViewModel.swift` だった。その後 client は
#   `Core/ConversationClients.swift` の注入容器へ移り、ViewModel は protocol
#   (`MessageSending`)に依存する形になった —— 設計としては正しい改修なのに、
#   此処だけが取り残されて **「打てない」という製品の赤**を出し続けた。
#   打てる事の性質は3つ: ViewModel が送り手を保持し / 実際に呼び / 容器が本物を挿す。
VM="$SRC/Screens/Conversation/ConversationViewModel.swift"
CC="$SRC/Core/ConversationClients.swift"
if [ -n "$miss" ]; then
    row fail "2-a. §5-2 読める・打てる(実装経路)" "無い実装:$miss"
elif [ ! -f "$VM" ] || [ ! -f "$CC" ]; then
    # 空振り防止。file が無いのを「綴りが無い」と読むと、此処は永久に赤になる。
    row skip "2-a. §5-2 読める・打てる(実装経路)" "ConversationViewModel.swift か ConversationClients.swift が無い = 測れていない"
elif ! grep -q 'MessageSending' "$VM"; then
    row fail "2-a. §5-2 読める・打てる(実装経路)" "ViewModel が送り手(MessageSending)を保持していない = 打てない"
elif ! grep -qE '\.send\(' "$VM"; then
    row fail "2-a. §5-2 読める・打てる(実装経路)" "ViewModel が送り手を保持するだけで呼んでいない = 打てない"
elif ! grep -q 'send: SendClient()' "$CC"; then
    # ★`SendClient()` だけを錨にすると同じ file の 7 行目の**注釈**に当たり、47 行目の
    #   配線を潰しても緑のままだった(2026-08-09、対照が捕まえた)。錨は配線の綴りへ絞る。
    row fail "2-a. §5-2 読める・打てる(実装経路)" "注入容器が本物の SendClient を挿していない = 打てない"
else
    row pass "2-a. §5-2 読める・打てる(実装経路)" "取得・併合・送信の3つが在り、ViewModel が送り手を保持して呼び、容器が本物を挿している"
fi
check_names "2-b. §5-2 読める・打てる(検査)" "3 役の表示・以前を読む・打ち切り印の在無" \
    testThreeRolesShowsAllThreeRolesAndTheLoadEarlierButton \
    testTruncatedTrueDecodes \
    testTruncatedFalseHidesTheButtonEntirely \
    testLoadEarlierRefetchesWithNextHistoryLimitValue

# --- 3. §5-3 対話しながらその場で直す ----------------------------------------
# Tom 逐語(REQUIREMENTS §4):「返答待ちであれ作業中であれいつでも見て、干渉できればいい」
# = BUSY で**打ち込む欄も割り込みも死なない**。此処が死ぬと v1 の目的が消える。
check_names "3. §5-3 その場で直す(BUSY で両方生きている)" "画面1本 + 単体2本。Tom の裁定そのもの" \
    testBusyLeavesBothTheComposerAndTheInterruptButtonUsable \
    testComposerStaysEnabledOnBUSY \
    testInterruptStaysEnabledOnBUSY

# --- 5. §5-5 切断を跨いで会話が失われない ------------------------------------
check_names "5-a. §5-5 切断を跨ぐ(机の上の検査)" "欠落の理由9種・欠落通知・自動再同期の1回性・前面復帰の再取得" \
    testAllNineKnownGapWhyValuesDecode \
    testGapWithNoticeDrawsTheNoticeAndAlwaysTriggersARefetch \
    testAutoResyncFiresAtMostOnceUntilAReadableResponseEndsTheEpisodeNegativeControl \
    testARealBackgroundRoundTripResumesExactlyOnce \
    testHandleForegroundResumeRefetchesHistoryAndTheRefetchLandsInHistory \
    testAPeekThatNeverReachesTheBackgroundIsNotAResumeNegativeControl

# 5-b: Day 7 の3脚のうち、サーバ側(rc-backend 再起動を挟む)は閉じている。
REC="$ROOT/rc-backend/test/restart-epoch-controls.sh"
if [ ! -f "$REC" ]; then
    row fail "5-b. Day 7 第3脚(再起動を挟む)" "restart-epoch-controls.sh が無い"
elif [ "$FULL" = 1 ]; then
    recout=$(bash "$REC" 2>&1); recrc=$?
    if [ "$recrc" -eq 0 ]; then
        row pass "5-b. Day 7 第3脚(再起動を挟む)" "対照を実際に回して 0。末尾: $(printf '%s' "$recout" | tail -1)"
    else
        row fail "5-b. Day 7 第3脚(再起動を挟む)" "対照が $recrc。末尾: $(printf '%s' "$recout" | tail -2 | tr '\n' ' ')"
    fi
else
    row skip "5-b. Day 7 第3脚(再起動を挟む)" "対照は在るが此処では回していない(DOD_FULL=1 で回す)"
fi

# 5-c: 残る2脚は電話が要る。ここは構造的に未測定 —— 走らせ方を変えても緑にならない。
row skip "5-c. Day 7 第1・2脚(実回線)" \
    "Wi-Fi→セルラー切替 / 機内モード往復 は Tom の iPhone が要る。HANDOFF §4 の 8-b。サーバ側は 5-b で閉じているので、実機で赤が出たら原因は電話側だと先に絞れる"

# --- 6. §5-6 Loading で待たされない ------------------------------------------
# 定数そのものが実装に在るか(検査名だけでは、定数が消えた事を捕まえられない)
BS="$SRC/Core/BackendSession.swift"
const_miss=""
for c in interactiveTimeout pollTimeout writeTimeout serverPollMaxWait; do
    # ★語の境界を付ける(2026-08-07、対照が教えた)。境界無しだと
    #   `static let writeTimeoutDisabled` が `writeTimeout` の在る証拠として通る =
    #   定数を殺す改名を緑のまま素通しする。
    grep -rqE "static let $c\b" "$SRC" 2>/dev/null || const_miss="$const_miss $c"
done
if [ -n "$const_miss" ]; then
    row fail "6-a. §5-6 待たされない(定数)" "実装に無い定数:$const_miss"
else
    row pass "6-a. §5-6 待たされない(定数)" "読む 8 秒 / 待つ 30 秒 / 書く 30 秒 の3本と server 側の写しが在る"
fi
check_names "6-b. §5-6 待たされない(検査)" "定数どうしの関係 + 計器の陰性対照2本" \
    testPollTimeoutIsDerivedFromTheServerConstantNotHandWritten \
    testInteractiveTimeoutIsShorterThanThePollTimeout \
    testWriteTimeoutStaysAtThePollLength \
    testABareRequestDoesNotRecordTheInteractiveTimeout \
    testReadAndPollDifferOnTheSameSession

# 6-c: 電話の側の実測。**私が測った数字は全部 Mac から**で、電話の数字は1つも無い。
#      引用先が実在する事も同時に測る(2026-08-07 に自分で踏んだ形)。
d810=0; h8a=0
grep -q '^### 8-10\.' "$ROOT/DESIGN.md" 2>/dev/null && d810=1
grep -q '8-a(今すぐ' "$ROOT/HANDOFF-NEXT-SESSION.md" 2>/dev/null && h8a=1
if [ "$d810" -eq 1 ] && [ "$h8a" -eq 1 ]; then
    row skip "6-c. §5-6 電話の側の体感" \
        "Mac からは 同一接続 10.6ms / 新規接続 45-52ms / 冷えた1回目 870ms。電話の数字は Tom の iPhone が要る。行き先は DESIGN §8-10 と HANDOFF §4 の 8-a(両方の実在を照合済み)"
else
    row fail "6-c. §5-6 電話の側の体感" \
        "引用先が実在しない(DESIGN §8-10 = $d810 / HANDOFF 8-a = $h8a)。どこも指していない矢印になっている"
fi

# --- 7. §5-7 所有して拡張できる(vendor-closed でない) ------------------------
PY="$IOS/project.yml"
ext_pkg="$(grep -cE '^\s*packages:|^\s*-\s*package:' "$PY" 2>/dev/null || true)"
pkg_files="$(find "$IOS" -name 'Package.resolved' -o -name 'Package.swift' 2>/dev/null | grep -vc '/build/' || true)"
imports="$(grep -rhoE '^import [A-Za-z]+' "$SRC" 2>/dev/null | awk '{print $2}' | sort -u)"
foreign=""
while IFS= read -r m; do
    [ -n "$m" ] || continue
    case "$m" in
        Foundation|SwiftUI|UIKit|Combine|Security|os|OSLog|CryptoKit|Network|SwiftData) ;;
        *) foreign="$foreign $m" ;;
    esac
done <<< "$imports"
if [ ! -f "$PY" ]; then
    row skip "7. §5-7 所有して拡張できる" "project.yml が無い"
elif [ "${ext_pkg:-0}" -ne 0 ]; then
    row fail "7. §5-7 所有して拡張できる" "project.yml に外部 package の宣言が $ext_pkg 行"
elif [ "${pkg_files:-0}" -ne 0 ]; then
    row fail "7. §5-7 所有して拡張できる" "Package.resolved / Package.swift が $pkg_files 本 = 外部依存が入っている"
elif [ -n "$foreign" ]; then
    row fail "7. §5-7 所有して拡張できる" "Apple 標準でない import:$foreign"
else
    row pass "7. §5-7 所有して拡張できる" "外部 package 0 / Package.resolved 無し / import は Apple 標準のみ($(printf '%s' "$imports" | tr '\n' ' '))"
fi

# --- 9. §5-9 期限性(渡米後も作れる) ----------------------------------------
# 主張:「UI は Tailscale 越しの純ソフト = 渡米後も作れる」。
# これを崩す観測可能な条件 = **日本に残す機械**の tailnet 鍵に生きた期限が在る事。
# 切れた時の復旧はその機械の前での browser 認証なので、渡米後は手が届かない。
#
# ★測る対象を self から peer へ絞った(2026-08-07、初版の欠陥)。
#   初版は `--chain edith` で self(この MBP)も数えて赤を出していた。だがこの機械は
#   **Tom と一緒に渡米する**。手元に在る機械の鍵が切れても、その場で入り直せる =
#   「渡米後も作れる」を崩さない。falsifier は「日本に置いて行く機械へ届かなくなる」事だけ。
#   DESIGN §8-5 が名指ししているのも edith と friday の 2 台で、self は入っていない。
# ★機械名は出さない(status --json は LoginName と node key を含む面なので、
#   此処では porcelain の side / 日数 / 日付だけを読む)。
TKE="$ROOT/rc-backend/tools/tailnet-key-expiry.sh"
JP_NODES="edith friday"   # DESIGN §8-5 が名指しする、日本に残す 2 台
if [ ! -f "$TKE" ]; then
    row skip "9. §5-9 期限性(渡米後も作れる)" "tailnet-key-expiry.sh が無い"
else
    nkey=0; live=0; unmeas=0; detail=""
    for n in $JP_NODES; do
        line="$(bash "$TKE" --peer "$n" --porcelain 2>/dev/null | grep '^KEY ' | head -1 || true)"
        d="$(printf '%s' "$line" | awk '{print $3}')"
        case "${d:-}" in
            "")        unmeas=$((unmeas+1)); detail="$detail 読めず" ;;
            -)         unmeas=$((unmeas+1)); nkey=$((nkey+1)); detail="$detail 測れず" ;;
            none)      nkey=$((nkey+1));     detail="$detail 期限なし" ;;
            *[!0-9-]*) unmeas=$((unmeas+1)); nkey=$((nkey+1)); detail="$detail 読めず" ;;
            *)         nkey=$((nkey+1)); live=$((live+1))
                       detail="$detail $(printf '%s' "$line" | awk '{print $3"日("$4")"}')" ;;
        esac
    done
    if [ "$nkey" -eq 0 ]; then
        row skip "9. §5-9 期限性(渡米後も作れる)" "日本側 2 台の鍵を1件も読めなかった(tailscale が居ないか、一覧に居ない)"
    elif [ "$unmeas" -ne 0 ]; then
        row skip "9. §5-9 期限性(渡米後も作れる)" "日本側 2 台のうち $unmeas 台が測れない。測れない事を「切れない」と読まない。$detail"
    elif [ "$live" -ne 0 ]; then
        row fail "9. §5-9 期限性(渡米後も作れる)" \
            "日本に残す 2 台のうち $live 台に生きた期限が在る($detail)。切れたら復旧はその機械の前 = 渡米後は届かない。DESIGN §8-5(締切 2026-09-19、Tom の操作)"
    else
        row pass "9. §5-9 期限性(渡米後も作れる)" "日本に残す 2 台とも期限なし(無効化済み)= 鍵切れで経路が死ぬ道が塞がっている"
    fi
fi

# --- 10. 証跡そのもの --------------------------------------------------------
# ★この行は「表を書いたか」ではなく「表が**この道具の出力から**作られ、引用が実在するか」を見る。
EV="$HARNESS/evidence-2026-08-1x/sprint6-acceptance.md"
if [ ! -f "$EV" ]; then
    row skip "10. 証跡 sprint6-acceptance.md" "まだ無い(この道具の出力から作る)"
else
    ALL_NAMES="$( { grep -rhoE 'func test[A-Za-z0-9_]+' "$TESTS" "$UITESTS" 2>/dev/null | sed 's/func //'; } | sort -u )"
    cited="$(grep -oE '\btest[A-Z][A-Za-z0-9_]+' "$EV" | sort -u)"
    ncit="$(printf '%s\n' "$cited" | grep -c . || true)"
    ghost="$(comm -23 <(printf '%s\n' "$cited") <(printf '%s\n' "$ALL_NAMES") | grep . || true)"
    nghost="$(printf '%s\n' "$ghost" | grep -c . || true)"
    if ! grep -q 'dod-sprint-6.5.sh' "$EV"; then
        row fail "10. 証跡 sprint6-acceptance.md" "何が測ったのかを名指ししていない(この道具の名前が無い)"
    elif [ "${nghost:-0}" -ne 0 ]; then
        row fail "10. 証跡 sprint6-acceptance.md" "名指しした $ncit 種のうち $nghost 種が実在しない: $(printf '%s' "$ghost" | tr '\n' ' ')"
    elif ! grep -q '未測定' "$EV"; then
        row fail "10. 証跡 sprint6-acceptance.md" "未測定の行が1つも書かれていない = 電話が要る脚を緑に丸めている"
    else
        row pass "10. 証跡 sprint6-acceptance.md" "この道具を名指しし、引用した $ncit 種は全部実在し、未測定の行が残っている"
    fi
fi

echo
echo "=== 合計: 緑 $GREEN / 赤 $RED / 未測定 $UNMEASURED ==="
echo "  未測定を緑にも赤にも丸めない。5-c と 6-c は Tom の iPhone が要る(HANDOFF §4 の 8-a / 8-b)。"
echo "  0 と 5-b は DOD_FULL=1 で実測する。"
[ "$RED" -gt 0 ] && exit 1
[ "$UNMEASURED" -gt 0 ] && exit 2
exit 0
