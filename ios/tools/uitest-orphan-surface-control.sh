#!/bin/bash
# controls-for: ios/UITests/AttachButtonUITests.swift ios/UITests/AwayDigestUITests.swift ios/UITests/BuildIdentityUITests.swift ios/UITests/ComposerKeyboardToolbarUITests.swift ios/UITests/ConversationSearchUITests.swift ios/UITests/DiffCommentUITests.swift ios/UITests/DiffUITests.swift ios/UITests/ListRenameUITests.swift ios/UITests/NewSessionPickerUITests.swift ios/UITests/SlashEffortArgUITests.swift ios/UITests/SlashModelArgUITests.swift ios/Sources/Screens/List/ListView.swift ios/Sources/Core/BuildInfo.swift
#
# **誰も走らせていなかった UI 検査 11 class** を門に載せる対照。
#
# ── なぜ要るか(2026-09-08、同じ病の 2 度目)────────────────────────────────
# 1 度目 = `.harness/evidence-2026-09-08/ui-tests-were-never-in-the-commit-path.md`:
#   UI 検査 8 本が赤いまま出荷された。誰も走らせていなかったので**赤である事すら判らなかった**。
#   其の時は `composer-surface-control.sh` を1本作って 4 class を塞いだ。
# 2 度目 = 同日の掃引(別セッションの読み取り専用走行が発見、私が実測で確認):
#   27 class 中、commit の門で走るのは **10 本だけ**だった。
#   `ios/tools/uitest-reachability-gate.sh` が此の穴を毎回 全数で数える門で、
#   此の file は其の門を緑にする側 —— 門だけ作って中身を宣言で逃がすと、
#   門は「免除の一覧」に変わる。
#
# ★載せた class の中に `ListRenameUITests` が居る。同じ日に直した「名前変更が机を
#   叩かない(alert の submit が no-op)」欠陥を守る為に書いた検査で、**書いた当日から
#   誰も走らせていなかった**。MU1 は其の欠陥を植え直して、此の対照が本当に捕まえる事を示す。
#
# ★`RC_BUILD_REV` を **xcodegen の前に export する**(`ios/tools/build.sh` と同じ)。
#   之が無いと `project.yml` の `RCBuildRev: "${RC_BUILD_REV}"` が未展開のまま焼かれ、
#   `BuildIdentityUITests` 5 本が「版が unknown」で赤くなる —— **製品の欠陥ではなく
#   走らせ方の欠陥**。実測で1度踏んだ(基準 30 緑 / 5 赤、全部 BuildIdentity)。
#   検査自身が失敗文にそう書いているので、読めば判る形にはなっていた。
#
# 何を測るか(変異 -> 赤くなるべき検査):
#   MU1 `submitRename` を no-op へ戻す      -> ListRenameUITests が赤
#       ★当日直した欠陥そのもの。此処が緑のままなら、直しは守られていない。
#   MU2 版の表示を常に unknown にする        -> BuildIdentityUITests が赤
#       ★刻印の経路が生きている事の確認も兼ねる(上の ★ の裏返し)。
#
# 費用(隠さない): xcodebuild を 3 回(基準1 + 変異2)、11 class = 35 検査。
#   基準の実測 537 秒。`controls-for:` が此の 11 本の検査 file と、変異が当たる
#   2 つの source だけなので、**其れらを触った commit でしか走らない**。
#
# 終了コード: 0=全変異が期待通り赤 / 1=赤くならない検査が在る / 2=測れなかった
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # = ios/
IOS="$HERE"
ROOT="$(cd "$HERE/.." && pwd)"
. "$HERE/tools/sim-device.sh"
BUNDLE_ID="com.tomarai.remotemini"
SIM_UDID="$(xcrun simctl list devices 2>/dev/null | grep -F "$SIM_NAME (" | head -1 \
    | grep -oE '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}' | head -1)"
LOGDIR="${TMPDIR:-/tmp}"
INFLIGHT="${TMPDIR:-/tmp}/rc-ios-mutation-inflight.tsv"
PASS=0; FAIL=0; UNMEASURED=0
ok() { echo "  OK   $1"; PASS=$((PASS+1)); }
ng() { echo "  ★NG  $1 — $2"; FAIL=$((FAIL+1)); }
un() { echo "  未測定 $1"; UNMEASURED=$((UNMEASURED+1)); }

# ★書き換え先は**砂場**。作業中の木は1バイトも触らない(CF-12 / CF-21)。
. "$IOS/tools/mutation-sandbox.sh"
ms_prepare || exit 2
LV="$MS_TREE/Sources/Screens/List/ListView.swift"
BI="$MS_TREE/Sources/Core/BuildInfo.swift"
TARGETS=("$LV" "$BI")

CLASSES=(
    "RemoteMiniUITests/AttachButtonUITests"
    "RemoteMiniUITests/AwayDigestUITests"
    "RemoteMiniUITests/BuildIdentityUITests"
    "RemoteMiniUITests/ComposerKeyboardToolbarUITests"
    "RemoteMiniUITests/ConversationSearchUITests"
    "RemoteMiniUITests/DiffCommentUITests"
    "RemoteMiniUITests/DiffUITests"
    "RemoteMiniUITests/ListRenameUITests"
    "RemoteMiniUITests/NewSessionPickerUITests"
    "RemoteMiniUITests/SlashEffortArgUITests"
    "RemoteMiniUITests/SlashModelArgUITests"
)
WANT_RENAME=ListRenameUITests
WANT_BUILD=BuildIdentityUITests

WORK="$(mktemp -d "${TMPDIR:-/tmp}/uitest-orphan.XXXXXX")"
ORIG="$WORK/orig"
mkdir -p "$ORIG"
snap_path() { printf '%s/%s' "$ORIG" "$1"; }

restore_one() {
    local i="$1"
    local f s
    f="${TARGETS[$i]}"
    s="$(snap_path "$i")"
    [ -f "$s" ] || return 0
    /bin/cp "$s" "$f"
}

cleanup() {
    local i=0
    while [ "$i" -lt "${#TARGETS[@]}" ]; do
        restore_one "$i"
        i=$((i+1))
    done
    /bin/rm -f "$INFLIGHT"
    [ -n "${WORK:-}" ] && [ -d "$WORK" ] || return 0
    find "$WORK" -type f -print0 2>/dev/null | xargs -0 /bin/rm -f 2>/dev/null
    find "$WORK" -type d -depth -exec /bin/rmdir {} + 2>/dev/null
}
trap 'cleanup; ms_release' EXIT

# ★此の区間は**全対照で一字一句同じ**でなければならない
#   (`rc-backend/test/mutation-recovery-copy.test.mjs` が突き合わせる)。
#   1本だけ直すと、他が残した変異を此方が復元の基準点として複製する。
#   ★砂場へ移った後も残す: 台帳は**全対照で共有**なので、まだ作業中の木を触る
#     対照(bar-material / conversation-ui / signout-notice)が殺された時、
#     次に走った此の台本が其の取り残しを戻す。移行の途中こそ効く。
#   ★2026-08-30、中の助言文を「砂場では git checkout は効かない」と直そうとして
#     単体を1本落とした —— 共有ブロックへの善意の一行が、突き合わせを壊す。
# ---- 前回の走行が殺されていたら、その取り残しを先に戻す(ここから)-------------
# ★この位置でなければならない: 下の複製 loop より**前**。後に置くと、変異したバイトを
#   「走る前の中身」として複製してしまい、復元の基準点そのものが汚染される。
if [ -f "$INFLIGHT" ]; then
    recovered=""; lost=""
    while IFS="$(printf '\t')" read -r rf rs; do
        [ -n "${rf:-}" ] || continue
        if [ -f "$rs" ] && [ -f "$rf" ]; then
            if ! cmp -s "$rs" "$rf"; then
                /bin/cp "$rs" "$rf"
                recovered="$recovered ${rf#$ROOT/}"
            fi
        else
            lost="$lost ${rf#$ROOT/}"
        fi
    done < "$INFLIGHT"
    /bin/rm -f "$INFLIGHT"
    if [ -n "$recovered" ]; then
        echo "復旧: 前回の走行が殺されて残っていた変異を戻した:$recovered"
    fi
    if [ -n "$lost" ]; then
        echo "UNMEASURED  前回の変異を戻せない(複製が消えている):$lost"
        echo "            何が変わっているかは git diff で見え、戻すのは git checkout -- で足りる。"
        exit 2
    fi
fi
# ---- 前回の取り残しの復旧(ここまで)-----------------------------------------

i=0
while [ "$i" -lt "${#TARGETS[@]}" ]; do
    /bin/cp "${TARGETS[$i]}" "$(snap_path "$i")"
    printf '%s\t%s\n' "${TARGETS[$i]}" "$(snap_path "$i")" >> "$INFLIGHT"
    i=$((i+1))
done
restore_all() {
    local i=0
    while [ "$i" -lt "${#TARGETS[@]}" ]; do restore_one "$i"; i=$((i+1)); done
}

settle_sim() {
    [ -n "${SIM_UDID:-}" ] || return 0
    xcrun simctl terminate "$SIM_UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
}

ran_count() { local n; n="$(grep -cE "Test Case '-\[RemoteMiniUITests\." "$1" 2>/dev/null)" || n=0; printf '%s' "${n:-0}"; }

run_ui_once() { # $1 = log -> rc を印字
    local log="$1" rc=0 args=() c
    for c in "${CLASSES[@]}"; do args+=(-only-testing:"$c"); done
    # ★`RC_BUILD_REV` は **generate の前**に export(build.sh と同じ順)。
    #   後でも未定義でも xcodegen は落ちず、`${RC_BUILD_REV}` を literal で焼く。
    ( cd "$MS_TREE" \
      && RC_BUILD_REV="$(git -C "$IOS/.." rev-parse --short HEAD 2>/dev/null || echo ctl)-ctl" \
      && export RC_BUILD_REV \
      && xcodegen generate >/dev/null 2>&1 \
      && xcodebuild -project RemoteMini.xcodeproj -scheme RemoteMini -configuration Debug \
        -sdk iphonesimulator -destination "platform=iOS Simulator,name=$SIM_NAME" \
        -derivedDataPath "$MS_ROOT/build" "${args[@]}" test ) >"$log" 2>&1 || rc=$?
    printf '%s' "$rc"
}

# ★診断を stdout に書かない事。呼び出し側は `rc=$(run_ui …)` で標準出力を rc として読む。
run_ui() { # $1 = log -> rc を印字
    local log="$1" rc
    settle_sim
    rc="$(run_ui_once "$log")"
    if [ "$(ran_count "$log")" -eq 0 ]; then
        echo "     (検査が1本も走っていない = 測定が起きていない。app を落として1度だけ取り直す)" >&2
        settle_sim
        rc="$(run_ui_once "$log")"
    fi
    printf '%s' "$rc"
}

extract() { # $1 = log, $2 = passed|failed -> class 名の一覧
    grep -oE "Test Case '-\[RemoteMiniUITests\.[A-Za-z0-9_]+ [a-zA-Z0-9_]+\]' $2" "$1" \
        | sed -E "s/^.*RemoteMiniUITests\.([A-Za-z0-9_]+) .*$/\1/" | sort -u | tr '\n' ' '
}
has() { case " $1 " in *" $2 "*) return 0 ;; *) return 1 ;; esac; }

