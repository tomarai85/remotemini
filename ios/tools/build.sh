#!/bin/bash
# Remote Mini -- build, sign against the wildcard team profile, install on the phone.
#
# Why signing is done here and not by xcodebuild: the app carries no explicit App
# ID. It borrows the team's wildcard profile ("iOS Team Provisioning Profile: *"),
# which is what lets this whole path run without an Apple Developer portal round
# trip. xcodebuild's automatic signing would try to mint a profile for the bundle
# ID instead, which needs an authenticated Xcode account. So: build unsigned,
# then codesign by hand -- the same shape as ~/Infra/blink-selfbuild/build.sh,
# which has been putting a self-built app on this phone since 2026-07-30.
#
# NOTHING here is hard-coded to a team, a certificate or a device. Every value is
# read from the machine at run time, so a rotated cert or a re-paired phone does
# not silently produce a build that installs nothing.
#
#   ./tools/build.sh                 -- build + sign + install on the phone
#   ./tools/build.sh --no-install    -- build + sign only (verifies the signature)
#   ./tools/build.sh --sim           -- simulator build + test, no signing at all
#   ./tools/build.sh --sim-app       -- 検査を回さず、**種を刻んだ**app を simulator へ入れて開く
#   ./tools/build.sh --print-device  -- どの電話へ入れるつもりかだけを出す(焼かない)
#   ./tools/build.sh --print-build-num -- 今焼くなら何番になるかだけを出す(焼かない)
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE"

BUNDLE="com.tomarai.remotemini"
SCHEME="RemoteMini"
APPNAME="RemoteMini.app"
DERIVED="$HERE/build"
SIM_NAME="${SIM_NAME:-iPhone-dogfood}"

MODE="install"
case "${1:-}" in
  --no-install) MODE="sign" ;;
  --sim) MODE="sim" ;;
  --sim-app) MODE="simapp" ;;
  --print-rev) MODE="rev" ;;
  --print-device) MODE="device" ;;
  --print-build-num) MODE="num" ;;
  "") ;;
  *) echo "usage: $0 [--no-install|--sim|--sim-app|--print-rev|--print-device|--print-build-num]" >&2; exit 2 ;;
esac

step() { echo "==> $*"; }

# ★焼いた物がどの commit かを、成果物自身に持たせる(2026-08-08 / 監査 X2-7)。
#
# なぜ commit の sha にしたか: 机側(rc-backend)が `/healthz` の `version` で
# 名乗っているのが `DEPLOYED-REV` の1行目 = 同じ repo の同じ形。両側が同じ文字列を
# 出していれば「電話と机は同じ物で動いている」が目で確定する。中身の指紋
# (この下の SRC_SHA)は log と原稿を結ぶには正しいが、**机側が名乗っていない形**
# なので突き合わせには使えない。
#
# 汚れの判定を自前で書かずに rc-backend/tools/deploy-dirt.sh を呼ぶのは、同じ判断の
# 実装を2つ持つとどちらか片方だけ腐るから(あの file の doc がその実測)。
# 終了コード 0=綺麗 / 1=付随物のみ / 2=src か test が汚れている / 3=git で判らない。
# ios/ の下に `src/` も `test/` も無いので 2 は構造上出ない = 1 と 2 を区別しない。
#
# ★`-dirty` は版印としては弱い(何が違うかを一切名乗らない)。強い名乗りが要る時は
# commit してから焼く事。ここで出来るのは「これは commit された物ではない」と言う所まで。
build_rev() {
  local sha dirt rc=0
  sha="$(git -C "$HERE" rev-parse --short HEAD 2>/dev/null || true)"
  if [ -z "$sha" ]; then echo "unknown"; return 0; fi
  # ★`bash <path>` で呼ぶ。deploy-dirt.sh は git 上 100644(実行ビットが無い)ので、
  #   直に叩くと exit 126 = permission denied になる。rc-backend/tools/deploy-to-edith.sh も
  #   同じ形で呼んでいる。実測 2026-08-08: 最初これを直に叩いて 126 を貰い、下の `*)` が
  #   それを「汚れている」と読んで**たまたま正解を出した** —— 汚れていたので気付けたが、
  #   綺麗な木なら「綺麗なのに -dirty」と名乗る所だった。
  # `X="$(cmd)"` は cmd の終了コードを引き継ぐので、非0が正常な検査は `|| rc=$?` で受ける
  # (`set -e` の下でそのまま書くと、汚れているだけで build.sh 全体が死ぬ)。
  dirt="$(bash "$HERE/../rc-backend/tools/deploy-dirt.sh" "$HERE" 2>/dev/null)" || rc=$?
  case "$rc" in
    0) echo "$sha" ;;
    # 1 = 付随物のみ / 2 = src か test。ios/ の下にその2つの名前の dir が無いので 2 は
    # 構造上出ない = 区別しない。どちらも「commit された物ではない」で同じ強さ。
    1|2) echo "$sha-dirty" ;;
    # 3 = git で判らない。それ以外(126/127 = 呼べなかった 等)も此処へ落とす:
    # **判らなかった事を「汚れている」と言い換えない**。
    *) echo "$sha-unknown-dirt" ;;
  esac
  # 汚れの中身は log にだけ出す(標準出力は版そのものなので混ぜられない)。
  [ "$rc" -eq 0 ] || printf '    作業木の汚れ(deploy-dirt rc=%s):\n%s\n' "$rc" "$dirt" >&2
}

