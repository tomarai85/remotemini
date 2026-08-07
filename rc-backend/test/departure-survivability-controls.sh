#!/bin/bash
# controls-for: tools/departure-survivability-check.sh
# departure-survivability-controls.sh — 渡米前の耐久検査が**赤へ倒れる**事を測る。
#
# なぜ要るのか:
#   あの検査は 2026-08-07 の実機で 1 項目を除いて全部緑だった。緑しか見ていない検査は
#   「壊れていない」と「壊れを見付けられない」を区別できない。ここは**壊した状態を
#   与えて赤(または未測定)が出るか**だけを見る = 陰性対照。
#
# どうやって edith 無しで測るか:
#   検査は `ssh` を1回だけ呼び、その標準出力の `key=value` を全部の判定に使う。
#   PATH の先頭に偽の `ssh` を置けば、実機無しで任意の状態を作れる。
#   ★偽物にしているのは **ssh の返答だけ**。判定・閾値・文面・終了コードは本物。
#   ★冷起動の 7 項目は向こうの coldboot-chain.sh の**終了コードをそのまま**使うので、
#     ここで測るのはその引き取り方(0/1/2/欠落)だけ。7 項目自体の対照は
#     `test/coldboot-chain-controls.sh` の仕事 —— 役割を混ぜない。
#
# 使い方: bash test/departure-survivability-controls.sh   (exit 0 = 全部 OK)
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SUT="$HERE/../tools/departure-survivability-check.sh"
[ -f "$SUT" ] || { echo "検査本体が無い: $SUT" >&2; exit 2; }

T=$(mktemp -d /tmp/rc-dep-controls.XXXXXX) || exit 2
cleanup() { [ -d "$T" ] && find "$T" -mindepth 0 -delete 2>/dev/null; }
trap cleanup EXIT

mkdir -p "$T/bin"
fail=0

# 全項目が緑になる返答。各対照はここから **1 行だけ** 差し替える。
# こうしないと「別の理由で赤になった」のを「狙った項目で赤になった」と読み違える。
GOOD='cb_rc=0
job_rc=0
job_pid=574
tmux_job=0
phone_job=0
alive=1
alive_total=22
auth=yes
auth_method=api_key
http=401
freeg=133
ts_state=ok
ts_total=6
ts_expiring=0
ts_min_days=-
cb_sha=__CB_SHA__
pw_sha=__PW_SHA__'