echo "=== 基準(変異なし)"
BASE_LOG="$LOGDIR/uitest-orphan-base.log"
rc=$(run_ui "$BASE_LOG")
if [ "$(ran_count "$BASE_LOG")" -eq 0 ]; then
    un "基準で検査が一度も走っていない(2度試して 0 本)= 機械の側が動いていない。全文: $BASE_LOG"
    echo "--- 合計: PASS $PASS / FAIL $FAIL / UNMEASURED $UNMEASURED ---"; exit 2
fi
if [ "$rc" -ne 0 ]; then
    un "基準が緑でない(rc=$rc)。赤: $(extract "$BASE_LOG" failed)。以降は測れない。全文: $BASE_LOG"
    echo "--- 合計: PASS $PASS / FAIL $FAIL / UNMEASURED $UNMEASURED ---"; exit 2
fi
BASE_PASSED="$(extract "$BASE_LOG" passed)"
for w in "$WANT_RENAME" "$WANT_BUILD"; do
    if ! has "$BASE_PASSED" "$w"; then
        un "基準で的の class が緑になっていない: $w(緑: $BASE_PASSED)"
        echo "--- 合計: PASS $PASS / FAIL $FAIL / UNMEASURED $UNMEASURED ---"; exit 2
    fi
done
ok "基準: 11 class が緑($(ran_count "$BASE_LOG") 検査、的の 2 class を含む)"