if [ "$MODE" = "rev" ]; then
  # tools/shots.sh が同じ値を使う為の口。版の計算は此処にしか無い。
  build_rev
  exit 0
fi

# ★機械が突き合わせられる版(2026-08-10 / Codex 指摘②)。
#
# 何を直しに来たか: 鎖⑧(渡米前検査の「電話の側」)は **在るか無いか**しか言えず、
# 自分の出力に「版の一致は此処では測れない —— 電話の画面の名乗りで見る」と書いていた。
# それは #56(edith が 5 commit 古い版で走っていた)と同じ穴が電話側に開いたまま、
# 塞ぐ役を Tom の目に預けている状態。**人の目にしか出来ない事へ機械の仕事を寄せない**。
#
# なぜ sha ではなく commit の通算数か: `xcrun devicectl device info apps` が返すのは
# 固定の schema で、Info.plist の任意の鍵(RCBuildRev)は**出て来ない**。出て来る版の
# 欄は version(CFBundleShortVersionString)と bundleVersion(CFBundleVersion)の2つだけ。
# その CFBundleVersion は「点区切りの整数で単調増加」しか受けない枠なので、sha は
# 構造上入らない(BuildInfo.swift の revKey の comment に同じ理由が書いてある)。
# 通算数はその枠に其のまま乗る唯一の版の形。
#
# ★これで判らない物 = **汚れた木で焼いた事**。commit しない限り通算数は動かないので、
#   同じ番号で中身の違う app が焼ける。其れを名乗るのは RCBuildRev(sha + -dirty)の役で、
#   2つは写しではなく**役が違う**: 番号 = 機械が突き合わせる / rev = 人が画面で読む。
#
# ★数える範囲を **ios/ を触った commit だけ**にしてある(`-- .`。`$HERE` = ios/)。
#   repo 全体の通算数にすると、WORKLOG や DESIGN を1行直しただけで番号が動き、
#   **中身が1 byte も変わっていない電話**が「古い」と赤くなる。実測 2026-08-10:
#   直近 10 commit のうち ios/ を触ったのは 2 本 —— 全体で数えると 8 回が嘘の赤だった。
#   嘘の赤は2度払う(今日は違う場所を疑わせ、明日は本物の赤を読み飛ばさせる)。
#   #61 で潰したばかりの型を、番号の側で作り直さない。
#   逆側の危険(範囲を絞り過ぎて本物の変更を見落とす)には、絞りを Sources だけに
#   しない事で対処した —— 見落とし = 古い app が緑、が此の鎖の潰したい形そのもの。
#
# 判らない時に 0 を返すのは、緑にも赤にも丸めない為の値。突き合わせる側(鎖⑧)は
# 期待値が 0 なら **未測定** へ倒す。CFBundleVersion に非数値は入れられないので、
# 「読めなかった」を文字で名乗る事が此処では出来ない。
build_num() {
  local n
  n="$(git -C "$HERE" rev-list --count HEAD -- . 2>/dev/null || true)"
  case "$n" in
    ''|*[!0-9]*) echo "0" ;;
    *) echo "$n" ;;
  esac
}

if [ "$MODE" = "num" ]; then
  # 鎖⑧が期待値を取る口。**計算は此処にしか無い** —— 検査側で
  # `git rev-list --count` を書き直すと、片方だけ直る日が来る。
  build_num
  exit 0
fi

