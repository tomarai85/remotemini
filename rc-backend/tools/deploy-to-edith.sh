#!/bin/bash
# deploy-to-edith.sh — rc-backend を edith に置き、**その機械で緑を取ってから**入れ替える。
#
# 理由: edith は Node 25.9.0、MBP とは別の実行系。MBP の緑は edith の緑ではない。
#
# 使い方:
#   bash tools/deploy-to-edith.sh            # 仮置き → edith で緑 → 入れ替え → 再起動を観測
#   bash tools/deploy-to-edith.sh --dry-run  # 仮置きの rsync 差分だけ見る(転送しない)
#
# ============================================================================
# ★2026-08-03 に**順序を作り直した**。旧版は
#     rsync で本番の木を上書き → その木で npm test → e2e → kickstart
#   だった。`set -e` なので edith 側の検査が赤なら kickstart の前で止まる。
#   その時に残る状態が **disk=新しくて赤 / process=古くて正常** で、
#   走っているサーバはメモリ上の古いコードで動き続けるから**その場では何も壊れない**。
#   壊れるのは次に機械が落ちた時 —— KeepAlive や再起動が拾うのは
#   「自分の検査に落ちた木」で、**赤い木が次回起動の木になっている**。
#   Codex の裁定(同日): 「A failed deployment must not replace the next-boot tree.」
#
#   → 新しい順序は **仮置き(rc-staging)で緑を取るまで本番の木に触らない**。
#     赤なら本番の木は前回の緑のまま = 次回起動も緑のまま。
#
# ★入れ替えの形について(Codex は当初「symlink を貼り替えろ」と言った。**採らなかった**)
#   採らない理由は2つ、どちらも Codex が知らなかった事実:
#     1. `/Users/edith/rc-backend` には**私の物ではない `.git` が居る**(2026-08-03 12:52、
#        版管理外の本番コードを git 化する fleet の掃除が作った物。remote 無し・単発 commit)。
#        本番パスを symlink にすると、その repo を特定の release の中へ**黙って移す**事になる。
#     2. 本番パスを見ている plist が**2枚**ある(com.edith.rc-backend / com.edith.rc-phone-window)。
#        plist を書き換えると `bootout` + `bootstrap` が要る(この機械には 2026-07-17 に
#        `launchctl load` が古い定義を掴んだ事故が在る)= 依存している面を一度畳む事になる。
#   代わりに得た物: 「本番の木に触る前に緑を取る」と「戻せる複製が再起動を跨いで残る」。
#   諦めた物: 入れ替えそのものの原子性。走っている node は module をメモリに持っていて
#   rsync 中に `src/` を読み直さないので、この非原子の窓は**サービスからは観測されない**。
#
# ★戻し先を `$TMPDIR` に置かない(Codex 裁定)。tmp は再起動や掃除で消える =
#   **一番戻したい瞬間に無い**。`/Users/edith/rc-releases/` に実体で残す。
#
# 触らない物(同期ツリーの外に在るので --delete の巻き添えにならない):
#   ~/.rc-backend/api.key      鍵。作り直すと電話に貼った鍵が失効する
#   ~/.rc-backend/panes/*.json 登録簿
#   ~/Library/Logs/rc-backend/ ログ
# 触らない物(同期ツリーの**中**に在るが、私の物ではないので除外する):
#   /Users/edith/rc-backend/.git       fleet の掃除が作った repo
#   /Users/edith/rc-backend/.gitignore ↑と同時刻に作られた対の file。手元の木には**無い**ので、
#                                      除外しないと `--delete` が黙って消す。中身は
#                                      tokens/oauth/credential を無視する規則 = 消すと
#                                      その repo が次に秘密を巻き込む側に倒れる。

set -euo pipefail

EDITH="${RC_EDITH_HOST:-edith@10.0.0.0}"
LIVE="${RC_EDITH_DIR:-/Users/edith/rc-backend}"
STAGE="${RC_EDITH_STAGE:-/Users/edith/rc-staging}"
RELEASES="${RC_EDITH_RELEASES:-/Users/edith/rc-releases}"
# 配備中の印。**同期ツリーの外**に置く(`--delete` の巻き添えにならない為)。
# 既定値は `tools/rc-backend-launch.sh` の `RC_DEPLOY_MARK` と一致していなければならない。
MARK="${RC_DEPLOY_MARK:-/Users/edith/.rc-backend/deploy-in-progress}"
LOCK="${RC_DEPLOY_LOCK:-/Users/edith/.rc-backend/deploy.lock}"
LOCK_MAX_S="${RC_DEPLOY_LOCK_MAX_S:-7200}"
# ★配備先の機体名を台本から剥がす(2026-08-25)。既定は edith の実物のまま =
#   引数無しの既往の呼び方は 1 文字も変わらない。他機体へ向ける時だけ env で差し替える。
#   `RC_JOB_LABEL` は **plist の Label と一致していなければならない**(kickstart の宛先)。
JOB_LABEL="${RC_JOB_LABEL:-com.edith.rc-backend}"
# ★値を検証する(Codex 2026-08-25)。遠隔へは `"'"'"'$VAR'"'"'"` の形で渡しており、値に単引用符が
#   在ると引用が割れて任意コマンドになる。既存 5 引数と同じ構造の穴だが、**新しく開けた面は
#   自分で塞ぐ**。launchd の Label が取り得る字だけ通す。
case "$JOB_LABEL" in
    *[!A-Za-z0-9._-]*|"") echo "★RC_JOB_LABEL に使えない字が在る: $JOB_LABEL" >&2; exit 1 ;;
