#!/bin/bash
# deploy-to-edith.sh — rc-backend を edith に置き、**その機械で緑を取る**まで。
#
# 常設(launchd)の前段。ここが緑にならない限り plist は入れない。
# 理由: edith は Node 25.9.0、MBP とは別の実行系。MBP の緑は edith の緑ではない。
#
# 使い方:
#   bash tools/deploy-to-edith.sh            # 転送 + edith 側で単体 + e2e
#   bash tools/deploy-to-edith.sh --dry-run  # rsync の差分だけ見る(転送しない)
#
# 触らない物(同期ツリーの外に在るので --delete の巻き添えにならない):
#   ~/.rc-backend/api.key      鍵。作り直すと電話に貼った鍵が失効する
#   ~/.rc-backend/panes/*.json 登録簿
#   ~/Library/Logs/rc-backend/ ログ

set -euo pipefail

EDITH="${RC_EDITH_HOST:-edith@10.0.0.0}"
DEST="${RC_EDITH_DIR:-/Users/edith/rc-backend}"
NODE="/opt/homebrew/bin/node"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

DRY=""
[ "${1:-}" = "--dry-run" ] && DRY="--dry-run"

# 送らない物: git の中身と、e2e が作る作業場(そもそもここには無い筈だが保険)。
# ★`--delete` を使うので、除外に入れた物は宛先に在っても消されない = 意図的。
say() { printf '\n=== %s ===\n' "$1"; }

say "1. 転送 (rsync -a --delete${DRY:+ ${DRY}})"
rsync -a --delete $DRY \
    --exclude '.git/' \
    --exclude 'node_modules/' \
    --exclude '*.log' \
    "$SRC"/ "$EDITH:$DEST"/

if [ -n "$DRY" ]; then
    echo "(dry-run。ここで終わり)"
    exit 0
fi

say "2. edith 側の実行系を観測"
ssh "$EDITH" "$NODE -v && cd '$DEST' && ls -1 src/ test/ | wc -l"

say "3. 単体 (edith 上)"
ssh "$EDITH" "cd '$DEST' && PATH=/opt/homebrew/bin:\$PATH npm test --silent"

say "4. e2e (edith 上)"
ssh "$EDITH" "cd '$DEST' && PATH=/opt/homebrew/bin:\$PATH $NODE test/e2e-local.mjs"

say "5. e2e の作業場が残っていないか"
# ★この確認が無かったせいで 364個 65MB を残した(WORKLOG 2026-08-02 02:10)。
# 「転送先が消えたか」だけを見て「常設物なし」と書いたのが元の誤り。
#
# ★★書き方も直した(2026-08-02 02:5x)。旧版は
#     ssh "$EDITH" 'ls -d "$TMPDIR"rc-e2e-* 2>/dev/null | wc -l'
#
#   ★訂正を先に書く: 私は最初この旧版を「構造的に赤が出ない検査」だと書いた。**間違い**。
#   edith(zsh)で現物を測ったら、残骸を1つ置いた状態で旧版はちゃんと `1` を出した。
#   一致ゼロの時に `no matches found` でコマンドごと落ちて `wc -l` が `0` を返すのは事実だが、
#   その `0` は**答えとしては合っている**。負の対照を取る前に「壊れている」と書きかけた =
#   今夜4回やった「正しい観測を、それが支えていない結論に貼る」の5回目になる所だった。
#
#   実際に旧版が落とす物は2つだけ。それを直す為に書き換えている:
#     1. `TMPDIR` が空だと glob は cwd 基準になり、**探せていないのに `0`** と出る。
#        (edith では今日 TMPDIR は在った。= 今日の話ではなく、環境が変わった時の話)
#     2. どこを探したのかがログに残らない。人が後から「本当に見たのか」を確かめられない。
#   → `bash -s` で shell を固定し、TMPDIR が空なら**落ちる**。探した場所を必ず出す。
#
#   (verify-on-edith.sh:65-68 に在るのは**別の罠**。`ls -d A B C` と glob を並べた時、
#    A の nomatch で B と C を一度も見ずに終わる、という情報を落とす型。こちらは単一 glob
#    なのでそれには当たらない。同じ教訓に見えるが別物なので混ぜない)
ssh "$EDITH" bash -s <<'REMOTE'
T="${TMPDIR:-}"
if [ -z "$T" ]; then
    # 見られない事を「無い」と言わない。TMPDIR が空なら e2e の作業場の場所自体が不明。
    echo "★TMPDIR が空なので rc-e2e-* を探せない(=「残っていない」とは言えない)" >&2
    exit 2
fi
n=0
for d in "$T"rc-e2e-*; do
    [ -e "$d" ] || continue
    n=$((n + 1))
done
echo "残っている rc-e2e-*: ${n}  (探した場所: ${T})"
[ "$n" -eq 0 ] || echo "★片付いていない。e2e が異常終了した跡が在る"
REMOTE