# どの電話へ入れるかを実行時に決める。UDID を焼き込むと「電話が繋がっていない」が
# 「どこかへ入れた」に化けるので、それはしない。
#
# ★2026-08-09: 選ぶ条件を tunnelState から pairingState へ変えた。実測 ——
#   一覧が `tunnelState=disconnected` を返した電話に対して install がそのまま通り、
#   devicectl 自身が最初の行で `Acquired tunnel connection to device.` と言った。
#   つまり tunnelState は「いま管が張られているか」であって「張れるか」ではない。
#   これを門にすると、繋がる電話を「繋がっていない」と断って作業ごと止まる ——
#   実際この行のせいで install が1回空振りし、電話の側を疑いに行った。
#   正しい値を持たない診断を判定にすると、嘘の赤で検査ごと信用されなくなる。
#   だから門は「対になっている iOS 機が1台に決まるか」だけにし、届くかどうかは
#   install 自身に決めさせる(3回の撃ち直しが本物の判定)。
#
# 標準出力へ出すのは**識別子1行だけ**。説明も苦情も stderr へ出す(呼ぶ側が
# `$(resolve_device)` で受けるので、混ぜると識別子が汚れる)。
resolve_device() {
  if [ -n "${RC_DEVICE:-}" ]; then
    # 名指しされた時は一覧を引かない。一覧が引けない場所でも撃てる様にする為
    echo "    RC_DEVICE で名指し: $RC_DEVICE" >&2
    printf '%s\n' "$RC_DEVICE"
    return 0
  fi
  xcrun devicectl list devices --json-output "$DERIVED/devices.json" >/dev/null 2>&1 \
    || { echo "devicectl が機器の一覧を出せない -- Xcode の command line tools を確かめる" >&2; return 1; }
  local dev
  dev=$(/usr/bin/python3 -c '
import json,sys
try:
    d=json.load(open(sys.argv[1]))
except Exception as e:
    sys.stderr.write("devicectl の一覧が読めない(%s)\n" % e); sys.exit(3)
devs=d.get("result",{}).get("devices") if isinstance(d,dict) else None
if not isinstance(devs,list):
    sys.stderr.write("devicectl の一覧の形が変わった(result.devices が無い)\n"); sys.exit(3)
out=[]
for x in devs:
    if not isinstance(x,dict): continue
    ident=x.get("identifier")
    plat=(x.get("hardwareProperties") or {}).get("platform")
    pair=(x.get("connectionProperties") or {}).get("pairingState")
    if isinstance(ident,str) and plat=="iOS" and pair=="paired":
        out.append(ident)
if len(out)==1:
    print(out[0])
elif len(out)>1:
    # 複数居る時に黙って先頭を選ぶと「どこかへ入れた」になる。名指しさせる
    sys.stderr.write("対になった iOS 機が %d 台ある。RC_DEVICE=<識別子> で名指しする:\n" % len(out))
    for i in out: sys.stderr.write("  %s\n" % i)
    sys.exit(4)
' "$DERIVED/devices.json") || return $?
  [ -n "$dev" ] || { echo "対になった iOS 機が1台も居ない -- 電話の鍵を外して、ペアリングを確かめる" >&2; return 1; }
  printf '%s\n' "$dev"
}

if [ "$MODE" = "device" ]; then
  # 焼かずに「今この機械はどの電話へ入れるつもりか」だけを出す口。
  # 対照が此処を撃つ(step 6 と**同じ関数**を撃つので、写しにならない)。
  mkdir -p "$DERIVED"
  resolve_device
  exit 0
fi

# ★生成物(ios/Info.plist / RemoteMini.xcodeproj)を触る走行を **1 本に絞る**。
# 2026-08-15、此れが無くて `build.sh --sim` と対照台本が `RC_BUILD_REV` の刻印を
# 潰し合い、**偽の赤が 9 本**出た(製品の欠陥と見分けが付かない赤)。
. "$HERE/tools/xcode-tree-guard.sh"
trap 'xtl_release' EXIT

step "1. generate project"
# xcodegen が project.yml の `RCBuildRev: "${RC_BUILD_REV}"` へ差し込む。**generate の前**に
# export する事。未定義でも xcodegen は落ちず、`${RC_BUILD_REV}` という文字列をそのまま
# Info.plist に書く(実測)ので、失敗は「もっともらしい版」として画面に出る。
# それを版と読ませない分岐は ios/Sources/Core/BuildInfo.swift の displayRev に在る。
RC_BUILD_REV="$(build_rev)"
export RC_BUILD_REV
echo "    版: $RC_BUILD_REV"
xcodegen generate >/dev/null

# 番号(CFBundleVersion)は xcodegen の `${VAR}` 差し込みに**乗せず**、生成された
# Info.plist を此処で書き換える。理由(2026-08-10):
#   `CFBundleVersion: "${RC_BUILD_NUM}"` と書くと、build.sh を通さない xcodegen の
#   呼び手が壊れた値を貰う —— ios/tools/ui-fixture-absence-control.sh と
#   signout-notice-control.sh は自分で `xcodegen generate` を撃つ。変数が無くても
#   xcodegen は落ちず `${RC_BUILD_NUM}` という**文字列**を書く(RCBuildRev で実測済。
#   現に此の瞬間の ios/Info.plist は掃引が生成した `RCBuildRev = ${RC_BUILD_REV}` を
#   持っている)。RCBuildRev は誰も検証しない自作の鍵なので其れで済むが、
#   CFBundleVersion は **OS が検証する枠**で、壊れた値を全ての焼き手へ配る事になる。
#   此処で書き換えれば他の呼び手は project.yml の直値のまま無傷で、なお
#   **build.sh を通さずに焼いた物は番号が合わない = 鎖⑧が赤**になる(fail-closed)。
# Info.plist は xcodegen の生成物(ios/.gitignore 済)なので、毎回 generate → 刻印の順。
RC_BUILD_NUM="$(build_num)"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $RC_BUILD_NUM" "$HERE/Info.plist" >/dev/null
# 刻めた事を其の場で読み戻す。黙って効かない形(鍵の名前が変わった / 生成先が動いた)は
# 読み戻さないと**焼いて電話に入れた後**にしか判らない。
_stamped="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$HERE/Info.plist" 2>/dev/null || true)"
[ "$_stamped" = "$RC_BUILD_NUM" ] || {
  echo "CFBundleVersion を刻めなかった(読み戻し=[$_stamped] 期待=[$RC_BUILD_NUM])" >&2
  exit 1
}
echo "    番号: $RC_BUILD_NUM"