esac
REMOTE_LOG_DIR="${RC_REMOTE_LOG_DIR:-/Users/edith/Library/Logs/rc-backend}"
NODE="/opt/homebrew/bin/node"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

DRY=""
[ "${1:-}" = "--dry-run" ] && DRY="--dry-run"

# ★変異の走行中は配備しない。**ただし理由は当初書いていた物ではない**(2026-08-02 17:1x に訂正)。
#   旧: 「走行中は `src/` が意図的に壊されているので、壊れた木を本番へ送る事になる」
#   → **これは事実と違う。** 台本は `tempfile.mkdtemp` + `copytree` で複製を壊すだけで
#     (test/mutation-controls.py の `tempfile.mkdtemp` + `copytree`。走らせる時の
#      `cwd` も複製の中)、本物の木は無傷。
#     走行中の node の cwd を lsof で見ると `/private/var/folders/.../T/mut-*/rc` = 複製。
#     rsync が送るのは常に本物の木なので、「壊れた木を送る」は起き得ない。
#
#   それでも止める、本当の理由: **配備を正当化する検査が、まだ答えを出していない**。
#   走行は 85 分ぶんの「この木に既知の欠陥が無い」の証明で、その途中の値は証明ではない。
#   step 3/4 の検査は大半を止めるが、**未到達の変異は素通りする**ので検査任せにもできない。
#   加えて、走行が始まった後に `src/` を編集していれば、走行の結果は**送る木を説明しない**
#   (台本は変異ごとに木を写し直す為、前半と後半で違う木を測る)。
#   逃げ道は置かない: 本当に配備したいなら走行が終わるまで待つか、走行を止める方が正しい。
#
#   ★判定そのものは `tools/mutation-run-live.sh` に一本化(同日)。素の pgrep を直書きして
#   いた時は**文字列を含むだけの無関係なシェル**にも当たり、`vim` や待ち受けが1本残って
#   いるだけで配備が**恒久的に塞がった**。fail-closed でも詰まったままなら壊れている。
#
#   ★★2026-08-04、Codex の指摘で**進む条件を反転**した。前は `if <判定>; then 止める` で、
#   つまり「exit 0 以外は全部 進んでよい」と読んでいた。判定側が「測れなかった」を返せる
#   様になった以上、その形は**判らない時に配備する**という意味になる。門が答えるべきは
#   「進んでよいと確認できたか」であって「止めろと言われたか」ではない。
#   よって進むのは **exit が丁度 1(居ないと確認できた)の時だけ**。
#   ★書き方に注意: 裸で置くと `set -e` が非零で**台本ごと殺す**。この判定は「1 を返すのが
#   正常」なので、裸に置いた瞬間に配備が毎回そこで死ぬ —— 実際そう書いて
#   `test/deploy-to-edith-behavior-controls.sh` の B0a/B0c/B1c… が一斉に赤くなった(同日)。
#   `cmd || rc=$?` は左辺が条件の位置なので `set -e` が発火しない(warn-ledger.sh の頭と同じ話)。
_mrl=0
bash "$(dirname "${BASH_SOURCE[0]}")/mutation-run-live.sh" || _mrl=$?
if [ "$_mrl" -ne 1 ]; then
    if [ "$_mrl" -eq 0 ]; then
        echo "★配備しない: 変異の走行が動いている = **配備を正当化する検査がまだ答えを出していない**。" >&2
        echo "  (木が壊れている訳ではない。台本は複製を壊すので本物の src/ は無傷)" >&2
        echo "  終わるまで待つか、走行を止めてから回す事。" >&2
        # 当たった相手を見せる(実行体の名前だけ。引数は出さない)。
        # `python` 以外が並んでいたら、それは走行ではなく**その名を文字列として持つだけ**の
        # プロセスに当たっている = 塞がったままになる方の誤りなので、見て判断できる様にする。
        echo "  当たった相手(pid と実行体。python でなければ誤検出):" >&2
        bash "$(dirname "${BASH_SOURCE[0]}")/mutation-run-live.sh" --who 2>/dev/null | /usr/bin/sed 's/^/    /' >&2
    else
        echo "★配備しない: 変異の走行の有無を**測れなかった**(mutation-run-live.sh exit=$_mrl)。" >&2
        echo "  「動いていない」ではない。判らないまま進むと、走行中の配備が黙って通る。" >&2
        echo "  pgrep が動く事を確かめてから回し直す事。" >&2
    fi
    exit 1
fi