say "6. 常設(launchd)が既に在るなら、走っている物を新しい木に入れ替える"
# ★rsync しただけでは**動いているサーバは古いコードのまま**。
#   同型の事故で F1 を 11 日止めた(memory: method_measure_where_the_system_actually_reads
#   のプロセス版)。「転送した」を「反映された」と読み替えない為に、ここで機械に確かめさせる。
#   まだ常設していない段階では job が無いので、何もせずそう言う。
#
# ★★2026-08-02 の Codex レビューで**この段の検査を作り直した**。初版は
#   `curl` して `401` が返れば良し、としていた。**それは「新しいコードが動いている」を
#   一切証明しない**: 8787 を掴んだままの**古いプロセス**も同じ 401 を返す。
#   = 入れ替えに失敗しても緑で通る検査 = 今夜ずっと潰してきた型そのものを、
#   30 分前に自分で書いていた。→ **応答コードではなく同一性(PID)で見る**。
#     ① kickstart の前後で launchd job の PID が**変わる**事(= 本当に入れ替わった)
#     ② 8787 を実際に掴んでいるプロセスが**その PID である**事(= 古い居座りではない)
#     ③ その上で 401(= 認証が生きている)
#   ①②が通らないのに③だけ通る状態こそが、この検査が捕まえたい状態。
ssh "$EDITH" bash -s <<'REMOTE'
job=gui/501/com.edith.rc-backend
jobpid() { launchctl print "$job" 2>/dev/null | awk -F'= *' '/^[[:space:]]*pid =/ {print $2; exit}'; }

if ! launchctl print "$job" >/dev/null 2>&1; then
    echo "常設なし(まだ plist を入れていない)。転送だけで終わり = これは正常"
    exit 0
fi

before=$(jobpid)
echo "常設あり(pid=${before:-不明}) → kickstart -k で入れ替える(bootout はしない = 定義は触らない)"
launchctl kickstart -k "$job" || { echo "★kickstart が失敗した" >&2; exit 1; }

# 立ち上がるまで待つ。固定 sleep だと遅い機械で偽の赤、速い機械で無駄待ちになる。
after=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
    sleep 1
    after=$(jobpid)
    [ -n "$after" ] && [ "$after" != "$before" ] && break
done

rc=0
if [ -z "$after" ]; then
    echo "★10 秒待っても PID が付かない。crash loop の疑い" >&2; rc=1
elif [ "$after" = "$before" ]; then
    echo "★PID が変わっていない(${before})= 入れ替わっていない" >&2; rc=1
else
    echo "PID: ${before:-なし} → ${after}(入れ替わった)"
fi

# ★ここが本題。8787 を掴んでいるのが**その PID か**。
listener=$(lsof -nP -iTCP:8787 -sTCP:LISTEN -t 2>/dev/null | head -1)
if [ -z "$listener" ]; then
    echo "★8787 を掴んでいるプロセスが居ない(起動に失敗している)" >&2; rc=1
elif [ "$listener" != "$after" ]; then
    echo "★8787 を掴んでいるのは pid=${listener} で、launchd の job(pid=${after})ではない。" >&2
    echo "  = 古いプロセスが居座っている。この状態でも curl は 401 を返すので、応答コードだけ見ると気付けない" >&2
    rc=1
else
    echo "8787 の listener = ${listener}(launchd の job と一致)"
fi

code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:8787/api/sessions 2>/dev/null || echo "接続不可")
echo "応答: ${code}(401 が正 = 鍵を求めている)"
[ "$code" = "401" ] || { echo "★401 以外" >&2; rc=1; }

[ "$rc" -eq 0 ] || echo "ログ: /Users/edith/Library/Logs/rc-backend/rc-backend.error.log" >&2
exit "$rc"
REMOTE

say "7. tailnet 鍵の残り日数(**警告であって門ではない**)"
# ★ここで見る理由 = 「触っている今」が唯一まともに手を打てる瞬間だから。
#   起動ラッパも同じ script を呼ぶが、あちらは**起動時にしか**出ない。4ヶ月先に切れる鍵に
#   対して起動時の1行は警報にならない(そう書いてあるのに気付かないと、見張った気になる)。
#   恒久的な見張りは外部への生存通知(HANDOFF §3-P の候補)側の仕事。ここは中継ぎ。
#
# ★`|| true` を付ける理由 = 鍵が 40 日後に切れる事は、コードを配る妨げにならない。
#   ここで deploy を止めても被害は減らず、出来る仕事だけが止まる。止めるかは人が決める。
ssh "$EDITH" "/bin/bash '$DEST/tools/tailnet-key-expiry.sh'" || true

say "完了 — ここまで緑なら Phase P の step 2(plist を書く)へ"