if [ "$MODE" = "sim" ]; then
  step "2. build + test on the simulator ($SIM_NAME)"
  # The full log goes to a file; the one-line summary is CLASSIFIED (green / red /
  # not-measured) by tools/sim-log-summary.sh rather than scraped inline here.
  #
  # Why a separate file: a summariser that lives inside this script can only be
  # exercised by a real several-minute xcodebuild run. Something that expensive to
  # test does not get a control written for it. Taking the log path as an argument
  # lets a control feed it hand-made logs and measure every branch in a second.
  #
  # What it fixes and why the old inline version was actively dangerous is written
  # at the top of that file -- summary: `... | tail -1` reported only the LAST test
  # bundle's count, so a 100-test run printed "Executed 3 tests", and a run whose
  # unit bundle never started at all still printed a green-looking line.
  mkdir -p "$DERIVED"
  SIM_LOG="$DERIVED/xcodebuild-sim.log"

  # ★原稿の指紋を log の隣に残す(2026-08-07 追加)。走らせる**前**に取る =
  #   この log が語っているのはこの中身、という対応を残す為。
  #
  # 何を直したか: `.harness/dod-sprint-6.5.sh` は「同じ1本の log に passed として
  # 名前が在る」を根拠に緑を出す。その log が**今の原稿**の話なのかを log 自身は
  # 何も語らない。代用を2つ試して両方外した:
  #   mtime  -> `.harness/dod-sprint-6-controls.sh` は変異を植えて複製から戻す。戻した瞬間
  #             中身は同一なのに mtime だけ新しくなる = 恒常的に「古い」と読む。
  #   commit -> 検査は commit の**前**に走る。log が commit より古いのは正常な順序で、
  #             これを異常と読むと毎回 未測定 になり判定が意味を失う。
  # どちらも中身の代理として成立しない。だから中身そのものを測る。
  SRC_SHA="$DERIVED/xcodebuild-sim.sources.sha"
  ( cd "$HERE" && find Sources Tests UITests -type f -name '*.swift' -print0 \
      | sort -z | xargs -0 shasum -a 256 ) | shasum -a 256 | awk '{print $1}' > "$SRC_SHA"

  rc=0
  xcodebuild -project "$SCHEME.xcodeproj" -scheme "$SCHEME" -configuration Debug \
    -sdk iphonesimulator -destination "platform=iOS Simulator,name=$SIM_NAME" \
    -derivedDataPath "$DERIVED" test >"$SIM_LOG" 2>&1 || rc=$?

  sum_rc=0
  bash "$HERE/tools/sim-log-summary.sh" "$SIM_LOG" "$rc" || sum_rc=$?
  echo "==> 全文: $SIM_LOG"
  # xcodebuild 自身が落ちたなら、その終了コードを潰さずに返す(65 のまま外へ出す)。
  # 落ちていない時だけ要約側の判定を採る = 「rc=0 だが1件も測っていない」を 2 で返す道。
  if [ "$rc" -ne 0 ]; then
    exit "$rc"
  fi
  exit "$sum_rc"
fi

# ── 1b. 既定の接続先を机から貰って焼き込む(2026-08-11 / #64)────────────────────
#
# ★何を直しに来たか。此処が空だった間、電話に資格情報が入る経路は鍵入力画面ただ一つで、
#   新品の Keychain は空だから **初回起動は必ず「Base URL と API Key を打て」から始まって
#   いた**。REQUIREMENTS.md の合格条件は「開くとセッション一覧が出る」で、人が打つとは
#   何処にも書いていない。禁止(機械名を追跡ファイルに残さない)だけを置いて、其れで
#   塞いだ供給経路を引き直していなかった。引くのが此の段。
#
# ★値は repo の何処にも書かない。焼く瞬間に**机自身へ訊く**:
#     鍵  = edith の ~/.rc-backend/api.key(ios/tools/live-send-check.sh と
#           rc-backend/tools/verify-phone-window.sh が既に読んでいる**同じ正本**。
#           2つ目の写しを作らない)
#     URL = 机が名乗る tailnet の名前(tailscale status --json の Self.DNSName)
#   刻む先は xcodegen の生成物 ios/Info.plist(ios/.gitignore 済)= 追跡ファイルは
#   一文字も増えない。読む側は ios/Sources/Core/Provisioning.swift。
#
# ★simulator では走らない —— 此の段は `--sim` の分岐より**後**に在る。単体も UI 検査も
#   本物の鍵を一度も見ない。規則ではなく置き場所で保証してある。加えて `--sim` は毎回
#   `xcodegen generate` から始まるので、直前の実機焼きが刻んだ値は消えてから走る。
#
# ★鍵の扱い(ios/tools/live-send-check.sh の doc と同じ約束):
#   - argv に置かない。**PlistBuddy は値を argv で受けるので此処では使えない**(`ps` に出る)。
#     代わりに plistlib へ**標準入力**から渡す。`printf` は bash の組込みなのでプロセスに
#     ならず、`ps` にも出ない。
#   - export しない(子プロセスの環境に漏れない)
#   - 印字しない。此の script は `set -x` を使わない。python 側の例外本文も握り潰す
#     (plistlib の例外は値を含み得る)。
#
# ★届かない時は**焼かない**。種の無い app は「打て」と言う画面から始まる = 直す前と
#   同じ姿に、しかも黙って戻る。意図して種無しを焼く時だけ `RC_NO_SEED=1`。
if [ "${RC_NO_SEED:-0}" = "1" ]; then
  step "1b. 既定の接続先は焼かない(RC_NO_SEED=1)"
  echo "    ★此の app は初回起動で Base URL と API Key を打たせる。意図した時だけ此の道を通る事" >&2
