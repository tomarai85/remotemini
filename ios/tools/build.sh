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
  --print-rev) MODE="rev" ;;
  "") ;;
  *) echo "usage: $0 [--no-install|--sim|--print-rev]" >&2; exit 2 ;;
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

step "1. generate project"
# xcodegen が project.yml の `RCBuildRev: "${RC_BUILD_REV}"` へ差し込む。**generate の前**に
# export する事。未定義でも xcodegen は落ちず、`${RC_BUILD_REV}` という文字列をそのまま
# Info.plist に書く(実測)ので、失敗は「もっともらしい版」として画面に出る。
# それを版と読ませない分岐は ios/Sources/Core/BuildInfo.swift の displayRev に在る。
RC_BUILD_REV="$(build_rev)"
export RC_BUILD_REV
echo "    版: $RC_BUILD_REV"
xcodegen generate >/dev/null

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
trap 'rm -f "$ENT"' EXIT
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

[ "$MODE" = "install" ] || exit 0

step "6. install"
# Resolve the device at run time. A hard-coded UDID turns "the phone is not
# plugged in" into "installed something somewhere", which is worse.
DEV=$(xcrun devicectl list devices --json-output "$DERIVED/devices.json" >/dev/null 2>&1 &&
  /usr/bin/python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
def walk(o,out):
    if isinstance(o,dict):
        if "identifier" in o and isinstance(o.get("identifier"),str) and o.get("connectionProperties",{}).get("tunnelState") in ("connected","available"):
            out.append(o["identifier"])
        for v in o.values(): walk(v,out)
    elif isinstance(o,list):
        for x in o: walk(x,out)
out=[]; walk(d,out)
print(out[0] if out else "")
' "$DERIVED/devices.json")
[ -n "$DEV" ] || { echo "no connected device -- unlock the phone and make sure it is paired" >&2; exit 1; }

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
