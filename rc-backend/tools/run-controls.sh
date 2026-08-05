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
    test/design-supersede-world-controls.sh   # ★2026-08-04 に此処へ入れた。世界の見分け
                                              # (designOrSkip)の対照。差し替え口だけ在って
                                              # 使う側が居らず、其処が実際に配備を止めた
    test/mutation-run-live-controls.sh
    test/mutation-target-controls.sh
    test/pii-controls.sh
    test/prove-control-controls.sh   # 判定する道具そのものの対照。これが壊れると
                                     # 全ての対照の判定が静かに嘘になるので、砂場の
                                     # repo(RC_ROOT)で測定経路まで通す
    test/prove-all-scope-controls.sh # ★2026-08-05。prove-all が **どの dir を探すか**
                                     # の対照。継ぎ目は毎回探すのに探す範囲が手書きで、
                                     # .harness/ と ios/tools/ の 5 本が視野の外に居た。
                                     # 縮める方向と伸ばす方向の両方を持つ(伸ばす方が本命 —
                                     # 生きた導出と「今の値と等しい定数」を見分けるのは此方)
    test/verify-script-controls.sh
    test/deploy-dirt-controls.sh
    test/session-guard-controls.sh   # ★2026-08-05 に此処へ入れた。電話側の HTTP が
                                     # 転送を拒否するセッション以外を通っていないか、の検査の対照。
                                     # Sprint 1 の Evaluator が見つけた欠陥(既定値だけが守られた
                                     # セッション = 呼ぶ側が素の URLSession を渡せば N5 が消える)の
                                     # 2段目の守り。型で縛る①は既存の client にしか効かず、
                                     # Sprint 2-6 が足す**新しい** client には一切かからないので、
                                     # 綴りの側から見張る。live の木には足すだけ、実測1秒未満
    test/wire-shape-controls.sh      # ★2026-08-05 に此処へ入れた。本番の応答の**形**だけを取る
                                     # 道具(`tools/wire-shape.mjs`)が、中身を伏せるかの対照。
                                     # 一覧には会話の題・直近の発言・作業 dir が載るので、
                                     # 伏せ方が壊れても出力は綺麗に見える = 事故の後にしか判らない。
                                     # 網も鍵も要らない(道具の `-` 口を使う)。実測1秒未満
    test/no-linerefs-controls.sh     # ★2026-08-05 に此処へ入れた。検査の**届く範囲**を測る。
                                     # 電話側の木(`ios/`)に行番号を1件植えて赤になるかを見る
                                     # ので、走査が届いていない事は緑で隠せない。実測1秒未満、
                                     # live の木には**足すだけ**で既存 file には触らない。
                                     # ★部分木(変異の作業コピー)でも緑である事を測る項が本体 ——
                                     # 此処が赤い造りだと変異走行の**全件**が「検出」に化ける
    test/disposable-session-controls.sh
                                     # ★2026-08-05 に此処へ入れた。DoD 9行目を閉じた計器
                                     # (`tools/disposable-session.mjs`)そのものの対照。守る本命は
                                     # **破壊側** —— `down` は tmux を殺し file を消すので、名前の
                                     # 検査(`rc-e2e-<数字>` 以外は畳まない)が緩めば Tom の実
                                     # セッションを殺せる。だから「殺さない事」を戻り値ではなく
                                     # **行為**で測る(偽 tmux に argv を記録させ `kill-session` が
                                     # 0 回である事を数える)。⑯ は検査を外した写しで ⑦ が
                                     # **赤になる**事まで見るので、対照が空振りしている状態を緑で
                                     # 隠せない。砂場は mktemp、実物の `~/.rc-backend` にも
                                     # `~/.claude` にも触らない。実測1秒未満
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
    test/mutation-timeout-controls.sh # 変異の脚が**時間切れ**になった時の処分。緑にも赤にも
                                     # 丸めず「未測定」で1件だけ落として走行は続ける、を測る。
                                     # 実測5秒(偽の脚 = `sleep`。検査一式は回さない)。
                                     # ★2026-08-04 まで die して走行ごと止めていた。M111 の様な
                                     # 「固まる事が欠陥の症状」な変異を1つも置けない形だった
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
    test/copied-tree-controls.sh     # 単体スイートが**木の写しでも回る**か。写しで回る事は
                                     # 行儀ではなく機能要件 —— 変異台本は写しで `npm test` を
                                     # 回し、その赤/緑が「変異を検出した」の判定そのものだから。
                                     # 木の外を読む1行で対照1が死に、197 件が1件も回らなくなる
                                     # (2026-08-04 実測。手元は 580/580 緑のまま)。実測15秒。
    test/run-controls-controls.sh    # ★**この台本自身**の対照。砂場に自分の複製を建てて
                                     # 偽の子を並べるので、本物の対照は1本も走らない。実測1秒未満。
                                     # 自己言及に見えるが循環しない —— 走るのは砂場の複製の方。
                                     # ★据えた初回に1件捕まえた: 旧版は `exit $(( red > 0 ))` で、
                                     # 画面に「未測定(緑ではない)」と出しながら**終了コードは 0**を
                                     # 返していた。この lane では変異の走行中に 2 が出るのが常なので、
                                     # 一番よく起きる状況で緑になっていた。旧版に差し替えると
                                     # **R4 だけ**が倒れる(他 18 本は旧版も持っていた性質)
    test/port-coverage-controls.sh   # ★2026-08-05。C群移植の**分母**を測る道具の対照。
                                     # 道具は「JS の検査が食わせた入力が Swift の検査にも
                                     # 在るか」を見る。訂正6-1(`nextHistoryLimit(0)` の
                                     # 移し忘れ = `||` と `??` の割れ目)を人手で見つけた後、
                                     # **同じ物を機械で数える為**に据えた。実測1秒未満。
                                     # ★この道具の一番痛い壊れ方は偽の緑(移っていない入力を
                                     # 「在る」と言う)なので、対照の重心は語境界(P3)と
                                     # 判定しない種別(P5-P7)に置いてある。3種の変異で
                                     # 倒れる集合が重ならない事を実測済(台本の頭の表)。
    test/deploy-to-edith-controls.sh # 配備台本(本番の木を上書きする 600 行)の対照・第1弾。
                                     # ★型は**構造検査**(台本の文字列を読む)であって挙動検査
                                     # ではない。捕まえるのは「脚を足して除外を書き忘れた」
                                     # 「除外を消した」「正本に見える写しが増えた」の3つだけで、
                                     # **これが緑でも「配備は安全」とは言えない**。実測1秒未満。
                                     # ★据えた初回に1件捕まえた: `FOREIGN=(--exclude '.git/'
                                     # --exclude '.gitignore')` が**一度も展開されていなかった**。
                                     # 本当の保護は remote heredoc 内のリテラル4箇所で、配列は
                                     # 「正本に見える写し」。3つ目を足した人は全部直したと信じて
                                     # 何も変わらない。旧版(HEAD)に差し替えると **E4 だけ**が倒れる。
    test/deploy-to-edith-behavior-controls.sh
                                     # 同・第2弾 = **挙動検査**。砂場に台本を置き、PATH の先頭に
                                     # 偽 ssh / 偽 rsync を据えて**実際に走らせ**、呼び出しの log を
                                     # 読む。第1弾では届かない性質を測る:
                                     #   ★赤い検査(単体 / e2e / 起動ラッパ)の後、本番の木に
                                     #     触る呼び出しが **1 本も出ない**事。
                                     # これは台本を読んでも判らない(`set -e` の抜け / `|| true` の
                                     # 置き所 / 段の並び替えのどれか1つで壊れ、壊れた事は**本番で
                                     # 初めて判る**)。空振り防止に B0c = 「通れば触っている」を
                                     # 陽性側で釘付けにしてある。陰性 N1-N5 付き。実測4秒。
                                     # ★これでも言えない事: 偽 rsync は転送しないので、除外の旗が
                                     # 本当に `.git/` を守るか。→ 第3弾(次)が実測で塞いだ。
    test/rsync-exclude-controls.sh
                                     # 同・第3弾 = **実測**。台本から option 文字列を抜き、
                                     # **本物の rsync** を砂場で走らせて、宛先の `.git/` と
                                     # `.gitignore` が残る事を見る。第1弾は「旗が書いてある」、
                                     # 第2弾は「本番に触らない」までで、**旗が効く**は誰も
                                     # 測っていなかった(両弾が自分でそう書いていた)。
                                     # 守っている物 = edith 側の他人の `.git`(fleet の整備が
                                     # 2026-08-03 12:52 に置いた物。私の物ではない)。
                                     # 陰性 N1/N2 = 旗を外すと本当に消える(消えないなら
                                     # 上の緑は「守っている」でなく「元々消えない」を見ている)。
                                     # ★ここで測るのは**手元の** rsync。入れ替え/戻しは edith 側で
                                     # 走るので、向こうの実測は EDITH_CTLS の姉家族が持つ。実測1秒。
    ../ios/tools/ui-fixture-absence-control.sh # ★2026-08-05 に此処へ入れた。Sprint 2 の
                                     # `RC_UI_FIXTURE`(List 画面の UI テスト用 fixture 切替口、
                                     # `ios/Sources/Core/SessionsListingFixture.swift`)が
                                     # Release バイナリの文字列表に一切残っていない事の対照。
                                     # `#if DEBUG` を信じるだけでは確認にならない(条件コンパイルで
                                     # 落ちたはずの文字列が最適化で残る事がある)ので、実際に
                                     # Release/Debug 両方の iphonesimulator ビルドを起こし、
                                     # `strings | grep -c` で直接見る。Debug 側は錨(anchor):
                                     # 検索方法そのものが壊れて常に0を返す病気だと、Release の
                                     # 「漏れていない」0 と見分けが付かない。`grep -c` は0件の時
                                     # 終了コード1を返すので、この対照は `set -e` を使わず件数を
                                     # 変数へ受けてから比較する(brief 本文が名指しで警告した罠)。
                                     # ビルド自体の失敗は2(未測定)、漏れの検出は1(赤)と、
                                     # 「まだ測っていない」と「測って赤」を同じ籠に入れない。
                                     # 実測: xcodebuild を2構成分走らせるので数十秒〜数分掛かる。
    ../ios/tools/ui-fixture-behavior-control.sh # 同・第2弾 = **挙動検査**。第1弾(文字列走査)は
                                     # brief 本文が「脆い」と名指しした通り、バイナリに文字が
                                     # 無くても別経路で同じ状態に落ちるバグは拾えない。ここでは
                                     # Release の .app を headless simulator へ実際に install/launch
                                     # し(`SIMCTL_CHILD_RC_UI_FIXTURE=list-empty`)、Sprint 1 の
                                     # `KeyEntryViewModel.swift` の診断 print と同じ convention で
                                     # `RootView.swift` に足した `"root flow:normal"` /
                                     # `"root flow:fixture state:..."` を `simctl launch --console`
                                     # 越しに読む(鍵もホストも書かない、通った経路の名前だけ)。
                                     # 期待: "normal" は出る・"fixture" は一切出ない、の両方が
                                     # 揃って初めて緑 -- 片方だけでは「たまたま今回は退避した」を
                                     # 緑と誤読しかねない。`open -a Simulator` は使わない
                                     # (Tom の GUI を奪わない禁則、この repo 全体の方針)。
                                     # 実測: install + 起動待ち4秒 + ビルドで1分前後。
    test/verify-log-controls.sh      # `tools/verify-log.sh`(検査の出力と終了コードを残す包み)。
                                     # ★据えた理由は実害から: `loop-replan-gate.sh survival` が
                                     # `choice-reply` に赤を出したのに**出力を捨てる**ので、赤の
                                     # 理由を一言も言えなかった。仮説を3つ潰す羽目になり(ポート
                                     # 衝突・`npm test` 同時・機械の負荷、全部外れ)、機序は今も
                                     # 未確定。**根は「機序が分からない」ではなく「計器が証拠を
                                     # 捨てる」**。包みが判定を書き換えたら repo 全体の生死が嘘に
                                     # なるので、測る中心は「終了コードが素と一字一句同じか」。
                                     # 陰性 N1 = 握り潰す版は失敗を 0 で返す(この repo は
                                     # `mutation-verdict.sh assert` で同じ病気を既に踏んでいる)。
                                     # 実測1秒未満。
    ../ios/tools/sim-log-summary-control.sh # ★2026-08-05。ios/tools/build.sh --sim が印字する
                                     # **要約1行**の判定(ios/tools/sim-log-summary.sh)。
                                     # ★この2つを backtick で囲まない事。`test/no-linerefs.test.mjs` は
                                     # backtick の引用を実在検査に掛けるが、`test/copied-tree-controls.sh`
                                     # が作る写しには **ios/ が入っていない**(backend の変異走行用なので
                                     # 入れるのも違う)。囲むと「完全な木では緑・写しでだけ赤」になり、
                                     # commit の門は通って**変異走行の中でだけ**落ちる —— 検査 file 自身が
                                     # 頭で警告している罠に、2026-08-05 に此処で一度嵌まった。
                                     # 隣の ui-fixture 2本が ios/ の `.swift` を囲めているのは、
                                     # 引用検査の対象拡張子が mjs/sh/py だけで `.swift` が入っていないから
                                     # = **たまたま**であって、真似してよい形ではない。
                                     # 据えた理由も実害から: 旧版は `Executed N tests` 行を
                                     # `tail -1` で拾っていたので、bundle が2本(単体97 / UI3)在る
                                     # この repo では 100 件走った run が「Executed 3 tests」と出た。
                                     # Sprint 1/2 の Generator と Evaluator が**4者とも別々に**
                                     # log を grep し直して回避しており、誰も計器の方を直していない。
                                     # ★本当の害は数字違いではない: 単体 bundle が1件も起動しなくても
                                     # UI 3件が緑なら「失敗0件」と出る = **偽の緑の道**。DoD が読むのは
                                     # この1行なので、ここが嘘を吐ける事は sprint 全体の証拠が嘘になる事。
                                     # 直した版は `Test Case ... passed/failed` の行を数える(1件=1行、
                                     # bundle を跨いでも二重に数えない)。0件は緑ではなく2(未測定)。
                                     # ★この対照は**本番の xcodebuild を起こさない**。判定を build.sh から
                                     # 別ファイルへ出して log を引数で受ける形にしたので、作り物の log で
                                     # 全分岐を測れる。測るのに数分掛かる造りだと対照は書かれない
                                     # (上の ui-fixture 2本が実際に数十秒〜数分掛かっている)。実測1秒未満。
    ../.harness/dod-sprint-3-controls.sh # ★2026-08-05。Sprint 3 の DoD 照合表
                                     # (`.harness/dod-sprint-3.sh`)の対照 = 15 行のうち 12 行が
                                     # **本当に赤にも緑にもなる**事を測る。照合表は「全部緑」を
                                     # 出した瞬間から誰も疑わなくなるので、逆向き(測っていないのに
                                     # 緑)を見張る物が要る。実際に初回で私の regex の基準点の誤りを
                                     # 3件捕まえた。ios/ を scratch へ写して**複製だけ**を壊す
                                     # (主作業木では Generator が xcodebuild を回している)。実測2秒。
                                     # ★sprint が閉じたら EXCLUDED_CTLS へ理由付きで移す事。
                                     #   消すのではなく移す —— 消すと「対照が在った」記憶だけが残る。
                                     # ★★2026-08-05、Sprint 3 は閉じた。だが**移さない**。理由:
                                     #   Sprint 4 で ios/ は大きく動いた(検査 150→212、Sources に
                                     #   5 file 追加)のに、この対照は 12/12 緑のまま通っている。
                                     #   churn を一つ跨いで緑な対照は「負債」ではなく**現に効いている
                                     #   計器**で、外せば守りがその分縮む。上の指示が想定していたのは
                                     #   「歴史的な DoD が腐って全員を止める」場面 —— それは起きていない。
                                     #   移すのは**実際に赤くなり、その赤が正当な進化だと確認できた時**。
                                     #   その日まで、指示に従わない判断をここに置く(黙って無視しない)。

    ../.harness/dod-sprint-4-controls.sh # ★2026-08-05。Sprint 4 の DoD 照合表の対照(27 本)。
                                     # 各行の緑・赤を**写しの中で自分で作る**。現在の判定を前提に
                                     # しないのは、Generator が同じ木の ios/Tests と progress.md を
                                     # 書き換えている最中にも走るから —— 「今 8-b が赤だから赤を
                                     # 期待する」と書いた対照は、直された瞬間に嘘になる。
                                     # 基準の一式 log すら写しの実数から合成する。
                                     # ★初回で本体の欠陥を1つ捕まえた: 失敗数を `$NF` で読んでいて、
                                     #   抜き出した文字列の最終語は "failures" という**語**なので
                                     #   常に 0 = 失敗を含む log を「失敗 0」と報告していた。
                                     # ★4 行目だけ3方向から撃つ(本文の Date() は赤 / **注釈の中の
                                     #   Date() は緑** / 時刻を受ける宣言が消えたら赤)。真ん中が要るのは、
                                     #   本体の初版が実装ではなく doc 注釈に当たって偽の赤を出したから。
                                     # 実測 12 秒。

    # ── ★2026-08-05、6本まとめて此処へ入れた(**登録漏れの実例**)──────────────
    # 経緯: この6本は同じ晩に書いて commit した。commit の門(`staged-controls-gate`)は
    # **その commit が触れた**対照を staged 一覧から導いて回すので、7/7 緑が出た。
    # 私はそれを「対照が生きている」と読んだ。読み違えである ——
    # **「触った時に回る」と「常に回る」は別の問い**で、常設の一式(此処)から見れば
    # 6本とも `UNREG = 一度も回らない対照` だった。実測 2026-08-05: disk 45 本 /
    # 未登録 6 本、全部この晩に私が書いた物。
    # 気付いたのは自分ではなく、並走していた Sprint 4 の Generator が進捗にそう書いたから。
    # 上の UNREG 照合は正しく赤を出していて、**私がそれを見ていなかった**だけである。
    # ★教訓は「一覧へ足せ」ではない: **緑を出した instrument が何を測っているのかを、
    #   緑を受け取る前に言える事**。commit の門の緑は「触れた物は緑」であって
    #   「守りが立っている」ではない。
    # 6本とも速い(実測: 13s / 1s / 1s / 0s / 1s / 0s = 合計 16 秒)ので既定へ入れる。
    test/doc-linerefs-gate-controls.sh # 書類の行番号引用ラチェットの門。緑/赤/**測れていない**の
                                     # 撃ち分け6本。偽 repo を `git init` して撃つので本物の
                                     # 基準値(393件)と 36 本の .md に依存しない。実測1秒。
    test/pre-commit-gates-controls.sh # commit の門の**呼び出し側**。どの門が呼ばれるか、
                                     # 絞り込みが何を通すかを、偽 repo とスタブで測る12本。
    test/install-hooks-controls.sh   # `.git/hooks/pre-commit` を据える台本。据え直しても
                                     # 壊れない事と、既存の hook を黙って上書きしない事。
    test/vacuous-gate-controls.sh    # 「錨の無い検査」を書いた瞬間に止める門(11本)。
    test/vacuous-scan-controls.sh    # 同・走査の本体(10本)。
    test/test-discovery-controls.sh  # 新しい test file が単体スイートに**拾われる**か。
                                     # 拾われない検査は書いた本人にだけ緑に見える。
)
# ── ★ここに**わざと入れていない**物(消えた訳ではない)────────────────────────
# `test/verdict-mutants.sh` = `test/mutation-verdict-controls.sh` の陰性対照
#   (対照そのものを壊して、狙った項が本当に赤くなるかを見る)。LOCAL_CTLS には**入れない**。
#   理由: この道具は既定で終了コード **2(未測定)** を正直に返す。遅い 6 体は親の対照が
#   本物の変異の走行を2回起こす為に 1 体 150〜250 秒 = 全部で 20 分超あり、pre-commit の
#   門の中では回せないから。ここへ登録すると commit が**毎回**止まる。
#   **止まる門は外される** —— 常に止まる門は「今回は飛ばす」を習慣にし、最後には門ごと
#   捨てられる。門に置かない方が、門が生き残る。
#   回し方: `RC_VERDICT_MUTANTS_SLOW=1 bash test/verdict-mutants.sh`(全 8 体、20 分超)。
#           既定(2 体だけ)は `bash test/verdict-mutants.sh` = exit 2。
#   ★「登録漏れ」に見えても直さない事。直すなら先にこの段落を読んで、上の理由が
#     まだ成り立つか(= 遅い 6 体が速くなったか)を確かめる。
# ── ★意図して一覧に入れない物(理由付きで**此処に**置く)────────────────────────
# 空でよい。空である事に意味が在る —— 下の照合は「此処に無い = 登録漏れ」と読むので、
# 外す判断をした時は必ず1行足す事。外した理由が書いていない除外は、次に読む人には
# 「漏れを黙らせた跡」と区別が付かない。
# (`test/verdict-mutants.sh` は名前が `*-controls.sh` ではないので照合の網に入らない。
#  外す理由は上の段落に書いてある)
EXCLUDED_CTLS=()