else
  step "1b. 机から既定の接続先を貰って刻む"
  SEED_SSH="${RC_EDITH_HOST:-edith@10.0.0.0}"
  # BatchMode = 鍵が無い時に**問い合わせずに落ちる**(焼きが人の入力待ちで止まらない)。
  # StrictHostKeyChecking=yes = known_hosts に無い / 変わった相手には繋がない。焼き込む物が
  # 鍵である以上、相手の取り違えは「届かない」より悪い。
  SEED_SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes)

  seed_rc=0
  SEED_KEY="$(ssh "${SEED_SSH_OPTS[@]}" "$SEED_SSH" 'cat ~/.rc-backend/api.key' 2>/dev/null)" || seed_rc=$?
  [ "$seed_rc" -eq 0 ] && [ -n "$SEED_KEY" ] || {
    echo "机の鍵(~/.rc-backend/api.key)が読めない(ssh rc=$seed_rc)。" >&2
    echo "  机が起きているか / tailnet に居るか / ssh の鍵が通るかを確かめる。" >&2
    echo "  種無しで焼くと決めたなら RC_NO_SEED=1 ./tools/build.sh" >&2
    exit 1
  }

  # 名前は Tailscale 自身に名乗らせる。`tailscale` が PATH に無い焼き方でも通る様に
  # app 内の実体を先に見る(rc-backend/tools/com.edith.rc-backend.plist と同じ path)。
  seed_rc=0
  SEED_STATUS="$(ssh "${SEED_SSH_OPTS[@]}" "$SEED_SSH" \
    'TS=/Applications/Tailscale.app/Contents/MacOS/Tailscale; [ -x "$TS" ] || TS=tailscale; "$TS" status --json' \
    2>/dev/null)" || seed_rc=$?
  [ "$seed_rc" -eq 0 ] && [ -n "$SEED_STATUS" ] || {
    echo "机が tailnet の名前を名乗れない(tailscale status rc=$seed_rc)" >&2; exit 1
  }

  # DNSName は末尾に `.`(root ラベル)が付いた FQDN で返る。付けたまま URL にすると
  # host が別物になる = 証明書が合わない。
  SEED_HOST="$(printf '%s' "$SEED_STATUS" | /usr/bin/python3 -c '
import json, sys
try:
    name = (json.load(sys.stdin).get("Self") or {}).get("DNSName") or ""
except Exception:
    sys.stderr.write("tailscale status --json の形が変わった\n"); sys.exit(3)
print(name.rstrip("."))
')" || { echo "机の名前を取り出せない" >&2; exit 1; }

  # 形の検査。**焼く前に落とす**為に此処で見る —— 壊れた値は電話の側では
  # 「サーバに届かない」という、刻印とは無関係な故障を名乗る(Provisioning.swift の doc)。
  case "$SEED_HOST" in
    ''|*[!A-Za-z0-9.-]*) echo "机の名前が名前の形をしていない" >&2; exit 1 ;;
    *.*) ;;
    *) echo "机の名前に領域が無い(点を含まない)" >&2; exit 1 ;;
  esac
  # ★検査用の偽の値が実機の焼き物へ入る道を塞ぐ。`.invalid` は RFC 2606 の予約領域で、
  #   ios/Sources/Core/ProvisioningFixture.swift と姉家族の fixture が使っている綴り。
  case "$SEED_HOST" in
    *.invalid) echo "検査用の名前(.invalid)を実機へ焼こうとしている" >&2; exit 1 ;;
  esac
  SEED_URL="https://$SEED_HOST"

  # 刻んで、其の場で**読み戻して**照合する。黙って効かない形(鍵の名前が変わった /
  # 生成先が動いた)は読み戻さないと焼いて電話に入れた後にしか判らない。
  # 鍵は標準入力から渡し、比較も python の中で終わらせる(shell へ戻すと `ps` と log に近付く)。
  #
  # ★指紋も此処で出す(2026-08-11)。前の版は shell 側で `$SEED_KEY` から別に
  #   計算していたが、plist へ入るのは `key.strip()` の方なので、鍵の前後に
  #   空白が1つ在るだけで**印字した指紋と焼いた物の指紋が食い違う**。
  #   指紋は「入れようとした値」ではなく**読み戻した値**から取る。
  SEED_FP="$(printf '%s' "$SEED_KEY" | /usr/bin/python3 -c '
import hashlib, plistlib, sys
path, url = sys.argv[1], sys.argv[2]
key = sys.stdin.read().strip()
if not key:
    sys.stderr.write("鍵が空\n"); sys.exit(1)
try:
    with open(path, "rb") as f:
        doc = plistlib.load(f)
    doc["RCBaseURL"] = url
    doc["RCAPIKey"] = key
    with open(path, "wb") as f:
        plistlib.dump(doc, f)
    with open(path, "rb") as f:
        back = plistlib.load(f)
except Exception:
    # ★例外の本文を出さない。plistlib の例外は書こうとした値を含み得る。
    sys.stderr.write("Info.plist へ刻めなかった\n"); sys.exit(1)
if back.get("RCBaseURL") != url:
    sys.stderr.write("URL の読み戻しが合わない\n"); sys.exit(1)
if back.get("RCAPIKey") != key:
    sys.stderr.write("鍵の読み戻しが合わない\n"); sys.exit(1)
material = "{}\n{}".format(back["RCBaseURL"], back["RCAPIKey"]).encode("utf-8")
print(hashlib.sha256(material).hexdigest()[:16])
' "$HERE/Info.plist" "$SEED_URL")" || exit 1

  # 焼いた物同士を人が見分ける為の指紋。**値は出さない**。
  # 材料と切り方は ios/Sources/Core/Provisioning.swift の `SeedDigest.of` と同じ
  # (URL + 改行 + 鍵 の sha256 を先頭 8 byte)なので同じ値になる —— 其の「同じ」を
  # 突き合わせているのは rc-backend/test/seed-digest-recipe.test.mjs(両側が
  # 同一の既知の値へ落ちる事を、双方の綴りから独立に見る)。
  echo "    種: 刻んだ(指紋 $SEED_FP)。URL も鍵も此処には出さない"
