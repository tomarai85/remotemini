#!/bin/bash
# controls-for: tools/health-observer.sh tools/health-step.mjs tools/tailnet-key-expiry.sh
# `tools/health-observer.sh` + `tools/health-step.mjs` の**対照**(DESIGN §7-P の検査欄)。
#
# ここが測るのは「鳴る」ではなく **「鳴らないべき時に鳴らず、鳴るべき時に1回だけ鳴る」**。
# yoda(2026-07-31)で 46 時間気付けなかった原因は閾値でもロジックでもなく**通知先**だったので、
# 通知の**出口**まで通して見る。ただし本物の Discord/iMessage へは**一度も出さない**:
# 出し先を捨て台本に差し替えて、何が渡ったかをファイルで受ける。
#
# ★入力は本物の生成元から取る(run-controls.sh 冒頭の規則(1))。
#   probe の検査は curl を差し替えず、**本物の HTTP サーバを立てて叩く**。
#   手で書いた応答を食わせると「応答の形についての私の思い込み」ごと緑になる。
#
# 終了コード: 0=緑 / 1=赤 / 2=測定不成立
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

OBS="$ROOT/tools/health-observer.sh"
[ -f "$OBS" ] || { echo "対象が無い: $OBS"; exit 2; }
[ -f "$ROOT/tools/health-step.mjs" ] || { echo "判定台本が無い: $ROOT/tools/health-step.mjs"; exit 2; }

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
ng()   { fail=$((fail+1)); printf '  NG   %s\n' "$1"; }
chk()  { if [ "$2" = "$3" ]; then ok "$1"; else ng "$1 — 期待[$3] 実際[$2]"; fi; }

