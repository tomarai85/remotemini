#!/bin/bash
# controls-for: ios/Sources/Core/UpdateSnooze.swift ios/Sources/Core/SessionsModels.swift ios/Sources/Screens/List/ListViewModel.swift ios/Sources/Screens/List/ListView.swift ios/Sources/Core/SessionsListingFixture.swift
#
# 「机は新しい版を配っている」の帯の、**電話側**の負の対照。
#
# ★なぜ此の帯が要るか(2026-08-30): CF-11 で私は「4件の指摘は反映済み」と報告したが、
#   其の修正は **Tom が持っているどの版にも入っていなかった**(commit は署名の3分後)。
#   CF-17 の実測では配布口に `client=app` が **path を問わず1本も来ていない** ——
#   栞は一度も叩かれていない。「新しい版が在る」を伝える経路が
#   **私が思い出して言う**しか無かった。私の記憶は F3 以来この系の最弱点なので、構造に置く。
#
# ★守る継ぎ目は4本。どれが切れても、残りの検査は緑を出し続ける ——
#   S8-5 / CF-14 / CF-15 で実際に3回起きた形(規則は正しく、単体も緑で、画面に繋がっていない)。
#
#     机 `updateNotice()`(文面を決める。此処は rc-backend/test/app-update-notice-controls.sh)
#       -> `SessionsResponse.OuterDisplay.update`(復号)          …… U1
#         -> `ListViewModel.updateNotice`(運ぶ)                  …… U2 / U3
#           -> `ListView` の帯(**画素になる**)                    …… U4
#
# 変異 -> 赤くなるべき検査:
#   U1 復号した値を写さない(`self.update = nil`)       -> ListUpdateNoticeTests(復号)
#   U2 ViewModel が常に nil を返す                      -> ListUpdateNoticeTests(運ぶ)
#   U3 空文字を nil に落とす番人を外す                  -> ListUpdateNoticeTests(空の帯)
#   U4 view が帯を描かない                              -> UpdateNoticeUITests(画素)
#   U5 版を**辞書順**で比べる("99" > "105")           -> ListUpdateNoticeTests(数として)
#   U6 番号が無くても「後で」を憶える                   -> ListUpdateNoticeTests(鍵なし記憶)
#   U7 「後で」を押しても何も起きない                   -> UpdateNoticeUITests(押せる物)
#
# ★U4 は画を出す検査でしか物を言えない。2026-08-27 に同じ形で踏んでいる ——
#   `.accessibilityElement(children: .contain)` の無い `VStack` に識別子だけ付けても
#   SwiftUI は要素を公開せず、**錨を置いた気になって到達不能**になる。grep では捕まらない。
#
# 費用(隠さない): xcodebuild を8回(基準1 + 変異7)。うち3回は UI 検査を含むので重い。
#
# 使い方: bash ios/tools/update-notice-ui-control.sh
# 終了コード: 0=全部緑 / 1=1本でも赤 / 2=測定不成立
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"     # = ios/tools
IOS="$(cd "$HERE/.." && pwd)"                            # = ios/
SIM_NAME="${SIM_NAME:-iPhone-dogfood}"
CONTROL_RUN_LIMIT_S="${CONTROL_RUN_LIMIT_S:-1200}"

# ★書き換える file を**1行の宣言**で名乗る。`ios/tools/mutation-residue-check.sh` は
#   此の綴りを走査して「殺された走行が木に残した変異」を名指しするので、
#   別の形で書くと**此の対照の残骸だけが検知から漏れる**(2026-08-30 に実測した穴)。
MODELS="$IOS/Sources/Core/SessionsModels.swift"
VM="$IOS/Sources/Screens/List/ListViewModel.swift"
LV="$IOS/Sources/Screens/List/ListView.swift"
SNOOZE="$IOS/Sources/Core/UpdateSnooze.swift"

UNIT="-only-testing:RemoteMiniTests/ListUpdateNoticeTests"
UI="-only-testing:RemoteMiniUITests/UpdateNoticeUITests"

pass=0; fail=0
ok() { echo "PASS  $1"; pass=$((pass + 1)); }
ng() { echo "FAIL  $1  ($2)"; fail=$((fail + 1)); }

# ★木を戻す手。`git checkout --` を使うのは、`mutation-residue-check.sh` が
#   「復元を持つ台本 = 書き換える台本」として此の綴りで数えている為でもある。
restore() { ( cd "$IOS/.." && git checkout -- "$MODELS" "$VM" "$LV" "$SNOOZE" ) 2>/dev/null; }
trap 'restore' EXIT

