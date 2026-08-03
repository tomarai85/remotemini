#!/bin/bash
# 手元で回す**対照**を全部まとめて回す。
#
# なぜ要るか(2026-08-02): 対照が6本在るのに、それを**まとめて回す物が無かった**。
#   実測した参照元:
#     env-death-controls.sh      → tools/verify-on-edith.sh が呼ぶ(edith 上)
#     phone-window-controls.sh   → 同上
#     pii-controls.sh            → 書類に名前が在るだけ
#     verify-script-controls.sh  → 書類に名前が在るだけ
#     mutation-target-controls.sh→ 書類に名前が在るだけ(pre-commit が回すのは**検査**であって対照ではない)
#     mutation-run-live-controls.sh → **参照 0 件**
#   対照は「検査が壊れていないか」を見る物なので、**誰も回さない対照は対照ではない**。
#   検査そのものが常に緑を返す病気(DESIGN §2.18-10)を見つける唯一の目がこれなので、
#   置き場所を1つに決めて、書類からはここを指す。
#
# edith 上でしか意味が無い2本(実 tmux / 実 launchd 相当)は既定では回さない。
#   `--all` を付けると回す(edith 上での `verify-on-edith.sh` 経由が本来の道)。
#
# 終了コードの扱い: 0=緑 / 1=赤 / **2=測っていない**(変異の走行中など)。
#   2 を緑に丸めない —— 「測れなかった」を「異常なし」と読み替えるのが一番危ない。
#
# ══ ★対照を**新しく書く**時に必ず読む2行(ここに置く理由 = 判断する場所に置かないと効かない)══
#   (1) **入力は本物の生成元から取る。** 手で書いた入力を食わせた対照は、
#       「入力の形についての自分の思い込み」を検証できない —— 思い込みごと緑になる。
#   (2) **直したら、直す前の版で対照が赤になるか個別に見る。** 赤にならない対照は
#       その欠陥について何も測っていない。「守りが緑」と「守りが効く」は別。
#       ★これを**回す物**が `tools/prove-all-controls.sh`(1本だけなら `prove-control.sh`)。
#         規則を書くだけでは効かなかった —— 人が手で思い出して回す限り毎回はやらない、
#         というのが (1) が同じ形で再発した理由そのもの。継ぎ目は毎回**探して**いるので
#         対照を新しく書いても一覧に足す手間は要らない(足し忘れが起きない造りにした)。
#         変異走行中は測れないので断る。`--dry` なら対象だけ出す(実行しない)。
#   経緯: (1) は env-death の対照で一度学んだのに、8/02 に `deploy-dirt-controls.sh` で
#   **同じ形で再発**した(手書きの porcelain 行を食わせて 13/13 緑 → 実物で偽陰性)。
#   前回の是正が「その対照1本を直す」で終わっていたから、次に対照を書く私は規則を読まずに
#   同じ穴を掘れた。だから規則を**呼び口の頭**に移した。詳細 = DESIGN §2.18-10 (15)(16)。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

ALL=0
[ "${1:-}" = "--all" ] && ALL=1