fi

# ── 1c. simulator へ「開いたら一覧」の app を入れる(2026-08-15 / Tom の「論外」)──
#
# ★何を直しに来たか。1b(種を刻む)は `--sim` の分岐より**後ろ**に在る。置き場所で
#   「検査は本物の鍵を一度も見ない」を保証する為で、其れ自体は今も正しい。ただし
#   其の置き方の帰結として、**simulator に入る束だけが永久に種を貰えなかった**。
#   Tom が製品を見るのは simulator なので、彼の席からはアプリの玄関がずっと
#   「Base URL と API Key を打て」の欄だった —— 2026-08-15 01:43 の画面。実測:
#   入っていた束の Info.plist に `RCBaseURL` が無い。
#
#   これは 2026-08-11 に自分で書いた教訓の再発でもある(禁止を1本置いたら、其れが
#   塞いだ供給経路を同じ変更の中で引き直す)。あの日引いたのは実機の道だけで、
#   私自身が毎日焼いている道は引かないまま「直した」と言っていた。
#
# ★検査が鍵を見ない保証は落とさない。落とさない為に**検査を回さない**別の道にした:
#   `--sim` は `test` を回して此処へ来ない。`--sim-app` は此処に居るので種を持つが、
#   `build` しかせず検査束を一度も走らせない。次に `--sim` を回すと先頭の
#   `xcodegen generate` が Info.plist を作り直すので、刻印は検査の前に消える。
#   規則ではなく順序で分けてある = 1b と同じ守り方。
if [ "$MODE" = "simapp" ]; then
  step "2. simulator 用に焼く(検査は回さない)"
  mkdir -p "$DERIVED"
  SIMAPP_LOG="$DERIVED/xcodebuild-simapp.log"
  rc=0
  xcodebuild -project "$SCHEME.xcodeproj" -scheme "$SCHEME" -configuration Debug \
    -sdk iphonesimulator -destination "platform=iOS Simulator,name=$SIM_NAME" \
    -derivedDataPath "$DERIVED" build >"$SIMAPP_LOG" 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || { echo "simulator 用の焼きが失敗(rc=$rc)。全文: $SIMAPP_LOG" >&2; exit "$rc"; }

  SIM_APP="$DERIVED/Build/Products/Debug-iphonesimulator/$APPNAME"
  [ -d "$SIM_APP" ] || { echo "焼けた筈の app が無い: $SIM_APP" >&2; exit 1; }

  step "3. 焼き上がった束の種を読み戻す"
  # ★此処を省くと、刻印が黙って効かなかった時に**電話を開くまで**判らない。
  #   今回 Tom が踏んだのが正に其の形なので、同じ道は機械で塞ぐ。
  if [ "${RC_NO_SEED:-0}" = "1" ]; then
    /usr/bin/python3 "$HERE/tools/seed-verify.py" absent "$SIM_APP/Info.plist" || exit 1
    echo "    種: 無し(RC_NO_SEED=1)。此の app は鍵入力画面から始まる"
  else
    printf '%s' "$SEED_KEY" | /usr/bin/python3 "$HERE/tools/seed-verify.py" present "$SIM_APP/Info.plist" "$SEED_URL" || exit 1
    echo "    種: 焼き上がった app に入っている(指紋 $SEED_FP)"
  fi

  step "4. simulator へ入れて開く"
  # 名前 → UDID。`simctl list --json` に訊く(名前で `install` は通らない)。
  SIM_UDID="$(xcrun simctl list devices --json | /usr/bin/python3 -c '
import json, sys
name = sys.argv[1]
data = json.load(sys.stdin).get("devices") or {}
best = None
for runtime, devices in data.items():
    for d in devices:
        if d.get("name") != name or not d.get("isAvailable", True):
            continue
        # 起きている物を優先する。同じ名前の器が版違いで並ぶ事が在り、
        # 寝ている方へ入れると「入れたのに画面が変わらない」になる。
        if d.get("state") == "Booted":
            best = d
            break
        best = best or d
    if best and best.get("state") == "Booted":
        break
