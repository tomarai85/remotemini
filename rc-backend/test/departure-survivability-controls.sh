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

# 偽 ssh は **行き先で振り分ける**。鎖(9)が加わって ssh の相手が2台になったので、
# 相手を見ずに1つの答えを返すと、監視側の問いに edith の答えを返して
# 「別の理由で未測定」を「狙った枝で未測定」と読み違える。
# 行き先 = option を読み飛ばした最初の非 option 引数(`-o X` の X を食わない)。
cat > "$T/bin/ssh" <<'EOS'
#!/bin/bash
dest=""; skip=0
for a in "$@"; do
    if [ "$skip" = 1 ]; then skip=0; continue; fi
    case "$a" in
        -o|-i|-p|-l|-F) skip=1 ;;
        -*) ;;
        *) dest="$a"; break ;;
    esac
done
case "$dest" in
    *athenas*) cat "$FAKE_MON_ANSWER" ;;
    *)         cat "$FAKE_SSH_ANSWER" ;;
esac
EOS
chmod +x "$T/bin/ssh"

# 鎖(8)(電話にアプリが入っているか)だけは ssh の向こうではなく **手元の xcrun** を
# 叩くので、偽 ssh では届かない。偽 xcrun は PATH ではなく検査側の継ぎ目
# (RC_PHONE_XCRUN)で挿す —— PATH で `xcrun` を隠すと mktemp や python3 まで
# 巻き込み、「別の理由で落ちた」を「狙った枝で落ちた」と読み違える。
cat > "$T/bin/xcrun" <<'EOX'
#!/bin/bash
mode="${FAKE_XCRUN_MODE:-installed}"
out=""; prev=""
for a in "$@"; do [ "$prev" = "--json-output" ] && out="$a"; prev="$a"; done
[ -n "$out" ] || exit 64
case "$2" in
  list)
      [ "$mode" = "listfail" ] && exit 1
      if [ "$mode" = "nodevice" ]; then
          printf '{"result":{"devices":[]}}\n' > "$out"
      else
          printf '{"result":{"devices":[{"identifier":"FAKE-UDID","hardwareProperties":{"platform":"iOS"},"connectionProperties":{"pairingState":"paired"}}]}}\n' > "$out"
      fi
      ;;
  device)
      case "$mode" in
          appsfail) exit 1 ;;
          absent)   printf '{"result":{"apps":[]}}\n' > "$out" ;;
          garbage)  printf 'not json at all\n' > "$out" ;;
          # 絞り込みが壊れて**別のアプリ**が返る形。件数だけ数えていると緑になる
          otherapps) printf '{"result":{"apps":[{"bundleIdentifier":"com.tomarai.blink"},{"bundleIdentifier":"com.tomarai.lingo.Lingo"}]}}\n' > "$out" ;;
          # 在るのに版の欄が無い形(古い devicectl / schema 変更)。在否は緑のまま
          # 版だけ未測定へ倒れる事を測る為に、既定とは別の枝で置く。
          noversion) printf '{"result":{"apps":[{"bundleIdentifier":"com.tomarai.remotemini"}]}}\n' > "$out" ;;
          *)        printf '{"result":{"apps":[{"bundleIdentifier":"com.tomarai.remotemini","bundleVersion":"%s"}]}}\n' "${FAKE_APP_VER:-777}" > "$out" ;;
      esac
      ;;
  *) exit 64 ;;
esac
exit 0
EOX
chmod +x "$T/bin/xcrun"

# 鎖(8)の**期待値**を出す道具の継ぎ目(2026-08-10)。検査は
# `ios/tools/build.sh --print-build-num` へ番号を訊きに行く —— 其処を偽物へ向ける。
# 本物を呼ばせない理由は2つ: (1) 期待値が repo の commit 数に連動するので、
# 対照が「今日の履歴」に依存して明日壊れる。(2) 食い違いの枝を作る為に本物の
# 履歴を汚す訳にいかない。知らない引数で落とすのは、検査が別の口を叩き始めた時に
# 黙って既定値を返さない為(綴りの間違いを緑にしない)。
cat > "$T/bin/fake-build.sh" <<'EOB'
#!/bin/bash
[ "${1:-}" = "--print-build-num" ] || { echo "偽 build.sh に知らない引数: ${1:-(無)}" >&2; exit 2; }
printf '%s\n' "${FAKE_WANT_NUM:-777}"
EOB
chmod +x "$T/bin/fake-build.sh"

# 既定は「入っている」。此処を既定にしないと、上の全対照が電話の赤で汚染される
# (= 狙った項目とは別の理由で赤くなり、対照が意味を失う)。
# 版も既定では**一致**させる(777 = 777)。同じ理由。
XMODE=installed
XBIN="$T/bin/xcrun"
XVER=777
WANTNUM=777
BSH="$T/bin/fake-build.sh"

