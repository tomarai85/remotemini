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
# ★掃除は**この一覧に積む**。後から `trap … EXIT` を書くと**此の診断ごと消える** ——
#   実際 2026-08-30 に消えていた(下の ENT の掃除が上書きしていた)。結果、
#   `ota-verify.sh` の rc=2 で `set -e` が中断した時に**1行も出ずに終わり**、
#   呼び側が `| tail` を挟んでいた為に tail の 0 が真の rc を隠して「成功」に見えた。
#   3つ重なって初めて嘘になる: 上書きされた trap / 未測定を失敗と読む / pipe の rc。
CLEANUP=()
cleanup_all() { local f; for f in ${CLEANUP+"${CLEANUP[@]}"}; do /bin/rm -f "$f"; done; }
# ★rc を取った直後に `set +e` する(2026-08-30、Codex が実測)。掃除が失敗すると
#   `set -e` が診断の**前に**止め、元の rc も失う —— Codex の実測では `exit 7` が
#   無言の `exit 1` に化けた。掃除の失敗は警告に留め、元の rc を返す。
trap 'rc=$?; set +e; cleanup_all || echo "★掃除に失敗した(rc=$rc は保つ)" >&2; [ "$rc" -ne 0 ] && echo "★ adhoc-ota.sh は rc=$rc で止まった(直前に出た行の次が犯人)" >&2; exit $rc' EXIT

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

# --- 0. 木が汚れていないか(2026-08-30、実際に踏みかけた)---------------------
# ★変異試験の対照は `ios/Sources/**` を**その場で書き換えて**測り、trap で戻す。
#   走行が殺されると trap は走らず、**変異が木に残る**(`account-ui-control.sh` の
#   註記が既に其の事故を記録している)。気付く仕掛けは「次に其の対照を回した時」だけで、
#   **焼く側は誰も見ていなかった**。
#
#   2026-08-30、全対照の掃引を SIGTERM で止めた直後に実際に残っていた:
#     ConversationView.swift  `inFlight == key` -> `inFlight != nil`(全ボタンが一斉に回る)
#     AccountBar.swift        `.task { await viewModel.load() }` -> `.task { }`(口座が永久に出ない)
#   此処で止めなければ、**その壊れた版を Tom の電話へ配る**所だった。
#
# ★見るのは `ios/Sources` `ios/Tests` `ios/UITests` の3つ。道具(`ios/tools`)の
#   未コミットは焼く物に入らないので止めない —— 止める理由の無い所で止める番人は外される。
# ★見る範囲は「成果物を変える物」であって「iOS の file 全部」ではない
#   (2026-08-30、Codex の指摘1で切り直した)。初版は Sources/Tests/UITests を見ていたが
#   **切り方が逆**だった: `Tests` と `UITests` は Release の app に入らない一方、
#   `project.yml`(xcodegen の入力)・`Assets.xcassets`・`Info.plist`・
#   `tools/build.sh`(版と種を焼き込む)は**成果物を変える**。
#   ★汚れたまま焼くと、**同じ CFBundleVersion で中身が違う束**が出来る ——
#     版番号で古さを見る鎖が、そこから先ずっと嘘を言う。
ART_PATHS="ios/Sources ios/Assets.xcassets ios/project.yml ios/Info.plist ios/tools/build.sh"
step "0. 木が汚れていないか(変異の残骸を配らない)"
DIRTY="$(cd "$HERE/.." && git status --porcelain -- $ART_PATHS 2>/dev/null)"
if [ -n "$DIRTY" ]; then
    echo "$DIRTY" >&2
    echo "★ 成果物を変える path に未コミットの差分が在る。**変異試験の残骸かもしれない**。" >&2
    echo "  見る範囲: $ART_PATHS" >&2
    echo "  確かめる: git diff -- $ART_PATHS" >&2
    echo "  戻す:     git checkout -- $ART_PATHS" >&2
    # ★配る時は逃げ道を置かない(Codex の指摘1)。env で越えられる門は、いずれ
    #   「毎回打つ物」になる。**人の電話に載る**物なので commit か stash を要求する。
    #   手元で形を見たいだけなら `--no-upload` を使う(そちらは越えられる)。
    if [ "$MODE" = "local" ] && [ "${RC_OTA_ALLOW_DIRTY:-0}" = "1" ]; then
        echo "    --no-upload かつ RC_OTA_ALLOW_DIRTY=1 なので続ける(配らないので害が外へ出ない)"
    else
        echo "  配る前に commit か stash を。手元で見るだけなら: RC_OTA_ALLOW_DIRTY=1 ./tools/adhoc-ota.sh --no-upload" >&2
        exit 1
    fi