# ★送る木の版を**送る前に**確定させる(rsync 中に手元が変わっても、刻む値は送った物と一致する)。
#   これが無いと本番は「何版が動いているか」を答えられない = 2026-08-02 に実際に困った:
#   数字が動いた原因を、WORKLOG に残っていた pid の時刻から推理する羽目になった。
#   `.git` は送らない(正しい)ので、版は**別の物として刻む**しかない。
#   汚れた木からの配備は隠さない: dirty を値に出す(嘘の版を刻む位が、版が無いより悪い)。
#   ★2026-08-02: `-dirty` は正しかったが**読めなかった**。刻印は判定だけを出して観測を伏せる
#   ので、「動いている物は commit から再現できるか」に答えるのに4手かかった(git status →
#   rsync の除外表 → .gitignore の有無 → edith 側の実物)。実際の汚れは**未 commit の
#   evidence JSON 2件だけ**で src/ test/ は 9c8b57f と同一だった = 順序の問題(検査を回すと
#   未追跡の artifact が出来る → それを commit する前に配備した)。
#   だから旗を消すのではなく、**何が汚れているかを配備時に出す**。judgement より observation。
#   判定そのものは `tools/deploy-dirt.sh` に居る(対照が本物の repo で同じ経路を通せる様に)。
SRC_REV="$(git -C "$SRC" rev-parse --short HEAD 2>/dev/null || echo 'unknown')"
# ★`set -e` の下では `X="$(cmd)"` は cmd の終了状態をそのまま取るので、**非零を返すのが
#   正常**なこの判定では代入した瞬間に台本が死ぬ(2026-08-02 に実際に死んだ。しかも
#   `| head` を通していたので終了状態が握り潰され、**無言で何も出さない**形で現れた)。
#   だから `|| dirt_rc=$?` で明示的に受ける。
dirt_rc=0
DIRT="$(bash "$(dirname "${BASH_SOURCE[0]}")/deploy-dirt.sh" "$SRC")" || dirt_rc=$?
case "$dirt_rc" in
  0) : ;;  # 綺麗 = 何も言わない
  3) SRC_REV="${SRC_REV}-unknown-dirt"
     echo "★木の汚れを git で判定できない。刻む版 = ${SRC_REV}" ;;
  *) SRC_REV="${SRC_REV}-dirty"
     echo "★汚れた木から配備する。刻む版 = ${SRC_REV}"
     printf '%s\n' "$DIRT" | sed 's/^/    /'
     if [ "$dirt_rc" -eq 2 ]; then
         echo "    ⚠ src/ か test/ が未 commit = 配備される**実行コードが commit から再現できない**。"
     else
         echo "    (src/ test/ は無傷 = 実行コードは ${SRC_REV%-dirty} と同一。汚れは付随物のみ)"
     fi ;;
esac

say() { printf '\n=== %s ===\n' "$1"; }

# ★警告の段(門ではない検査)の結果を、log の真ん中で流さずに最後まで持ち帰る帳面。
#   2026-08-03 に足した。それまでは 3 段とも `|| true` で終了コードを飲み、
#   最後の行は `say "完了"` だけだった —— 9b の注釈自身が「変わった事に**気付ける場所**が
#   要る」と書いているのに、579 行の log の真ん中は気付ける場所ではない。
#   `|| true`(= 門にしない)判断は変えない。捨てているのは判断ではなく**信号**の方。
#   詳細と対照 = tools/warn-ledger.sh / test/warn-ledger-controls.sh(16 本)。
. "$(dirname "${BASH_SOURCE[0]}")/warn-ledger.sh"
wl_init

# 私の物ではない2つ(`.git/` と `.gitignore` = 2026-08-03 に fleet の衛生 pass が置いた物)。
# 本番の木へ書き戻す時と、複製を取る時の**両方**で除外する。
#
# ★ここには配列を置かない(2026-08-03 に消した)。以前は
#     FOREIGN=(--exclude '.git/' --exclude '.gitignore')
#   と書いてあったが、**一度も展開されていなかった**(`FOREIGN[@]` の使用 0 回)。
#   本当の保護は remote heredoc の中の**リテラル4箇所**(339 / 354 / 367 / 514)。
#   heredoc の中は remote 側の shell なので、手元の配列は届かない —— 届かない物を
#   「正本」の顔で置いておくと、3つ目を足した人が「全部直した」と信じて何も変わらない。
#   ★よそに正本が在る一覧の写しは、両方直すのでなく**写しを持たない形**にする。
#   不変条件(= 4本全部が2つとも除外する)は test/deploy-to-edith-controls.sh の
#   E0-E3 が持つ。脚を足して除外を書き忘れると、そこが赤くなる。

say "0-pre. 手元で e2e を先に回す(= 遠くへ行く前に落ちる)"
# ★2026-08-15 に足した。実測の動機:
#   `/api/account` が台本の標準出力の素通しから解析後の封筒に変わった commit(66fbf64)を
#   配ろうとして、**step 4(edith 上の e2e)で 1 本落ちた**。落ちたのは机ではなく
#   検査の側の期待値(素通し時代の1行)で、直すのに要る情報は最初から手元に在った。
#   それを知るまでに rsync + edith 上の `npm test` + e2e で 12 分掛かり、
#   仮置きには半端な木が残った。
#
# ★これは**新しい守り**ではない。step 4 と同じ file を同じ様に回すだけで、
#   捕まえられる欠陥は1つも増えない —— 変わるのは**知るまでの時間**だけ
#   (12 分・遠隔 → 86 秒・手元。2026-08-15 実測)。守りの本体は今も step 4:
#   edith は node 25.9.0 で、手元の緑はあの機械の緑ではない。
#
# ★commit の門には置かない。`npm test` は 6 秒で、e2e は 86 秒 = 15 倍。
#   src を触る commit 全部に 86 秒を課しても、防げるのは「配布が落ちる」だけで
#   **本番には元々届かない**(step 4 が仮置きで止める)。門の値段は毎回払い、
#   得るのは待ち時間の短縮だけなので、払う場所は配布の側が正しい。
if [ -z "$DRY" ]; then
    if ! ( cd "$SRC" && "$NODE" test/e2e-local.mjs ); then
        echo "★手元の e2e が赤い。ここで止める(edith へは何も送っていない)" >&2
        exit 1
    fi
else
    echo "(dry-run なので手元の e2e は回さない)"
fi