# 鎖(9)(見張りが生きているか)の「全部良い」返答。GOOD と同じ規律で、
# 各対照は此処から **1 行だけ** 差し替える。
MON_GOOD='job=loaded
interval=600
log=present
age=120
ticks=198'
MON_ANS="$MON_GOOD"

# MON_ANS の1行を差し替える(replace の見張り版)
mreplace() { printf '%s\n' "$MON_GOOD" | sed "s/^$1=.*/$1=$2/"; }

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
    printf '%s\n' "$MON_ANS" > "$T/mon-answer"
    OUT=$(FAKE_SSH_ANSWER="$T/answer" FAKE_MON_ANSWER="$T/mon-answer" \
          FAKE_XCRUN_MODE="$XMODE" FAKE_APP_VER="$XVER" FAKE_WANT_NUM="$WANTNUM" \
          RC_PHONE_XCRUN="$XBIN" RC_BUILD_SH="$BSH" PATH="$T/bin:$PATH" bash "$SUT" "$@" 2>&1)
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

# --- 鎖(8) 電話にアプリが入っているか(2026-08-09 に足した)------------------
# 足した理由: 鎖①〜⑦は全部 edith 側で、旅程で使う2台のうち**電話を誰も数えて
# いなかった**。実際に測ったら入っておらず、その間ずっと机の上の検査は 527 件緑で、
# 引き継ぎ文書は「実機到達済み」と書いていた。ここで測るのはその**三色の割り当て**。
phone_probe() {  # phone_probe <名前> <XMODE> <期待コード> <出力に居るべき語>
    XMODE="$2"; run "$GOOD" --days 30; XMODE=installed
    if [ "$RC" -ne "$3" ]; then ng "$1: 終了 $RC(期待 $3)"; return; fi
    if printf '%s\n' "$OUT" | grep -q "$4"; then ok "$1 -> 終了 $3"
    else ng "$1: 終了は合ったが理由が出ていない($4 が無い)"; fi
}

phone_probe "BA アプリが入っていない"   absent   1 "RemoteMini が入っていない"
phone_probe "BB 電話が繋がっていない"   nodevice 2 "繋いでから撃つ"
phone_probe "BC 機器一覧が返らない"     listfail 2 "機器一覧を返さない"
phone_probe "BD 一覧が返らない(tunnel)" appsfail 2 "tunnel が落ちた疑い"
phone_probe "BE 一覧が JSON でない"     garbage  2 "中身が読めない"
# BE2: `--bundle-id` の絞りが壊れて別のアプリが返る形。件数だけ数えていると緑になる
#      (Codex 2026-08-09 指摘①。「1件以上」は対象が在る事の証明ではない)。
phone_probe "BE2 別のアプリが返る"      otherapps 1 "RemoteMini が入っていない"

# BF: 道具そのものが無い枝。継ぎ目を無い場所へ向けて測る(PATH ごと隠すと
#     mktemp や python3 まで落ちて、別の理由の失敗を此処の緑と読み違える)。
XBIN="$T/no-such-dir/xcrun"; run "$GOOD" --days 30; XBIN="$T/bin/xcrun"
if [ "$RC" -eq 2 ] && printf '%s\n' "$OUT" | grep -q "xcrun が無い"; then
    ok "BF xcrun が無い -> 未測定"
else ng "BF xcrun 不在: 終了 $RC"; fi

# BG: **入っていない事を「繋がっていない」に丸めない**。此処が今回の本丸 ——
#     未測定と赤の取り違えは、渡米前に「後で測ればいい」と読ませて出発させる。
XMODE=absent; run "$GOOD" --days 30; XMODE=installed
if [ "$RC" -eq 1 ] && ! printf '%s\n' "$OUT" | grep -q "繋いでから撃つ"; then
    ok "BG 入っていない -> 赤(未測定へ逃がさない)"
else ng "BG 入っていないのに 終了 $RC(未測定に丸めている)"; fi