else
    echo "    綺麗(成果物を変える path に未コミットの差分なし)"
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
CLEANUP+=("$ENT")   # ★trap を書き足さない(上の一覧に積む)
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
# ★掲載の順が意味を持つ(Codex 2026-08-28)。**束を先に、manifest を最後に**。
#   逆だと「manifest は新しい版を名乗っているのに束はまだ古い」窓が開く ——
#   其の隙に電話が取りに来ると、電話は新しい版を入れたと信じて古い物を動かす。
#   署名は**完全性**を証明するが**新しさ**は証明しないので、此の取り違えは検知されない。
# ★★**上書きの最中に部分 file を掴まれる**(2026-08-30、Codex の指摘3)。
#   `scp` は宛先を切り詰めてから書くので、其の間に電話が取りに来ると**書きかけの束**を掴む。
#   署名は完全性を証明するが「今この瞬間の file が完全か」は証明しないので、
#   電話には「入らなかった」としか見えず原因が判らない。
#
#   直し方は**名前を変えない**。`ota-verify.sh` が `RemoteMini.ipa` を3箇所で直に叩くので、
#   版付きの名前にすると検証の方が壊れる —— 原子性を買って検証を失うのは割に合わない。
#   一時名で送ってから remote で `mv` する。**rename は原子的**なので、電話が見るのは
#   「前の完全な file」か「次の完全な file」のどちらかだけになる。
#
# ★掲載の順は変えない(Codex 2026-08-28)。**束を先に、manifest を最後に**。
#   逆だと「manifest は新しい版を名乗っているのに束はまだ古い」窓が開き、
#   電話は新しい版を入れたと信じて古い物を動かす。
put_atomic() {  # put_atomic <手元の file> <向こうの名前>
    scp -q "$1" "$DESK_SSH:~/$DESK_DIR/$SECRET/$2.new"
    ssh -o ConnectTimeout=15 -o BatchMode=yes "$DESK_SSH" \
        "cd ~/$DESK_DIR/$SECRET && mv -f '$2.new' '$2'"
}
# 束を差し替える前に1世代だけ退避(rollback の材料)。
ssh -o ConnectTimeout=15 -o BatchMode=yes "$DESK_SSH" \
    "cd ~/$DESK_DIR/$SECRET 2>/dev/null && [ -f $IPA ] && cp -f $IPA $IPA.prev" || true
put_atomic "$STAGE/$IPA" "$IPA"
put_atomic "$STAGE/index.html" "index.html"
# manifest が最後。之が置かれた瞬間から新しい版が「配られている」事になる。
put_atomic "$STAGE/manifest.plist" "manifest.plist"
# ★**所有者だけ**にする(2026-08-28、敵対レビューが掴んだ)。初版は `chmod -R a+rX` と
#   書いていた —— 配信する物だから読ませる、という反射で。之が唯一の守りを潰していた:
#   配る path の秘密の一段は「推測できない」事が全部なのに、`a+rX` は**同じ機体の
#   全ローカルアカウントに dir の一覧を許す**。実測 2026-08-28、friday の実アカウントは
#   athenas / tomtim / udagawa の3つ、全員が staff に居て、`/Users/athenas` は
#   `drwxr-x---`(= group に r-x)。つまり秘密の hex は他の2人から**そのまま読めた**。
#   配るのは node(athenas 権限)なので、他人に読ませる必要は最初から無い。
#   ★守りを1つ足すより、**主張していない守りを主張しない**方が先: 之を直すまで
#     `ota-delivery.md` の「推測できない path の一段」は嘘だった。
ssh -o ConnectTimeout=15 -o BatchMode=yes "$DESK_SSH" "chmod 700 ~/$DESK_DIR && chmod -R go-rwx ~/$DESK_DIR"
echo "    置いた"

step "6. 確かめる(此処は机の LAN に居ない = 同一 WiFi 無しの実証)"
# ★`ota-verify.sh` は **未測定が1件でも rc=2** を返す(電話の UDID は今聞けない、等)。
#   未測定は失敗ではない —— それを `set -e` で中断に落とすと、**配り終わった後に
#   黙って止まる**。実際 2026-08-30 の走行がそうなり、step 7 が一度も走らなかった。
#   赤(1)は止める。未測定(2)は名指しして続ける。
set +e
vout="$(bash "$HERE/tools/ota-verify.sh" 2>&1)"; vrc=$?
set -e
printf '%s\n' "$vout"
# ★rc=2 を一律で「続けてよい」に丸めない(2026-08-30、Codex の指摘2)。
#   `ota-verify.sh` は **UDID が聞けない時**にも **HTTPS 面に届かない時**にも 2 を返す。
#   後者は「配れていない」そのものなので、続けると *ssh で manifest が読めるだけ*で
#   最終的に exit 0 に辿り着ける = **届いていないのに成功**。
#   区別は rc ではなく**中身**でする: 配達の3本(manifest / 束 / 導線)が緑である事を要求する。
delivered_ok() {
    printf '%s' "$vout" | grep -q "緑.*manifest が返る" \
      && printf '%s' "$vout" | grep -q "緑.*束(.ipa)が返る" \
      && printf '%s' "$vout" | grep -q "緑.*導線の頁が返る"
}
case "$vrc" in
    0) ;;
    2)
        if delivered_ok; then
            echo "    ※未測定が在る(rc=2)が、配達の3本は緑。続ける"
        else
            echo "★rc=2 だが**配達そのものが 測れていない**(面に届いていない可能性)。止める" >&2
            exit 2
        fi ;;
    *) echo "★配る面の検証が赤い(rc=$vrc)" >&2; exit "$vrc" ;;
esac

# ★配った版が、手元の署名済みより古くない事を**別の道具で**確かめる(2026-08-30)。
#   `ota-verify.sh` は「取りに行けるか」を見るが、**何番が置かれたかは見ない**。
#   実際その隙で 2 日間ずれた: 配布 89 / Tom の電話 96 / HEAD なら 99。
#   §11 は此の頁を「Tom が栞から自分で入れ直す道」と定めているので、
#   古い版が載ったままだと**唯一の復旧経路が彼を巻き戻す**。
step "7. 配った版が古くない事(rc-backend/tools/ota-freshness-check.sh)"
bash "$HERE/../rc-backend/tools/ota-freshness-check.sh"

echo
echo "==> 電話で開く頁: $BASE/"
