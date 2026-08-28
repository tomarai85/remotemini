#!/usr/bin/env bash
# ★`controls-for:` を**意図的に持たない**。xcodebuild と ssh と本物の署名鍵が要る。
#   門で回す物は網にも鍵にも依存しない物だけにする(偽の赤は本物の赤を読ませなくする)。
# 同一 WiFi 無しで電話へ新しい束を渡す道(2026-08-28)。
#
# ★なぜ在るか: Tom「同じ WIFI じゃないといけないの論外」。実測でその通りだった ——
#   `xcrun devicectl` の tunnel は USB か**同一 LAN の探索(mDNS)**の上に建つ。
#   Tailscale は L3 なので mDNS を運ばない。電話が tailnet に居ても(実測 10.0.0.0)
#   devicectl は `tunnelState: unavailable` を返し、`--device <tailnet の IP>` は
#   「そんな端末は無い」で落ちる。だから**配布の経路そのもの**を替える。
#
#   替え先は Ad Hoc の OTA: Apple Distribution で署名した .ipa を机(friday)の
#   tailnet HTTPS に置き、`itms-services://` で電話に取りに行かせる。
#   Apple へ binary を送らない / App Store Connect のアプリ登録も要らない /
#   机は既に其の host で HTTPS を出している。要るのは端末が profile に居る事だけ。
#
# ★TestFlight にしなかった理由(Codex 2026-08-28 が「唯一の道ではない」と訂正):
#   TestFlight は binary を Apple へ送る = 取り消せない外部送信で、Apple の処理待ちが挟まり、
#   束は 90 日で消える。Ad Hoc は全部 Tom の設備の中で完結し、消したければ file を消すだけ。
#
# ★配る面は**秘密の一段**を噛ませる。tailnet 限定は同居する機体を守らない ——
#   実測 2026-08-28、Tom の tailnet には未だ edith(2026-08-20 に家族さんへ譲渡した機体)が
#   居る。認証を付けられない(iOS の installd は独自の header を送らない)ので、
#   推測できない path が実質の鍵になる。path は焼き直しても変えない = 電話の栞が生き続ける。
#
# 使い方:
#   ./tools/adhoc-ota.sh              焼く → 署名 → 置く → 検証まで
#   ./tools/adhoc-ota.sh --print-url  今の導線の URL だけ出す(何も作らない)
#   ./tools/adhoc-ota.sh --no-upload  手元で .ipa と manifest を作るだけ
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED="$HERE/build"
STAGE="$DERIVED/adhoc"
APPNAME="RemoteMini.app"
IPA="RemoteMini.ipa"
PROFILE="$DERIVED/RemoteMini_AdHoc.mobileprovision"
SECRET_FILE="$STAGE/.ota-path-secret"

DESK_SSH="${RC_DESK_SSH:-athenas}"
DESK_HOST="${RC_DESK_HOST:desk.tailnet.example}"
DESK_PORT="${RC_DESK_PORT:-9443}"
DESK_DIR="${RC_OTA_DIR:-ota}"          # 机の $HOME からの相対
SERVE_PATH="${RC_OTA_SERVE_PATH:-/ota}"

MODE="all"
case "${1:-}" in
  --print-url) MODE="url" ;;
  --no-upload) MODE="local" ;;
  "") ;;
  *) echo "usage: $0 [--print-url|--no-upload]" >&2; exit 2 ;;
esac

step() { echo "==> $*"; }

# ★無言で死ねなくする。`set -e` は止めた場所を言わないので、上の SIGPIPE の様な
#   「途中まで出ているのに成果物が無い」を読み解く手掛かりが1つも残らなかった。
trap 'rc=$?; [ "$rc" -ne 0 ] && echo "★ adhoc-ota.sh は rc=$rc で止まった(直前に出た行の次が犯人)" >&2; exit $rc' EXIT

# --- 秘密の一段。**一度作ったら変えない** -----------------------------------
# 変えると Tom の栞が死ぬ。焼き直しの度に URL が変わる導線は、結局
# 「毎回私に訊く」になって同一 WiFi の不便を別の不便へ移し替えただけになる。
if [ -f "$SECRET_FILE" ]; then
  SECRET="$(cat "$SECRET_FILE")"