EDITH_CTLS=(
    test/env-death-controls.sh
    test/phone-window-controls.sh
    test/rsync-exclude-edith-controls.sh
                                     # 第3弾の edith 側。同じ台本を `RC_RSYNC_EXCL_WHERE=edith`
                                     # で回すだけ(写しを2つ持たない)。入れ替えと戻しの rsync は
                                     # remote heredoc の中 = **向こうの binary** が走るので、
                                     # 手元の緑は向こうの保証にならない。砂場は向こうの mktemp、
                                     # 小片が自分で消して `LEFT=0` を報告する(恒久物を置かない)。
)

list=("${LOCAL_CTLS[@]}")
[ "$ALL" -eq 1 ] && list+=("${EDITH_CTLS[@]}")

green=0; red=0; unmeasured=0
declare -a red_names=() unm_names=()

# ── ★一覧に載っていない対照を**赤**にする(2026-08-04、実際に漏れた)──────────
# 上の2つの一覧は**手で書いている**。`prove-all-controls.sh` は継ぎ目を毎回探すので
# 足し忘れが構造的に起きないが、**この台本は起きる** —— 冒頭に「足し忘れが起きない
# 造りにした」と書いてあるのは prove-all の話であって、此処の話ではなかった。
# 実測(2026-08-04): 対照が 30 本在るのに登録は 29 本。漏れていた 1 本は、同じ日に
# 書いた `copied-tree-controls.sh`(= 197 件の変異が回らない事を 15 秒で名指しする物)。
# **書いた対照が一度も回らない**のは DESIGN (19) そのもので、しかも書いた本人には
# 「対照を足した」という記憶だけが残るので、一番気付けない形で守りが1本消える。
#
# 未測定(2)ではなく**赤(1)**にする。回せなかったのではなく、回す物が無い事が
# 確定しているから —— 「測れなかった」と「守りが欠けている」を同じ籠に入れない。
# ★★2026-08-05: 見る範囲を **3つの木**へ広げる(門と同じ集合)。
#   此処は `test/*-controls.sh` しか見ていなかったので、`ios/tools/` と `.harness/` の
#   対照は**登録を忘れても誰も言わない**状態だった。実測: disk 上 38 本に対し、
#   どの一覧にも無い物が 1 本(`.harness/dod-sprint-3-controls.sh` = 今夜書いた物)。
#   ios 側が今まで無事だったのは手で入れていたからで、instrument が見ていたからではない。
#   ★これで「守りの届く範囲が欠陥と一緒に縮む」形の**5箇所目**。門(SCAN_SPECS)側は
#     一覧を1本に畳んだが、此処は走らせる順番と ALL の分岐を持つので配列は残す ——
#     代わりに**照合の網だけ**を門と同じ導出(走査 dir 全部)に合わせる。
#   単数形も拾う(`*-control*.sh`)。rc-backend 側の集合は変わらない(34 → 34、実測)。
#
# ★★★2026-08-05(同日・後): 上の「合わせる」が**写しだった**。走査 dir 3つを此処に
#   手で書いてあったので、門の SCAN_SPECS に4つ目が入った日に、此処だけが黙って
#   3つのまま残る。門側は同じ問題を「一覧を1つにして残りを導出」で根治したのに、
#   その導出の**外側**に写しが1枚残っていた —— 6箇所目、そして初めて
#   「踏む前に数えて見つけた」1件(他の5件は全部、赤か事故が先に来た)。
#   同じ一覧が2箇所に居る限り、要素を足す作業が片方を置き去りにするのは
#   注意力の問題ではなく**既定の結果**。だから網は門から取り出す。
#   取り出せなければ空にせず**未測定(2)で止める** —— 網が空だと全部が「登録済み」に
#   見えるので、黙って 0 本を走査するのがこの道具の一番危ない壊れ方。
GATE_FOR_SPECS="${GATE_FOR_SPECS:-$ROOT/tools/staged-controls-gate.sh}"
SCAN_DIRS=()
while IFS= read -r _d; do
    [ -n "$_d" ] || continue
    # SCAN_SPECS は repo の根から。此処の cwd は rc-backend なので基点を移す。
    case "$_d" in
        rc-backend/*) SCAN_DIRS+=("${_d#rc-backend/}") ;;
        *)            SCAN_DIRS+=("../$_d") ;;
    esac
done < <(/usr/bin/sed -n '/^SCAN_SPECS=(/,/^)/p' "$GATE_FOR_SPECS" 2>/dev/null \
         | /usr/bin/sed -n 's/^[[:space:]]*"\([^|"]*\)|.*/\1/p')

if [ "${#SCAN_DIRS[@]}" -eq 0 ]; then
    echo "UNMEASURED  門の走査 dir を取り出せなかった: $GATE_FOR_SPECS"
    echo "            SCAN_SPECS の書き方を変えたなら、此処の取り出しも同じ commit で直す事"
    echo "--- 合計: green=0 red=0 未測定=1(照合の網が空)---"
    exit 2
fi

for _dir in "${SCAN_DIRS[@]}"; do
  for _f in "$_dir"/*-control*.sh; do
    [ -f "$_f" ] || continue
    case " ${LOCAL_CTLS[*]} ${EDITH_CTLS[*]} ${EXCLUDED_CTLS[*]:-} " in
        *" $_f "*) : ;;
        *) echo "UNREG  $_f  ← どの一覧にも無い = **一度も回らない対照**"
           echo "         直し方: LOCAL_CTLS へ足す(既定)か、EXCLUDED_CTLS へ**理由付きで**入れる"
           red=$((red+1)); red_names+=("$(basename "$_f")(未登録)") ;;
    esac
  done
done

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