say "0. 配備の錠を取る(= 二重配備を構造的に不可能にする)"
# ★Codex 2026-08-03 指摘。2本の配備が重なると、片方の「複製」が
#   **もう片方が入れ替えた後の木**になる = 戻し先が前の版ではなくなる。
#   `mkdir` は原子的なので、成功した側だけが錠を持つ(file の存在確認 → 作成、では競る)。
#   fail-closed だが**詰まらせない**: 落ちた配備が残した錠は 2 時間で取り直す
#   (mutation-run-live.sh で恒久的に塞がった時と同じ轍を踏まない)。
#
# ★★2026-08-03 の Codex 査読で**錠に持ち主が無い**事が出た。初版は次の 2 つが同時に壊れていた:
#   ① 2 時間で「取り直す」のは `at` を上書きするだけ = 1 本目が**まだ生きている**時に
#      2 本目が並走する。錠が防いでいる筈の物(複製が別の配備の後の木になる)がそのまま起きる。
#   ② `release_lock` が持ち主を見ずに消す = 1 本目が終わる時に、**2 本目の錠を外す**。
#      これは並走が 2 本で止まらず 3 本目まで入れる、という意味。
#   → 錠に持ち主の札(`$LOCK/owner`)を入れ、**自分の札が入っている時だけ**外す。
#     取り直しは札を書いてから読み直して、競り負けた側が降りる。
#
# ★★★2026-08-03 追記(**火を噴く前に見つけた欠陥**)。初版は札に `hostname -s` を
#   そのまま入れていた。この機械の短い hostname には **Tom の実名が入っている**(実測)。
#   札は ① edith に書かれ ② 配備の標準出力に出る。そして配備の出力は
#   `.harness/evidence-*/` に証拠として**commit する**物なので、そのままだと実名が repo に入る。
#   → 名前ではなく **hostname の digest の頭 8 文字**を使う。機械ごとの一意性と
#     「どの機械が持っているか」の判別は残り、名前は出ない。
#     照合が要る時は、その機械で同じ式を叩けば同じ 8 文字が出る(= 復元でなく突き合わせ)。
#   ★`hostname` が空でも `shasum` は空文字の hash を返して**成功する**ので、
#     digest を取る前に空を潰す。潰さないと全機械が同じ札になる = 一意性が静かに消える。
_h="$(hostname -s 2>/dev/null || true)"
[ -n "$_h" ] || _h="unknown-host"
OWNER="deploy-$(printf '%s' "$_h" | /usr/bin/shasum | /usr/bin/cut -c1-8)-$$-$(date +%s)"
unset _h
release_lock() {
    # 自分の札でない錠は**絶対に触らない**。触る実装が上の ② そのものだった。
    ssh "$EDITH" "test \"\$(cat '$LOCK/owner' 2>/dev/null)\" = '$OWNER' || exit 0
                  rm -f '$LOCK/at' '$LOCK/owner' 2>/dev/null; rmdir '$LOCK' 2>/dev/null" >/dev/null 2>&1 || true
}
# 本番の木を書く段の直前に呼ぶ。2 時間の取り直しで錠を奪われていた場合、
# ここで降りないと「錠を持っていない配備」が本番を書く。
assert_lock_owner() {
    local who=""
    who="$(ssh "$EDITH" "cat '$LOCK/owner' 2>/dev/null" 2>/dev/null || true)"
    [ "$who" = "$OWNER" ] && return 0
    echo "★錠の持ち主が私($OWNER)ではなく ${who:-不明} になっている。" >&2
    echo "  = 別の配備が割り込んだ。ここから先は本番の木を書くので進まない。" >&2
    exit 1
}
lock_rc=0
ssh "$EDITH" bash -s -- "'$LOCK'" "'$LOCK_MAX_S'" "'$OWNER'" <<'REMOTE_LOCK' || lock_rc=$?
set -u
lock="$1"; maxs="$2"; owner="$3"
mkdir -p "$(dirname "$lock")"
if mkdir "$lock" 2>/dev/null; then
    printf '%s\n' "$owner" > "$lock/owner"
    date +%s > "$lock/at"
    echo "錠を取った: $lock(持ち主 $owner)"
    exit 0
fi
at="$(cat "$lock/at" 2>/dev/null || echo 0)"
age=$(( $(date +%s) - at ))
if [ "$age" -lt "$maxs" ]; then
    echo "★別の配備が走っている(${age} 秒前 / 持ち主 $(cat "$lock/owner" 2>/dev/null || echo 不明))。重ねない" >&2
    exit 1
fi
echo "★錠が古い(${age} 秒 > ${maxs} 秒)= 前の配備が途中で落ちた跡。取り直す" >&2
printf '%s\n' "$owner" > "$lock/owner"
date +%s > "$lock/at"
# 取り直しは 2 本が同時に来うる。書いた後に読み直して、**負けた側が降りる**。
# 最後に書いた者が勝つので、勝者は必ず 1 人になる。
sleep 2
now="$(cat "$lock/owner" 2>/dev/null || echo '')"
if [ "$now" != "$owner" ]; then
    echo "★取り直しが競った(今の持ち主: ${now:-不明})。降りる" >&2
    exit 1
fi
exit 0
REMOTE_LOCK
[ "$lock_rc" -eq 0 ] || exit 1
trap release_lock EXIT

say "1. 仮置きへ転送 (rsync -a --delete${DRY:+ ${DRY}} → $STAGE)"
# ★本番の木ではなく**仮置き**へ送る。ここが今回の設計変更の本体。
#   仮置きは毎回 `--delete` で手元の木の完全な写しにする(前回の残骸を持ち越さない)。
rsync -a --delete $DRY \
    --exclude '.git/' \
    --exclude 'node_modules/' \
    --exclude '*.log' \
    "$SRC"/ "$EDITH:$STAGE"/

