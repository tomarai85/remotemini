#!/bin/bash
# controls-for: ios/Sources/AppState.swift ios/Sources/Core/KeyEntryClients.swift ios/Sources/Core/KeyEntryProbeFixture.swift ios/Sources/Core/KeychainCredentialStore.swift ios/Sources/Core/Provisioning.swift ios/Sources/Core/ProvisioningFixture.swift ios/Sources/Core/SignOutNotice.swift ios/Sources/Core/SignOutNoticeFixture.swift ios/Sources/RootView.swift ios/Sources/Screens/KeyEntry/DisconnectedView.swift ios/Sources/Screens/KeyEntry/KeyEntryView.swift ios/Sources/Screens/KeyEntry/KeyEntryViewModel.swift ios/Tests/AppStateTests.swift ios/Tests/Core/KeychainCredentialStoreTests.swift ios/Tests/Core/ProvisioningTests.swift ios/Tests/Core/SignOutNoticeStoreTests.swift ios/Tests/Screens/DisconnectedViewTests.swift ios/Tests/Screens/KeyEntryViewTests.swift ios/Tests/Screens/KeyEntryViewModelTests.swift ios/UITests/FirstRunUITests.swift ios/UITests/KeyEntryUITests.swift
#
# 鍵入力画面の負の対照。守っている物は3つ在り、**同じ file 群**の上に載っている:
#   (a) 401 で戻された時の断り(DESIGN §2.65 / 監査 X2-6) …… M1-M9
#   (b) 接続を押した後の「確かめています」(DESIGN §2.68 / 監査 X2-8) …… M10-M12
#   (c) 焼き込んだ種で初回起動が一覧に着く事(2026-08-11 の欠陥) …… M13-M24
#       M13-M17 = 蒔く側(AppState / RootView)。M18-M19 = **刻印の形を落とす門**
#       (`Provisioning.clean` と scheme+host)。後者は `vacuous-gate` が
#       「否定だけで錨なし」と挙げた6本の錨が本当に効くかを測る為に足した。
#       M20-M24 = 台帳の反転(2026-08-15 / DESIGN §2.94)。台帳が覚えるのが
#       「蒔いた種」から**「机が拒んだ種」**へ変わり、守る枝が増えた ——
#       保存に失敗した種を拒否として記録しない(M20)・拒まれた鍵を起動時に
#       金庫から掃く(M21)・鍵を入れ替えた後に届いた古い 401 で今の鍵を
#       落とさない(M22)・同じ値が通ったら拒否を降ろす(M23)・
#       束の種でない鍵の 401 を台帳へ書かない(M24)。
#   (d) 単体検査が**電話の本物の Keychain 項目**に触らない事 …… M25-M26
#       此れが 2026-08-15 の引き金そのもの。`KeychainCredentialStoreTests` が
#       `setUp`/`tearDown` で `clear()` を呼び、座標が製品と同じだったので
#       検査を1回回すと資格情報が消えた。往復の検査はどんな座標でも緑になるので、
#       座標の話は座標を見る検査でしか捕まらない(M26 が其れを実演する)。
#
# ★1本に束ねてあるのは、`staged-controls-gate.sh` が path で対照を選ぶから。別 file に
#   割ると `KeyEntryViewModel.swift` を1行触るだけで xcodebuild が**2組**走る ——
#   同じ木・同じ simulator を測るのに費用だけ倍になる。概念の綺麗さより測定の費用を取る。
#
# 何を守るか(a): 「通っていた鍵が拒まれた」という事実が、disk に書かれてから**画面の
# 画素になる**まで4本の継ぎ目を渡る。
#
#     SignOutNoticeStoring(UserDefaults)
#       -> AppState.clearCredentials / loadStoredCredentials
#         -> RootView.normalFlow が KeyEntryView に notice を渡す
#           -> KeyEntryView.init が文に変える
#             -> body が節を描く
#
# どの継ぎ目が切れても、残りの検査は緑を出し続ける。これは S8-5 で実際に起きた形
# (規則は正しく、単体も緑で、画面に繋がっていなかった)なので、継ぎ目ごとに名指しで撃つ。
#
# 何を測るか(変異 -> 赤くなるべき検査):
#   M1 clearCredentials が断りを一切残さない -> 401 が理由を残す検査が赤
#   M2 断りを Keychain の**後**に書く        -> 「順序」の検査が赤
#      ★同時に「断りが残る」検査は**緑のまま**。順序だけを見る検査が在って初めて
#        「間で殺された電話が白紙に戻る」欠陥が捕まる事の実演。
#   M3 起動時の掃除を外す                    -> 「鍵が在れば古い断りは掃かれる」が赤
#   M4 KeyEntryView.init が notice を捨てる  -> 「組んだ view が文を握る」が赤
#      ★同時に純関数 sentence(for:) の検査は**緑のまま** = 純関数だけ測っても
#        画面に繋がらない実装が通る、の実演。
#   M5 2文を1文に畳む                        -> 「URL が無い時に前のままと言わない」が赤
#   M6 UserDefaults の store が書かない       -> 「別の器から読める」が赤
#      ★同時に AppState 側の検査は**緑のまま** = 忘れる金庫でも app の検査は通る。
#   M7 拒まれた鍵まで欄に戻す                -> 「鍵は戻さない」が赤
#   M8 body の節を描かない                   -> **UI 検査だけ**が赤
#      ★同時に「組んだ view が文を握る」は緑のまま。単体では永久に届かない一歩が
#        此処に在る事の実演で、この対照の一番の要。
#   M9 RootView が notice を渡さない          -> **UI 検査だけ**が赤
#      ★配線の1行。単体は1本も落ちない。RootView は今後も触られる file なので、
#        黙って外れた日に気付けるかを測る。
#
# 何を測るか(b)。此方の継ぎ目は3本:
#
#     KeyEntryViewModel.probe(今どの段か)
#       -> inFlightText が段ごとに別の文を返す
#         -> body の footer が描く / 欄が .disabled になる
#
#   M10 2段目の文を1段目の文に差し替える -> 「段ごとに別の文」が赤
#       ★同時に文を作る純関数の検査は**緑のまま**。M4 と同じ形の実演で、
#         「文は正しいが、正しい段に結ばれていない」を純関数側は永久に見ない。
#   M11 footer が一文を描かない            -> **UI 検査だけ**が赤
#       ★同時に viewModel 側の段の検査は緑のまま。M8 の相方。
#   M12 欄の .disabled を外す              -> **UI 検査だけ**が赤
#       ★同時に単体の「両段で isChecking が立つ」は緑のまま = 単体が届くのは
#         `isChecking` の値までで、その値が現に欄を止めている事は測れない。
#
# 何を測るか(c)。2026-08-11、Tom が実機で開いた最初の画面が「Base URL と API Key を
# 打て」だった —— 合格条件は「開くと一覧が出る」で、人が打つとは何処にも書いていない。
# 数十本の検査が一度も赤くならなかったのは、**製品の入口を見る計器が1つも無かった**から。
# 継ぎ目は此の4本:
#
#     ProvisioningSource(焼き込んだ刻印)
#       -> AppState.loadStoredCredentials が「読めた上で空」だけを見る
#         -> plantSeedIfNeeded が指紋を見て1回だけ蒔く
#           -> RootView.normalFlow が一覧を選ぶ
#
#   M13 種を蒔かない                      -> 「空の Keychain が種で埋まる」が赤
#       ★直す前の姿そのもの。此の1行が Tom の見た画面を作っていた。
#   M14 指紋の門を外す(毎回蒔く)          -> 「捨てた種は蒔き直さない」が赤
#       ★同時に「空の Keychain が種で埋まる」は**緑のまま** = 幸せな道だけ測ると、
#         401 で捨てた鍵をまた蒔いて電話が回り続ける実装が通る。
#   M15 「読めなかった」を「空」に潰す      -> 「読めない Keychain を空と読まない」が赤
#       ★同時に幸せな道は緑のまま。潰したままだと、Keychain が一時的に読めない起動で
#         **Tom が手で入れた鍵を種が上書きする**。
#   M16 記録を Keychain へ書く**前**に付ける -> 「順序」の検査が赤
#       ★同時に幸せな道は緑のまま。M2 と同じ形で、間で殺された時だけ壊れる。
#   M17 RootView が鍵を持っていても鍵入力画面を出す -> **UI 検査だけ**が赤
#       ★単体は1本も落ちない。此れが 2026-08-11 に実際に起きた形 —— 種の側を
#         どれだけ単体で固めても、画面まで繋がっている事は単体からは永久に見えない。
#   M18 `clean` が何も落とさない            -> 「未解決の ${…} は種でない」が赤
#   M19 宛先の門(https + host)を外す        -> 「平文の URL は種でない」が赤
#       ★M18/M19 は**両方とも**「整った刻印は種になる」を緑のまま残す。此の2本は
#         `vacuous-gate` が「否定だけ・錨なし」と挙げた6本(①〜⑥)の錨が本当に
#         効くかを測る為に足した —— 錨を足しただけでは、其の錨が働く証拠にならない。
#   M20 保存の失敗を握り潰して記録だけ付ける -> 「書けなかった種は蒔いた事にしない」が赤
#       ★同時に**順序の検査(M16 の的)は緑のまま**。順序を見る対照だけでは、
#         `try?` で握り潰す実装が通る —— 一度きりの保存失敗で、次の起動が入力欄に戻る。
#         此の変異は commit 26d4566 直後まで実際に出荷していた姿そのもの。
#   M27 1枚目を「名乗る面」から**打つ欄**へ戻す -> 「1枚目で値を訊かない」が赤
#       ★2026-08-16(DESIGN §2.100 / REQUIREMENTS §9-5)。Tom が2回「論外」と言った
#         姿そのものを機械で植える。同時に**種が在る電話は一覧に着いたまま**(M17 の的は
#         緑)= 此の変異が入口の面だけを壊している事の証拠。
#         規則ではなく**面**を測る唯一の変異なので、単体は1本も落ちない。
#
# 費用(隠さない): xcodebuild を28回(基準1 + 変異27)。うち7回は UI 検査を含むので重い。
#   ★2026-08-16 に数え直した。「21回(基準1 + 変異20)」と書いてあったが、其の時点で
#     既に probe は26本 —— **費用の見積りが嘘になっていた**(足す度に此処を直していない)。
#   実測値は rc-backend/tools/run-controls.sh の登録行に書く。
#
# ★目印(INFLIGHT)は ios の変異対照で**共有**する。分けると片方の取り残しを
#   もう片方が「走る前の中身」として複製し、復元の基準点ごと汚れる。ズレは
#   rc-backend/test/mutation-recovery-copy.test.mjs が毎 commit 測る。
#
# 終了コード: 0=全変異が期待通り赤 / 1=赤くならない検査が在る / 2=測れなかった
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # = ios/
ROOT="$(cd "$HERE/.." && pwd)"
IOS="$HERE"
# ★機の既定は tools/sim-device.sh が持つ(2026-08-26)。此処で直に dogfood を既定に
#   していた間、`xcodebuild test` が対照のたびに **Tom が見る機**へ種なしの Debug 版を
#   install していた。守りを1箇所へ寄せる —— 既定・dogfood の拒否・機の不在を全部あちらで。
# ★$HERE(= ios/、先頭で絶対解決済み)から引く。BASH_SOURCE を此処で引き直すと、
#   相対 path で起動された時に `cd` 後の評価になって source が空振りする。
. "$HERE/tools/sim-device.sh"
BUNDLE_ID="com.tomarai.remotemini"
# UDID が読めなくても走る(落ち着かせる手順を飛ばすだけ)。此処で止めると、元は
# 動いていた対照を「測れない」に変えてしまう。
SIM_UDID="$(xcrun simctl list devices 2>/dev/null | grep -F "$SIM_NAME (" | head -1 \
    | grep -oE '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}' | head -1)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/signout-notice.XXXXXX")"