print((best or {}).get("udid", ""))
print((best or {}).get("state", ""))
' "$SIM_NAME")" || { echo "simulator の一覧が読めない" >&2; exit 1; }

  SIM_STATE="$(printf '%s' "$SIM_UDID" | sed -n '2p')"
  SIM_UDID="$(printf '%s' "$SIM_UDID" | sed -n '1p')"
  [ -n "$SIM_UDID" ] || { echo "simulator '$SIM_NAME' が無い(SIM_NAME= で名前を渡す)" >&2; exit 1; }

  if [ "$SIM_STATE" != "Booted" ]; then
    # ★`open -a Simulator` は使わない —— 画面の主導権を奪わない(机の約束)。
    #   `simctl boot` は窓を前へ出さずに器だけ起こす。
    echo "    起こす($SIM_NAME は $SIM_STATE だった)"
    xcrun simctl boot "$SIM_UDID" || { echo "simulator を起こせない" >&2; exit 1; }
    xcrun simctl bootstatus "$SIM_UDID" -b >/dev/null 2>&1 || true
  fi

  xcrun simctl install "$SIM_UDID" "$SIM_APP" || { echo "simulator へ入れられない" >&2; exit 1; }

  # 入れた**後**の束を見る。derivedData の物と simulator の中の物は別の写しで、
  # 入れ損ねると古い束が残ったまま「入れた」と言える(2026-08-15 に実際に
  # 古い束を読んで診断した)。
  INSTALLED="$(xcrun simctl get_app_container "$SIM_UDID" "$BUNDLE" app 2>/dev/null || true)"
  if [ -n "$INSTALLED" ] && [ "${RC_NO_SEED:-0}" != "1" ]; then
    printf '%s' "$SEED_KEY" | /usr/bin/python3 "$HERE/tools/seed-verify.py" present "$INSTALLED/Info.plist" "$SEED_URL" || {
      echo "simulator の中に入った束に種が無い = 入れ替わっていない" >&2; exit 1; }
    echo "    simulator の中の束にも種が在る"
  fi

  xcrun simctl launch "$SIM_UDID" "$BUNDLE" >/dev/null || { echo "app を開けない" >&2; exit 1; }
  echo "==> $SIM_NAME で開いた(番号 $RC_BUILD_NUM / 版 $RC_BUILD_REV)"
  exit 0
fi

step "2. locate the wildcard provisioning profile"
# Scan every installed profile and take the one whose application-identifier ends
# in ".*". Picking it by filename would break the day Xcode re-downloads it under
# a new UUID -- which it does, silently.
PROFILE=""
for p in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"/*.mobileprovision; do
  [ -e "$p" ] || continue
  appid=$(security cms -D -i "$p" 2>/dev/null | plutil -extract Entitlements.application-identifier raw - 2>/dev/null || true)
  case "$appid" in
    *".*") PROFILE="$p"; TEAM="${appid%%.*}"; break ;;
  esac
done
[ -n "$PROFILE" ] || { echo "no wildcard provisioning profile installed -- open Xcode once with the account signed in" >&2; exit 1; }

EXPIRY=$(security cms -D -i "$PROFILE" 2>/dev/null | plutil -extract ExpirationDate raw -)
# Fail before building rather than after installd rejects the app: an expired
# profile produces a signature that verifies locally and dies on the device.
if [ "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \> "$EXPIRY" ]; then
  echo "the wildcard profile expired at $EXPIRY" >&2; exit 1
fi
echo "    profile expires $EXPIRY"

step "3. locate the signing identity"
# Match on the team OU rather than the certificate's common name: the CN carries
# a personal Apple ID address and changes when the cert is reissued.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null |
  awk '/Apple Development/ {print $2; exit}')
[ -n "$IDENTITY" ] || { echo "no Apple Development codesigning identity in the keychain" >&2; exit 1; }

step "4. build (unsigned)"
xcodebuild -project "$SCHEME.xcodeproj" -scheme "$SCHEME" -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath "$DERIVED" \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  build >/dev/null
SRC="$DERIVED/Build/Products/Release-iphoneos/$APPNAME"
[ -d "$SRC" ] || { echo "build produced no $APPNAME" >&2; exit 1; }

step "5. sign"
OUT="$DERIVED/signed"
rm -rf "$OUT"; mkdir -p "$OUT"
cp -R "$SRC" "$OUT/"
APP="$OUT/$APPNAME"
cp "$PROFILE" "$APP/embedded.mobileprovision"

# The entitlements MUST be a subset of what the profile grants, or installd
# rejects the app with 0xe8008015 and the message blames the profile rather than
# the extra key. The wildcard profile grants exactly these four.
ENT=$(mktemp -t remotemini-entitlements)
trap 'rm -f "$ENT"; xtl_release' EXIT
cat > "$ENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>application-identifier</key>
	<string>$TEAM.$BUNDLE</string>
	<key>com.apple.developer.team-identifier</key>
	<string>$TEAM</string>
	<key>get-task-allow</key>
	<true/>
	<key>keychain-access-groups</key>
	<array>
		<string>$TEAM.$BUNDLE</string>
	</array>
</dict>
</plist>
PLIST

if [ -d "$APP/Frameworks" ]; then
  find "$APP/Frameworks" -maxdepth 1 -name "*.framework" -print0 |
    xargs -0 -I{} codesign --force --timestamp=none --sign "$IDENTITY" {}
fi
codesign --force --timestamp=none --sign "$IDENTITY" --entitlements "$ENT" "$APP"
codesign --verify --deep --strict "$APP"
echo "    signed: $APP"

# ★焼き上がった物**其れ自身**を読む(2026-08-11 / #64、Codex 指摘)。
#
# 上の 1b が読み戻したのは ios/Info.plist = xcodebuild の**入力**。電話に入るのは
# 此の `.app` の中の Info.plist で、間に xcodebuild の加工が1段挟まる(変数展開・
# binary 化・鍵の取捨)。入力を読み戻しただけで「刻めた」と言うのは、**測っていない
# 物を測ったと言う**事になる。番号(CFBundleVersion)も同じ理由で此処で見る ——
# 渡米前検査の鎖⑧が電話から読むのは此の値で、ios/Info.plist の値ではない。
#
# 鍵は此処でも標準入力から渡し、比較を python の中で終わらせる。合わない時も値は出さない。
APP_PLIST="$APP/Info.plist"
[ -f "$APP_PLIST" ] || { echo "焼き上がった $APPNAME に Info.plist が無い" >&2; exit 1; }