if [ -n "$DRY" ]; then
    echo "(dry-run。ここで終わり)"
    exit 0
fi

say "1b. 送った木の版を**仮置きに**刻む(= 本番の版を推理でなく観測にする)"
# 旧版はここで本番へ直接書いていた。仮置きに刻んでおけば step 7 の rsync が本番へ運ぶので、
# 「刻印だけ新しくて中身が古い」も「中身だけ新しくて刻印が古い」も**構造的に起きない**。
ssh "$EDITH" "printf '%s\n%s\n' '$SRC_REV' \"\$(date -Iseconds)\" > '$STAGE/DEPLOYED-REV'"
echo "刻む版: $SRC_REV"

say "2. edith 側の実行系を観測"
ssh "$EDITH" "$NODE -v && cd '$STAGE' && ls -1 src/ test/ | wc -l"

say "3. 単体 (edith 上・仮置きで)"
ssh "$EDITH" "cd '$STAGE' && PATH=/opt/homebrew/bin:\$PATH npm test --silent"

say "4. e2e (edith 上・仮置きで)"
# ★本番のサーバが 8787 で動いたままここを走らせても衝突しない。実測(2026-08-03)で確かめた:
#   e2e は `RC_PORT: "0"`(= 借りる port は毎回別)で、状態も `mkdtemp` の砂場と
#   `RC_KEY_DIR=<砂場>/keys` に閉じている。本番の鍵も登録簿も触らない。
ssh "$EDITH" "cd '$STAGE' && PATH=/opt/homebrew/bin:\$PATH $NODE test/e2e-local.mjs"

say "4b. 起動ラッパの分岐 (edith 上・仮置きで)"
# ★`npm test` は `test/*.test.mjs` しか回さないので、**起動ラッパは単体の網に入っていない**。
#   ところが配備で最後に効くのはこの台本で、間違えた時の症状は
#   「edith の上では全部緑、電話からだけ永久に到達できない」= 一番気付けない形。
#   step 8 の kickstart で気付く事は出来るが、その時にはもう本番の木を入れ替えた後 =
#   **戻す羽目になってから知る**。ここで先に駆動しておけば、赤なら本番に触らずに止まる。
#   この検査は偽の tailscale / node / dir を噛ませた砂場で完結する(本物の serve は撃たない)。
ssh "$EDITH" "cd '$STAGE' && /bin/bash tools/rc-backend-launch-check.sh"

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
#   (verify-on-edith.sh の `ls -d A B C` の注記に在るのは**別の罠**。`ls -d A B C` と glob を並べた時、
#    A の nomatch で B と C を一度も見ずに終わる、という情報を落とす型。こちらは単一 glob
#    なのでそれには当たらない。同じ教訓に見えるが別物なので混ぜない)
ssh "$EDITH" bash -s <<'REMOTE_LEFTOVER'
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
REMOTE_LEFTOVER

# ------------------------------------------------------------------------------
# ここから先が**本番の木に触る**区間。ここより上が全部緑でなければ到達しない。
# ------------------------------------------------------------------------------

say "6. 複製を取ってから、仮置きを本番の木へ入れ替える"
# ★この段の間だけ**配備中の印**を立てる。理由(Codex 2026-08-03 指摘):
#   `KeepAlive` が張ってあるので、入れ替えの窓に今の node がたまたま死ぬと launchd は
#   **版の混ざった木**から起動しうる。起動には成功して振る舞いだけが壊れる = 最悪の形。
#   印が在る間、`tools/rc-backend-launch.sh` は node を起こさず launchd の再試行に任せる。
#   印は同期ツリーの外(`~/.rc-backend/`)に置く = `--delete` の巻き添えにならない。
#   `trap` で必ず外す。外し損ねても launcher 側が 180 秒で無視するので詰まらない。
#
# ★複製は `.partial` に作ってから rename する(Codex 指摘)。途中で落ちた複製が
#   `prev-*` の名前で残ると、**戻せない物を戻せる物として数える**事になる。
#   rename は原子的なので、名前が付いている = 完成している、が構造的に保証される。
assert_lock_owner
SWAP_OUT="$(ssh "$EDITH" bash -s -- "'$LIVE'" "'$STAGE'" "'$RELEASES'" "'$MARK'" "'$OWNER'" <<'REMOTE_SWAP'
# ★`set -e` を足した(Codex 2026-08-03)。初版は `set -u` だけで、**rsync の失敗を無視して
#   先へ進んだ**。途中まで書けた木に対して「入れ替えた」と言い、刻印(DEPLOYED-REV)は
#   名前順で早いので先に届いている事が多い = step 7 の刻印一致も通る。
#   つまり「版の混ざった木」が緑で本番になる経路が、実際に開いていた。
set -eu
live="$1"; stage="$2"; releases="$3"; mark="$4"; owner="$5"

mkdir -p "$(dirname "$mark")" "$releases"
# 印も持ち主で守る。並走した配備が**他人の印**を外すと、外された側は
# 「起こされない筈の窓」で launchd に起こされる。
trap 'case "$(cat "$mark" 2>/dev/null)" in *" $owner") rm -f "$mark" ;; esac' EXIT
printf '%s %s\n' "$(date +%s)" "$owner" > "$mark"
echo "配備中の印を立てた: $mark"