# 版の突き合わせは**手元の実ファイル**の sha と比べる。GOOD に手書きの定数を置くと
# 道具を1文字直すたびに対照が赤くなる(嘘の赤 = 一番早く無視される種類の赤)。
# なので GOOD の中の目印を、走る時に手元の実測値へ差し替える。
sha_of() { shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'; }
GOOD=${GOOD//__CB_SHA__/$(sha_of "$HERE/../tools/coldboot-chain.sh")}
GOOD=${GOOD//__PW_SHA__/$(sha_of "$HERE/../tools/ensure-phone-window.sh")}

cat > "$T/bin/ssh" <<'EOS'
#!/bin/bash
cat "$FAKE_SSH_ANSWER"
EOS
chmod +x "$T/bin/ssh"

# 1行を置き換える(キーの完全一致)。無いキーを指定したら落とす —— 綴りを間違えたまま
# 「対照が通った」と言わない為。
replace() {
    printf '%s\n' "$GOOD" | awk -F= -v k="$1" -v l="$2" '
        $1 == k { print l; found=1; next } { print }
        END { if (!found) exit 9 }
    ' || { echo "対照の綴り間違い: $1 は GOOD に無い" >&2; exit 2; }
}

run() {  # run <answer-text> [args...]
    local ans="$1"; shift
    printf '%s\n' "$ans" > "$T/answer"
    OUT=$(FAKE_SSH_ANSWER="$T/answer" PATH="$T/bin:$PATH" bash "$SUT" "$@" 2>&1)
    RC=$?
}

ok() { printf '  OK   %s\n' "$1"; }
ng() { printf '  NG   %s\n' "$1"; fail=$((fail+1)); printf '%s\n' "$OUT" | sed 's/^/       /'; }

# --- P: 全部良ければ緑 -------------------------------------------------------
# これが無いと「常に赤を返す壊れた検査」でも下の対照が全部通ってしまう。
run "$GOOD" --days 30
if [ "$RC" -eq 0 ]; then ok "P 全項目良好 -> 終了 0"; else ng "P 全項目良好なのに 終了 $RC"; fi

probe() {  # probe <名前> <key> <壊した行> <期待コード> <出力に居るべき語>
    run "$(replace "$2" "$3")" --days 30
    if [ "$RC" -ne "$4" ]; then ng "$1: 終了 $RC(期待 $4)"; return; fi
    if printf '%s\n' "$OUT" | grep -q "$5"; then ok "$1 -> 終了 $4"
    else ng "$1: 終了は合ったが理由が出ていない($5 が無い)"; fi
}

# --- 冷起動の鎖の引き取り方 --------------------------------------------------
probe "A 鎖が切れている"     cb_rc "cb_rc=1"       1 "鎖が切れている"
probe "B 鎖が測れなかった"   cb_rc "cb_rc=2"       2 "緑と読まない"
probe "C 道具が向こうに無い" cb_rc "cb_rc=missing" 1 "deploy-to-edith"

# --- ここが足している 6 項目 -------------------------------------------------
probe "D 落ちて再起動を繰り返す" job_rc      "job_rc=78"      1 "繰り返している疑い"
probe "E 鍵が外れて 200"         http        "http=200"       1 "鍵が外れている"
probe "F 面に届かない"           http        "http=000"       2 "届かなかった"
probe "G 空きが少ない"           freeg       "freeg=3"        1 "空き 3GB"
probe "H 鍵に期限が在る"         ts_expiring "ts_expiring=2"  1 "期限付き 2 台"
probe "I tailscale が無い"       ts_state    "ts_state=absent" 1 "経路そのものを測れていない"

# --- 鎖②③ を戻す job(此処が空なら「読めるが送れない」)---------------------
# ①(rc-backend)が緑でも②③が死んでいれば電話からは打ち込めない。その差が出るか。
probe "O phone job が異常終了" phone_job "phone_job=1" 1 "com.edith.rc-phone-window の最後の終了コードが 1"
probe "Q tmux job が異常終了"  tmux_job  "tmux_job=9"  1 "com.tom.work-tmux の最後の終了コードが 9"
probe "R phone job が走行中"   phone_job "phone_job=-" 2 "走っている最中に見た"

# --- 鎖④ 今この瞬間 話せる相手が居るか ---------------------------------------
probe "S 相手が 0 件"            alive "alive=0"           1 "phone 窓が戻っていない"
probe "T 鍵が読めず数えられない" alive "alive=nokey"       2 "判定を付けない"
probe "U 面に届かず数えられない" alive "alive=unreachable" 2 "数えられなかった"

# --- 鎖⑤ その相手が返事を返せるか -------------------------------------------
# 鎖④ が緑でも此処が赤になり得る事が、この項目を足した理由そのもの。
probe "AA 認証が切れている"   auth "auth=no"      1 "返事が返らない"
probe "AB 対話 shell が固まる" auth "auth=timeout" 2 "25 秒で返らなかった"
probe "AC zsh が無い"          auth "auth=nozsh"   2 "同じ文脈を再現できない"

# AD: 方式で注記が変わる。api_key は予備が無い / oauth は failover が守る。
#     どちらも緑だが**運用上の意味が逆**なので、緑の中で言い分けられているかを測る。
probe "AD 方式が oauth"        auth_method "auth_method=oauth" 0 "2時間毎に予備へ回す"
run "$GOOD" --days 30
if [ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -q "守られていない"; then
    ok "AE 方式が api_key -> 緑、ただし予備が無い事を名乗る"
else ng "AE api_key の注記が出ていない(終了 $RC)"; fi

# AF: auth のキーごと欠落 = 測れていない。緑にも赤にも丸めない。
run "$(printf '%s\n' "$GOOD" | grep -v '^auth=')" --days 30
if [ "$RC" -eq 2 ] && printf '%s\n' "$OUT" | grep -q "JSON を返さない"; then
    ok "AF auth が欠落 -> 未測定"
else ng "AF auth 欠落: 終了 $RC"; fi

# AG: **鎖④が緑のまま鎖⑤で赤**。件数の緑を「返事が返る」と読ませない。
#     これが DESIGN §6 の誤読の一段奥。件数の行が緑で出ている事も同時に確かめる。
run "$(replace auth "auth=no")" --days 30
if [ "$RC" -eq 1 ] \
   && printf '%s\n' "$OUT" | grep -q "緑    tmux 経路 1 件" \
   && printf '%s\n' "$OUT" | grep -q "返事が返らない"; then
    ok "AG 件数は緑・返事は赤 -> 赤(見えて打てるが返事が来ない形を潰す)"
else ng "AG 件数の緑と返事の赤が同時に出ていない(終了 $RC)"; fi

# --- V/W: job のキーごと欠落 = launchctl に居ない ----------------------------
# 「異常終了」と「そもそも登録されていない」は別の壊れ方。後者の方が渡米では致命的
# (再起動の後、鎖を戻す物が誰も居ない)。
run "$(printf '%s\n' "$GOOD" | grep -v '^phone_job=')" --days 30
if [ "$RC" -eq 1 ] && printf '%s\n' "$OUT" | grep -q "com.edith.rc-phone-window が launchctl に居ない"; then
    ok "V phone job 不在 -> 赤"
else ng "V phone job 不在: 終了 $RC"; fi

run "$(printf '%s\n' "$GOOD" | grep -v '^tmux_job=')" --days 30
if [ "$RC" -eq 1 ] && printf '%s\n' "$OUT" | grep -q "com.tom.work-tmux が launchctl に居ない"; then
    ok "W tmux job 不在 -> 赤"
else ng "W tmux job 不在: 終了 $RC"; fi

# --- X: ①が緑でも②③④が死んでいれば赤 -------------------------------------
# この検査を足した理由そのもの。「サーバが上がった = 電話が使える」と読ませない。
run "$(printf '%s\n' "$GOOD" | sed 's/^phone_job=0/phone_job=1/; s/^alive=1/alive=0/')" --days 30
if [ "$RC" -eq 1 ] && printf '%s\n' "$OUT" | grep -q "打ち込めない"; then
    ok "X ①緑・②③④死 -> 赤(サーバが上がった事を電話が使える事と読まない)"
else ng "X ①だけ緑なのに 終了 $RC"; fi

# --- J: job が居ない ---------------------------------------------------------
run "$(printf '%s\n' "$GOOD" | grep -v '^job_pid=')" --days 30
if [ "$RC" -eq 1 ] && printf '%s\n' "$OUT" | grep -q "launchctl に居ない"; then ok "J job 不在 -> 赤"
else ng "J job 不在: 終了 $RC"; fi

# --- K: 赤と未測定が同時に在れば**赤**が勝つ ---------------------------------
# 未測定が在るからと 2 を返すと、直さなければならない赤が「測り直せ」に化ける。
run "$(printf '%s\n' "$GOOD" | sed 's/^http=401/http=000/; s/^freeg=133/freeg=3/')" --days 30
if [ "$RC" -eq 1 ]; then ok "K 赤+未測定 -> 赤(1)が勝つ"
else ng "K 赤が在るのに 終了 $RC"; fi

# --- L: edith に届かない時は 2(未測定)。**赤に丸めない** -------------------
# 到達不能を赤にすると「向こうが壊れている」と読まれ、実際は自分の回線だった時に
# 渡米前の判断を誤らせる。ここがこの対照の本丸。
run "" --days 30
if [ "$RC" -eq 2 ] && printf '%s\n' "$OUT" | grep -q "未測定"; then ok "L 到達不能 -> 終了 2"
else ng "L 到達不能なのに 終了 $RC(赤にも緑にも丸めてはいけない)"; fi

# --- M: 旅程を伸ばしても、期限が無ければ緑のまま -----------------------------
# 「日数を伸ばせば必ず赤」という誤った実装を落とす。期限が無い機器は日数と無関係。
run "$GOOD" --days 365
if [ "$RC" -eq 0 ]; then ok "M 旅程 365 日でも期限無しなら緑"
else ng "M 期限が無いのに旅程を伸ばしただけで 終了 $RC"; fi

# --- N: 引数の検算 -----------------------------------------------------------
run "$GOOD" --days abc
if [ "$RC" -eq 2 ]; then ok "N --days abc -> 終了 2"; else ng "N --days abc を受け入れた(終了 $RC)"; fi
run "$GOOD" --days
if [ "$RC" -eq 2 ]; then ok "N2 --days が空 -> 終了 2"; else ng "N2 空の --days を受け入れた(終了 $RC)"; fi

# --- Z: 向こうの写しが別の版なら、緑を此処の緑として読ませない ---------------
# 判定を edith 上の coldboot-chain.sh に委ねているので、「緑だった」だけでは
# **どの道具の緑か**が言えない。deploy が半端に失敗した時、古い道具の緑が
# 新しい保証に見える。赤ではなく未測定へ倒すのが正しい向き
# (edith が壊れている訳ではない。此処のコードの緑として読めないだけ)。
probe "Z1 冷起動の道具が別の版" cb_sha "cb_sha=0000000000000000000000000000000000000000000000000000000000000000" 2 "手元と違う版"
probe "Z2 窓の道具が別の版"     pw_sha "pw_sha=1111111111111111111111111111111111111111111111111111111111111111" 2 "手元と違う版"

# Z3: 版が読めない時も未測定。「読めない」を「一致」と読むと守りが消える。
run "$(printf '%s\n' "$GOOD" | grep -v '^pw_sha=')" --days 30
if [ "$RC" -eq 2 ] && printf '%s\n' "$OUT" | grep -q "版が edith 側で読めない"; then
    ok "Z3 版が読めない -> 未測定"
else ng "Z3 版が読めない: 終了 $RC"; fi

# Z4: 一致している時は判定を動かさない(P が緑である事が既に効いているが、
#     突き合わせが**赤へ倒れる方にだけ**効く事を名指しで測る)。
run "$GOOD" --days 30
if [ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -q "版は手元と一致"; then
    ok "Z4 版が一致 -> 緑のまま、一致した事を名乗る"
else ng "Z4 版が一致しているのに 終了 $RC"; fi

# --- Y: 鎖④ の問い合わせに件数の上限を付け直させない -------------------------
# 此処だけ本文の走査(偽 ssh は URL を見られない)。弱い形だと承知の上で置く理由:
# 一度 limit=50 を付け、根拠を「生きた会話は心拍で先頭に留まる」と書いた。実際の
# 並び基準は jsonl の mtime(最終発言)で、打ち切りは sort の後に掛かる。
# = 生きているが暫く黙っている会話は沈んで切られ、0 件 = 偽の赤になる。
# 登録簿は伸びる一方なので、この誤りは**渡米中にこそ**発火する。
# 偽 ssh では原理的に出ない型なので、本文に錨を打つ以外に留める手が無い。
if printf '%s\n' "$(grep -n 'api/sessions?' "$SUT")" | grep -q 'limit='; then
    OUT=$(grep -n 'api/sessions?' "$SUT")
    ng "Y 鎖④ の問い合わせに limit が戻っている(沈んだ生存を切り落とす)"
else
    ok "Y 鎖④ の問い合わせに件数の上限が無い"
fi

echo
if [ "$fail" -eq 0 ]; then echo "departure-survivability-controls: 全部 OK"; exit 0; fi
echo "departure-survivability-controls: NG ${fail} 件"; exit 1