LOGDIR="${TMPDIR:-/tmp}"
INFLIGHT="${TMPDIR:-/tmp}/rc-ios-mutation-inflight.tsv"
PASS=0; FAIL=0; UNMEASURED=0

# ★書き換え先は**砂場**(2026-08-30、CF-21 の移行の最後の1本)。
#   作業中の木は1バイトも触らない。此の台本は変異 31 箇所で最大手なので、
#   殺された時に残る量も一番多かった。
. "$IOS/tools/mutation-sandbox.sh"
ms_prepare || exit 2
AS="$MS_TREE/Sources/AppState.swift"
KV="$MS_TREE/Sources/Screens/KeyEntry/KeyEntryView.swift"
KM="$MS_TREE/Sources/Screens/KeyEntry/KeyEntryViewModel.swift"
SN="$MS_TREE/Sources/Core/SignOutNotice.swift"
RV="$MS_TREE/Sources/RootView.swift"
PR="$MS_TREE/Sources/Core/Provisioning.swift"
KC="$MS_TREE/Sources/Core/KeychainCredentialStore.swift"
# ★`Tests/` も砂場側(2026-08-30)。移行の初回は `Sources/` だけを向け直し、
#   此処を取り零した —— 変異が本物の検査 file に当たるのに、ビルドは砂場を読むので
#   **効かない**。対照は其れを「欠陥を植えたのに全部緑」と自己申告して赤くなった
#   (黙って緑にならなかったのが効いた)。しかも作業中の木を書き換えてもいた。
KCT="$MS_TREE/Tests/Core/KeychainCredentialStoreTests.swift"
# ★KCT だけ `Tests/` 側。変異が製品の中にしか植えられないと思い込むと、
#   「検査が製品の項目を消す」型の欠陥は**測る手が無い**(2026-08-15 に実際に起きた)。
TARGETS=("$AS" "$KV" "$KM" "$SN" "$RV" "$PR" "$KC" "$KCT")

# 全部回して緑だった事の**印**(#66、2026-08-12)。commit で変異を繰り延べる様にした
# 以上、「出荷の前に全部回す」を人の記憶に懸けると、記憶に懸けた守りは1日で戻る
# (此の repo が 2026-08-06 に実測した)。だから機械が言える形にする。
# ★門ではない。`ios/tools/build.sh` が電話へ入れる直前に**警告を出すだけ**
#   (裁定「門をもう増やさない」2026-08-11)。止めるかは人が決める。
# ★印の中身は「其の時に測ったバイト」。commit の sha ではない —— 汚れた木で回した
#   走行を「其の commit で緑だった」と読ませない為。
# ★砂場側へ移した(2026-08-30)。生成木の錠を外したので、`$IOS/build/` へ無施錠で
#   書くと live のビルドと競る。読み手は此の台本だけ(repo 全体を grep して確認)。
STAMP="$MS_ROOT/.mutation-sweep-stamp"
sweep_digest() { # 変異が読む file 群のバイト。1本でも動けば前の全走行は効力を失う
    ( for _t in "${TARGETS[@]}"; do shasum "$_t" 2>/dev/null; done
      /usr/bin/find "$IOS/Tests" "$IOS/UITests" -name '*.swift' -print0 2>/dev/null \
        | LC_ALL=C sort -z | /usr/bin/xargs -0 shasum 2>/dev/null
    ) | shasum | awk '{print $1}'
}
# ★出荷の口(`ios/tools/build.sh`)は此処に**訊く**。向こうで同じ式を書くと、
#   digest の実装が2本になって黙って食い違う —— 食い違った時に出るのは「印が古い」
#   という**嘘の警告**で、本物の腐りと見分けが付かなくなる。
#   一覧は此の file の `TARGETS` 1本のまま(`staged-controls-gate.sh --would-select` と同じ手)。
if [ "${1:-}" = "--sweep-digest" ]; then
    printf '%s\n' "$(sweep_digest)"
    printf '%s\n' "$STAMP"
    exit 0
fi