LOCAL_CTLS=(
    test/mutation-run-live-controls.sh
    test/mutation-target-controls.sh
    test/pii-controls.sh
    test/prove-control-controls.sh   # 判定する道具そのものの対照。これが壊れると
                                     # 全ての対照の判定が静かに嘘になるので、砂場の
                                     # repo(RC_ROOT)で測定経路まで通す
    test/verify-script-controls.sh
    test/deploy-dirt-controls.sh
    test/child-reaping-controls.sh   # 実際に変異台本を起こして殺す。実測10秒だが e2e の子が
                                     # 上がるまで待つので状況で伸びる(上限90秒で測定不成立)
    test/health-observer-controls.sh # 本物の HTTP サーバを立てて probe を測る。実測3秒
    test/example-artifacts-controls.sh # 見本(plist / conf)が据える前に壊れていないか。実測1秒
    test/gui-run-controls.sh         # edith の launchd の中で走らせる計器が、終了コードを
                                     # ちゃんと持ち帰るか。実測6秒。**網が要る** —— 届かない時は
                                     # 2(未測定)を返す。緑に丸めない事
    test/fork-check-controls.sh      # `--fork-session` を測る台本が、**測れていない時に
                                     # 測れていないと言う**か。偽の claude を7通りに振る舞わせる
                                     # ので上限を1トークンも食わない。実測2秒。網も不要
    test/limit-lifted-controls.sh    # 「上限が明けたか」の門番が両方向に壊れていないか。
                                     # fake HOME なので edith も上限も要らない。実測1秒。
                                     # ★据えた初回に2件捕まえた: haiku を根拠にする誤答と、
                                     # `.js` が repo 内で crash する(= /tmp では動く)拡張子の罠
    test/post-gate-batch-controls.sh # 窓が開いた後の一発勝負を撃つ台本の**門**。偽 ssh/scp なので
                                     # edith も上限も要らない。実測1秒。★**開く方向**が本体 ——
                                     # 「閉じている時に閉じる」は本物で撃てるが、「明けたら撃つ」は
                                     # 窓が開くまで本物では測れない。片方向だけ見ると
                                     # 「常に閉じる門」を緑と読む
    tools/rc-backend-launch-check.sh # ★2026-08-03 に此処へ入れた。それまで**参照 0 件**
                                     # (3箇所在った参照は全部「検査は此処に在る」と書いた
                                     # 注記で、誰も回していなかった)= この runner が潰す為に
                                     # 在るまさにその病気。中身は偽の tailscale / node / dir で
                                     # 起動ラッパを実走する対照 38 本。実測2秒、本物の
                                     # `tailscale serve` は撃たない。`test/` ではなく `tools/`
                                     # に在るのは置き場所の歴史的な揺れで、性質は対照
    test/remote-mini-root-controls.sh # ★測る相手が **この repo の外**(`~/.claude/tools/
                                     # remote-mini.sh`)に在る唯一の対照。それでも此処に居るのは、
                                     # 回す物が此処しか無いから ——「誰も回さない対照は対照でない」。
                                     # 偽 ssh/rsync + 偽 HOME で、edith にも Tom の tmux にも
                                     # 触らない(偽 ssh は tmux/osascript/curl/wget を含む命令を
                                     # 実行拒否する = 手元で走る偽 ssh が本物の tmux へ
                                     # send-keys する事故を構造で塞ぐ)。実測25秒。
                                     # ★Claude Code の版が上がったら **これを回す** ——
                                     # `--resume` の探索鍵が slug だけ、という実測(
                                     # `.harness/evidence-2026-08-03/resume-scope-measurement.md`)
                                     # の上に写像設計が乗っているので、版が変われば前提が動く
    test/mutation-verdict-controls.sh # 門の外へ出した変異の判定(`tools/mutation-verdict.sh`)が
                                     # **今の木の物でない緑**を返さないか。木を丸ごと砂場へ写して
                                     # から触るので、repo にも走行中の変異にも触らない。
                                     # ★**この一覧で一番長い(実測 90〜150 秒)**。理由は
                                     # 「本物の走行を1件回して判定を作る」から —— 手で書いた log を
                                     # 食わせた対照は、log の形についての思い込みごと緑になる。
                                     # `RC_VERDICT_CTL_FAST=1` で §5-9 を飛ばせるが、その時は
                                     # **2(未測定)を返す**。速い方を緑と読ませない為
    test/mutation-freeze-controls.sh # 変異の走行が**走っている最中の編集で汚れない**か。
                                     # 実測 150〜200 秒。走行を1本起こすので、別の走行が
                                     # 動いている間は **2(未測定)**を返す。
                                     # ★2026-08-03 に実際に汚れた事の再発防止 —— 3時間半の
                                     # 走行の途中で repo を10 file 触り、その1つが散文規則を
                                     # 破って `npm test` を赤にした結果、以降の変異が全部
                                     # 「検出」と記録された(= 素通りが丸ごと隠れ、要約は
                                     # 「素通り: なし」= **緑の方向に壊れた**)
    test/coldboot-chain-controls.sh  # 停電の後 edith が自力で戻れるかを測る道具
                                     # (`tools/coldboot-chain.sh`)。偽の fdesetup/
                                     # defaults/pmset + **本物の PlistBuddy に本物の
                                     # plist** を読ませるので、edith にも電源にも
                                     # 触らない。実測1秒未満。
                                     # ★元は deploy 9b の heredoc。切り出した理由は
                                     # 「注釈が名指しした 7 つの内 4 つしか読んでいな
                                     # かった」= heredoc には対照が書けないから
                                     # 誰も気付けなかった。旧版に差し替えると
                                     # **17 本全部が倒れる**(旧版は常に 0 で終わる)
    test/commit-suite-gate-controls.sh # commit の直前に単体の一式を回す門
                                     # (`tools/commit-suite-gate.sh`)。偽の一式を差すので
                                     # 本物の `npm test` は回さない。実測1秒未満。
                                     # ★本体が守るのは「rc は 0 なのに落ちた検査が在る」形と
                                     # 「集計行が出ていない(= そもそも走っていない)」形。
                                     # 素朴な rc だけ見る版に差し替えると 11 本中 8 本が倒れる
    test/staged-controls-gate-controls.sh # commit が**触れた対照**を回す門
                                     # (`tools/staged-controls-gate.sh`)。偽の repo の木 +
                                     # 偽の staged 一覧なので、本物の git にも repo にも
                                     # 触らない。実測1秒未満。
                                     # ★上の門(単体の一式)と役割が違う: `test/*-controls.sh`
                                     # は `npm test` の一部ではないので、上の門では対照の
                                     # 回し忘れが素通りする。**同日に2回踏んだ**方の穴。
                                     # ★一番危ない壊れ方は「選び方が空振りして、いつも
                                     # 『触れた対照は無い』と言う」—— 普段の commit では
                                     # 区別が付かないので S15 が陰性対照を張っている。
                                     # 道具だけ見る素朴版に差し替えると S6/S7/S8 が倒れる
    test/warn-ledger-controls.sh     # 「門ではない検査」の結果を捨てずに持ち帰る帳面
                                     # (`tools/warn-ledger.sh`)。source して使う関数なので
                                     # 偽の命令(`/bin/bash -c "exit N"`)だけで測れる。実測1秒未満。
                                     # ★守るのは**丸め方**: 255(ssh が繋がらない)を赤に混ぜると
                                     # 「edith が答えない」が「edith の停電対策が壊れている」として
                                     # 残り、居ない相手を直しに行く事になる。2(未測定)を緑に
                                     # 丸めるのも同じ族。
                                     # ★一番危ない壊れ方は「1 段も記録していないのに異常なし」——
                                     # 全部緑の配備では区別が付かないので W10/W11 が張っている。
                                     # 素朴な `|| true` 版に差し替えると 16 本中 14 本が倒れる
                                     # (W12/W13 は素朴版でも緑 = 見分けていない事を明記)
    test/run-controls-controls.sh    # ★**この台本自身**の対照。砂場に自分の複製を建てて
                                     # 偽の子を並べるので、本物の対照は1本も走らない。実測1秒未満。
                                     # 自己言及に見えるが循環しない —— 走るのは砂場の複製の方。
                                     # ★据えた初回に1件捕まえた: 旧版は `exit $(( red > 0 ))` で、
                                     # 画面に「未測定(緑ではない)」と出しながら**終了コードは 0**を
                                     # 返していた。この lane では変異の走行中に 2 が出るのが常なので、
                                     # 一番よく起きる状況で緑になっていた。旧版に差し替えると
                                     # **R4 だけ**が倒れる(他 18 本は旧版も持っていた性質)
    test/deploy-to-edith-controls.sh # 配備台本(本番の木を上書きする 600 行)の対照・第1弾。
                                     # ★型は**構造検査**(台本の текст を読む)であって挙動検査
                                     # ではない。捕まえるのは「脚を足して除外を書き忘れた」
                                     # 「除外を消した」「正本に見える写しが増えた」の3つだけで、
                                     # **これが緑でも「配備は安全」とは言えない**。偽 ssh /
                                     # 偽 rsync で実走させる第2弾は未着手 —— そこを黙って
                                     # 「配備に対照が付いた」と読み替えない事。実測1秒未満。
                                     # ★据えた初回に1件捕まえた: `FOREIGN=(--exclude '.git/'
                                     # --exclude '.gitignore')` が**一度も展開されていなかった**。
                                     # 本当の保護は remote heredoc 内のリテラル4箇所で、配列は
                                     # 「正本に見える写し」。3つ目を足した人は全部直したと信じて
                                     # 何も変わらない。旧版(HEAD)に差し替えると **E4 だけ**が倒れる。
)
EDITH_CTLS=(
    test/env-death-controls.sh
    test/phone-window-controls.sh
)