snapshot="NONE"
if [ -d "$live" ]; then
    # 置き場が足りないまま複製を始めると、半端な複製と満杯の disk が同時に出来る。
    need_k=$(du -sk "$live" | awk '{print $1}')
    free_k=$(df -k "$releases" | awk 'NR==2 {print $4}')
    if [ "$free_k" -lt $(( need_k * 10 )) ]; then
        echo "★空きが足りない(必要 ${need_k}KB の10倍を見る / 空き ${free_k}KB)。配備しない" >&2
        exit 1
    fi
    oldrev="$(head -1 "$live/DEPLOYED-REV" 2>/dev/null || true)"
    [ -n "$oldrev" ] || oldrev="unknown"
    base="$releases/$(date +%Y%m%d-%H%M%S)-$oldrev"
    mkdir -p "$base.partial"
    # `.git` と `.gitignore` は私の物ではないので複製にも入れない(戻す時にも書き戻さない為)。
    # `--delete` を付けるのは、万一 `.partial` が残っていても**混ざった複製**にしない為。
    if ! rsync -a --delete --exclude '.git/' --exclude '.gitignore' "$live"/ "$base.partial"/; then
        echo "★複製が途中で失敗した。名前を付けない(= 戻せる物として数えない)。配備しない" >&2
        exit 1
    fi
    mv "$base.partial" "$base"
    snapshot="$base"
    echo "複製: $base"
else
    echo "初回配備(本番の木がまだ無い)= 複製は取らない"
fi

# ★ここだけは `set -e` に任せない。中断すると**版の混ざった木が本番に残る**ので、
#   落ちた事を捕まえてその場で複製から戻すまでが 1 つの動作。
#   `set -e` の下でも `|| swap_rc=$?` の形なら殺されない。
swap_rc=0
rsync -a --delete --exclude '.git/' --exclude '.gitignore' "$stage"/ "$live"/ || swap_rc=$?
if [ "$swap_rc" -ne 0 ]; then
    echo "★入れ替えの rsync が失敗した(rc=${swap_rc})= 本番の木が版の混ざった状態" >&2
    if [ "$snapshot" = "NONE" ]; then
        echo "★戻す複製が無い(初回配備)。木は混ざったまま。印は残す" >&2
        trap - EXIT   # 印を外さない = launchd に起こさせない側へ倒す
        exit 1
    fi
    # 戻しは3回まで試す。失敗の多くは一過性(相手が書いている最中 / 一時的な I/O)なので、
    # 1 回で諦めると「直せた筈の混ざった木」を残す事になる。
    back_rc=1
    for _ in 1 2 3; do
        back_rc=0
        rsync -a --delete --exclude '.git/' --exclude '.gitignore' "$snapshot"/ "$live"/ || back_rc=$?
        [ "$back_rc" -eq 0 ] && break
        sleep 3
    done
    if [ "$back_rc" -eq 0 ]; then
        echo "複製から戻した: $snapshot → $live(本番は前の版)" >&2
        exit 1
    fi
    echo "★戻しも 3 回失敗した(rc=${back_rc})。木は混ざったまま。" >&2
    # 印は外さない。ただし**印が守るのは 180 秒だけ**(launcher が
    # `RC_DEPLOY_MARK_MAX_S` を過ぎた印を無視する)。つまりこれは
    # 「起動を止める仕掛け」ではなく「人が気付く為の 3 分」でしかない。過信しない。
    trap - EXIT
    exit 1
fi
echo "入れ替えた: $stage → $live"
echo "SNAPSHOT=$snapshot"
REMOTE_SWAP
)"
# `|| true` = 全行が SNAPSHOT= だけだった時に grep が 1 を返して `set -e` に殺されない為。
printf '%s\n' "$SWAP_OUT" | grep -v '^SNAPSHOT=' || true
SNAPSHOT="$(printf '%s\n' "$SWAP_OUT" | sed -n 's/^SNAPSHOT=//p')"
[ -n "$SNAPSHOT" ] || { echo "★入れ替えの結果を読めなかった" >&2; exit 1; }

say "7. 刻印が送った版と一致するか(= rsync が黙って何もしていない、を捕まえる)"
LIVE_REV="$(ssh "$EDITH" "head -1 '$LIVE/DEPLOYED-REV'")"
echo "本番に刻まれた版: $LIVE_REV"
[ "$LIVE_REV" = "$SRC_REV" ] || { echo "★刻印($LIVE_REV)が送った版($SRC_REV)と違う" >&2; exit 1; }

say "8. 常設(launchd)が在るなら、走っている物を新しい木に入れ替える"
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
#
# ★2026-08-03 追加: ここが赤なら**複製から戻して、もう一度 kickstart する**。
#   「配ったが動かない」で終わらせない = 戻す判断を人の手に残さない(戻す事自体は可逆)。
assert_lock_owner
restart_rc=0
ssh "$EDITH" bash -s -- "'$SNAPSHOT'" "'$LIVE'" "'$MARK'" "'$SRC_REV'" "'$OWNER'" "'$JOB_LABEL'" "'$REMOTE_LOG_DIR'" <<'REMOTE_RESTART' || restart_rc=$?
# ★`set -e` は**足さない**。この段は `verify` が非零を返す事を前提に分岐しており、
#   `lsof` や `sed` が空を返す場面も正常。`set -e` を足すと正常な分岐が中断に化ける。
#   代わりに、黙って進んで良い所が 1 箇所も無い**戻しの rsync** を明示的に見る(下)。
set -u
snapshot="$1"; live="$2"; mark="$3"; want_rev="$4"; owner="$5"
job="gui/$(id -u)/$6"; logdir="$7"
jobpid() { launchctl print "$job" 2>/dev/null | awk -F'= *' '/^[[:space:]]*pid =/ {print $2; exit}'; }
# 戻しの途中で launchd に起こされない為の印(step 6 と同じ物)。**自分が立てた印だけ**外す。
trap 'case "$(cat "$mark" 2>/dev/null)" in *" $owner") rm -f "$mark" ;; esac' EXIT

