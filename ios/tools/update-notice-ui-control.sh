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
# ★書き換え先は**砂場**(2026-08-30、CF-21 の移行)。作業中の木は1バイトも触らない。
#   殺されても木に変異は残らない —— 安全が trap の実行に依存しなくなる。
. "$IOS/tools/mutation-sandbox.sh"
ms_prepare || exit 2
MODELS="$MS_TREE/Sources/Core/SessionsModels.swift"
VM="$MS_TREE/Sources/Screens/List/ListViewModel.swift"
LV="$MS_TREE/Sources/Screens/List/ListView.swift"
SNOOZE="$MS_TREE/Sources/Core/UpdateSnooze.swift"

UNIT="-only-testing:RemoteMiniTests/ListUpdateNoticeTests"
UI="-only-testing:RemoteMiniUITests/UpdateNoticeUITests"

pass=0; fail=0
ok() { echo "PASS  $1"; pass=$((pass + 1)); }
ng() { echo "FAIL  $1  ($2)"; fail=$((fail + 1)); }

# ★生成木の錠は**要らなくなった**(砂場で焼くので生成木を触らない)。直列化は
#   砂場側の錠(`ms_prepare` の `mkdir`)が持つ。以下は移行前の理由の記録:
#   ★生成木(`RemoteMini.xcodeproj` / `ios/Info.plist`)へ書く走行を**1本に絞る**。
#   之が無いと `build.sh --sim` や他の UI 対照と刻印を潰し合い、**偽の赤**が出る
#   (2026-08-15 の実測では 9 本 —— 製品の欠陥と見分けが付かない赤)。
#   ★同じ形を今日 自分でも踏んだ: 対照が回っている最中に `ios/Sources` を編集し、
#     其の走行の結果を捨てる羽目になった。錠は其れを機械で止める。
#   取れなければ此処で非零終了する = 生成物に触らないまま止まる。

# ★復元は**砂場の再同期**が担う(次の `ms_prepare` が `--delete` 付きで上書きする)。
#   `git checkout --` は使わない —— 砂場は git の管理下に無いし、
#   作業中の木へ `git checkout` を撃つ台本であり続けると、**触らない筈の木に
#   書き込む道**が残る。変異は其の場で戻す(下の run_mut が毎回 ms_prepare し直す)。
restore() { ms_prepare >/dev/null 2>&1 || true; }
# ★錠の返却を**同じ trap に**入れる。後から掛けた trap は前のを置き換えるので、
#   別々に書くと片方が消える(対照 C4 が此れを縛っている)。
trap 'ms_release' EXIT

# 汚れた木では測れない。意図した編集と変異の区別が付かないまま緑を出す方が悪い。
# ★汚れの検査は要らない。砂場は毎回 `--delete` 付きで本物から作り直されるので、
#   「意図した編集と変異の区別が付かない」状態が起きない。
dirty=""
if [ -n "$dirty" ]; then
    echo "update-notice-ui-control: 測る file が既に汚れている = 測定不成立" >&2
    printf '%s\n' "$dirty" | sed 's/^/  /' >&2
    echo "  先に commit か stash を(索引に在る物は汚れとして出ない)" >&2
    exit 2
fi

xcb() {   # xcb <log> <-only-testing 群...> → 0=緑
    local log="$1"; shift
    # ★砂場で焼く。derived data も砂場側に持つので生成木と潰し合わない。
    #   固定 path なので温かいまま(`mutation-sandbox.sh` の実測)。
    ( cd "$MS_TREE" && xcodegen generate >/dev/null 2>&1 && \
      /usr/bin/perl -e 'alarm shift; exec @ARGV or exit 127' "$CONTROL_RUN_LIMIT_S" \
        xcodebuild -project RemoteMini.xcodeproj -scheme RemoteMini -configuration Debug \
        -sdk iphonesimulator -destination "platform=iOS Simulator,name=$SIM_NAME" \
        -derivedDataPath "$MS_ROOT/build" \
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
# ★砂場は git の管理下に無いので `git diff` は使えない —— 移行の直後、此処は
#   `fatal: … is outside repository` で**空を得て緑**になっていた(別の理由で出た緑)。
#   測るべき物も変わった: 砂場が汚れているかではなく、**本物の木が無傷か**。
#   砂場の汚れは次の `ms_prepare` が `--delete` 付きで消すので、残っても害が無い。
if ms_assert_live_unchanged; then
    ok "Z 本物の木を1バイトも触っていない(走行前後の指紋が一致)"
else
    ng "Z 本物の木が変わった" "対照が触ったか別の何かが同時に触った。どちらでも結果は stale"
fi

echo ""
echo "UPDATE-NOTICE-UI-CONTROL: pass=$pass fail=$fail (log: $LOGD)"
exit $(( fail > 0 ))