# ---- commit では変異を繰り延べる(#66、2026-08-12)-----------------------------
# 何故: `ios/` を触る commit 1本が 20〜25分で、其の殆どが此の対照(実測 725秒)。
# 中身は**別物が2つ**束ねてあり、要る頻度が違う:
#
#   基準(ビルド1回、約35秒) …… ios の検査一式が緑 + 錨22本が実在して緑。
#                                 **commit 毎に要る**(ios の commit 時検証は此れだけ)
#   変異20本(約690秒)       …… 錨に**歯が在る**か = 計器そのものの証明。
#                                 鈍るのは検査を書き換えた時なので、頻度は commit ではなく**出荷**
#
# ★最初は「変わった面の変異だけ回す」形で書いた。**Codex に否定されて捨てた**(2026-08-12)。
#   変異の sed 対象は**欠陥を注入する点**であって、同じ欠陥が**発生し得る file の集合**では
#   ない。実例: `ios/Sources/Core/Provisioning.swift` には `SeedDigest` /
#   `UserDefaultsSeedLedger` / `BundleProvisioning` が同居していて、其処の1行が
#   M13-M16/M20 の測る欠陥(= #64 そのもの)を混入できるのに、file で選ぶと M18/M19 しか
#   選ばれない。健全にするには継ぎ目を変異ごとに宣言する事になり、其れは黙って古くなる
#   **2本目の一覧** —— 作らないと決めた物。だから狭めずに**繰り延べる**。
#
# ★繰り延べは「回さなかった」であって「緑」ではない。毎回名前で言う。
#   同じ形が既に此の repo に在る(`staged-controls-gate.sh` の edith 側の対照)。
# ★計器そのもの / ビルドの土台が staged の時は繰り延べない —— 其の commit の目的が
#   計器の証明なので、繰り延べたら証明が消える。
DRY=0
[ "${1:-}" = "--which" ] && DRY=1

SELF_REL="ios/tools/signout-notice-control.sh"
DEFER=0
STAGED_IOS=""
DEFERRED=""
DEFERRED_N=0
RAN_N=0

_rel() { printf '%s' "${1#"$ROOT/"}"; }
_has_line() { # $1=改行区切りの一覧 $2=探す行
    case "
$1
" in *"
$2
"*) return 0 ;; esac
    return 1
}

# 繰り延べの結果を言う口は**1つだけ**。本番と `--which` で別々に書くと、片方だけを
# 測った対照が「印字している」と言い、もう片方が黙って分母を痩せさせる。
# ★0 本繰り延べた時も言う —— 「繰り延べが効いていない」と「繰り延べた結果0本」は
#   別の話で、後者を黙ると前者と見分けが付かない。
defer_summary() { # $1=回した変異の本数 $2=繰り延べた本数
    if [ "$DEFER" -eq 1 ]; then
        printf -- '--- 変異: 回す %s 本 / 繰り延べ %s 本(commit では繰り延べる) ---\n' "$1" "$2"
        echo "  繰り延べた変異:${DEFERRED:- なし}"
        echo "  ★繰り延べた分は**緑ではない**(回していない)。基準(検査一式 + 錨の実在)は上で回した。"
        echo "  出荷の前に全部回す事:"
        echo "    bash ios/tools/signout-notice-control.sh      # 単体(本数は --which で出る)"
        echo "    bash rc-backend/tools/run-controls.sh --all   # 全掃き"
    else
        printf -- '--- 変異: 回す %s 本 / 繰り延べ %s 本(繰り延べなし = 全部回す) ---\n' "$1" "$2"
    fi
}

# 基準で緑である事を確かめる的。**件数ではなく実名**で錨を打つ(数を発明しない)。
WANT_LEFT=testA401LeavesAReasonBehindRatherThanJustDroppingTheKey
WANT_ORDER=testTheNoticeIsWrittenBeforeTheKeychainIsCleared
WANT_SWEEP=testAStaleNoticeIsSweptWhenCredentialsAreStillThere
WANT_CARRIED=testTheViewBuiltWithANoticeCarriesTheSentence
WANT_SENTENCE=testWithAURLTheSentenceExplainsWhyTheFieldIsAlreadyFilled
WANT_TWO=testWithoutAURLTheSentenceDoesNotClaimTheFieldWasFilled
WANT_DISK=testANoticeSurvivesTheObjectThatWroteIt
WANT_NOKEY=testTheRejectedKeyIsNotBroughtBackWithTheURL
WANT_SCREEN=testTheRejectedKeyNoticeIsActuallyOnTheScreen
# (b) 「確かめています」の側。
WANT_STAGES=testEachStageSaysWhichStageItIsWhileItIsRunning
WANT_TIMEOUT=testTheSentencesAreBuiltFromTheTimeoutTheyAreGiven
WANT_INFLIGHT=testTheURLStageSaysWhatItIsWaitingFor
WANT_LOCKED=testTheFieldsCannotBeEditedWhileAStageIsRunning
WANT_LOCKED_UNIT=testTheFieldsStayLockedAcrossBothStages
# (c) 焼き込んだ種の側。
WANT_SEEDED=testAnEmptyKeychainIsSeededFromTheStampSoTheFirstScreenIsNotTheForm
WANT_ONCE=testARejectedSeedIsNotPlantedAgainOnTheNextLaunch
WANT_UNREADABLE=testAnUnreadableKeychainIsNotTreatedAsEmpty
WANT_SEED_ORDER=testTheRejectionIsRecordedBeforeTheKeychainIsCleared
WANT_SEED_FAIL=testASeedThatCouldNotBeSavedIsPlantedAgainOnTheNextLaunch
WANT_FIRSTRUN=testAProvisionedPhoneReachesTheListWithoutBeingAskedToTypeAnything
# 2026-08-16(§9-5)。**1枚目で値を訊かない**を測る側。M27 の的。
WANT_NO_FORM=testTheFirstScreenNeverAsksForAValueEvenWithoutASeed
# ★2026-08-15 の反転(台帳が覚える物を「蒔いた種」→「拒まれた種」)で生えた枝4本。
#   枝を足して変異を足さないと、`orphan-instrument-scan` の言う「対照の無い分岐」が
#   増える —— 単体は緑でも、其の枝を消した実装が此の計器に映らなくなる。
WANT_SEED_SWEEP=testARejectedKeyLeftInTheKeychainIsSweptOnLaunch
WANT_STALE_401=testA401ForAKeyThatIsNoLongerInUseIsIgnored
WANT_SEED_UNBLOCK=testAKeyThatWorksAgainClearsTheRejection
WANT_SEED_ONLY=testARejectedHandTypedKeyIsNotRecordedInTheLedger
# 刻印の**形**を落とす側(M18/M19)。整った刻印は種になる、を同じ検査の中で錨にしてある。
WANT_ISOLATED=testTheseTestsAddressADifferentKeychainItemThanTheProduct
WANT_PINNED=testTheProductionItemKeepsTheCoordinatesAlreadyInstalledOnThePhone
WANT_ROUNDTRIP=testSaveThenLoadRoundTrips

WANT_TEMPLATE=testAnUnresolvedTemplateIsNotASeed
WANT_PLAINTEXT=testAPlaintextURLIsNotASeed

# 錨の一覧。**本数を手で書かない**(2026-08-11、#64)。前の版は下の報告文に `21本` と
# 直書きしていて、此処へ1本足した人が報告文を知らない = 数が黙って嘘になる形だった。
# 同じ日に `extract()` の class 一覧でも踏んだ、写しが2つ在る型。
# ★2026-08-12(#66): 基準の確認と**面の絞り込みの両方**が此の一覧を読む。定義を
#   走行の途中(基準の中)から此処へ上げたのは、絞りの判定が基準より先に要る為。
WANTS="$WANT_LEFT $WANT_ORDER $WANT_SWEEP $WANT_CARRIED $WANT_SENTENCE
       $WANT_TWO $WANT_DISK $WANT_NOKEY $WANT_SCREEN
       $WANT_STAGES $WANT_TIMEOUT $WANT_INFLIGHT $WANT_LOCKED $WANT_LOCKED_UNIT
       $WANT_SEEDED $WANT_ONCE $WANT_UNREADABLE $WANT_SEED_ORDER $WANT_SEED_FAIL $WANT_FIRSTRUN
       $WANT_SEED_SWEEP $WANT_STALE_401 $WANT_SEED_UNBLOCK $WANT_SEED_ONLY
       $WANT_ISOLATED $WANT_PINNED $WANT_ROUNDTRIP
       $WANT_TEMPLATE $WANT_PLAINTEXT"