list=("${LOCAL_CTLS[@]}")
[ "$ALL" -eq 1 ] && list+=("${EDITH_CTLS[@]}")

green=0; red=0; unmeasured=0
declare -a red_names=() unm_names=()

for c in "${list[@]}"; do
    if [ ! -f "$c" ]; then
        echo "MISSING  $c  ← 書類が指しているのに無い"
        red=$((red+1)); red_names+=("$c(不在)")
        continue
    fi
    t0=$(date +%s)
    out="$(bash "$c" 2>&1)"; rc=$?
    t1=$(date +%s)
    last="$(echo "$out" | tail -1)"
    case "$rc" in
        0) green=$((green+1));      printf 'GREEN  %-34s %3ds  %s\n' "$(basename "$c")" "$((t1-t0))" "$last" ;;
        2) unmeasured=$((unmeasured+1)); unm_names+=("$(basename "$c")")
           printf 'UNMEA  %-34s %3ds  %s\n' "$(basename "$c")" "$((t1-t0))" "$last" ;;
        *) red=$((red+1)); red_names+=("$(basename "$c")")
           printf 'RED    %-34s %3ds  %s\n' "$(basename "$c")" "$((t1-t0))" "$last"
           echo "$out" | sed 's/^/         /' | tail -12 ;;
    esac
