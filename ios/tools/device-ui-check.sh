#!/bin/bash
# device-ui-check.sh — UI 検査を**実機**(Tom の iPhone)で走らせる。2026-09-04。
#
# ── なぜ在るか ────────────────────────────────────────────────────────────
# 此の repo の UI 検査は**全部シミュレータ**で回っていた。緑は本物だが、
# 測っていない物が 3 つ在る: 実機の描画で操作子が本当に押せる位置に出るか /
# 実機のキーボードと入力欄の相互作用 / 本物の網と机との往復。
# 2026-09-04 に初めて実機で 6 クラスを通した(6/6、iPhone 13 / iOS 26.5)。
#
# ★躓いた所を 2 つ残す。どちらも同じ文言(`Lost pending connection to the test runner
#   before launch`)で出るが、原因が**別**:
#     1. 端末が `unavailable`(ケーブル / 一時的な切断)
#     2. 端末は `connected` だが**画面がロックされている** —— XCUITest のランナーは
#        ロック中に起動できない。`devicectl device process launch` を直に叩くと
#        `BSErrorCodeDescription = Locked` と正直に言う。
#   上の層のメッセージは犯人を名指しできない。**拒否している層に直接訊く**方が速い。
#   だから此の台本は建てる前に state を見て、駄目なら 2 秒で降りる(rc=90)。
#
# 使い方: bash ios/tools/device-ui-check.sh <log-path>
# 終了コード: 0 = 緑 / 90 = 端末が繋がっていない(測っていない)/ その他 = xcodebuild の rc
#
# ★測らない物: 離脱窓の本体。あれは ViewModel の検査(机も作り物)なので、
#   実機で確かめるには「本物の机の長い会話で 500 件より奥を押す」形が別に要る。
set -u
cd /Users/tomtim/Infra/mobile-work/ios || exit 1
. ./tools/xcode-tree-guard.sh
trap 'xtl_release' EXIT
RC_BUILD_REV="$(git rev-parse --short HEAD)"; export RC_BUILD_REV
export RC_ROLE=control
DEV=EC0FCBEE-745C-5755-A82C-A9743434A62B
# ★建てる前に端末の状態を見る(2026-09-04 実測)。前回は 4 分かけて建ててから
#   `Lost pending connection to the test runner before launch` で落ちた —— 原因は
#   コードではなく端末が途中で `unavailable` になった事。先に見れば 2 秒で分かる。
STATE=$(xcrun devicectl list devices 2>/dev/null | awk -v d="$DEV" '$0 ~ d {for(i=1;i<=NF;i++) if($i=="connected"||$i=="unavailable"||$i=="disconnected") print $i}')
if [ "$STATE" != "connected" ]; then
  echo "端末が connected でない(state=${STATE:-見つからない})。ケーブルと画面のロックを確かめる"
  echo "xcode rc=90"; exit 90
fi
xcodegen generate >/dev/null || { echo "xcodegen rc=$?"; exit 1; }
xcodebuild test -project RemoteMini.xcodeproj -scheme RemoteMini \
  -destination "platform=iOS,id=EC0FCBEE-745C-5755-A82C-A9743434A62B" -derivedDataPath build-device \
  -only-testing:RemoteMiniUITests/ToolOutputFoldUITests \
  -only-testing:RemoteMiniUITests/SearchJumpUITests \
  -only-testing:RemoteMiniUITests/SearchHighlightUITests \
  -only-testing:RemoteMiniUITests/ListSearchUITests \
  -only-testing:RemoteMiniUITests/AttachFileButtonUITests \
  -only-testing:RemoteMiniUITests/EmptySessionListHintUITests \
  DEVELOPMENT_TEAM=KJ2942P8F8 CODE_SIGN_STYLE=Automatic \
  CODE_SIGN_IDENTITY="Apple Development" CODE_SIGNING_REQUIRED=YES CODE_SIGNING_ALLOWED=YES \
  2>&1 | tee "$1" | grep -E 'error:|Executed|TEST (SUCCEEDED|FAILED)|Testing failed|requires a provisioning|Signing' | tail -14
echo "xcode rc=${PIPESTATUS[0]}"