SB="$(cd "$(mktemp -d /tmp/health-ctl.XXXXXX)" && pwd -P)"
SRV_PID=""
cleanup() {
    [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null
    for f in "$SB"/tools/*; do [ -e "$f" ] && /bin/rm -f "$f"; done
    rmdir "$SB/tools" 2>/dev/null
    for f in "$SB"/*; do [ -e "$f" ] && /bin/rm -f "$f"; done
    rmdir "$SB" 2>/dev/null
}
trap cleanup EXIT

# ★差替型の継ぎ目(`tools/prove-control.sh` が「直す前の版」を差し込む口)。
#   素直に旧版の経路をそのまま使うと**測定にならない**: health-observer.sh は兄弟を
#   自分の位置から引く(`$ROOT/tools/health-step.mjs`)ので、/tmp に置かれた旧版は
#   判定台本を見失って落ちる —— 対照は測りたい物へ辿り着く前に赤くなり、
#   **理由の違う赤**が「効いている」と読まれる(prove-control.sh が一番嫌う偽陽性)。
#   なので差された時だけ、砂場に tools/ を組んで**兄弟ごと**据える。
#   差し替えるのは1枚だけ(規則: 守られている file 以外は今の版のまま)。
#
#   ★兄弟は health-step.mjs だけではない —— それ自身が `../src/health.mjs` を読む。
#     判定台本1枚だけ写した初稿は、node が import に失敗して KIND が想定外になり、
#     **28 枚が赤**になった。狙った Q3 の対照は 6 枚なので、残り 22 枚は
#     「差し替えが壊れている」赤。そのまま読めば「効いている」と誤読する ——
#     赤の枚数ではなく**赤の理由**を見る事。だから src は丸ごと繋いで、
#     差分を「守られている file 1枚」に閉じ込める。
if [ -n "${RC_HEALTH_OBS:-}" ]; then
    [ -f "$RC_HEALTH_OBS" ] || { echo "差し込まれた版が無い: $RC_HEALTH_OBS"; exit 2; }
    /bin/mkdir -p "$SB/tools" || exit 2
    /bin/cp "$ROOT/tools/health-step.mjs" "$SB/tools/health-step.mjs" || exit 2
    /bin/ln -s "$ROOT/src" "$SB/src" || exit 2
    /bin/cp "$RC_HEALTH_OBS"              "$SB/tools/health-observer.sh" || exit 2
    /bin/chmod +x "$SB/tools/health-observer.sh"
    OBS="$SB/tools/health-observer.sh"
    echo "  (継ぎ目 \$RC_HEALTH_OBS で差し替え済み: $RC_HEALTH_OBS)"
fi

# 捨ての通知先: 渡された文面と mention の値を1行で記録するだけ。本物へは出さない。
cat > "$SB/fake-notify.sh" <<'EOF'
#!/bin/bash
printf 'MENTION=[%s] MSG=[%s]\n' "${FLEET_NOTIFY_MENTION:-既定}" "$(cat)" >> "$FAKE_NOTIFY_LOG"
EOF
chmod +x "$SB/fake-notify.sh"
export FAKE_NOTIFY_LOG="$SB/notify.log"
: > "$FAKE_NOTIFY_LOG"

# ★鍵の残日数の系統を、**それを測っていない対照からは黙らせる**(2026-08-03 に足した時の実測)。
#   `check_key_expiry` は毎回走るので、既定のままだと(a)本物の tailscale を1回叩いて数十秒
#   食い、(b)観測側の鍵が閾値を割った日から、鍵とは無関係な対照の通知数が全部 1 ずれる。
#   実測: この機械の Self は残り 46 日 = 閾値 45 の**すぐ外**。つまり明日には割る = 時限爆弾。
#   なので既定は「期限なし」を返す捨て台本に差し替える。鍵を測る対照だけが §10 で本物を差す。
printf '#!/bin/bash\necho "KEY self - none"\nexit 0\n' > "$SB/quiet-key.sh"; chmod +x "$SB/quiet-key.sh"

STATE="$SB/state.json"
# 「監視が最後に働けた時刻」の記録(§11 が測る)。既定は `$STATE.last-ok` だが、
# 砂場の中で**明示的に**持つ —— 位置を既定値の綴りに頼ると、本体側で既定を変えた日に
# 対照は「何も測っていないまま緑」になる(測る相手を見失った事に気付けない)。
OKM="$SB/last-ok.mark"

_obs() {  # 環境を差して実走するだけ。stdout は握り潰さない(§11-g が読む)
    RC_HEALTH_CONF="$SB/none.conf" \
    RC_HEALTH_URL="${TEST_URL:-http://127.0.0.1:9/健康}" \
    RC_HEALTH_HOST="test.example" \
    RC_HEALTH_STATE="$STATE" \
    RC_HEALTH_NOTIFY="$SB/fake-notify.sh" \
    RC_HEALTH_LOG="$SB/observer.log" \
    RC_HEALTH_BROKEN_MARK="$SB/broken.mark" \
    RC_HEALTH_OK_MARK="$OKM" \
    RC_HEALTH_KEY_CHECK="${TEST_KEY_CHECK:-$SB/quiet-key.sh}" \
    RC_HEALTH_KEY_MARK="$SB/key.mark" \
    RC_HEALTH_KEY_EVERY="${TEST_KEY_EVERY:-0}" \
    RC_HEALTH_KEY_PEER="${TEST_KEY_PEER:-test.example}" \
    RC_TAILSCALE_BIN="${TEST_TAILSCALE:-$SB/no-such-tailscale}" \
    bash "$OBS" "$@"
}
run()     { _obs "$@" >/dev/null 2>&1; echo $?; }   # $@ = health-observer.sh への引数
run_out() { _obs "$@" 2>/dev/null; }                # 終了コードでなく**文面**を見る時
notify_count() { wc -l < "$FAKE_NOTIFY_LOG" | tr -d ' '; }

echo "── 1. 連続の数え方と、鳴る回数 ──"
: > "$FAKE_NOTIFY_LOG"; /bin/rm -f "$STATE"
run --inject-fail >/dev/null; run --inject-fail >/dev/null
chk "2回失敗では鳴らない" "$(notify_count)" "0"
run --inject-fail >/dev/null
chk "3回目で1回だけ鳴る" "$(notify_count)" "1"
run --inject-fail >/dev/null; run --inject-fail >/dev/null
chk "★以後は失敗が続いても鳴らない(黙らされない為)" "$(notify_count)" "1"

echo "── 2. mention の向き(落ちた=@Tom / 戻った=ping 無し)──"
grep -q 'MENTION=\[既定\]' "$FAKE_NOTIFY_LOG" \
  && ok "落ちた通知は mention 既定(= @Tom が付く)" \
  || ng "落ちた通知に mention が付いていない"
run --inject-ok >/dev/null
chk "戻ったら鳴る" "$(notify_count)" "2"
tail -1 "$FAKE_NOTIFY_LOG" | grep -q 'MENTION=\[0\]' \
  && ok "★戻り通知は ping 抑制(FLEET_NOTIFY_MENTION=0 が出し先へ渡っている)" \
  || ng "戻り通知が ping を抑えていない: $(tail -1 "$FAKE_NOTIFY_LOG")"
run --inject-ok >/dev/null; run --inject-ok >/dev/null
chk "戻った後は成功が続いても鳴らない" "$(notify_count)" "2"

echo "── 3. 初回(状態ファイルが無い)で「戻りました」と言わない ──"
: > "$FAKE_NOTIFY_LOG"; /bin/rm -f "$STATE"
run --inject-ok >/dev/null; run --inject-ok >/dev/null
chk "★何も起きていないのに鳴らない" "$(notify_count)" "0"

echo "── 4. 通知の文面に会話の情報が入らない ──"
: > "$FAKE_NOTIFY_LOG"; /bin/rm -f "$STATE"
run --inject-fail >/dev/null; run --inject-fail >/dev/null; run --inject-fail >/dev/null
if grep -qiE 'session|cwd|pane|tmux|api\.key|Bearer' "$FAKE_NOTIFY_LOG"; then
    ng "文面に載ってはいけない語が在る: $(cat "$FAKE_NOTIFY_LOG")"
else ok "会話の情報が載っていない"; fi
grep -q 'test.example' "$FAKE_NOTIFY_LOG" && ok "どの機械かは載っている" || ng "host が載っていない"

echo "── 5. ★監視自体が壊れた時、黙らない ──"
: > "$FAKE_NOTIFY_LOG"; /bin/rm -f "$SB/broken.mark"
echo 'これは JSON ではない' > "$STATE"
rc="$(run --inject-fail)"
chk "壊れた状態ファイルで終了コード 3(= 0 に丸めない)" "$rc" "3"
chk "  その事を通知する" "$(notify_count)" "1"
grep -q '監視側が壊れています' "$FAKE_NOTIFY_LOG" && ok "  文面が「監視側」だと分かる" || ng "  文面が曖昧"
rc="$(run --inject-fail)"
chk "  ★2回目は抑制(10分毎に鳴り続けて黙らされるのを防ぐ)" "$(notify_count)" "1"
echo '{"status":"up","fails":"三","firstFailAt":null}' > "$STATE"
rc="$(run --inject-fail)"
chk "形だけ JSON でも中身が違えば 3" "$rc" "3"

echo "── 6. probe を**本物の HTTP サーバ**で測る ──"
/bin/rm -f "$STATE" "$SB/broken.mark"; : > "$FAKE_NOTIFY_LOG"
cat > "$SB/srv.mjs" <<'EOF'
import { createServer } from "node:http";
import { writeFileSync } from "node:fs";
const srv = createServer((req, res) => {
    if (req.url === "/healthz")      { res.writeHead(200, {"content-type":"application/json"}); res.end(JSON.stringify({ok:true,pid:1,uptime:2,version:"t"})); }
    else if (req.url === "/notok")   { res.writeHead(200, {"content-type":"application/json"}); res.end(JSON.stringify({ok:false})); }
    else if (req.url === "/hollow")  { res.writeHead(200, {"content-type":"text/html"}); res.end("<html>proxy の受け口</html>"); }
    // ★HTTP コードの検査**だけ**を切り出す入口: 中身は完全に健康な形なので、
    //   ここが失敗と判定されるのは「コードを見ている」から以外にあり得ない。
    //   これが無いと 404 の対照は本体の検査に拾われてしまい、コードの検査を消しても緑のままだった(実測)。
    else if (req.url === "/sick503") { res.writeHead(503, {"content-type":"application/json"}); res.end(JSON.stringify({ok:true,pid:1,uptime:2,version:"t"})); }
    else                             { res.writeHead(404); res.end("no"); }
});
srv.listen(0, "127.0.0.1", () => writeFileSync(process.argv[2], String(srv.address().port)));
EOF
node "$SB/srv.mjs" "$SB/port" & SRV_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$SB/port" ] && break; sleep 0.3; done
PORT="$(cat "$SB/port" 2>/dev/null)"
if [ -z "$PORT" ]; then echo "  (試験用サーバが上がらなかった)"; echo "HEALTH-OBSERVER-CONTROLS: 測定不成立"; exit 2; fi
BASE="http://127.0.0.1:$PORT"

probe_says() {   # $1 = path。1回叩いた後の状態の fails を返す(0 = 成功と判定された)
    /bin/rm -f "$STATE"
    TEST_URL="$BASE$1" run >/dev/null
    /usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["fails"])' "$STATE" 2>/dev/null || echo "?"
}
chk "200 + ok:true は成功"                  "$(probe_says /healthz)" "0"
chk "200 でも ok:false は失敗"              "$(probe_says /notok)"   "1"
chk "★200 だが中身が別物(受け口/proxy)は失敗" "$(probe_says /hollow)"  "1"
chk "404 は失敗"                            "$(probe_says /nope)"    "1"
chk "★503 は中身が健康でも失敗(コードを見ている事の単独対照)" "$(probe_says /sick503)" "1"
kill "$SRV_PID" 2>/dev/null; wait "$SRV_PID" 2>/dev/null; SRV_PID=""
chk "★サーバを落とすと失敗(繋がらない = 落ちている)" "$(probe_says /healthz)" "1"

echo "── 7. ★配達に失敗した警報を消費しない(この設計で一番怖い壊れ方)──"
# 元の欠陥(実際に再現させてから直した): 「知らせると決めた」時点で状態を down に
# 確定していたので、出し先が壊れていると **出し先が直っても二度と鳴らなかった**。
# ログには「鳴らさない」と正常同然に出るので、外から見て正常と見分けが付かない。
# 状態の項は `owed`(= まだ Tom に伝えていない変化)ひとつ。null = 借り無し = 伝え済み。
owed_kind() { /usr/bin/python3 -c 'import json,sys
o=json.load(open(sys.argv[1])).get("owed")
print("none" if o is None else o.get("kind","?"))' "$STATE" 2>/dev/null || echo "?"; }
run_with_notify() {   # $1 = 出し先。残りは health-observer.sh への引数
    local n="$1"; shift
    RC_HEALTH_CONF="$SB/none.conf" RC_HEALTH_URL="http://127.0.0.1:9/健康" \
    RC_HEALTH_HOST="test.example" RC_HEALTH_STATE="$STATE" RC_HEALTH_NOTIFY="$n" \
    RC_HEALTH_LOG="$SB/observer.log" RC_HEALTH_BROKEN_MARK="$SB/broken.mark" \
    RC_HEALTH_OK_MARK="$OKM" \
    RC_HEALTH_KEY_CHECK="${TEST_KEY_CHECK:-$SB/quiet-key.sh}" \
    RC_HEALTH_KEY_MARK="$SB/key.mark" \
    RC_HEALTH_KEY_EVERY="${TEST_KEY_EVERY:-0}" \
    RC_HEALTH_KEY_PEER="${TEST_KEY_PEER:-test.example}" \
    RC_TAILSCALE_BIN="${TEST_TAILSCALE:-$SB/no-such-tailscale}" \
    bash "$OBS" "$@" >/dev/null 2>&1
    echo $?
}
printf '#!/bin/bash\ncat >/dev/null\nexit 1\n' > "$SB/notify-fails.sh"; chmod +x "$SB/notify-fails.sh"

/bin/rm -f "$STATE" "$SB/broken.mark"; : > "$FAKE_NOTIFY_LOG"
run_with_notify "$SB/does-not-exist.sh" --inject-fail >/dev/null
run_with_notify "$SB/does-not-exist.sh" --inject-fail >/dev/null
rc="$(run_with_notify "$SB/does-not-exist.sh" --inject-fail)"
chk "出し先が実行できない時、0 で終わらない" "$rc" "2"
chk "  ★警報を消費していない(借りが残っている)" "$(owed_kind)" "down"
chk "  1通も出ていない" "$(notify_count)" "0"

run --inject-fail >/dev/null      # 出し先が直った = 本物(捨て台本)へ
chk "★出し先が直った次の回に、ちゃんと鳴る(元の欠陥はここで永久に沈黙した)" "$(notify_count)" "1"
chk "  配達できたので借りが消える" "$(owed_kind)" "none"
run --inject-fail >/dev/null; run --inject-fail >/dev/null
chk "  以後は静か(重複を垂れ流さない)" "$(notify_count)" "1"

/bin/rm -f "$STATE" "$SB/broken.mark"; : > "$FAKE_NOTIFY_LOG"
run_with_notify "$SB/notify-fails.sh" --inject-fail >/dev/null
run_with_notify "$SB/notify-fails.sh" --inject-fail >/dev/null
rc="$(run_with_notify "$SB/notify-fails.sh" --inject-fail)"
chk "出し先が非0で終わった時、監視は健全と名乗らない" "$rc" "3"
chk "  ★状態は未配達のまま(次回また鳴る)" "$(owed_kind)" "down"

# ★古い形の状態ファイル(owed が無い / 旧版の announced が付いている)を「壊れている」と切らない。
#   切ると、上げ直した瞬間に「監視が壊れた」と騒ぐ = 本物の異常と見分けが付かなくなる。
/bin/rm -f "$SB/broken.mark"; : > "$FAKE_NOTIFY_LOG"
echo '{"status":"down","fails":9,"firstFailAt":1000}' > "$STATE"
rc="$(run --inject-fail)"
chk "owed の無い古い状態でも 3 にしない" "$rc" "0"
chk "  ★未配達と読んで鳴らし直す(沈黙より重複へ倒す)" "$(notify_count)" "1"

# ★旧版が書いた `announced` 付きの状態も切らない(項の名前を変えた時の移行の穴)。
/bin/rm -f "$SB/broken.mark"; : > "$FAKE_NOTIFY_LOG"
echo '{"status":"down","fails":9,"firstFailAt":1000,"announced":true}' > "$STATE"
rc="$(run --inject-fail)"
chk "旧版の announced 付きでも 3 にしない" "$rc" "0"
chk "  ★知らない項は無視して鳴らし直す(沈黙より重複へ倒す)" "$(notify_count)" "1"

echo "── 8. ★「監視が壊れた」の抑制時計も、知らせ**終えて**から進める ──"
# §7 と同じ「一語が二役」の形が、抑制時計の側にも残っていた(2026-08-02 に発見):
# `broken.mark` を通知の**前**に書いていたので、監視が壊れていて通知も失敗すると
# 6 時間(BROKEN_EVERY)黙る。壊れている事を誰にも言えないまま時計だけ進む形。
mark_exists() { [ -f "$SB/broken.mark" ] && echo yes || echo no; }

/bin/rm -f "$STATE" "$SB/broken.mark"; : > "$FAKE_NOTIFY_LOG"
echo '{"status":"壊れている"}' > "$STATE"
rc="$(run_with_notify "$SB/notify-fails.sh" --inject-fail)"
chk "壊れた状態 + 出し先が失敗 → 3" "$rc" "3"
chk "  ★抑制時計を進めていない(次回また鳴らせる)" "$(mark_exists)" "no"

rc="$(run --inject-fail)"   # 出し先が直った
chk "出し先が直った次の回に、壊れている事を鳴らす" "$(notify_count)" "1"
chk "  ★ここで初めて抑制時計が進む" "$(mark_exists)" "yes"
rc="$(run --inject-fail)"
chk "  以後 6 時間は抑制(10分毎に鳴り続けて黙らされるのを防ぐ)" "$(notify_count)" "1"

echo "── 9. ★監視が**動き出す前**に落ちる形でも黙らない ──"
# 2026-08-02 の実測(直す前): 閾値に `0` と書いた設定で 5 回叩いて通知 **0 通**、
# node の場所を違えて 3 回叩いて **0 通**。log に 1 行残るだけで、監視は永久に鳴らない。
# 判定側の門(`health.mjs` の閾値検査)は在ったが、**門が閉じた事を誰にも知らせていなかった**
# = 守り手自身が静かに死ぬ形。据え付けた当日に書き損じで起きる類なのが特に悪い。
# 設定は環境変数で差す(`run` は threshold も node も指定しないので、export が素通りする)。

/bin/rm -f "$STATE" "$SB/broken.mark"; : > "$FAKE_NOTIFY_LOG"
export RC_HEALTH_THRESHOLD=0
rc="$(run --inject-fail)"
chk "設定の閾値が不正 → 3(監視が壊れている)" "$rc" "3"
chk "  ★その事を Tom に知らせる(元は log だけで 0 通)" "$(notify_count)" "1"
grep -q '監視側が壊れています' "$FAKE_NOTIFY_LOG" \
  && ok "  文面で「監視側」だと分かる" || ng "  文面が曖昧: $(cat "$FAKE_NOTIFY_LOG")"
# ★負の対照: 判定が吐いた素の文字列を Tom の面へ流していない事。
#   通知は Tom が読む面なので、素性の分からない文字列の通り道にしない。
if grep -qE '受け取った値|threshold|health-step' "$FAKE_NOTIFY_LOG"; then
    ng "  ★判定の生の文言が通知に漏れている: $(cat "$FAKE_NOTIFY_LOG")"
else
    ok "  ★判定の生の文言は漏れていない(出るのは機械名と短い語だけ)"
fi
rc="$(run --inject-fail)"
chk "  2回目は抑制(状態ファイル側と同じ時計を共用)" "$(notify_count)" "1"
unset RC_HEALTH_THRESHOLD

/bin/rm -f "$STATE" "$SB/broken.mark"; : > "$FAKE_NOTIFY_LOG"
export RC_HEALTH_NODE="$SB/no-such-node"
rc="$(run --inject-fail)"
chk "node の場所が違う(launchd の PATH / brew の移動)→ 3" "$rc" "3"
chk "  ★その事を Tom に知らせる(元は log だけで 0 通)" "$(notify_count)" "1"
unset RC_HEALTH_NODE

# 起動前に落ちた回も「知らせ**終えて**から」時計を進める(§8 と同じ規則が効いているか)。
/bin/rm -f "$STATE" "$SB/broken.mark"; : > "$FAKE_NOTIFY_LOG"
export RC_HEALTH_THRESHOLD=0
rc="$(run_with_notify "$SB/notify-fails.sh" --inject-fail)"
chk "起動前の破損 + 出し先が失敗 → 3" "$rc" "3"
chk "  ★抑制時計を進めていない(次回また鳴らせる)" "$(mark_exists)" "no"
rc="$(run --inject-fail)"
chk "  出し先が直った次の回に鳴る" "$(notify_count)" "1"
chk "  ★ここで初めて抑制時計が進む" "$(mark_exists)" "yes"
unset RC_HEALTH_THRESHOLD

/bin/rm -f "$STATE" "$SB/broken.mark"; : > "$FAKE_NOTIFY_LOG"
export RC_HEALTH_THRESHOLD=0
rc="$(run --inject-fail --dry-run)"
chk "--dry-run は壊れていても本物の出し先へ出さない" "$(notify_count)" "0"
chk "  それでも 3 を返す(健全と名乗らない)" "$rc" "3"
chk "  ★抑制時計も進めない(次に本番で叩いた時に鳴る)" "$(mark_exists)" "no"
unset RC_HEALTH_THRESHOLD

echo "── 10. ★tailnet 鍵の残日数(期限の**前**に言う為の、up/down とは別系統)──"
# 何を守っているか: 鍵が切れると機械は tailnet から落ちる。up/down の監視はそれを
# 「落ちた」としか言えず、しかも**切れてから**しか言えない。だから期限前に言う系統が要る。
#
# ★測る相手が2つある理由(2026-08-03 実測): 監視は「edith を、別のノードから」叩く形なので
#   鎖には鍵が2本ある。実測値は 観測側 46 日 / edith 143 日 = **先に切れるのは監視する側**。
#   遠い方だけ見ていると先に壊れる方を一度も見ない。10-c がその向きの対照。
#
# ★入力は本物の生成元から取る(run-changes.sh 冒頭の規則(1)):
#   偽の JSON を手で書くと「status --json の形についての私の思い込み」ごと緑になる。
#   なので**本物の `tailscale status --json` を1回取り**、台本が読む項(HostName / DNSName /
#   KeyExpiry)だけを残し、機械名は差し替え、KeyExpiry だけを合成値にする。
#   ★残す項を絞るのは PII の為でもある: 生の status には LoginName(= 実在の mail address)が
#     載る。対照の出力にも一時ファイルにも、それを持ち込まない。
#
# ── 規則(2)の測定結果(2026-08-03、`scratchpad/key-mutants.sh`)────────────
#   「直したら、直す前の版で対照が赤になるか個別に見る」を欠陥ごとに1つずつ実施。
#   ★先に**変異なしの木**を写して 81/81 緑を確認してから始める事。最初の sweep は
#     写す木に `src/` を入れ忘れ(`tools/health-step.mjs` が `../src/health.mjs` を読む)、
#     全部が手前で転けていた —— その赤は変異ではなく異常終了が作った赤で、何も測っていない。
#     判定に「§10 の外で落ちた数」を必ず併記するのはその為。
#
#     ★もう1つの偽の緑(同日 二巡目): 本体を書き換えると**古い変異の sed が当たらなくなる**。
#       当たらない sed は「変異なしの木」を走らせているのと同じで、対照は緑のまま出る。
#       駆動側は当てる**前後のハッシュ**を比べ、変わっていなければ「未測定」と言う。
#     ★3つ目の偽の緑: 狙いの照合に `ok()` の文言を書くと、赤くなっているのに緑と出る
#       (NG 行に出るのは `ng()` の文言)。照合は必ず**失敗時の文**で書く。
#
#     変異(1箇所だけ壊す)          落ちた対照                     §10外の巻き添え
#     b=9999 → 45                   10-a 両方 200 日 → 鳴らない      0
#     呼ぶ位置を判定の後ろへ        10-b 異常なしの回でも鳴る        0
#     観測側を見ない(peer だけ)   10-c 観測側だと分からない        0  ←★退けた設計そのもの
#     段の抑制を外す                10-d 9 日は同じ段 = 増えない     0
#     `step <= 7` → 常に真          10-d 遠い段に ping が付いている  0
#     `step <= 7` → 常に偽          10-d 7 日以内は @Tom             0
#     期限なしで段を戻さない        10-e また近付いたら鳴り直す      0
#     rc=2 の分岐を殺す             10-f 監視側が壊れている          0
#     配達の**前**に段を進める      10-g 失敗した side の段          0
#     --dry-run で記録を書く        10-h 記録も進めない              0
#     `[ $# -ge 2 ]` を外す         10-j 値の無い --peer             0
#     既定 SCOPE を chain に        10-i 引数なし・遠い → 0          0
#     ── 査読(Codex 2026-08-03)で塞いだ穴を戻す変異 ──
#     段を鎖で1つだけ持つ           10-k 相手が段7へ入ったら鳴る     0
#     2欄目を self の段として読む   10-k 古い2欄の記録は未通知       0
#     期限切れの段(0)を消す       10-l 期限を越えたら段0           0
#     失敗した回も時計を進める      10-g 時計も進めない              0
#     観測主体を名乗らない          10-l 観測主体が載っていない      0
TS_REAL="${RC_TAILSCALE_BIN:-/Applications/Tailscale.app/Contents/MacOS/Tailscale}"
KEY_UNMEASURED=0
if [ ! -x "$TS_REAL" ]; then
    echo "  ※測定不成立: 本物の tailscale が無い($TS_REAL)= 生成元から入力を取れない"
    KEY_UNMEASURED=1
else
    "$TS_REAL" status --json 2>/dev/null > "$SB/ts-real.json"
    if ! /usr/bin/python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
self_n = d.get("Self") or {}
peers = [v for v in (d.get("Peer") or {}).values() if v.get("KeyExpiry")]
if not peers:
    # 本物に KeyExpiry を持つ相手が1人も居ない = この形を実物で確かめられない。
    raise SystemExit(3)
out = {
  "Self": {"HostName": "test-self", "DNSName": "test-self.example.ts.net.",
           "KeyExpiry": self_n.get("KeyExpiry")},
  "Peer": {"nodekey:test": {"HostName": "test-peer", "DNSName": "test-peer.example.ts.net.",
                            "KeyExpiry": peers[0].get("KeyExpiry")}},
}
json.dump(out, open(sys.argv[2], "w"))
' "$SB/ts-real.json" "$SB/ts-skeleton.json"; then
        echo "  ※測定不成立: 本物の status --json から骨組みを採れない(形が変わった可能性)"
        KEY_UNMEASURED=1
    fi
    /bin/rm -f "$SB/ts-real.json"      # ★生の status は即座に捨てる(LoginName を残さない)
fi

if [ "$KEY_UNMEASURED" -eq 0 ]; then
    # 偽 tailscale: 骨組みの KeyExpiry だけを環境変数の日数で差し替えて返す。
    #   FAKE_*_DAYS = 整数(その日数後に切れる) / none(期限なし) / gone(相手が居ない)
    cat > "$SB/fake-tailscale.sh" <<'EOF'
#!/bin/bash
[ "${1:-}" = "status" ] || exit 1
/usr/bin/python3 - "$FAKE_TS_SKELETON" <<'PY'
import json, sys, os, datetime
d = json.load(open(sys.argv[1]))
def stamp(days):
    # ★12 時間足す: ちょうど N 日後に置くと、読む頃には僅かに過ぎていて
    #   `(t - now).days` が N-1 に落ちる(切り捨て)。対照が 1 日ずれる。
    t = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=int(days), hours=12)
    return t.strftime("%Y-%m-%dT%H:%M:%SZ")
def apply(node, spec):
    if spec == "none": node.pop("KeyExpiry", None)
    else:              node["KeyExpiry"] = stamp(spec)
apply(d["Self"], os.environ.get("FAKE_SELF_DAYS", "none"))
p = os.environ.get("FAKE_PEER_DAYS", "none")
if p == "gone": d["Peer"] = {}
else:           apply(d["Peer"]["nodekey:test"], p)
json.dump(d, sys.stdout)
PY
EOF
    chmod +x "$SB/fake-tailscale.sh"

    export FAKE_TS_SKELETON="$SB/ts-skeleton.json"
    export TEST_KEY_CHECK="$ROOT/tools/tailnet-key-expiry.sh"   # ★本物を通す(偽の porcelain を書かない)
    export TEST_TAILSCALE="$SB/fake-tailscale.sh"
    export TEST_KEY_PEER="test-peer"
    key_run() { export FAKE_SELF_DAYS="$1" FAKE_PEER_DAYS="$2"; shift 2; run "$@"; }
    key_count()    { local n; n="$(grep -c 'tailnet の鍵' "$FAKE_NOTIFY_LOG" 2>/dev/null)"; echo "${n:-0}"; }
    broken_count() { local n; n="$(grep -c '監視側が壊れています' "$FAKE_NOTIFY_LOG" 2>/dev/null)"; echo "${n:-0}"; }
    key_reset()    { : > "$FAKE_NOTIFY_LOG"; /bin/rm -f "$STATE" "$SB/key.mark" "$SB/broken.mark"; }

    echo "  ── 10-a. 閾値の内側で鳴る / 外側で鳴らない ──"
    key_reset; key_run 200 200 --inject-ok >/dev/null
    chk "★両方 200 日 → 鳴らない(負の対照)" "$(key_count)" "0"
    key_reset; key_run 200 10 --inject-ok >/dev/null
    chk "相手が残り 10 日 → 1通" "$(key_count)" "1"
    grep -q 'あと 10 日' "$FAKE_NOTIFY_LOG" && ok "  残日数が文面に載る" \
      || ng "  残日数が載っていない: $(cat "$FAKE_NOTIFY_LOG")"
    grep -q 'test-peer' "$FAKE_NOTIFY_LOG" && ok "  どちらの鍵かが分かる" \
      || ng "  対象が分からない: $(cat "$FAKE_NOTIFY_LOG")"

    echo "  ── 10-b. ★probe が健全な回(KIND=0 で即 exit する道)でも走る ──"
    # 平常時こそがこの系統の働き場所。up/down の判定より**手前**で呼んでいないと、
    # 異常が無い限り一度も走らない = 期限が来るまで誰も気付かない形になる。
    key_reset; rc="$(key_run 200 10 --inject-ok)"
    chk "  異常なしの回でも鳴る" "$(key_count)" "1"
    chk "  ★それでも終了コードは 0(鍵の警報は監視の異常ではない)" "$rc" "0"

    echo "  ── 10-c. ★近い方を採る(観測側が先に切れる形)──"
    key_reset; key_run 10 200 --inject-ok >/dev/null
    chk "  観測側 10 日 / 相手 200 日 → 鳴る" "$(key_count)" "1"
    grep -q '監視を動かしている機械' "$FAKE_NOTIFY_LOG" \
      && ok "  ★観測側の鍵だと分かる(相手だけ見ていたら出ない文面)" \
      || ng "  観測側だと分からない: $(cat "$FAKE_NOTIFY_LOG")"

    echo "  ── 10-d. 段を降りた時だけ鳴る(45日ぶん毎日鳴らして黙らされない為)──"
    key_reset
    key_run 200 10 --inject-ok >/dev/null; chk "  10 日(段 14)で 1通" "$(key_count)" "1"
    key_run 200 9  --inject-ok >/dev/null; chk "  ★9 日は同じ段 = 増えない" "$(key_count)" "1"
    key_run 200 5  --inject-ok >/dev/null; chk "  5 日(段 7)で段を降りた = 2通目" "$(key_count)" "2"
    # ★3 日は段 7 のまま。査読 Q4 で段を 45/30/14/7/3/1 → 45/14/7/1 に減らした事の対照。
    #   減らす前の版はここで鳴った(= この行が赤くなれば段が戻った事に気付ける)。
    key_run 200 3  --inject-ok >/dev/null; chk "  ★3 日はまだ段 7 = 増えない" "$(key_count)" "2"
    key_run 200 1  --inject-ok >/dev/null; chk "  1 日(段 1)で 3通目" "$(key_count)" "3"
    grep -q 'MENTION=\[0\]' <(head -1 "$FAKE_NOTIFY_LOG") \
      && ok "  ★遠い段は ping 無し" || ng "  遠い段に ping が付いている: $(head -1 "$FAKE_NOTIFY_LOG")"
    grep -q 'MENTION=\[既定\]' <(tail -1 "$FAKE_NOTIFY_LOG") \
      && ok "  ★7 日以内は @Tom が付く" || ng "  近い段に ping が無い: $(tail -1 "$FAKE_NOTIFY_LOG")"

    echo "  ── 10-e. 鍵を更新したら段が戻る(次に近付いた時また言える)──"
    key_reset
    key_run 200 10   --inject-ok >/dev/null; chk "  まず 1通" "$(key_count)" "1"
    key_run none none --inject-ok >/dev/null; chk "  期限なしにした回は鳴らない" "$(key_count)" "1"
    key_run 200 10   --inject-ok >/dev/null
    chk "  ★また近付いたら鳴り直す(段を戻していないと二度と鳴らない)" "$(key_count)" "2"

    echo "  ── 10-f. ★測れない時に「異常なし」と読まない ──"
    key_reset; rc="$(key_run 200 gone --inject-ok)"
    chk "  相手が tailnet に居ない → 鍵の警報は出ない" "$(key_count)" "0"
    chk "  ★代わりに『監視側が壊れている』を出す(沈黙しない)" "$(broken_count)" "1"

    echo "  ── 10-g. 配達が失敗したら記録を進めない(次回また鳴らし直す)──"
    key_reset
    export FAKE_SELF_DAYS=200 FAKE_PEER_DAYS=10
    run_with_notify "$SB/notify-fails.sh" --inject-ok >/dev/null
    chk "  ★失敗した side の段を進めない" "$(/usr/bin/awk '{print $3}' "$SB/key.mark" 2>/dev/null)" "9999"
    # ★時計も据え置く。進めると次の回が KEY_EVERY(本番では1日)の間ずっと早期 return し、
    #   出し先が直っても最大1日黙る —— 「配達後に進める」の意図が時計側で骨抜きになる形。
    chk "  ★時計も進めない" "$(/usr/bin/awk '{print $1}' "$SB/key.mark" 2>/dev/null)" "0"
    key_run 200 10 --inject-ok >/dev/null
    chk "  ★出し先が直った次の回に鳴る" "$(key_count)" "1"

    echo "  ── 10-h. --dry-run が本物の警報を黙らせない ──"
    key_reset; key_run 200 10 --inject-ok --dry-run >/dev/null
    chk "  試し打ちでは出さない" "$(key_count)" "0"
    chk "  ★記録も進めない" "$([ -f "$SB/key.mark" ] && echo yes || echo no)" "no"
    key_run 200 10 --inject-ok >/dev/null
    chk "  ★次の本番の回でちゃんと鳴る" "$(key_count)" "1"

    echo "  ── 10-i. 呼び口の互換(deploy 台本 / 起動ラッパは引数なしで呼ぶ)──"
    ex_run() { FAKE_SELF_DAYS="$1" FAKE_PEER_DAYS=200 FAKE_TS_SKELETON="$SB/ts-skeleton.json" \
               RC_TAILSCALE_BIN="$SB/fake-tailscale.sh" \
               bash "$ROOT/tools/tailnet-key-expiry.sh" "${@:2}" 2>/dev/null; }
    out="$(ex_run 200)"; rc=$?
    chk "  引数なし・遠い → 0" "$rc" "0"
    case "$out" in *"鍵の期限"*) ok "  人向けの1行が出る" ;; *) ng "  文面が変わった: $out" ;; esac
    ex_run 10 >/dev/null; chk "  引数なし・近い → 1(警告であって門ではない)" "$?" "1"
    out="$(ex_run 200 --porcelain --chain test-peer)"
    case "$out" in
        "KEY self 200 "*$'\n'"KEY peer 200 "*) ok "  porcelain は1対象1行の固い形" ;;
        *) ng "  porcelain の形が違う: [$out]" ;;
    esac

    echo "  ── 10-j. ★引数不足で回り続けない(2026-08-03 に実際に焼いた形)──"
    # `shift 2` は残り1個の時に失敗し、しかも shift しない = while が永久に回る。
    # 対照そのものが固まらない様に、網を掛けて測る。
    ( bash "$ROOT/tools/tailnet-key-expiry.sh" --peer >/dev/null 2>&1 ) & lp=$!
    ( /bin/sleep 10; kill "$lp" 2>/dev/null ) & lw=$!
    wait "$lp"; lrc=$?; kill "$lw" 2>/dev/null; wait "$lw" 2>/dev/null
    chk "  値の無い --peer は即 2 で落ちる(143=網に殺された=回り続けた)" "$lrc" "2"

    echo "  ── 10-k. ★段は side ごとに持つ(片方の警告がもう片方の初回を消さない)──"
    # 査読(Codex 2026-08-03 / Q2)で見つかった穴。段を「鎖の最小値」に対して1つだけ覚えると、
    # 観測側が残り3日で段7を鳴らした後に edith が残り5日へ入っても、鎖の最小は3のままなので
    # 段は7、「段7は通知済み」で **edith の話が一度も出ない**。無人で残す方の機械が消える。
    key_reset
    key_run 3 200 --inject-ok >/dev/null
    chk "  観測側 3 日で 1通" "$(key_count)" "1"
    grep -q '監視を動かしている機械' "$FAKE_NOTIFY_LOG" && ok "  1通目は観測側の話" \
      || ng "  1通目が観測側でない: $(cat "$FAKE_NOTIFY_LOG")"
    key_run 3 5 --inject-ok >/dev/null
    chk "  ★相手が段7へ入ったら鳴る(片側1つの段だと此処が消える)" "$(key_count)" "2"
    grep -q 'test-peer' <(tail -1 "$FAKE_NOTIFY_LOG") && ok "  2通目は相手の話" \
      || ng "  2通目が相手でない: $(tail -1 "$FAKE_NOTIFY_LOG")"
    key_run 3 5 --inject-ok >/dev/null
    chk "  両方とも通知済みなら増えない" "$(key_count)" "2"
    # 記録は3欄。古い2欄の形(= 鎖全体で段を1つ)は、その段がどちら側の物か決められないので
    # 両方「未通知」に倒す。1通多く出るだけで済み、逆に倒すと黙る。
    #   下は「2欄目をそのまま self の段として読む」版だと沈黙する形:
    #   古い記録の段7 を self の段と読むと、残り3日(段7)の観測側が抑制されて 0通になる。
    key_reset; printf '%s 7\n' "$(date +%s)" > "$SB/key.mark"
    key_run 3 200 --inject-ok >/dev/null
    chk "  ★古い2欄の記録は未通知として読む(沈黙より重複)" "$(key_count)" "1"

    echo "  ── 10-l. ★既に切れた鍵に固有の段がある(段1の後で黙らない)──"
    # 同じ査読の Q2。残り -2 日は `-2 <= 1` なので段1に落ちる。段1を鳴らした後だと
    # 「通知済み」で黙る = 監視が数時間止まっている間に期限を越えると、**越えた事が出ない**。
    key_reset
    key_run 200 1 --inject-ok >/dev/null; chk "  まず 1 日の段で 1通" "$(key_count)" "1"
    key_run 200 -2 --inject-ok >/dev/null
    chk "  ★期限を越えたら段0でもう1通(段1で止まる版は此処が 1 のまま)" "$(key_count)" "2"
    grep -q '既に切れています' <(tail -1 "$FAKE_NOTIFY_LOG") \
      && ok "  ★文面が『あと N 日』でなく『既に切れています』" \
      || ng "  期限切れの文面になっていない: $(tail -1 "$FAKE_NOTIFY_LOG")"
    grep -q 'MENTION=\[既定\]' <(tail -1 "$FAKE_NOTIFY_LOG") \
      && ok "  期限切れは @Tom が付く" || ng "  期限切れに ping が無い: $(tail -1 "$FAKE_NOTIFY_LOG")"
    key_run 200 -3 --inject-ok >/dev/null
    chk "  切れたまま毎回は鳴らさない(段0も1回だけ)" "$(key_count)" "2"
    # ★観測している主体を必ず名乗る(査読 Q3: 誰から見た話かが無いと取り違える)。
    grep -q "$(hostname -s)" <(tail -1 "$FAKE_NOTIFY_LOG") \
      && ok "  ★どの機械から見た話かが文面に載る" \
      || ng "  観測主体が載っていない: $(tail -1 "$FAKE_NOTIFY_LOG")"


    echo "  ── 10-m. ★相手が居ない構成で狼を叫ばない(2026-08-26 に実測した誤報)──"
    # ★何が起きていたか: `KEY_PEER` が `${RC_HEALTH_KEY_PEER:-$HOST}` と書かれていて、
    #   表示用の `HOST` を機体名として継いでいた。athenas の observer.conf は
    #   `RC_HEALTH_HOST="friday(loopback)"`(URL は別に loopback を明示)なので、
    #   その**人が読む札**を引きに行って必ず失敗し、rc=2 =「監視が壊れている」を鳴らした。
    #   実測 2026-08-26 11:08。前後の行は全部 `ok` なので本物の障害ではない。
    #
    # ★測るのは通知の数ではなく **`--chain` を渡したか**。通知の数で見ると、
    #   偽 tailscale が rc=2 を返す(相手の有無と無関係)だけで赤くなり、
    #   実装の欠陥と駆動の都合が同じ顔になる —— 実際 3 回誤読した。**渡した引数は嘘をつかない。**
    #
    # ★`run()` を通さない。あれは `${TEST_KEY_PEER:-test.example}` と書いていて、
    #   `:-` は**空文字にも既定を当てる**ので「相手が居ない構成」を作れない。
    #   `run()` 側を `-` に変えたら既存 78 件が赤くなった(実測)ので、
    #   既存の仕掛けは1文字も触らず、この検査だけ独立に撃つ。
    peer_spy="$SB/keycheck-args.log"
    printf '#!/bin/bash\nprintf "ARGS=[%%s]\\n" "$*" >> "%s"\necho "KEY self 200 2027-01-01"\nexit 0\n' \
        "$peer_spy" > "$SB/spy-key.sh"
    chmod +x "$SB/spy-key.sh"

    peer_probe() { # $1 = KEY_PEER に渡す値
        : > "$peer_spy"
        /bin/rm -f "$SB/peer-probe.mark" "$SB/peer-probe.json"
        RC_HEALTH_CONF="$SB/none.conf" \
        RC_HEALTH_URL="http://127.0.0.1:9/健康" \
        RC_HEALTH_HOST="test.example" \
        RC_HEALTH_STATE="$SB/peer-probe.json" \
        RC_HEALTH_NOTIFY="/usr/bin/true" \
        RC_HEALTH_LOG="$SB/peer-probe.log" \
        RC_HEALTH_KEY_CHECK="$SB/spy-key.sh" \
        RC_HEALTH_KEY_MARK="$SB/peer-probe.mark" \
        RC_HEALTH_KEY_EVERY=0 \
        RC_HEALTH_KEY_PEER="$1" \
        bash "$OBS" --inject-ok >/dev/null 2>&1
    }

    peer_probe ""
    if grep -q -- '--chain' "$peer_spy" 2>/dev/null; then
        ng "★相手が未設定なら居ない相手を引きに行かない — 記録[$(head -1 "$peer_spy")]"
    else
        ok "★相手が未設定なら居ない相手を引きに行かない"
    fi

    # 過剰に黙らせていない事の負の対照 —— 相手を明示したら今まで通り引きに行く。
    peer_probe "test-peer"
    if grep -q -- '--chain test-peer' "$peer_spy" 2>/dev/null; then
        ok "相手を明示すれば今まで通り引きに行く(狼を殺していない)"
    else
        ng "相手を明示しても引きに行かない — 記録[$(head -1 "$peer_spy" 2>/dev/null)]"
    fi

    unset TEST_KEY_CHECK TEST_TAILSCALE TEST_KEY_PEER FAKE_SELF_DAYS FAKE_PEER_DAYS FAKE_TS_SKELETON
fi

echo "── 11. ★「監視側が壊れています」に**いつから**を載せる(査読 Q3)──"
# 何を守っているか: 「監視側が壊れています」だけを受け取った Tom は、それが 10 分前からなのか
# 3 日前からなのかを **log を開くまで**測れない。緊急度が文面に無い警報は、移動中に読んだ時に
# 「後で見る」に倒れる —— この案件の相手は渡米中の Tom なので、そこが実質の失敗点になる。
#
# ★この節の本体は「時刻が載る」ではなく **記録している時刻の意味**:
#   記録するのは「対象が up だった時刻」ではなく「**判定が一周できた時刻**」。
#   up を記録すると「対象が長く落ちている」が「監視が長く壊れている」に見え、
#   Q3 が消したがっている取り違えを別の場所で作り直す事になる。11-e / 11-f がそこを測る。
worked_at() { cat "$OKM" 2>/dev/null; }
fresh_mark() { # 記録が今さっき進んだか(60 秒以内)
    local t; t="$(worked_at)"
    case "$t" in ''|*[!0-9]*) echo no; return ;; esac
    [ $(( $(date +%s) - t )) -lt 60 ] && echo yes || echo no
}
break_state() { echo 'これは JSON ではない' > "$STATE"; }

echo "  ── 11-a. 据え付け直後(一度も成功していない)に**数字を作らない** ──"
/bin/rm -f "$STATE" "$SB/broken.mark" "$OKM"; : > "$FAKE_NOTIFY_LOG"
break_state
rc="$(run --inject-fail)"
chk "  壊れた状態で 3" "$rc" "3"
chk "  1通鳴る" "$(notify_count)" "1"
grep -q '一度も成功していない' "$FAKE_NOTIFY_LOG" \
  && ok "  ★記録が無い事をそう言う" || ng "  文面: $(cat "$FAKE_NOTIFY_LOG")"
# 負の対照。ここで「0 分前」と出す版が一番危ない —— 一度も動いた事が無い監視が
# 「さっきまで動いていた」と名乗る = 据え付けの書き損じが**緑の顔**で隠れる。
if grep -qE '[0-9]+ (分|時間|日)前' "$FAKE_NOTIFY_LOG"; then
    ng "  ★記録が無いのに時間を作っている: $(cat "$FAKE_NOTIFY_LOG")"
else
    ok "  ★分からない物を数字にしていない"
fi

echo "  ── 11-b. 一周できた後なら、その時刻が載る ──"
/bin/rm -f "$STATE" "$SB/broken.mark" "$OKM"; : > "$FAKE_NOTIFY_LOG"
run --inject-ok >/dev/null                      # 対象は正常 = 判定が一周した回
chk "  ★正常な回に記録が進む" "$(fresh_mark)" "yes"
break_state
run --inject-fail >/dev/null
grep -qE '最後に監視が働けたのは [0-9]+ 分前' "$FAKE_NOTIFY_LOG" \
  && ok "  ★壊れた通知に『いつから』が載る" || ng "  文面: $(tail -1 "$FAKE_NOTIFY_LOG")"

echo "  ── 11-c/d. 記録が読めない・未来を指している(ここも数字にしない)──"
/bin/rm -f "$STATE" "$SB/broken.mark"; : > "$FAKE_NOTIFY_LOG"
echo 'こわれた記録' > "$OKM"; break_state
run --inject-fail >/dev/null
grep -q '記録が読めない' "$FAKE_NOTIFY_LOG" \
  && ok "  ★数字でない記録 → 「不明(記録が読めない)」" || ng "  文面: $(tail -1 "$FAKE_NOTIFY_LOG")"

/bin/rm -f "$STATE" "$SB/broken.mark"; : > "$FAKE_NOTIFY_LOG"
echo $(( $(date +%s) + 100000 )) > "$OKM"; break_state
run --inject-fail >/dev/null
grep -q '時計が巻き戻っている' "$FAKE_NOTIFY_LOG" \
  && ok "  ★未来の記録 → 「不明(時計が巻き戻っている)」" || ng "  文面: $(tail -1 "$FAKE_NOTIFY_LOG")"
if grep -qE -- '-[0-9]+ (分|時間|日)前' "$FAKE_NOTIFY_LOG"; then
    ng "  ★負の時間を出している: $(tail -1 "$FAKE_NOTIFY_LOG")"
else
    ok "  ★負の時間を出していない"
fi

echo "  ── 11-e. ★**対象が落ちている間も**記録は進む(監視は働けている)──"
# ここが Q3 の意味の中心。対象の down を「監視の停止」と読み替えないので、
# 「対象が 3 日落ちている」の最中に監視が壊れても、その通知は正しく「今さっきまでは働けていた」
# と言える。逆に up 時刻を記録する版は、ここで「3 日前」と出して取り違えを作り直す。
/bin/rm -f "$STATE" "$SB/broken.mark" "$OKM"; : > "$FAKE_NOTIFY_LOG"
run --inject-fail >/dev/null; run --inject-fail >/dev/null
echo $(( $(date +%s) - 7200 )) > "$OKM"          # 記録を 2 時間前へ戻す
run --inject-fail >/dev/null                     # 3回目 = 「落ちました」と知らせる回
chk "  落ちたと知らせた" "$(notify_count)" "1"
chk "  ★その回にも記録が進む(対象は down のまま)" "$(fresh_mark)" "yes"
echo $(( $(date +%s) - 7200 )) > "$OKM"
run --inject-ok >/dev/null                       # 戻りましたの回
chk "  戻ったと知らせた" "$(notify_count)" "2"
chk "  ★戻りの回にも記録が進む" "$(fresh_mark)" "yes"

echo "  ── 11-f. ★監視が壊れた回は記録を進めない(そこが『いつから』の基準)──"
# これが無いと、壊れた回自身が記録を進めてしまい、何日壊れていても通知は毎回「0 分前」。
# = 文面に時刻は載るのに、その時刻が何も意味しない形(一番たちの悪い緑)。
/bin/rm -f "$STATE" "$SB/broken.mark"; : > "$FAKE_NOTIFY_LOG"
was=$(( $(date +%s) - 7200 )); echo "$was" > "$OKM"
break_state
rc="$(run --inject-fail)"
chk "  壊れた状態で 3" "$rc" "3"
chk "  ★記録は進んでいない" "$(worked_at)" "$was"
grep -q '最後に監視が働けたのは 2 時間前' "$FAKE_NOTIFY_LOG" \
  && ok "  ★文面が実際の経過を出す" || ng "  文面: $(tail -1 "$FAKE_NOTIFY_LOG")"
if grep -q '0 分前' "$FAKE_NOTIFY_LOG"; then
    ng "  ★壊れた回が記録を進めている(時刻が意味を失う形)"
else
    ok "  ★「0 分前」に化けていない"
fi
# 起動前に落ちる形(§9 の閾値不正)でも同じ —— こちらは判定を起こす**手前**で終わるので、
# 記録の書き込みが判定の後ろに在る事が効いているかを別経路で見る。
/bin/rm -f "$STATE" "$SB/broken.mark"; : > "$FAKE_NOTIFY_LOG"
was=$(( $(date +%s) - 7200 )); echo "$was" > "$OKM"
export RC_HEALTH_THRESHOLD=0
rc="$(run --inject-fail)"
chk "  設定が壊れている回も 3" "$rc" "3"
chk "  ★その回も記録を進めない" "$(worked_at)" "$was"
unset RC_HEALTH_THRESHOLD

echo "  ── 11-g. --dry-run でも同じ文面を出す(据える前に読める)──"
/bin/rm -f "$STATE" "$SB/broken.mark"; : > "$FAKE_NOTIFY_LOG"
echo $(( $(date +%s) - 7200 )) > "$OKM"; break_state
out="$(run_out --inject-fail --dry-run)"
chk "  本物の出し先へは出さない" "$(notify_count)" "0"
printf '%s' "$out" | grep -q '最後に働けたのは 2 時間前' \
  && ok "  ★下見でも『いつから』が読める" || ng "  出力: $out"

# ── ★公開面を測る台本が無い時(2026-08-30 追加)────────────────────────────────
#
# なぜ此処に足すか: 2026-08-30 に repo 版の observer を friday へ配る直前、依存物
# `funnel-exposure-check.sh` が向こうに**無い**事に気付いた。新版はその時
# `notify_monitor_broken` を**閾値なしで**撃つので(`health-observer.sh` の
# `[ ! -x "$EXP_CHECK" ]` の枝)、台本だけ配っていれば日1回の誤報が **10 分毎**に化けた。
# 依存物も一緒に配って回避したが、**この枝を測る対照は1本も無かった** ——
# 729 行のこの file は他の2つの壊れ方について同じ抑制を測っているのに、此処だけ空。
#
# 測るのは2つ:
#   (a) 台本が無い時に**鳴る**(黙って安全だと言わない)
#   (b) 鳴り続けない(`BROKEN_MARK` の抑制がこの枝にも効く)
echo "── 8. 公開面を測る台本が無い時 ──"
: > "$FAKE_NOTIFY_LOG"; /bin/rm -f "$SB/broken.mark" "$SB/exposure.mark"

_exp() {  # 露出の枝だけを回す(up/down の系統は動かさない)
    RC_HEALTH_CONF="$SB/none.conf" \
    RC_HEALTH_URL="http://127.0.0.1:9/健康" \
    RC_HEALTH_HOST="test.example" \
    RC_HEALTH_STATE="$STATE" \
    RC_HEALTH_NOTIFY="$SB/fake-notify.sh" \
    RC_HEALTH_LOG="$SB/observer.log" \
    RC_HEALTH_BROKEN_MARK="$SB/broken.mark" \
    RC_HEALTH_OK_MARK="$OKM" \
    RC_HEALTH_EXP_CHECK="${TEST_EXP_CHECK:-$SB/no-such-exposure-check.sh}" \
    RC_HEALTH_EXP_MARK="$SB/exposure.mark" \
    RC_HEALTH_EXP_TS="$SB/fake-tailscale.sh" \
    bash "$OBS" --exposure-only >/dev/null 2>&1
}

# tailscale の実体は在る事にする(無いと**別の枝**= "tailscale が無い" に落ちて、
# 測りたい枝を一度も通らない。今日この file の他の箇所が踏んだのと同じ型)。
printf '#!/bin/bash\necho "{}"\n' > "$SB/fake-tailscale.sh"; chmod +x "$SB/fake-tailscale.sh"

_exp
chk "(a) 台本が無ければ鳴る(黙って安全と言わない)" "$(notify_count)" "1"
grep -q "公開面を測れない" "$SB/observer.log" \
  && ok "(a2) 理由が log に残る" \
  || ng "(a2) 鳴ったのに理由が log に無い"

_exp; _exp
chk "★(b) 続けて回しても鳴り続けない(抑制がこの枝にも効く)" "$(notify_count)" "1"

# ★陽性対照: 台本を**在る**事にすると、この枝は鳴らない = 上の1件は
#   「台本が無い事」を測っていて、単に何でも鳴るのではない。
: > "$FAKE_NOTIFY_LOG"; /bin/rm -f "$SB/broken.mark" "$SB/exposure.mark"
printf '#!/bin/bash\nexit 0\n' > "$SB/present-exposure-check.sh"; chmod +x "$SB/present-exposure-check.sh"
TEST_EXP_CHECK="$SB/present-exposure-check.sh" _exp
chk "★(c) 台本が在れば鳴らない(何でも鳴る訳ではない)" "$(notify_count)" "0"

# ── 電話が版を名乗った事を1回だけ言う(2026-08-31)────────────────────────
# ★測る中心は「鳴るか」ではなく **1回だけ鳴るか** と **名乗っていない行で鳴らないか**。
#   前者だけなら「毎回鳴る」実装で通り、其の警報は一週間で読まれなくなる。
_phone() {  # _phone <log の中身...>  → 1回走らせる
    : > "$SB/rc.log"
    for l in "$@"; do printf '%s\n' "$l" >> "$SB/rc.log"; done
    RC_HEALTH_PHONE_LOG="$SB/rc.log" RC_HEALTH_PHONE_MARK="$SB/phone.mark" \
    RC_HEALTH_PHONE_EVERY=0 RC_HEALTH_CAP_MARK= RC_HEALTH_OTA_CHECK= \
        _obs >/dev/null 2>&1
}
# ★錨。机は起動のたびに之を書く。**之より後**が今の走行の行。
BOOT='[rc-backend] listening on http://127.0.0.1:8787 (key: /x/api.key)'
# ★今の走行より前の行(古い実装が UA の売り物の版を書いた形)。数えてはいけない。
LOLD='[rc-backend] req 2026-08-30T10:00:00.000Z GET /api/sessions route=r client=app build=1 code=200 reason=- ms=1'
L114='[rc-backend] req 2026-08-31T20:00:00.000Z GET /api/sessions route=r client=app build=114 code=200 reason=- ms=1'
L115='[rc-backend] req 2026-08-31T21:00:00.000Z GET /api/sessions route=r client=app build=115 code=200 reason=- ms=1'
LNONE='[rc-backend] req 2026-08-31T19:00:00.000Z GET /api/sessions route=r client=app build=- code=200 reason=- ms=1'
LTOOL='[rc-backend] req 2026-08-31T19:30:00.000Z GET /api/sessions route=r client=tool build=- code=200 reason=- ms=1'

# ★数えるのは**この枝の通知だけ**。全部の通知を数えると、同じ走行で出る
#   「机が応答しない」の1通が混ざり、枝の挙動と無関係にずれる(実測でずれた)。
# ★`|| echo 0` を付けない。`grep -c` は0件でも **0 を印字してから非ゼロで終わる**ので、
#   付けると "0\n0" になる(同じ罠を 2026-08-31 に2度踏んだ)。数は grep が出す。
phone_notices() { local c; c="$(grep -c '電話が build=' "$FAKE_NOTIFY_LOG" 2>/dev/null)"; printf '%s' "${c:-0}"; }

/bin/rm -f "$SB/phone.mark" "$SB/phone.mark.at"; : > "$FAKE_NOTIFY_LOG"
_phone "$LOLD" "$BOOT" "$L114"
chk "★電話が版を名乗ったら1通" "$(phone_notices)" "1"
_phone "$LOLD" "$BOOT" "$L114"
chk "★同じ版が続いても2通目は出ない(出来事であって状態ではない)" "$(phone_notices)" "1"
_phone "$LOLD" "$BOOT" "$L114" "$L115"
chk "★版が変われば また1通" "$(phone_notices)" "2"

# ★巻き戻し(115 → 114)で **114 を二度 言わない**(Codex 2026-08-31)。
#   「最後の版と違うか」で判じると此処で再び鳴る —— 憶えるのは集合であって最後の1つではない。
_phone "$LOLD" "$BOOT" "$L115" "$L114"
chk "★一度言った版は巻き戻っても二度と言わない(最後の1つではなく集合で憶える)" "$(phone_notices)" "2"

# ★名乗っていない行では鳴らない。2026-08-31 に UA から版を採る経路を消したので、
#   古い版からの要求は必ず `build=-` になる —— 其れを sighting と数えると、
#   版が判らないまま毎回「新しい」と読めて鳴り続ける。
/bin/rm -f "$SB/phone.mark" "$SB/phone.mark.at"; : > "$FAKE_NOTIFY_LOG"
_phone "$BOOT" "$LNONE" "$LTOOL"
chk "★版を名乗らない行(build=-)と道具の行では鳴らない" "$(phone_notices)" "0"

# ★`client=control`(私の走行)では鳴らない。2026-08-31 に役の既定を control へ倒し、
#   役の名乗りを通り道へ移したので、検査用の殻の要求は全部 control として記録される。
#   其れを sighting が拾うと、**誤報の根を直した意味が無くなる**(版が 1 でも 118 でも同じ)。
#   枝は `client=app` を見るので構造的に拾わない筈 —— 其の「筈」を測る。
LCTRL='[rc-backend] req 2026-08-31T22:00:00.000Z GET /api/account route=r client=control build=118 code=200 reason=- ms=1'
/bin/rm -f "$SB/phone.mark" "$SB/phone.mark.at"; : > "$FAKE_NOTIFY_LOG"
_phone "$BOOT" "$LCTRL"
chk "★私の走行(client=control)では鳴らない(誤報の根を直した意味が消えない)" "$(phone_notices)" "0"
# 陰性対照: 同じ版を app が名乗れば鳴る(= 上が「常に 0」の検査でない事)
/bin/rm -f "$SB/phone.mark" "$SB/phone.mark.at"; : > "$FAKE_NOTIFY_LOG"
LAPP118='[rc-backend] req 2026-08-31T22:00:01.000Z GET /api/account route=r client=app build=118 code=200 reason=- ms=1'
_phone "$BOOT" "$LAPP118"
chk "★同じ版でも app が名乗れば鳴る(control の検査が常に 0 ではない)" "$(phone_notices)" "1"

# ★錨(`listening on`)が無い log では黙る。上限で切られて起動の行が消えた時に、
#   古い実装が書いた数字を「今の版」と読まない為。「判らない」を「見た」に丸めない。
/bin/rm -f "$SB/phone.mark" "$SB/phone.mark.at"; : > "$FAKE_NOTIFY_LOG"
_phone "$LOLD" "$L114"
chk "★起動の錨が無い log では黙る(切られた後を今の走行と読まない)" "$(phone_notices)" "0"

# ★この機体では見ない(既定は空)。要求ログを持つのは机だけ。
/bin/rm -f "$SB/phone.mark" "$SB/phone.mark.at"; : > "$FAKE_NOTIFY_LOG"
: > "$SB/rc.log"; printf '%s\n' "$L114" >> "$SB/rc.log"
RC_HEALTH_PHONE_LOG= RC_HEALTH_PHONE_MARK="$SB/phone.mark" RC_HEALTH_PHONE_EVERY=0 \
RC_HEALTH_CAP_MARK= RC_HEALTH_OTA_CHECK= _obs >/dev/null 2>&1
chk "★空 = この機体では見ない(指していない機体は語らない)" "$(phone_notices)" "0"

echo ""
echo "HEALTH-OBSERVER-CONTROLS: pass=$pass fail=$fail$([ "$KEY_UNMEASURED" -eq 1 ] && echo ' ★鍵の系統は測定不成立')"
[ "$fail" -eq 0 ] || exit 1
[ "$KEY_UNMEASURED" -eq 0 ] || exit 2
exit 0