if ! launchctl print "$job" >/dev/null 2>&1; then
    echo "常設なし($job を探したが無い)。入れ替えだけで終わり = 初回配備なら正常、"
    echo "  既に常設している筈なら **Label の綴りが違う** = 走っている job は古い木のまま。"
    exit 0
fi

# $1 = kickstart 前の PID / $2 = 走っていて欲しい版(空なら観測だけして判定しない)
verify() {
    local before="$1" want="$2" rc=0 after="" listener="" code="" health="" hver="" hpid=""
    launchctl kickstart -k "$job" || { echo "★kickstart が失敗した" >&2; return 1; }
    # 立ち上がるまで待つ。固定 sleep だと遅い機械で偽の赤、速い機械で無駄待ちになる。
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        sleep 1
        after=$(jobpid)
        [ -n "$after" ] && [ "$after" != "$before" ] && break
    done
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

    # ★★2026-08-03 追加(Codex: "Verify the deployed build/revision, not merely 'returns 401.'")。
    #   ここまでの検査が全部通っても、証明できたのは「新しいプロセスが 8787 を掴んで
    #   認証している」まで。**そのプロセスが何版を読み込んだか**は一言も言っていない。
    #   `/healthz` の `version` は `src/server.mjs` の起動時 IIFE が読んだ値 = disk ではなく
    #   **プロセスが実際に載せた版**。disk の DEPLOYED-REV(step 7)と対にして初めて
    #   「配ったのは新版」と「動いているのも新版」の両方が言える。
    #   `/healthz` は鍵を求めないので、この検査自体は鍵を持たずに成立する。
    health=$(curl -sS --max-time 5 http://127.0.0.1:8787/healthz 2>/dev/null || echo '')
    hver=$(printf '%s' "$health" | sed -n 's/.*"version":"\([^"]*\)".*/\1/p')
    hpid=$(printf '%s' "$health" | sed -n 's/.*"pid":\([0-9]*\).*/\1/p')
    if [ -z "$health" ]; then
        echo "★/healthz が答えない(401 は返るのに = 経路の一部だけ生きている疑い)" >&2; rc=1
    else
        echo "/healthz: version=${hver:-不明} pid=${hpid:-不明}"
        if [ -n "$hpid" ] && [ -n "$listener" ] && [ "$hpid" != "$listener" ]; then
            echo "★/healthz が名乗る pid(${hpid})が listener(${listener})と違う" >&2; rc=1
        fi
        if [ -n "$want" ] && [ "$hver" != "$want" ]; then
            echo "★走っているのは ${hver:-不明} で、動いていて欲しい版(${want})ではない。" >&2
            echo "  = 木は入れ替わったのにプロセスが別の版を載せている(古いプロセスの居座り/起動失敗の後始末)" >&2
            rc=1
        fi
    fi
    return "$rc"
}

before=$(jobpid)
echo "常設あり(pid=${before:-不明}) → kickstart -k で入れ替える(bootout はしない = 定義は触らない)"
if verify "$before" "$want_rev"; then
    exit 0
fi

echo "" >&2
echo "★★新しい木で立ち上がらなかった。複製から戻す。" >&2
if [ "$snapshot" = "NONE" ] || [ ! -d "$snapshot" ]; then
    echo "★戻す複製が無い(${snapshot})。手で直す必要がある。" >&2
    echo "  ログ: $logdir/rc-backend.error.log" >&2
    exit 1
fi
# 戻しの間も KeepAlive は生きている。印を立ててから書き戻す(でないと**戻している最中の
# 混ざった木**で起動されうる = 前へ進む時と同じ危険が、戻る時にも在る)。
printf '%s %s\n' "$(date +%s)" "$owner" > "$mark"
# ★★Codex 2026-08-03: ここは初版で **rsync の終了状態を見ていなかった**。
#   半分だけ戻った木でも `rm -f "$mark"` → `verify` へ進み、`DEPLOYED-REV` は名前順で
#   早いので先に戻っている事が多い = `/healthz` が前の版を名乗り、**混ざった木が
#   「安全側で止まっている(exit 2)」として報告される**。戻しの失敗を無視するという事は、
#   この台本の唯一の逃げ道が黙って壊れているという事。
back_rc=1
for _ in 1 2 3; do
    back_rc=0
    rsync -a --delete --exclude '.git/' --exclude '.gitignore' "$snapshot"/ "$live"/ || back_rc=$?
    [ "$back_rc" -eq 0 ] && break
    sleep 3
done
if [ "$back_rc" -ne 0 ]; then
    echo "★戻しの rsync が 3 回失敗した(rc=${back_rc})。本番の木は版が混ざっている。" >&2
    echo "  ここから先の検査は意味を持たない(前の版を名乗る混ざった木を緑と読む)ので、進まない。" >&2
    echo "  ログ: $logdir/rc-backend.error.log" >&2
    exit 3
fi
rm -f "$mark"
echo "戻した: $snapshot → $live" >&2
prev_rev="$(head -1 "$snapshot/DEPLOYED-REV" 2>/dev/null || true)"
before=$(jobpid)
if verify "$before" "$prev_rev"; then
    echo "★戻した木では立ち上がった。配備は失敗、本番は前の版のまま = 安全側で止まっている。" >&2
    exit 2
fi
echo "★★戻した木でも立ち上がらない。これは配備とは別の障害。" >&2
echo "  ログ: $logdir/rc-backend.error.log" >&2
exit 3
REMOTE_RESTART

case "$restart_rc" in
  0) : ;;
  2) echo "" >&2
     echo "★配備は失敗した。ただし本番は前の版で動いている(自動で戻した)。" >&2
     exit 2 ;;
  *) echo "" >&2
     echo "★配備が失敗し、戻しも効かなかった。人の手が要る。" >&2
     exit "$restart_rc" ;;