WANT_N="$(printf '%s' "$WANTS" | wc -w | tr -d ' ')"

# ---- 繰り延べるか否か(#66)---------------------------------------------------
# 判定は3つだけ。**staged の中身で変異を選り分けない**(選り分けが不健全な理由は上）。
if [ -n "${RC_STAGED_FILES:-}" ]; then
    STAGED_IOS="$(printf '%s\n' "$RC_STAGED_FILES" | grep -E '^ios/')" || STAGED_IOS=""
    DEFER=1
    # ★計器そのもの = 此の commit の目的が計器の証明。繰り延べたら証明が消える。
    _has_line "$STAGED_IOS" "$SELF_REL"           && DEFER=0
    # ★ビルドの土台。全変異のビルドに効くので、壊れたら変異の走行自体が意味を失う。
    _has_line "$STAGED_IOS" "ios/project.yml"     && DEFER=0
    _has_line "$STAGED_IOS" "ios/tools/build.sh"  && DEFER=0
fi

ORIG="$WORK/orig"
mkdir -p "$ORIG"
snap_path() { printf '%s/%s' "$ORIG" "$1"; }   # $1 = TARGETS の添字

restore_one() { # $1 = 添字
    # ★`local i="$1" f="${TARGETS[$i]}"` と1行に書かない事。bash は local の右辺を
    #   全部展開してから代入するので、`$i` は引数ではなく**呼び出し元の i** を読む。
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
    # 目印は復元より**後**に消す。逆だと、消した直後に殺された時に
    # 「戻っていないのに手掛かりも無い」状態が作れる。
    /bin/rm -f "$INFLIGHT"
    [ -n "${WORK:-}" ] && [ -d "$WORK" ] || return 0
    find "$WORK" -type f -print0 2>/dev/null | xargs -0 /bin/rm -f 2>/dev/null
    find "$WORK" -type d -depth -exec /bin/rmdir {} + 2>/dev/null
}
# ★生成物(ios/Info.plist / RemoteMini.xcodeproj)を触る走行を **1 本に絞る**。
# 2026-08-15、此れが無くて `build.sh --sim` と此の台本が `RC_BUILD_REV` の刻印を
# 潰し合い、**偽の赤が 9 本**出た(製品の欠陥と見分けが付かない赤)。
# 取れなければ此処で非零終了する = 生成物に触らないまま止まる。
# ★生成木の錠は要らない(砂場で焼くので生成木を触らない)。直列化は砂場側の錠が持つ。
trap 'cleanup; ms_release' EXIT

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

# 複製が取れない = 復元できない = 走ってはいけない。此処だけは走る前に止める。
i=0
while [ "$i" -lt "${#TARGETS[@]}" ]; do
    f="${TARGETS[$i]}"
    if [ ! -f "$f" ]; then
        echo "UNMEASURED  変異の対象が無い: ${f#$ROOT/}"
        exit 2
    fi
    if ! /bin/cp "$f" "$(snap_path "$i")"; then
        echo "UNMEASURED  複製を取れなかった: ${f#$ROOT/}(復元手段が無いので走らない)"
        exit 2
    fi
    i=$((i+1))
done

# 複製が全部取れた**後**に目印を書く。先に書くと、複製に失敗して exit 2 した回が
# 「戻せる複製が在る」と嘘の申告を残す。
: > "$INFLIGHT"
i=0
while [ "$i" -lt "${#TARGETS[@]}" ]; do
    printf '%s\t%s\n' "${TARGETS[$i]}" "$(snap_path "$i")" >> "$INFLIGHT"
    i=$((i+1))
done

restore_all() {
    local j=0
    while [ "$j" -lt "${#TARGETS[@]}" ]; do
        restore_one "$j"
        j=$((j+1))
    done
}

ok() { PASS=$((PASS+1)); echo "  OK   $1"; }
ng() { FAIL=$((FAIL+1)); echo "  NG   $1"; }
un() { UNMEASURED=$((UNMEASURED+1)); echo "  UNM  $1"; }

# 走った検査の本数。0 = **一度も走っていない**(ビルドが通らない / simulator が
# 起動を拒んだ、のどちらも此処に落ちる)。赤緑の別を見ない事に意味が在る ——
# 取り直しの判断がこの値**しか**見ないので、落ちた assertion を取り直しに
# 流用できる形が構造上作れない。
ran_count() { # $1 = log path
    local n
    n="$(grep -cE "Test Case '-\[RemoteMini(UI)?Tests\." "$1" 2>/dev/null)" || n=0
    printf '%s' "${n:-0}"
}

# 前の走行の app が終了しきる前に次の launch が来ると、SpringBoard が preflight を
# Busy で蹴る。UDID が読めなければ何もしない(上記)。
settle_sim() {
    [ -n "${SIM_UDID:-}" ] || return 0
    xcrun simctl terminate "$SIM_UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
}

# 単体の class 群。UI 検査は含めない(速い方)。**本数を書かない** —— 下の
# `CLASS_ALT` は此の一覧から導出しており、数は `--which` と基準の印字が言う。
# ★ProvisioningTests を 2026-08-11 に足した。足す前は17本の変異が**一度も**此の class を
#   走らせておらず、刻印の形を落とす門(`clean` / scheme+host)を壊す変異は
#   どの probe にも映らなかった。「対照が在る」と「その対照を走らせている」は別。
# ★KeychainCredentialStoreTests を 2026-08-15 に足した。**足せる様になったのが先**で、
#   其れまで此の class は `setUp`/`tearDown` の `clear()` が製品の項目を消していたので、
#   変異の度に走らせる = simulator の資格情報を毎回消す事だった。座標を分けた今は
#   別の項目しか触らない。
UNIT_ONLY="-only-testing:RemoteMiniTests/AppStateTests \
-only-testing:RemoteMiniTests/SignOutNoticeStoreTests \
-only-testing:RemoteMiniTests/KeyEntryViewTests \
-only-testing:RemoteMiniTests/KeyEntryViewModelTests \
-only-testing:RemoteMiniTests/ProvisioningTests \
-only-testing:RemoteMiniTests/KeychainCredentialStoreTests \
-only-testing:RemoteMiniTests/DisconnectedViewTests"

# UI の class も**変数で一度だけ**名乗る。runner が字面で書くと、下の extract() が
# 持つ一覧と2つ目の写しになる。
UI_KEYENTRY="RemoteMiniUITests/KeyEntryUITests"
UI_FIRSTRUN="RemoteMiniUITests/FirstRunUITests"

# 1回の走行に掛ける上限(秒)と、上限で殺された時の終了コード(= 128 + SIGALRM(14))。
#
# ★上限が要る理由(2026-08-15、実測、DESIGN §2.96)。変異は「其の振る舞いを消す」物なので、
#   検査の側が**其の振る舞いの発生を期限なしに待って**いると、変異を植てた木で
#   誰も起こさない事象を永久に待つ。`account-ui-control.sh` の A3 で実際に起き、
#   `xcodebuild` が 16分26秒 生きたまま log に赤も出さなかった。
#   此の台本も pre-commit の門の中で回るので、吊れば commit が永久に返らない。
#   上限を置くと其れが `UNMEASURED`(= commit を止める)に変わる。緑には決してならない。
#   値: 変異1本あたりの実測は約29秒。冷えた最初のビルドが数分掛かるので 20 分。
CONTROL_RUN_LIMIT_S="${CONTROL_RUN_LIMIT_S:-1200}"
LIMIT_RC=142