else
  mkdir -p "$STAGE"
  SECRET="$(openssl rand -hex 12)"
  printf '%s\n' "$SECRET" > "$SECRET_FILE"
fi
BASE="https://$DESK_HOST:$DESK_PORT$SERVE_PATH/$SECRET"

if [ "$MODE" = "url" ]; then
  echo "$BASE/"
  exit 0
fi

# --- 1. 焼く(build.sh をそのまま使う) --------------------------------------
# ★此処で xcodebuild を直に叩かない。build.sh は版番号・commit の刻印・
#   **机の接続先の種**を焼き込んでから署名する。素の xcodebuild で焼いた束は
#   `RCBaseURL` を持たず、電話は接続先を知らないまま起動する(実測で踏んだ)。
step "1. 焼く(build.sh --no-install = 刻印と種を通す)"
bash "$HERE/tools/build.sh" --no-install >&2
SIGNED="$DERIVED/signed/$APPNAME"
[ -d "$SIGNED" ] || { echo "build.sh が $APPNAME を出していない" >&2; exit 1; }

[ -f "$PROFILE" ] || {
  echo "Ad Hoc の profile が無い: $PROFILE" >&2
  echo "  作り直す手: App Store Connect API で IOS_APP_ADHOC を1本(端末は登録済みの iPhone)" >&2
  exit 1
}

# profile の期限を**焼く前に**見る。切れた profile で署名した束は手元では検証を通り、
# 電話の installd で死ぬ —— 同じ罠を build.sh も踏んで、明示的に前へ出してある。
PEXP=$(security cms -D -i "$PROFILE" | plutil -extract ExpirationDate raw -)
if [ "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \> "$PEXP" ]; then
  echo "Ad Hoc の profile が $PEXP に切れている" >&2; exit 1
fi
echo "    profile 期限 $PEXP"

# --- 2. Ad Hoc で署名し直す --------------------------------------------------
step "2. Ad Hoc で署名し直す(get-task-allow を落とす)"
rm -rf "$STAGE/Payload" "$STAGE/$IPA"
mkdir -p "$STAGE/Payload"
cp -R "$SIGNED" "$STAGE/Payload/"
APP="$STAGE/Payload/$APPNAME"
cp "$PROFILE" "$APP/embedded.mobileprovision"

TEAM=$(security cms -D -i "$PROFILE" | plutil -extract Entitlements.com\\.apple\\.developer\\.team-identifier raw -)
BUNDLE=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Info.plist")
BUILDNUM=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Info.plist")
SHORTVER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Info.plist")

# ★`get-task-allow` は **false**。開発署名との唯一で決定的な違いで、
#   true のまま distribution 証明書で署名した束は OTA で入らない。
ENT=$(mktemp -t rm-adhoc-ent)
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
	<false/>
	<key>keychain-access-groups</key>
	<array>
		<string>$TEAM.$BUNDLE</string>
	</array>
</dict>
</plist>
PLIST

IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Distribution/ {print $2; exit}')
[ -n "$IDENTITY" ] || { echo "Apple Distribution の署名 identity が keychain に無い" >&2; exit 1; }

if [ -d "$APP/Frameworks" ]; then
  find "$APP/Frameworks" -maxdepth 1 -name "*.framework" -print0 |
    xargs -0 -I{} codesign --force --timestamp=none --sign "$IDENTITY" {}
fi
codesign --force --timestamp=none --sign "$IDENTITY" --entitlements "$ENT" "$APP"
codesign --verify --deep --strict "$APP"

# ★焼き上がった物**其れ自身**に訊く(build.sh 由来の作法)。入力ではなく成果物を読む。
# ★`awk ... {print; exit}` にしない(2026-08-28、此処で無言死した)。awk が先に降りると
#   codesign が SIGPIPE で非ゼロになり、`pipefail` + `set -e` で**何も出さずに**台本ごと
#   終わる —— 署名までは出ているのに .ipa が出来ていない、という読み解けない形になる。
#   最後まで読み切って最初の1本だけ拾う。
AUTH=$(codesign -dvvv "$APP" 2>&1 | awk -F= '/^Authority=/ && !seen { print $2; seen=1 }')
case "$AUTH" in
  "Apple Distribution"*) : ;;
  *) echo "署名が distribution ではない($AUTH)= OTA で入らない" >&2; exit 1 ;;