esac

say "9. tailnet 鍵の残り日数(**警告であって門ではない**)"
# ★ここで見る理由 = 「触っている今」が唯一まともに手を打てる瞬間だから。
#   起動ラッパも同じ script を呼ぶが、あちらは**起動時にしか**出ない。4ヶ月先に切れる鍵に
#   対して起動時の1行は警報にならない(そう書いてあるのに気付かないと、見張った気になる)。
#   恒久的な見張りは外部への生存通知(HANDOFF §3-P の候補)側の仕事。ここは中継ぎ。
#
# ★`|| true` を付ける理由 = 鍵が 40 日後に切れる事は、コードを配る妨げにならない。
#   ここで deploy を止めても被害は減らず、出来る仕事だけが止まる。止めるかは人が決める。
wl_run "鍵の期限" ssh "$EDITH" "/bin/bash '$LIVE/tools/tailnet-key-expiry.sh'"

say "9b. 停電で落ちた後、自分で戻って来られるか(**警告であって門ではない**)"
# ★2026-08-03 の Codex 査読の Q5「一度も検査していない壊れ方」への答え。
#   指摘そのもの(= 冷間再起動を検査していない)は当たっていたが、**結論は外れていた**:
#   実測すると鎖は既に繋がっていた —— FileVault Off / autoLoginUser=edith /
#   LaunchAgent は `~/Library/LaunchAgents/`(= edith の GUI login で load)/
#   RunAtLoad=true / KeepAlive=true / pmset autorestart=1 / sleep 0。
#   だから今日直す物は無い。問題は**誰も見張っていない事**の方で、
#   この 6 つはどれか 1 つ落ちるだけで「停電 = 二度と戻らない」に変わる。
#   2026-08-20 以降 edith に物理で触れないので、変わった事に気付ける場所が要る。
#   ここは配備の度に必ず通るので、置き場所として一番安い。
#   ★門にしない理由 = 自動ログインが切れている事は、コードを配る妨げにならない。
#     ここで止めても停電への強さは増えず、出来る仕事だけが止まる。
#
# ★2026-08-03 夜: ここに在った heredoc を `tools/coldboot-chain.sh` へ**切り出した**。
#   heredoc のままでは対照が書けず、実際にずれていた —— 上の注釈は 7 つの性質を
#   名指ししているのに、コードが読んでいたのは 4 つだけ(KeepAlive と `sleep 0` は
#   文章にしか無かった)。切り出して対照(`test/coldboot-chain-controls.sh`、17 本)を
#   当てたら、**旧版はその 17 本すべてを通せなかった**:
#     - 最後の文が `[ warn -eq 0 ] && echo || echo` なので **常に 0 で終わっていた**
#       (呼び側が `|| true` なので害は無いが、下流が読める信号は 1 つも無かった)
#     - 「fdesetup が答えない」と「FileVault が On」を同じ扱いにしていた(未測定 ≠ 壊れ)
#     - `awk '/autorestart/'` の部分一致。`sleep` を同じ書き方で足すと
#       `disksleep` `displaysleep` `SleepDisabled` に当たって壊れる(対照 C11)
#   実装は 1 つだけ在れば良いので、ここは呼ぶだけにする。
#   ★門にしない判断は変えていない。`|| true` を `wl_run` に替えたのは、
#     **飲み込んだ終了コードを最後の帳尻まで持ち帰る**為(tools/warn-ledger.sh)。
#     「門にしない」と「信号を捨てる」は別で、旧版はその2つを一緒にやっていた。
wl_run "停電から戻れるか" ssh "$EDITH" "/bin/bash '$LIVE/tools/coldboot-chain.sh'"

say "10. 複製の在庫(**自動では消さない**)"
# ★消す判断を台本に持たせない。1つ 2.7MB 程度で、消し間違いの害の方が大きい。
#   数と合計だけ出して、減らすかは人が決める。
wl_run "複製の在庫" ssh "$EDITH" "ls -1 '$RELEASES' 2>/dev/null | wc -l | tr -d ' ' | sed 's/^/複製の数: /'; du -sh '$RELEASES' 2>/dev/null | sed 's/^/合計: /'"

# ★配備そのものは通っている。ここで出すのは「門にしなかった段」の帳尻。
#   `wl_report` は 0=全部緑 / 1=赤 / 2=未測定 を返すが、**配備の終了コードには使わない**
#   —— 門にしない判断は変えていない。捨てるのを止めたのは判断ではなく信号の方。
wl_rc=0
wl_report || wl_rc=$?
case "$wl_rc" in
  0) : ;;
  1) echo "  ↑ 配備は成功。上の赤は**別件として今日中に**片付ける事(次の配備まで誰も見ない)" ;;
  2) echo "  ↑ 配備は成功。上の未測定は**緑ではない** —— 条件を揃えて測り直す事" ;;
esac

say "完了"