xcb() { # $1 = log, 残り = -only-testing 群
    local log="$1" rc=0
    shift
    # macOS に GNU timeout は無いので `perl -e alarm` + `exec`。診断は log にだけ書く
    # (stdout は rc 専用 —— 下の ★ を参照)。
    # ★砂場で焼く。derived data も砂場側(固定 path なので温かいまま)。
    ( cd "$MS_TREE" && xcodegen generate >/dev/null 2>&1 && \
      /usr/bin/perl -e 'alarm shift; exec @ARGV or exit 127' "$CONTROL_RUN_LIMIT_S" \
        xcodebuild -project RemoteMini.xcodeproj -scheme RemoteMini -configuration Debug \
        -sdk iphonesimulator -destination "platform=iOS Simulator,name=$SIM_NAME" \
        -derivedDataPath "$MS_ROOT/build" "$@" test ) >"$log" 2>&1 || rc=$?
    if [ "$rc" = "$LIMIT_RC" ]; then
        printf '\n[control] 上限 %s 秒で打ち切った(= 走行が返らなかった。期限の無い待ちを疑う)\n' \
            "$CONTROL_RUN_LIMIT_S" >>"$log"
    fi
    printf '%s' "$rc"
}

# ★診断を stdout に書かない事。呼び出し側は `rc=$(run_… )` で**標準出力を
#   そのまま rc として読む**ので、1行混ぜるだけで rc が壊れて全部の probe が狂う。
# ★zsh ではなく bash で走る(shebang)ので、引用しない $UNIT_ONLY は単語分割される。
run_unit() { # $1 = log path -> rc を印字
    local log="$1" rc
    settle_sim
    rc="$(xcb "$log" $UNIT_ONLY)"
    if [ "$(ran_count "$log")" -eq 0 ]; then
        echo "     (検査が1本も走っていない = 測定が起きていない。app を落として1度だけ取り直す)" >&2
        settle_sim
        rc="$(xcb "$log" $UNIT_ONLY)"
    fi
    printf '%s' "$rc"
}

# 単体4 class + 画面の検査。M8/M9 は画面まで届かないと測れない。
run_screen() { # $1 = log path -> rc を印字
    local log="$1" rc
    settle_sim
    rc="$(xcb "$log" $UNIT_ONLY -only-testing:$UI_KEYENTRY)"
    if [ "$(ran_count "$log")" -eq 0 ]; then
        echo "     (検査が1本も走っていない = 測定が起きていない。app を落として1度だけ取り直す)" >&2
        settle_sim
        rc="$(xcb "$log" $UNIT_ONLY -only-testing:$UI_KEYENTRY)"
    fi
    printf '%s' "$rc"
}

# 単体4 class + 初回起動の画面。M17 は此れでしか測れない。
run_firstrun() { # $1 = log path -> rc を印字
    local log="$1" rc
    settle_sim
    rc="$(xcb "$log" $UNIT_ONLY -only-testing:$UI_FIRSTRUN)"
    if [ "$(ran_count "$log")" -eq 0 ]; then
        echo "     (検査が1本も走っていない = 測定が起きていない。app を落として1度だけ取り直す)" >&2
        settle_sim
        rc="$(xcb "$log" $UNIT_ONLY -only-testing:$UI_FIRSTRUN)"
    fi
    printf '%s' "$rc"
}

# 基準だけは**両方**の UI class を走らせる。錨(WANT_*)は `$WANT_N` 本在り、其のうち
# WANT_FIRSTRUN は FirstRunUITests にしか居ない —— 基準で緑を見ていない名前を
# 変異の側で「赤くなった」と読むと、元から赤かった物を成果に数える事になる。
run_base() { # $1 = log path -> rc を印字
    local log="$1" rc
    settle_sim
    rc="$(xcb "$log" $UNIT_ONLY -only-testing:$UI_KEYENTRY \
          -only-testing:$UI_FIRSTRUN)"
    if [ "$(ran_count "$log")" -eq 0 ]; then
        echo "     (検査が1本も走っていない = 測定が起きていない。app を落として1度だけ取り直す)" >&2
        settle_sim
        rc="$(xcb "$log" $UNIT_ONLY -only-testing:$UI_KEYENTRY \
              -only-testing:$UI_FIRSTRUN)"
    fi
    printf '%s' "$rc"
}

# ★module 名まで付けた形で探す事。log の行は `-[RemoteMiniTests.AppStateTests …]` /
#   `-[RemoteMiniUITests.KeyEntryUITests …]` で、class 名だけで grep すると跨いだ時に取りこぼす。
#
# ★class の一覧は**走らせている引数から機械で取る**(2026-08-11)。此処は元々
#   6つを字面で持っており、`ProvisioningTests` を UNIT_ONLY へ足した時に**此方だけ
#   古いまま**になった —— 10本が緑で走っているのに scanner から見えず、基準の
#   錨チェックが「緑になっていない」と正しく止めた。写しを2つ持つと、片方を直した
#   人がもう片方の存在を知らない。**一覧は1つ、残りは導出。**
CLASS_ALT="$(
    { printf '%s\n' $UNIT_ONLY | sed -n 's|^-only-testing:RemoteMini\(UI\)\{0,1\}Tests/||p'
      printf '%s\n' "$UI_KEYENTRY" "$UI_FIRSTRUN" | sed 's|^RemoteMini\(UI\)\{0,1\}Tests/||'
    } | sort -u | paste -sd'|' -
)"
extract() { # $1 = log, $2 = passed|failed
    grep -oE "Test Case '-\[RemoteMini(UI)?Tests\.($CLASS_ALT) [a-zA-Z0-9_]+\]' $2" "$1" \
        | sed -E "s/^.*Tests ([a-zA-Z0-9_]+)\].*$/\1/" | sort -u | tr '\n' ' '
}
passed_tests() { extract "$1" passed; }
failed_tests() { extract "$1" failed; }

has() { # $1 = 空白区切りの一覧, $2 = 名前
    case " $1 " in *" $2 "*) return 0 ;; *) return 1 ;; esac
}

# ★`--which`(#66、2026-08-12)= **選択だけ**見せて1本も回さない口。
#   何故要るか: 選択が正しいかを測るのに本番を回すと xcodebuild が21回(基準+変異20)で
#   12分待つ事になり、**測る事自体をやめる**。狭める変更を入れる以上、其の当たり外れを
#   安く何度でも測れる口が同じ commit に要る。
#   ★判定の道は本番と完全に共有する —— 繰り延べの可否は probe() の中の同じ `$DEFER` 1箇所
#     だけで、此の口は「回すか」を差し替えない。別実装を持たない事が此の口の条件
#     (`staged-controls-gate.sh` の `--would-select` / `--list` と同じ規律)。
#   ★基準の走行も飛ばす。基準は「錨が今も緑か」を測る物で、選択とは無関係。
if [ "$DRY" -eq 0 ]; then
    echo "=== 基準(変異なし)"
    BASE_LOG="$LOGDIR/signout-notice-base.log"
    rc=$(run_base "$BASE_LOG")
    if [ "$(ran_count "$BASE_LOG")" -eq 0 ]; then
        un "基準で検査が一度も走っていない(2度試して 0 本)= 機械の側が動いていない。実装については何も測っていない。全文: $BASE_LOG"
        echo "--- 合計: PASS $PASS / FAIL $FAIL / UNMEASURED $UNMEASURED ---"
        exit 2
    fi
    if [ "$rc" = "$LIMIT_RC" ]; then
        un "基準が上限 ${CONTROL_RUN_LIMIT_S} 秒で打ち切られた(= 走行が返らなかった)。全文: $BASE_LOG"
        echo "--- 合計: PASS $PASS / FAIL $FAIL / UNMEASURED $UNMEASURED ---"
        exit 2
    fi
    if [ "$rc" -ne 0 ]; then
        un "基準が緑でない(rc=$rc)。以降は測れない。全文: $BASE_LOG"
        echo "--- 合計: PASS $PASS / FAIL $FAIL / UNMEASURED $UNMEASURED ---"
        exit 2
    fi
    BASE_PASSED="$(passed_tests "$BASE_LOG")"