# BH: 入っていて版も合っていれば緑。**両方の番号を名乗る**事まで測る ——
#     「一致」とだけ出す検査は、比べる相手を間違えていても同じ顔をする。
run "$GOOD" --days 30
if [ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -q "版: 電話 777 = この木 777"; then
    ok "BH 入っている・版も一致 -> 緑、両方の番号を名乗る"
else ng "BH 版が一致しているのに 終了 $RC / 番号を名乗っていない"; fi

# BH2: 緑の但し書き。番号は commit の通算数なので**汚れた木で焼いた事は判らない**。
#      此処を落とすと、緑が「電話と手元は完全に同じ」と読まれる = 言い過ぎ。
if printf '%s\n' "$OUT" | grep -q "汚れた木"; then
    ok "BH2 緑でも「汚れた木は見分けられない」と名乗る"
else ng "BH2 版の緑を無条件の一致として出している"; fi

# --- 鎖(8)の版(2026-08-10 / Codex 指摘②)------------------------------------
# 足した理由: 此処は元々「在るか無いか」しか言えず、自分の出力に
# 「版の一致は此処では測れない —— 電話の画面で見る」と書いていた。**人の目にしか
# 出来ない事へ機械の仕事を預けていた**。#56(edith が 5 commit 古い版で走っていた)と
# 同じ穴が電話側に開いたまま。以下が測るのは、その三色の割り当て。

# BI: 古い物が載っている -> **赤**。未測定へ逃がすと「後で見ればいい」と読まれる。
#     在否の緑は据え置かれる事も同時に測る(版の赤が在否の観測を消さない)。
XVER=770; run "$GOOD" --days 30; XVER=777
if [ "$RC" -eq 1 ] \
   && printf '%s\n' "$OUT" | grep -q "版: 電話は 770、この木は 777" \
   && printf '%s\n' "$OUT" | grep -q "焼き直す" \
   && printf '%s\n' "$OUT" | grep -q "電話に RemoteMini が入っている"; then
    ok "BI 版が食い違う -> 赤(在否の緑は据え置き)"
else ng "BI 版の食い違い: 終了 $RC"; fi

# BJ: 番号が "1" = project.yml の直値のまま = **build.sh を通さずに焼いた物**。
#     赤の理由に其れを名指しする(「なぜ 1 なのか」を読む人が探さずに済む)。
XVER=1; run "$GOOD" --days 30; XVER=777
if [ "$RC" -eq 1 ] && printf '%s\n' "$OUT" | grep -q "build.sh を通さずに焼いた"; then
    ok "BJ 番号が 1 -> 赤、直値のままだと名指しする"
else ng "BJ 番号 1: 終了 $RC"; fi

# BK: xcodegen の差し込み損ねが**そのまま**電話へ届いた形。project.yml の comment が
#     名指しで禁じている `${RC_BUILD_NUM}` を誰かが書いた時に此処へ出る。
XVER='${RC_BUILD_NUM}'; run "$GOOD" --days 30; XVER=777
if [ "$RC" -eq 1 ] && printf '%s\n' "$OUT" | grep -qF '${RC_BUILD_NUM}'; then
    ok "BK 差し込み損ねの literal が載っている -> 赤"
else ng "BK literal の版: 終了 $RC"; fi

# BL: 版の欄が無い(古い devicectl / schema 変更)-> **未測定**。
#     在否は緑のままで、版だけが未測定へ倒れる事を測る。
XMODE=noversion; run "$GOOD" --days 30; XMODE=installed
if [ "$RC" -eq 2 ] \
   && printf '%s\n' "$OUT" | grep -q "bundleVersion が一覧に無い" \
   && printf '%s\n' "$OUT" | grep -q "電話に RemoteMini が入っている"; then
    ok "BL 版の欄が無い -> 未測定(在否の緑は据え置き)"
else ng "BL 版の欄が無い: 終了 $RC"; fi

# BM: 期待値が出せない(build.sh が git から数えられず 0 を返した)-> 未測定。
#     0 を「番号 0 の版」として突き合わせると、必ず赤になる = 嘘の赤。
WANTNUM=0; run "$GOOD" --days 30; WANTNUM=777
if [ "$RC" -eq 2 ] && printf '%s\n' "$OUT" | grep -q "この木の番号が出せない"; then
    ok "BM 期待値が 0 -> 未測定(0 を版として突き合わせない)"
else ng "BM 期待値 0: 終了 $RC"; fi

# BM2: 期待値が数字でない -> 未測定。上の case の腕を綴りごと守る。
WANTNUM=x; run "$GOOD" --days 30; WANTNUM=777
if [ "$RC" -eq 2 ] && printf '%s\n' "$OUT" | grep -q "この木の番号が出せない"; then
    ok "BM2 期待値が数字でない -> 未測定"
else ng "BM2 期待値 x: 終了 $RC"; fi

# BN: 番号を出す道具が居ない -> 未測定。**此処が本丸** ——
#     道具が無い時に検査が自前で `git rev-list --count` を数え始めたら、
#     数える範囲の決定が2箇所になり、片方だけ腐る日が来る(写しが2つ問題)。
#     未測定で止まる = 期待値の出所が1つしか無い事の観測値。
BSH="$T/no-such-dir/build.sh"; run "$GOOD" --days 30; BSH="$T/bin/fake-build.sh"
if [ "$RC" -eq 2 ] && printf '%s\n' "$OUT" | grep -q "番号を出す道具が見付からない"; then
    ok "BN 道具が無い -> 未測定(自前で数え始めない)"
else ng "BN 道具不在: 終了 $RC"; fi

# --- 鎖(9): 見張りが生きているか ---------------------------------------------
# 此処の対照が守るのは1点 —— **監視の沈黙を健康と読まない**事。
# 見張りが死んでいる時に緑を返す検査は、旅程中の「何も来ない」を保証に変える。
mon_probe() {  # mon_probe <名前> <MON_ANS の中身> <期待コード> <出力に居るべき語>
    MON_ANS="$2"; run "$GOOD" --days 30; MON_ANS="$MON_GOOD"
    if [ "$RC" -ne "$3" ]; then ng "$1: 終了 $RC(期待 $3)"; return; fi
    if printf '%s\n' "$OUT" | grep -q "$4"; then ok "$1 -> 終了 $3"
    else ng "$1: 終了は合ったが理由が出ていない($4 が無い)"; fi
}
mon_probe "CA 見張りが登録されていない" "$(mreplace job absent)"        1 "launchctl に居ない —— 旅程中ずっと黙る"
mon_probe "CB ログが1本も無い"          "$(mreplace log missing)"        1 "一度も書いていない疑い"
mon_probe "CC 見張りが止まっている"     "$(mreplace age 5000)"           1 "監視が止まっている"
mon_probe "CD 刻みの設定が読めない"     "$(mreplace interval unreadable)" 2 "何秒で古いと言えるのか決まらない"
mon_probe "CE 判定の行が1本も無い"      "$(mreplace age noticks)"        1 "回っていない"
mon_probe "CF 最新の刻みの時刻が壊れ"   "$(mreplace age unparsed)"       2 "齢を出せない"
mon_probe "CG 監視の機械に届かない"     ""                               2 "届かない事は「監視が死んでいる」の証拠にならない"

# CH: 閾値の境目。2刻み+300 秒 = 1500 が上限で、**1500 は緑・1501 は赤**。
#     此処を測らないと「閾値が在る」だけで「正しい位置に在る」が未確認のまま。
mon_probe "CH1 上限ちょうど(1500)は緑" "$(mreplace age 1500)" 0 "回っている"
mon_probe "CH2 上限+1(1501)は赤"       "$(mreplace age 1501)" 1 "監視が止まっている"

# CI: 刻みを変えたら閾値も動く事。600 -> 60 なら上限は 420 秒で、
#     age=1000 は CH1 では緑だった値なのに此処では赤になる。
#     此処が緑のままなら、検査が plist を読まずに 600 を写している証拠。
mon_probe "CI 刻みが変われば閾値も動く" "$(printf '%s\n' "$MON_GOOD" | sed 's/^interval=.*/interval=60/; s/^age=.*/age=1000/')" 1 "監視が止まっている"

# CJ: 緑が**何を言っていないか**を名乗る事。Discord まで出る保証は此処には無い。
MON_ANS="$MON_GOOD"; run "$GOOD" --days 30
if [ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -q "Discord まで出るか"; then
    ok "CJ 回っている -> 緑、ただし通知経路は測れていないと名乗る"
else ng "CJ 緑なのに「通知経路は別」の但し書きが無い(終了 $RC)"; fi

# --- CK/CL: claude 本体の版は**記録であって判定ではない** ---------------------
# 此処に判定を付けると「更新された = 赤」になる。正しい版という物が無いのだから
# それは嘘の赤で、嘘の赤は検査ごと無視させる。**出るが色は変えない**事を固定する。
run "$(printf '%s\ncli_ver=2.1.223\ncli_auto=true\n' "$GOOD")" --days 30
if [ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -q "自動更新が入っている"; then
    ok "CK 自動更新が入っている -> 記録は出るが緑のまま"
else ng "CK 自動更新の記録で色が変わった(終了 $RC)"; fi

run "$(printf '%s\ncli_auto=true\n' "$GOOD")" --days 30
if [ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -q "版が読めない"; then
    ok "CL 版が読めなくても判定は付かない -> 緑のまま"
else ng "CL 版が読めない事を赤/未測定に倒した(終了 $RC)"; fi

# --- CM: --help が**冒頭の解説を最後まで**出す ------------------------------
# 以前は行番号(`2,48p`)で切っていて、鎖を足した日に説明が途中で切れた。
# 番号を消したので、此処が守るのは「最後の1行まで出る」かつ「コードに食い込まない」。
H=$(bash "$SUT" --help 2>&1)
if printf '%s\n' "$H" | grep -q "出さない物: 会話 id" \
   && printf '%s\n' "$H" | grep -q "見張りそのものが生きている事" \
   && ! printf '%s\n' "$H" | grep -q "^set -u"; then
    ok "CM --help が解説を最後まで出し、コードに食い込まない"
else ng "CM --help が途中で切れている / コードまで出している"; fi

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