_app_num="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_PLIST" 2>/dev/null || true)"
[ "$_app_num" = "$RC_BUILD_NUM" ] || {
  echo "焼き上がった app の番号が違う(app=[$_app_num] 期待=[$RC_BUILD_NUM])" >&2; exit 1
}

# ★通知をタップした時の行き先が**焼き上がった物に入っている**事(2026-08-12、
#   REQUIREMENTS §5-4)。此処で見る理由は上の番号と同じ —— 単体検査は plist を
#   選べないので、`project.yml` に書いた事は「焼けた事」の証拠にならない。
#
# ★壊れ方が静かな側なので機械で押さえる: scheme が消えても edith の通知は届き続け、
#   **押した時に何も起きないだけ**になる。届いている通知を見ている人は
#   「アプリが開かない」を通知の不具合と読む。だから通知の側ではなく此処で測る。
_app_scheme="$(/usr/libexec/PlistBuddy -c "Print :CFBundleURLTypes:0:CFBundleURLSchemes:0" "$APP_PLIST" 2>/dev/null || true)"
[ "$_app_scheme" = "remotemini" ] || {
  echo "焼き上がった app に通知の行き先(URL scheme)が無い(app=[$_app_scheme] 期待=[remotemini])" >&2
  echo "  正本 = ios/project.yml の CFBundleURLTypes。送る側は edith の ~/fleet-tools/ntfy-notify.sh" >&2
  exit 1
}
echo "    通知の行き先: remotemini:// (焼き上がった app に在る)"

if [ "${RC_NO_SEED:-0}" = "1" ]; then
  /usr/bin/python3 "$HERE/tools/seed-verify.py" absent "$APP_PLIST" || exit 1
  echo "    種: 無し(RC_NO_SEED=1。焼き上がりにも残っていない)"
else
  printf '%s' "$SEED_KEY" | /usr/bin/python3 "$HERE/tools/seed-verify.py" present "$APP_PLIST" "$SEED_URL" || exit 1
  echo "    種: 焼き上がった app にも同じ物が入っている(指紋 $SEED_FP)"
fi

[ "$MODE" = "install" ] || exit 0

# ★変異の走行の腐りを言う(#66、2026-08-12)。**門ではない、警告だけ。**
#
# 経緯: 同日、commit では変異20本(725秒)を繰り延べて基準だけ回す様にした。
# 繰り延べた分は「回していない」であって緑ではないが、**出荷の前に全部回す事を
# 機械が誰も強制しない**穴が空く。禁止/繰り延べを1本置いたら、同じ変更の中で
# 代わりの経路を引く —— 引かないと穴埋めは黙って人の記憶に落ちる。
# 止めないのは裁定「門をもう増やさない」(2026-08-11)に従う為。読んで決めるのは人。
# ★digest も印の場所も**持っている側に訊く**(`--sweep-digest`)。此処で同じ式を
#   書き写すと実装が2本になり、食い違った時に出るのは**嘘の「古い」警告** ——
#   本物の腐りと見分けが付かなくなる。一覧は向こうの `TARGETS` 1本のまま。
# ★`$HERE`(= ios/)。初版は `$IOS` と書いて `set -u` で死に、**install の段まで
#   到達しない**まま exit 0 に見えた(pipe の後段が 0 を返す)。sim 走行が捕まえ
#   なかったのは、此のブロックが install 経路にしか居ないから —— 2026-08-13 実測。
_sweep_ans="$(bash "$HERE/tools/signout-notice-control.sh" --sweep-digest 2>/dev/null)"
_sweep_now="$(printf '%s' "$_sweep_ans" | sed -n '1p')"
_sweep_stamp="$(printf '%s' "$_sweep_ans" | sed -n '2p')"
if [ -z "$_sweep_now" ] || [ -z "$_sweep_stamp" ]; then
  echo "    ⚠ 変異の走行の記録を問い合わせられなかった = 腐りは**未測定**" >&2
elif [ ! -r "$_sweep_stamp" ]; then
  echo "    ⚠ 変異20本を全部回した記録が無い。錨に歯が在るかは**未測定**のまま出荷する" >&2
  echo "      閉じる手: bash ios/tools/signout-notice-control.sh(約12分)" >&2
elif [ "$(cat "$_sweep_stamp" 2>/dev/null)" != "$_sweep_now" ]; then
  echo "    ⚠ 変異を全部回した後に、其れが読む file が動いている = 記録は**古い**" >&2
  echo "      閉じる手: bash ios/tools/signout-notice-control.sh(約12分)" >&2
else
  echo "    変異20本の全走行: 記録と現在のバイトが一致"
fi

step "6. install"
DEV=$(resolve_device) || exit $?

# Retry, because the tunnel genuinely flakes. Measured 2026-08-05: install
# succeeded first try, the uninstall right after it died with CoreDeviceError
# 4000 ("device disconnected immediately after connecting") and then succeeded
# on attempt 2 with nothing changed. A single-shot install would report that as
# a build failure and send me looking for a bug that is not there.
for attempt in 1 2 3; do
  if xcrun devicectl device install app --device "$DEV" "$APP"; then
    echo "==> installed (attempt $attempt)"
    exit 0
  fi
  echo "    install attempt $attempt failed; the tunnel drops intermittently -- retrying" >&2
done
echo "install failed 3 times -- unlock the phone, confirm it is on the same network, retry" >&2
exit 1