# 錨の一覧。**本数を手で書かない**(2026-08-11、#64)。前の版は下の報告文に `21本` と
# 直書きしていて、此処へ1本足した人が報告文を知らない = 数が黙って嘘になる形だった。
# 同じ日に `extract()` の class 一覧でも踏んだ、写しが2つ在る型。
    # ★狭めても此処は**全部**確かめる。基準は「錨が今も実在して緑か」を測る物で、
    #   面で絞るのは「其の錨を壊してみるか」の側。改名・削除・赤は狭めても捕まる。
    for w in $WANTS; do
        if ! has "$BASE_PASSED" "$w"; then
            un "基準で的の検査が緑になっていない: $w"
            echo "    (基準の緑は $(printf '%s' "$BASE_PASSED" | wc -w | tr -d ' ') 本。全文: $BASE_LOG)"
            echo "--- 合計: PASS $PASS / FAIL $FAIL / UNMEASURED $UNMEASURED ---"
            exit 2
        fi
    done
    ok "基準: 的の検査が ${WANT_N} 本とも緑(この走行の緑は全部で $(printf '%s' "$BASE_PASSED" | wc -w | tr -d ' ') 本)"
fi

# ---- 変異 M1: 401 が何も残さない(直す前の姿) ---------------------------------
# 断りを disk にも memory にも置かない。鍵だけ捨てて白紙の画面に戻る、元の欠陥そのもの。
mutate_m1() {
    /usr/bin/sed -i '' '/func clearCredentials/,/^    }$/ { /^        notices.save(notice)$/d; /^        signOutNotice = notice$/d; }' "$AS"
}
# ---- 変異 M2: 断りを Keychain の後に書く --------------------------------------
# 断りは最後には残るので「残す」検査は緑のまま。間で殺された時だけ白紙に戻る、
# 順序を見る検査にしか映らない欠陥。
mutate_m2() {
    /usr/bin/sed -i '' '/func clearCredentials/,/^    }$/ { /^        notices.save(notice)$/d; }' "$AS"
    /usr/bin/sed -i '' '/func clearCredentials/,/^    }$/ s|^        try? store.clear()$|        try? store.clear(); notices.save(notice)|' "$AS"
}
# ---- 変異 M3: 起動時に古い断りを掃かない --------------------------------------
mutate_m3() {
    /usr/bin/sed -i '' '/func loadStoredCredentials/,/^    }$/ { /^            notices.save(nil)$/d; }' "$AS"
}
# ---- 変異 M4: init が notice を捨てる -----------------------------------------
mutate_m4() {
    /usr/bin/sed -i '' 's|^        self.noticeText = Self.sentence(for: notice)$|        self.noticeText = nil|' "$KV"
}
# ---- 変異 M5: 2文を1文に畳む --------------------------------------------------
# URL が無くても「URL は前のまま入れてあります」と言う版。空欄を前にして
# 入っていない物を探させる。
mutate_m5() {
    /usr/bin/sed -i '' 's|^            if notice.baseURL != nil {$|            if true {|' "$KV"
}
# ---- 変異 M6: disk に書かない金庫 ---------------------------------------------
mutate_m6() {
    /usr/bin/sed -i '' 's|^        defaults.set(data, forKey: Self.storageKey)$|        _ = data|' "$SN"
}
# ---- 変異 M7: 拒まれた鍵まで欄に戻す ------------------------------------------
mutate_m7() {
    /usr/bin/sed -i '' 's|^        self.baseURLText = initialBaseURL?.absoluteString ?? ""$|        self.baseURLText = initialBaseURL?.absoluteString ?? ""; self.apiKeyText = initialBaseURL == nil ? "" : "rejected-key"|' "$KM"
}
# ---- 変異 M8: body が節を描かない ---------------------------------------------
# 文は init が握ったまま、画面には出ない。単体からは永久に見えない一歩。
mutate_m8() {
    /usr/bin/sed -i '' 's|^            if let noticeText {$|            if let noticeText, noticeText.isEmpty {|' "$KV"
}
# ---- 変異 M9: RootView が notice を渡さない -----------------------------------
# ★探し文は 2026-08-08(監査 X2-8)に付け直した。同じ行に `clients:` が入った日、
#   古い探し文は静かに当たらなくなる —— それは probe の shasum 検査が UNMEASURED で
#   捕まえる形なので、赤を緑と読む事にはならない。
# ★2026-08-16(DESIGN §2.100)に付け直した2度目。鍵の無い起動の1枚目が
#   `KeyEntryView` から `DisconnectedView` に変わり、`notice:` は引数の1行になった。
#   断りは今も **1枚目の文**と、退避路の奥の**節**の両方に効くので、落とせば
#   `KeyEntryUITests` が赤になる(奥の節が消える)。
mutate_m9() {
    /usr/bin/sed -i '' 's|^                notice: appState.signOutNotice,$|                notice: nil,|' "$RV"
}
# ---- 変異 M10: 2段目の文を1段目の文に差し替える -------------------------------
# 文そのものは2つとも正しいまま。**段との結び**だけを壊す。畳んだ実装
# (どちらの段でも同じ事を言う)と観測上まったく同じ姿になる。
mutate_m10() {
    /usr/bin/sed -i '' 's|^            return Self.keyProbeInFlightText(timeout: BackendSession.interactiveTimeout)$|            return Self.urlProbeInFlightText(timeout: BackendSession.interactiveTimeout)|' "$KM"
}
# ---- 変異 M11: footer が一文を描かない ----------------------------------------
# `inFlightText` は正しく段ごとの文を返し続ける。画面に出ないだけ ——
# 直す前の「押してから最大16秒空白」がそっくり戻る。
mutate_m11() {
    /usr/bin/sed -i '' 's|^                if let inFlight = viewModel.inFlightText {$|                if let inFlight = viewModel.inFlightText, inFlight.isEmpty {|' "$KV"
}
# ---- 変異 M12: 確かめている間も欄が打てる -------------------------------------
# 2行(URL 欄と鍵欄)を同時に外す。片方だけ外す版は「もう片方が守っている」と
# 読めてしまい、欠陥として弱い。
mutate_m12() {
    /usr/bin/sed -i '' 's|^                    .disabled(viewModel.isChecking)$|                    .disabled(false)|' "$KV"
}
# ---- 変異 M13: 種を蒔かない(2026-08-11 に Tom が見た画面そのもの)---------------
# 焼き込みは在るのに、空の Keychain を埋めない。初回起動が Base URL と API Key の
# 入力欄になる —— 直す前の姿。
mutate_m13() {
    /usr/bin/sed -i '' 's|^            stored = plantSeedIfNeeded()$|            stored = nil|' "$AS"
}
# ---- 変異 M14: 指紋の門を外す(毎回蒔く)---------------------------------------
# 幸せな道(空の Keychain が埋まる)は緑のまま。401 で捨てた鍵を次の起動で蒔き直し、
# 電話が「拒まれる鍵 -> 断り -> 同じ鍵」で回り続ける形だけが壊れる。
mutate_m14() {
    /usr/bin/sed -i '' '/^        guard seedLedger.rejectedSeedDigest != SeedDigest.of(seed) else { return nil }$/d' "$AS"
}
# ---- 変異 M15: 「読めなかった」を「空」に潰す ---------------------------------
# `try? store.load()` へ戻すのと同じ意味。Keychain が一時的に読めない起動で、
# Tom が手で入れた鍵を焼き込みの種が上書きする。
mutate_m15() {
    /usr/bin/sed -i '' 's|^        if stored == nil \&\& storeIsReadable {$|        if stored == nil {|' "$AS"
}
# ---- 変異 M16: 拒否の記録を Keychain を消した**後**に回す ---------------------
# 落ち着いた時の結果は同じなので、順序を見る検査にしか映らない。間で殺されると
# 「金庫は空 + 拒否の記録は無い」に落ち、次の起動が**拒まれたばかりの種を蒔き直す**
# = M14 が塞いだ輪が、殺され方1つで復活する。
#
# ★2026-08-15 に向きが変わった。#56 までの M16 は「蒔いた記録を保存より先に付ける」で、
#   台帳が「蒔いた種」を覚えていた頃の形。反転で其の手その物が消えた(⑭が
#   「台帳を一文字も触らない」を固定している)ので、順序の欠陥は拒否側にだけ在る。
mutate_m16() {
    /usr/bin/sed -i '' 's|^        notices.save(notice)$|        notices.save(notice); try? store.clear()|' "$AS"
    /usr/bin/sed -i '' '/^        try? store.clear()$/d' "$AS"
}
# ---- 変異 M20: 保存の失敗を拒否として記録する ---------------------------------
# 401 は起きていないのに、書けなかった種の指紋を台帳へ書く。幸せな道(空の Keychain が
# 埋まる)は緑のまま —— catch を通らないから。壊れるのは⑮だけで、一度きりの保存失敗が
# 次の起動から種の道を**恒久的に**塞ぐ = 電話が鍵の入力欄に戻って二度と出られない。
mutate_m20() {
    /usr/bin/sed -i '' 's|^            return seed$|            seedLedger.rejectedSeedDigest = SeedDigest.of(seed); return seed|' "$AS"
}
# ---- 変異 M21: 拒まれた鍵の掃除を外す -----------------------------------------
# `clearCredentials(rejected:)` の途中(台帳へ書いた後、金庫を消す前)で殺された電話が
# 起動する度に 401 を貰う。拒否を覚えているのに拒まれた鍵で繋ぎに行く形。
mutate_m21() {
    /usr/bin/sed -i '' 's|^        if let value = stored, SeedDigest.of(value) == seedLedger.rejectedSeedDigest {$|        if stored == nil, stored != nil {|' "$AS"
}
# ---- 変異 M22: 古い要求の 401 で今の鍵を落とす --------------------------------
# 引数を見ずに `self.credentials` を落とす版と同じ意味。鍵を打ち直した直後に前の鍵の
# 401 が届くと、使えている鍵が捨てられ、束の種まで「拒まれた」と記録される。
mutate_m22() {
    /usr/bin/sed -i '' '/^        guard credentials == rejected else { return }$/d' "$AS"
}
# ---- 変異 M23: 通った鍵の拒否を降ろさない -------------------------------------
# 机側で鍵を戻しても、種の道だけが塞がったまま残る。**打てば動く**ので、
# 塞がっている事に気付く機会が無いのが此の欠陥の質。
mutate_m23() {
    /usr/bin/sed -i '' 's|^        if SeedDigest.of(credentials) == seedLedger.rejectedSeedDigest {$|        if false {|' "$AS"
}
# ---- 変異 M24: 種かどうか見ずに拒否を記録する ---------------------------------
# 手で打った鍵の拒否まで台帳に載る。止める先が無い指紋が `UserDefaults` に残るだけ。
mutate_m24() {
    /usr/bin/sed -i '' 's|^        if provisioning.seed == rejected {$|        if true {|' "$AS"
}
# ---- 変異 M17: 鍵を持っていても鍵入力画面を出す -------------------------------
# `isLoadingCredentials` は此処では必ず false なので、資格情報が在っても else に落ちる。
# 種の側は単体で全部緑のまま —— **画面まで繋がっている事**だけが壊れる。
mutate_m17() {
    /usr/bin/sed -i '' 's|^        } else if let credentials = appState.credentials {$|        } else if let credentials = appState.credentials, appState.isLoadingCredentials {|' "$RV"
}
# ---- 変異 M27: 1枚目を打つ欄へ戻す --------------------------------------------
# 2026-08-16。`DisconnectedView`(名乗る面)を消して、鍵の無い起動が**いきなり
# Base URL と API Key の欄**から始まる姿へ戻す = Tom が2回「論外」と言った形。
# 単体は1本も落ちない —— 落ちるのは画素を見る `FirstRunUITests` だけ。
mutate_m27() {
    /usr/bin/sed -i '' '/^            DisconnectedView($/,/^            )$/c\
            KeyEntryView(clients: keyEntryClients, notice: appState.signOutNotice, onSaved: appState.setCredentials)
' "$RV"
}