# 汚れた木では測れない。意図した編集と変異の区別が付かないまま緑を出す方が悪い。
dirty="$( cd "$IOS/.." && git diff --name-only -- "$MODELS" "$VM" "$LV" "$SNOOZE" )"
if [ -n "$dirty" ]; then
    echo "update-notice-ui-control: 測る file が既に汚れている = 測定不成立" >&2
    printf '%s\n' "$dirty" | sed 's/^/  /' >&2
    echo "  先に commit か stash を(索引に在る物は汚れとして出ない)" >&2
    exit 2
fi

xcb() {   # xcb <log> <-only-testing 群...> → 0=緑
    local log="$1"; shift
    ( cd "$IOS" && xcodegen generate >/dev/null 2>&1 && \
      /usr/bin/perl -e 'alarm shift; exec @ARGV or exit 127' "$CONTROL_RUN_LIMIT_S" \
        xcodebuild -project RemoteMini.xcodeproj -scheme RemoteMini -configuration Debug \
        -sdk iphonesimulator -destination "platform=iOS Simulator,name=$SIM_NAME" \
        "$@" test ) > "$log" 2>&1
}

mutate() {  # mutate <file> <元> <後>
    python3 - "$1" "$2" "$3" <<'PY'
import io, sys
p, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
s = io.open(p, encoding="utf-8").read()
if a not in s:
    sys.stderr.write("ANCHOR-MISS\n"); sys.exit(3)
io.open(p, "w", encoding="utf-8").write(s.replace(a, b, 1))
PY
}

LOGD="$(mktemp -d)"

# ── 基準。**変異の前に緑である事**を見る(赤い木で変異を測っても何も言えない)。 ──
if xcb "$LOGD/base.log" $UNIT $UI; then
    ok "基準: 素の木で単体と UI が緑"
else
    ng "基準" "素の木で赤い = 変異の結果を読めない。$LOGD/base.log"
    echo ""; echo "UPDATE-NOTICE-UI-CONTROL: pass=$pass fail=$fail"; exit 1
fi

run_mut() {  # run_mut <名前> <file> <元> <後> <検査群...>
    local name="$1" file="$2" from="$3" to="$4"; shift 4
    if ! mutate "$file" "$from" "$to"; then
        ng "$name" "錨が動いた(実装を直したら此の対照の綴りも直す)"; restore; return
    fi
    if xcb "$LOGD/$name.log" "$@"; then
        ng "$name" "変異を植えたのに緑 = 其の継ぎ目は誰も見ていない。$LOGD/$name.log"
    else
        ok "$name → 赤くなる"
    fi
    restore
}

run_mut "U1-復号した値を写さない" "$MODELS" \
    'self.update = update' 'self.update = nil' \
    $UNIT

run_mut "U2-ViewModel が運ばない" "$VM" \
    'notice: lastResponse?.display.update,' \
    'notice: nil,' \
    $UNIT

run_mut "U3-空文字の番人を外す" "$SNOOZE" \
    'guard let notice, !notice.isEmpty else { return nil }' \
    'guard let notice else { return nil }' \
    $UNIT

run_mut "U4-view が帯を描かない" "$LV" \
    '                if let notice = viewModel.updateNotice {
                    updateBar(notice)
                }
                rows(sessions, grayedOut: false)' \
    '                rows(sessions, grayedOut: false)' \
    $UI

run_mut "U5-版を辞書順で比べる" "$SNOOZE" \
    'guard let b = Int(build), let s = Int(snoozed) else { return notice }
        return s >= b ? nil : notice' \
    'return snoozed >= build ? nil : notice' \
    $UNIT

run_mut "U6-番号が無くても憶える" "$VM" \
    'guard let build = lastResponse?.display.updateBuild, !build.isEmpty else { return }' \
    'let build = lastResponse?.display.updateBuild ?? ""' \
    $UNIT

run_mut "U7-「後で」の押し先が無い" "$LV" \
    'Button("後で") { viewModel.snoozeUpdateNotice() }' \
    'Button("後で") { }' \
    $UI

# ★戻せた事を測る。変異が木に残ると、次に焼いた版へ其れが乗る(CF-12 で配る寸前まで行った)。
still="$( cd "$IOS/.." && git diff --name-only -- "$MODELS" "$VM" "$LV" "$SNOOZE" )"
if [ -z "$still" ]; then
    ok "Z 木を汚したまま終わらない"
else
    ng "Z 木が汚れている" "$still ← bash ios/tools/mutation-residue-check.sh --restore"
fi

echo ""
echo "UPDATE-NOTICE-UI-CONTROL: pass=$pass fail=$fail (log: $LOGD)"
exit $(( fail > 0 ))