done

echo ""
echo "RUN-CONTROLS: green=$green red=$red 未測定=$unmeasured  (対象 ${#list[@]}本$([ "$ALL" -eq 1 ] || echo '、edith専用2本は除外'))"
[ "$red" -gt 0 ] && echo "  赤: ${red_names[*]}"
[ "$unmeasured" -gt 0 ] && echo "  未測定(緑ではない): ${unm_names[*]} ← 条件が揃ってから回し直す事"

# ★三値を**終了コードでも**保つ(2026-08-03 に直した)。
#   直す前は `exit $(( red > 0 ))` で、未測定が在っても **0 = 緑**を返していた。
#   上の行で人には「未測定(緑ではない)」と正しく出しているのに、機械には緑と言う ——
#   §7-P-g と同じ族(判定は正しく作れていて、持ち帰る所で捨てる)の8件目。
#   この lane では**変異の走行中に `mutation-verdict` / `mutation-freeze` が 2 を返す**ので、
#   一番よく起きる状況で「一番重い対照2本を測っていない run」が緑を返していた事になる。
#   ★HANDOFF:2496 は最初から「0=緑 / 1=赤 / 2=測っていない の三値を保つ事」と書いてある。
#     規則は在った。**回す物が無かった** = DESIGN (19)。対照 = test/run-controls-controls.sh
if [ "$red" -gt 0 ]; then exit 1; fi
if [ "$unmeasured" -gt 0 ]; then exit 2; fi
exit 0