# ---- 変異 M18: `clean` が何も落とさない(もっともらしい文字列を種にする)-------
# `${RC_BASE_URL}` も空文字も、そのまま種として通る。★**整った刻印は種のまま**なので
# 「空の Keychain が埋まる」側は緑 —— 壊れるのは「半端な刻印を蒔かない」だけ。
# 2026-08-11 に此れを足したのは、否定だけの検査6本が `seed` の全否定でしか
# 赤くならず、`vacuous-gate` に「錨なし」と挙げられた為。錨を足した証明が此処。
mutate_m18() {
    /usr/bin/sed -i '' '/^        if trimmed.contains("${") { return nil }$/d' "$PR"
    /usr/bin/sed -i '' '/^        if trimmed.isEmpty { return nil }$/d' "$PR"
}
# ---- 変異 M19: 宛先の門(https + host)を外す ----------------------------------
# `http://` も `desk.invalid`(scheme 無し)も通る。此方も整った刻印は種のまま。
mutate_m19() {
    /usr/bin/sed -i '' 's|^        guard let parsed = URL(string: url), parsed.scheme == "https", parsed.host != nil else { return nil }$|        guard let parsed = URL(string: url) else { return nil }|' "$PR"
}

# ---- 変異 M25: 検査の座標を製品と同じに戻す -----------------------------------
# 2026-08-15 の欠陥そのもの。此の class は `setUp`/`tearDown` で `clear()` を呼ぶので、
# 座標を共有した瞬間から「検査を走らせる事」が電話の資格情報を消す操作になる。
# ★此の変異が植わっている間だけ simulator の製品側の項目が消える。反転後の app は
#   次の起動で束の刻印から蒔き直すので自分で戻る —— 戻らない形だったのが #64 の姿。
mutate_m25() {
    /usr/bin/sed -i '' 's|^    private static let testService = "com.tomarai.remotemini.tests.credentials"$|    private static let testService = "com.tomarai.remotemini.credentials"|' "$KCT"
    /usr/bin/sed -i '' 's|^    private static let testAccount = "rc-backend-unit-tests"$|    private static let testAccount = "rc-backend"|' "$KCT"
}
# ---- 変異 M26: 製品側の座標を改名する -----------------------------------------
# 既に入っている電話の項目は旧座標に残り、新しい binary からは見えない = 人が鍵を
# 打ち直すまで戻らない(`provisioning.rejected-seed.v1` を新設した理由と同じ形)。
# ★往復の検査は**どんな座標でも緑**。だから「保存して読めた」を幾ら積んでも
#   此の欠陥は通る —— 其れを $WANT_ROUNDTRIP が緑のままである事で実演する。
mutate_m26() {
    /usr/bin/sed -i '' 's|^    static let productionService = "com.tomarai.remotemini.credentials"$|    static let productionService = "com.tomarai.remotemini.credentials.v2"|' "$KC"
}