esac
GTA=$(codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -extract get-task-allow raw - 2>/dev/null || echo "?")
[ "$GTA" = "false" ] || { echo "get-task-allow が $GTA(false でない)= OTA で入らない" >&2; exit 1; }
echo "    署名 $AUTH / get-task-allow=$GTA / build $BUILDNUM"

# --- 3. 梱包 -----------------------------------------------------------------
step "3. .ipa に梱む"
( cd "$STAGE" && zip -qry "$IPA" Payload )
SIZE=$(du -h "$STAGE/$IPA" | cut -f1)
echo "    $STAGE/$IPA ($SIZE)"

step "4. manifest と導線を作る"
cat > "$STAGE/manifest.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>items</key>
	<array>
		<dict>
			<key>assets</key>
			<array>
				<dict>
					<key>kind</key>
					<string>software-package</string>
					<key>url</key>
					<string>$BASE/$IPA</string>
				</dict>
			</array>
			<key>metadata</key>
			<dict>
				<key>bundle-identifier</key>
				<string>$BUNDLE</string>
				<key>bundle-version</key>
				<string>$BUILDNUM</string>
				<key>kind</key>
				<string>software</string>
				<key>title</key>
				<string>RemoteMini</string>
			</dict>
		</dict>
	</array>
</dict>
</plist>
PLIST

# ★HTML を挟むのは飾りではない。iOS は `itms-services://` を**リンクの tap** からしか
#   受けない(Safari のアドレス欄に打ち込んでも動かない)。栞にするのは此の頁。
cat > "$STAGE/index.html" <<HTML
<!doctype html>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>RemoteMini を入れる</title>
<style>
 body{font:17px/1.6 -apple-system,sans-serif;margin:0;padding:2.5rem 1.5rem;
      background:#111;color:#eee}
 a.btn{display:block;text-align:center;background:#0a84ff;color:#fff;
       text-decoration:none;padding:1.1rem;border-radius:14px;font-weight:600;margin:2rem 0}
 dl{display:grid;grid-template-columns:auto 1fr;gap:.35rem 1rem;color:#aaa;font-size:15px}
 dt{color:#777}
</style>
<h1>RemoteMini</h1>
<a class="btn" href="itms-services://?action=download-manifest&amp;url=$BASE/manifest.plist">この端末に入れる</a>
<dl>
 <dt>版</dt><dd>$SHORTVER (build $BUILDNUM)</dd>
 <dt>署名</dt><dd>Ad Hoc / $TEAM</dd>
 <dt>置き場</dt><dd>$DESK_HOST(tailnet 限定)</dd>
</dl>
<p style="color:#777;font-size:14px">
 同じ WiFi でなくて構いません。tailnet に繋がっていれば、外からでも入ります。
</p>
HTML
echo "    manifest と index.html"

if [ "$MODE" = "local" ]; then
  echo "==> 手元まで。置いていない(--no-upload)"
  echo "    $BASE/"
  exit 0
fi

# --- 5. 机へ置く -------------------------------------------------------------
step "5. 机($DESK_SSH)へ置く"
ssh -o ConnectTimeout=15 -o BatchMode=yes "$DESK_SSH" "mkdir -p ~/$DESK_DIR/$SECRET"
scp -q "$STAGE/$IPA" "$STAGE/manifest.plist" "$STAGE/index.html" \
    "$DESK_SSH:~/$DESK_DIR/$SECRET/"
ssh -o ConnectTimeout=15 -o BatchMode=yes "$DESK_SSH" "chmod -R a+rX ~/$DESK_DIR"
echo "    置いた"

step "6. 確かめる(此処は机の LAN に居ない = 同一 WiFi 無しの実証)"
bash "$HERE/tools/ota-verify.sh"

echo
echo "==> 電話で開く頁: $BASE/"