# ---- 変異 MU1: 名前変更を no-op へ戻す(2026-09-08 に直した欠陥そのもの)--------
mutate_mu1() {
    /usr/bin/sed -i '' \
        's|^        switch await renamer.rename(baseURL: baseURL, apiKey: apiKey, sessionID: target.id, title: title) {$|        if true { return }  // mutated: 机を叩かない no-op へ戻す\n        switch await renamer.rename(baseURL: baseURL, apiKey: apiKey, sessionID: target.id, title: title) {|' "$LV"
}
# ---- 変異 MU2: 版を常に unknown にする ----------------------------------------
mutate_mu2() {
    /usr/bin/sed -i '' \
        's|^        guard let raw else { return unknown }$|        guard let raw else { return unknown }\n        if true { return unknown }  // mutated: 版を名乗らない|' "$BI"
}

probe() { # $1=名前 $2=変異関数 $3=当たる file $4=赤くなるべき class
    local name="$1" fn="$2" target="$3" want="$4"
    restore_all
    local before after
    before=$(shasum "$target" | awk '{print $1}')
    "$fn"
    after=$(shasum "$target" | awk '{print $1}')
    if [ "$before" = "$after" ]; then
        un "$name: 変異が当たっていない(bytes が動かない)= 測っていない。探し文を付け直す事"
        return
    fi
    local log="$LOGDIR/uitest-orphan-$name.log" rc
    rc=$(run_ui "$log")
    if [ "$(ran_count "$log")" -eq 0 ]; then
        un "$name: 検査が一度も走っていない(2度試して 0 本)= 変異の当たり外れは測っていない。全文: $log"
        restore_all; return
    fi
    local reds; reds="$(extract "$log" failed)"
    if [ "$rc" -eq 0 ]; then
        ng "$name" "欠陥を植えたのに全部緑。$want は $name を測っていない。全文: $log"
    elif has "$reds" "$want"; then
        ok "$name -> 赤: $reds"
    else
        un "$name: 赤くはなったが $want ではない(赤: ${reds:-なし}, rc=$rc)。全文: $log"
    fi
    restore_all
}

probe MU1-rename-is-a-noop-again mutate_mu1 "$LV" "$WANT_RENAME"
probe MU2-build-never-names-itself mutate_mu2 "$BI" "$WANT_BUILD"

restore_all
if cmp -s "$LV" "$(snap_path 0)" && cmp -s "$BI" "$(snap_path 1)"; then
    ok "Z 砂場を書き換えたまま終わらない(対象 2 file が走る前のバイトと一致)"
else
    ng "Z 砂場が汚れている" "次の走行が汚れた基準点を使う"
fi

echo ""
echo "--- 合計: PASS $PASS / FAIL $FAIL / UNMEASURED $UNMEASURED ---"
[ "$FAIL" -gt 0 ] && exit 1
[ "$UNMEASURED" -gt 0 ] && exit 2
exit 0