probe() { # $1=名前 $2=変異関数 $3=対象file $4=赤くなるべき検査 $5=(任意)緑のままであるべき検査 $6=(任意)走らせ方
    local name="$1" fn="$2" target="$3" want="$4" stays="${5:-}" runner="${6:-run_unit}"
    # ★繰り延べた物は数えて名前を出す(下の締めで印字)。黙って飛ばすと
    #   「PASS n / FAIL 0」の分母が痩せた緑になる。
    if [ "$DEFER" -eq 1 ]; then
        DEFERRED="$DEFERRED $name"
        DEFERRED_N=$((DEFERRED_N+1))
        [ "$DRY" -eq 1 ] && printf '  DEFER %-34s (%s)\n' "$name" "$(_rel "$target")"
        return
    fi
    # ★数えるのは**変異の本数**。本番側で `PASS+FAIL+UNMEASURED` を使っていた時は
    #   基準の緑まで1本に数えており、同じ口が `--which` では 2、本番では 3 と
    #   言っていた(2026-08-12 の実測で発覚)。数が黙って嘘になる形。
    RAN_N=$((RAN_N+1))
    if [ "$DRY" -eq 1 ]; then
        printf '  RUN   %-34s (%s)\n' "$name" "$(_rel "$target")"
        return
    fi
    restore_all
    local before after
    before=$(shasum "$target" | awk '{print $1}')
    "$fn"
    after=$(shasum "$target" | awk '{print $1}')
    # ★バイトが動かない = 探し文が今の本文に当たらない(改名・整形で静かに外れる)。
    #   これを緑にすると「変異を植えても赤くならない」を「検査が強い」と読む事になる。
    if [ "$before" = "$after" ]; then
        un "$name: 変異が当たっていない(bytes が動かない)= 測っていない。探し文を付け直す事"
        return
    fi
    local log="$LOGDIR/signout-notice-$name.log" rc
    rc=$("$runner" "$log")
    # ★「走っていない」を「捕まえられなかった」と混ぜない。混ぜると、探し文が
    #   当たっているのに探し文を疑いに行く事になる。
    if [ "$(ran_count "$log")" -eq 0 ]; then
        un "$name: 検査が一度も走っていない(2度試して 0 本)= 変異の当たり外れは測っていない。全文: $log"
        restore_all
        return
    fi
    # ★上限で打ち切られた走行は、赤の名前が合っていても `OK` にしない。打ち切りより
    #   前に的が赤くなっていれば `has` は真になるが、其の走行は**途中で止まっている**ので
    #   「変異を植えたら此の検査だけが赤くなる」を測れていない。
    if [ "$rc" = "$LIMIT_RC" ]; then
        un "$name: 上限 ${CONTROL_RUN_LIMIT_S} 秒で打ち切った(= 走行が返らなかった。期限の無い待ちを疑う)。全文: $log"
        restore_all
        return
    fi
    local reds greens
    reds="$(failed_tests "$log")"
    greens="$(passed_tests "$log")"
    if [ "$rc" -eq 0 ]; then
        ng "$name: 欠陥を植えたのに全部緑。$want は $name を測っていない。全文: $log"
    elif has "$reds" "$want"; then
        ok "$name -> 赤: $reds"
        # 片側だけでは通る欠陥が在る事を、主張ではなく**この走行の実測**で出す。
        if [ -n "$stays" ]; then
            if has "$greens" "$stays"; then
                echo "       (実演: $stays は**緑のまま** = 片側の検査だけでは此の欠陥は通る)"
            else
                un "$name: 対になる検査 $stays まで赤くなった = 2本が別の物を測っている実演にならない"
            fi
        fi
    else
        un "$name: 赤くはなったが $want ではない(赤: ${reds:-なし}, rc=$rc)。全文: $log"
    fi
    restore_all
}

probe M1-no-reason-left-behind mutate_m1 "$AS" "$WANT_LEFT"
probe M2-notice-after-keychain mutate_m2 "$AS" "$WANT_ORDER"  "$WANT_LEFT"
probe M3-stale-notice-kept     mutate_m3 "$AS" "$WANT_SWEEP"
probe M4-init-drops-notice     mutate_m4 "$KV" "$WANT_CARRIED" "$WANT_SENTENCE"
probe M5-one-sentence-for-both mutate_m5 "$KV" "$WANT_TWO"
probe M6-store-forgets-on-disk mutate_m6 "$SN" "$WANT_DISK"   "$WANT_LEFT"
probe M7-rejected-key-restored mutate_m7 "$KM" "$WANT_NOKEY"
probe M8-body-draws-nothing    mutate_m8 "$KV" "$WANT_SCREEN" "$WANT_CARRIED" run_screen
probe M9-rootview-passes-none  mutate_m9 "$RV" "$WANT_SCREEN" "$WANT_CARRIED" run_screen
probe M10-both-stages-one-line mutate_m10 "$KM" "$WANT_STAGES" "$WANT_TIMEOUT"
probe M11-footer-draws-nothing mutate_m11 "$KV" "$WANT_INFLIGHT" "$WANT_STAGES" run_screen
probe M12-fields-stay-editable mutate_m12 "$KV" "$WANT_LOCKED" "$WANT_LOCKED_UNIT" run_screen
probe M13-seed-never-planted   mutate_m13 "$AS" "$WANT_SEEDED"
probe M14-seed-planted-always  mutate_m14 "$AS" "$WANT_ONCE"      "$WANT_SEEDED"
probe M15-unreadable-as-empty  mutate_m15 "$AS" "$WANT_UNREADABLE" "$WANT_SEEDED"
probe M16-reject-after-keychain  mutate_m16 "$AS" "$WANT_SEED_ORDER" "$WANT_ORDER"
probe M17-key-but-still-the-form mutate_m17 "$RV" "$WANT_FIRSTRUN" "$WANT_SEEDED" run_firstrun
probe M18-clean-rejects-nothing  mutate_m18 "$PR" "$WANT_TEMPLATE"  "$WANT_SEEDED"
probe M19-any-scheme-accepted    mutate_m19 "$PR" "$WANT_PLAINTEXT" "$WANT_SEEDED"
probe M20-unsaved-seed-rejected  mutate_m20 "$AS" "$WANT_SEED_FAIL" "$WANT_SEEDED"
probe M21-rejected-key-not-swept mutate_m21 "$AS" "$WANT_SEED_SWEEP" "$WANT_SEEDED"
probe M22-stale-401-drops-current mutate_m22 "$AS" "$WANT_STALE_401" "$WANT_LEFT"
probe M23-rejection-never-lifted mutate_m23 "$AS" "$WANT_SEED_UNBLOCK" "$WANT_ONCE"
probe M24-any-rejection-recorded mutate_m24 "$AS" "$WANT_SEED_ONLY" "$WANT_ONCE"
probe M25-tests-share-the-item   mutate_m25 "$KCT" "$WANT_ISOLATED" "$WANT_ROUNDTRIP"
probe M26-production-item-renamed mutate_m26 "$KC" "$WANT_PINNED"  "$WANT_ROUNDTRIP"
probe M27-first-screen-asks-again mutate_m27 "$RV" "$WANT_NO_FORM" "$WANT_FIRSTRUN" run_firstrun

# ★`--which` は此処で帰る。1本も変異させていないので復元の確認は測る物が無く、
#   「復元を確認」と言うと**測っていない事を測ったと言う**形になる。
if [ "$DRY" -eq 1 ]; then
    defer_summary "$RAN_N" "$DEFERRED_N"
    exit 0
fi

# ---- 復元の確認(想定ではなく観測する) ---------------------------------------
# 此処は trap が走る**前**なので、戻っていなければ此処で言える。
restore_all
not_restored=""
i=0
while [ "$i" -lt "${#TARGETS[@]}" ]; do
    if ! cmp -s "$(snap_path "$i")" "${TARGETS[$i]}"; then
        not_restored="$not_restored ${TARGETS[$i]#$ROOT/}"
    fi
    i=$((i+1))
done
if [ -n "$not_restored" ]; then
    echo "UNMEASURED  変異が作業木に残っている:$not_restored"
    echo "            = 変異ごとの復元が効いていない。git diff で中身、git checkout -- で戻る。"
    UNMEASURED=$((UNMEASURED+1))
else
    echo "復元を確認(対象 ${#TARGETS[@]} file すべて走る前のバイトと一致)"
fi

# ★繰り延べた事は**必ず**言う(#66)。口は `defer_summary` 1つ = `--which` と同じ文言・同じ数。
defer_summary "$RAN_N" "$DEFERRED_N"

# 全部回して1本も落ちなかった時だけ印を置く。繰り延べた走行は**置かない**
# (置くと「回した」と「回していない」が同じ顔になる = 此の変更が作った穴そのもの)。
if [ "$DEFER" -eq 0 ] && [ "$FAIL" -eq 0 ] && [ "$UNMEASURED" -eq 0 ] && [ "$RAN_N" -gt 0 ]; then
    /bin/mkdir -p "$(dirname "$STAMP")" 2>/dev/null
    printf '%s\n' "$(sweep_digest)" > "$STAMP" 2>/dev/null \
        && echo "変異の全走行を記録した(出荷の口が此の印を読む): ${STAMP#"$ROOT/"}"
fi

if ! ms_assert_live_unchanged; then
    echo "--- 合計: PASS $PASS / FAIL $FAIL / UNMEASURED $((UNMEASURED + 1)) ---"
    echo "★本物の木が走行中に変わった = 此の走行の結果は使えない"
    exit 2
fi
echo "--- 合計: PASS $PASS / FAIL $FAIL / UNMEASURED $UNMEASURED ---"
[ "$FAIL" -gt 0 ] && exit 1
[ "$UNMEASURED" -gt 0 ] && exit 2
exit 0
