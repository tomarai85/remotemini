#!/bin/bash
# commit の直前に回す門を**全部**ここに置く。`.git/hooks/pre-commit` は
# これを呼ぶだけの3行にする(追跡されるのはこの file)。
#
# なぜ移したか(2026-08-05): 門を4つ育てておきながら、それを呼ぶ hook は**未追跡**で
# この機械にしか無かった。clone すると門は1つも動かない —— 守りが repo に付いてこない。
# 同日に5つ目(vacuous-gate)を足した所で、置き場所ごと直した。
# ★写しは作らない。中身はそのまま持って来ただけで、一覧は依然1本。
#   入れ直し = `bash rc-backend/tools/install-hooks.sh`(対照 test/install-hooks-controls.sh)
#
# 変異の**的**が今のコードに当たるかを commit の直前に確かめる。
# 本体 = rc-backend/tools/check-mutation-targets.sh
# 対照 = rc-backend/test/mutation-target-controls.sh(この検査が緑にも赤にもなる事の確認)
#
# なぜ hook 側で範囲を絞るか: 検査が見張るのは `src/` と `test/` の本文だけ。
# 書類だけの commit まで止めると、走行中の 85 分は**書類も残せなくなる**。
# 使えない検査は外されるので、止める範囲は見張っている範囲に合わせる。
# ★repo の根は自分の位置から取る(cwd に依らず、単体でも回せる様に)。
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
staged="$(git -C "$ROOT" diff --cached --name-only)"

# ★`tools/` も入れる(2026-08-02 追加)。的が指すのは `src/` の13ファイルだけ(測って確認済)
#   なので的のズレだけなら `src|test` で足りる。だが**検査そのものの実装**は `tools/` に在る
#   (`check-mutation-targets.sh` / `mutation-run-live.sh`)。ここを外していると、
#   **見張りの本体を書き換える commit でだけ見張りが動かない**という穴になる。
#   実際にこの穴で、判定を一本化した commit が素通りした。
#
# ★★`ios/` も入れる(2026-08-05 追加)。**この穴は上の穴と同じ形の3件目**。
#   経緯: `f7c341e` で `staged-controls-gate.sh` が `ios/tools/*-control*.sh` の
#   `# controls-for:` 宣言を読める様になった。**門は ios を見られる様になったのに、
#   門を呼ぶこの条件は rc-backend しか知らないまま**だったので、
#   `ios/` だけの commit はここで `exit 0` し、門に一度も届かなかった。
#   実測(2026-08-05、条件をそのまま再現):
#     staged = ios/Sources/... + ios/Tests/...  -> `exit 0`(門を通らない)
#     staged = rc-backend/src/view.mjs          -> 門へ進む
#   ios/** を見張ると宣言している対照は 3 本在り、その内 2 本は
#   `ios/Sources/RootView.swift` / `SessionsListingFixture.swift` / `ios/project.yml`
#   を名指ししている —— Sprint 3 の成果物は**ほぼ全部 ios/** なので、
#   このままなら Sprint 3 の commit は門を1つも通らずに入る。
#   ★下流に能力を足した時、上流の絞り込みがその能力を知らないと守りは伸びない
#     (DESIGN §2.18-10「守りの届く範囲が、欠陥と一緒に縮む」の別の顔)。
#
#   範囲を「code を触ったか」に保つ理由は上の注釈と同じ: 書類だけの commit を止めない。
#   `ios/*.md` は入れず、code と、対照が名指ししている `ios/project.yml` だけを入れる。
#
# ★★★`.harness/*.sh` も入れる(2026-08-05、同日2件目)。**同じ形の4件目**。
#   `.harness/` は普段は書類(brief / progress / feedback)なので範囲外で正しい。
#   だが Sprint 3 で **検査の本体**(`.harness/dod-sprint-3.sh`)と**その対照**をここに置いた。
#   `staged-controls-gate.sh` の走査 dir にも `.harness` を足したので門は見られる ——
#   3件目とまったく同じで、**門が見られても呼び出し側が知らなければ届かない**。
#   だから両側を同じ commit で広げる。`*.sh` だけ。`.md` は今まで通り素通し。
#   ★これで「門の走査 dir」と「この絞り込み」という**手で同期する一覧が2本**在る事が
#     4回連続の再発の真因だと確定した。片方だけ広げる限り必ずまた起きる。
#     一本化は Sprint 3 の走行中に触る物ではないので、WORKLOG に構造課題として残す。
# ★★★★書類の門(2026-08-05、同日3件目 = **同じ形の5件目**)。
#   上の3件は「下流に能力を足したのに、上流の絞り込みがそれを知らない」だった。
#   5件目は**自分で作った**: 同じ日に `doc-linerefs`(書類の行番号引用を増やさない
#   ラチェット)を単体スイートへ入れたのに、この絞り込みは `.md` を素通しする。
#   実測(2026-08-05、この regex に追跡 .md を1本ずつ当てた):
#     追跡 .md 36 本 / この絞り込みを通る 0 本 = **36/36 が門ゼロ**
#   つまり「書類だけの commit」という、その検査が在る理由そのものの場面で
#   **1度も走らない**。4回連続の再発を名指しした注釈を書いた数時間後に、同じ穴を作った。
#
#   直し方は「全部の門を回す」ではない —— 上に書いた「書類だけの commit を止めない」は
#   今も正しい(走行中の 85 分に書類が残せなくなる)。**書類には書類の門だけ**を当てる。
#   0.3 秒。ここを通っても下の絞り込みはそのまま効くので、書類だけの commit は
#   この1本を通ってから `exit 0` する。
#   ★門は**下の絞り込みより前**に、無条件で呼ぶ。`.md` が入っているかの判断は
#     門自身が持つ(自分の対象は自分で決める)。ここに `.md` の条件を書くと、
#     また「手で同期する一覧」が1本増える —— それが4回続いた再発の真因だった。
bash "$ROOT/rc-backend/tools/doc-linerefs-gate.sh" || exit $?

# ★2026-08-06 追加: 対照を**新設**した commit が、全掃きの一覧を触っていなければ止める。
#   本体 = rc-backend/tools/controls-registration-gate.sh
#   対照 = rc-backend/test/controls-registration-gate-controls.sh(9 本、陰性対照つき)
#   経緯: 2026-08-05 21:41 の `a3d6b58` で「登録漏れ6本」を直した。以後 `run-controls.sh` は
#   一度も触られておらず、その翌日に書いた対照 8 本が**8本とも未登録**だった
#   (実測 2026-08-06: disk 57 本 / 未登録 8 本)。登録を守っていたのは私の記憶だけで、
#   記憶に懸けた守りは1日で戻った。だから機械に置く。0.02 秒。
#   ★上と同じ理由で**無条件・下の絞り込みより前**に呼ぶ。自分の対象は門自身が決める
#     (ここに「対照が入っているか」の条件を書くと、手で同期する一覧がまた1本増える)。
#   非ゼロ(未登録 1 / 未測定 2)はどちらも止める。降ろすなら RC_CTLREG_OK に理由を書く。
bash "$ROOT/rc-backend/tools/controls-registration-gate.sh" || exit $?

# ★2026-08-09 追加: 受け入れ表・証跡が**実在しない検査名**を引いていたら止める。
#   本体 = rc-backend/tools/cited-testnames-gate.sh
#   対照 = rc-backend/test/cited-testnames-gate-controls.sh(7 本)
#   経緯: `.harness/dod-sprint-6.5.sh` は「切断を跨げるか」を検査名2つで名指ししていた。
#   検査が改名され(否定対照も1本→4本に増えていた)、表だけが古い名前を持ったまま
#   **製品の赤**を出し続けた —— 挙動は完全に覆われているのに「切断を跨げていない」と
#   読める形で。計器の腐りが製品の欠陥に化けると、直す先を間違えるか、赤に慣れる。
#   ★これは `doc-linerefs-gate` が止めた病の**次の段**である。あちらの指示は
#     「行番号でなく関数名で引け」だった。逃げた先の関数名にも見張りが要る。
#   0.2 秒。非ゼロ(腐り 1 / 未測定 2)はどちらも止める。
#   ★上2本と同じ理由で**無条件・下の絞り込みより前**に呼ぶ。証跡の `.md` は
#     `.harness/evidence-*/` に居て下の regex に届かない = 絞り込みの後だと死ぬ。
bash "$ROOT/rc-backend/tools/cited-testnames-gate.sh" || exit $?

if ! echo "$staged" | grep -qE '^(rc-backend/(src|test|tools)|ios/(Sources|Tests|tools))/|^ios/project\.yml$|^\.harness/[^/]*\.sh$'; then
    # ★2026-08-06: regex が外れても**まだ即断しない**。対照の見張り先の一覧を
    #   ここで推測するのをやめ、**持っている側に聞く**。
    #
    #   何故(初めて数えた): 全対照の `# controls-for:` 宣言 75 本を、この regex に
    #   1 本ずつ当てた。74 本は届き、**1 本だけ届かない** —— `rc-backend/package.json`
    #   (`copied-tree-controls.sh` が宣言)。その file だけの commit は、その対照どころか
    #   下の門を**全部**飛ばす。`npm test` の設定を書き換える commit という、
    #   一番検査されるべき場面で `commit-suite-gate` が走らない形だった。
    #   (履歴上の発生は 0 件。原理の穴を、起きる前に塞ぐ)
    #
    #   ★`|^rc-backend/package\.json$` を足すのは**手書き同期の6個目**で、上に5回ぶん
    #     書いてある再発とまったく同じ手。一覧を増やさずに済む形はこれ ——
    #     `staged-controls-gate.sh` は `SCAN_SPECS` という**唯一の一覧**を既に持っている
    #     ので、そこに「回すなら何が回るか」だけ聞く。regex は据え置きで、
    #     届く範囲だけが下流の能力に自動追随する。
    #   ★聞くだけで走らせない(`--would-select`)。書類だけの commit に足す費用は
    #     この一往復だけ(実測 0.1 秒未満。本番の走行は 20〜1651 秒)。
    if [ -z "$(bash "$ROOT/rc-backend/tools/staged-controls-gate.sh" --would-select)" ]; then
        exit 0   # 的が指す物も、検査の本体も、**どの対照の見張り先も**入っていない
    fi
fi

bash "$ROOT/rc-backend/tools/check-mutation-targets.sh" || exit $?

# ★2026-08-03 追加: 単体の一式が緑かも見る。
#   本体 = rc-backend/tools/commit-suite-gate.sh(追跡されるのはそちら)
#   対照 = rc-backend/test/commit-suite-gate-controls.sh
#   経緯: 対照2本を足した commit 25f8e09 が `npm test` を1本赤にしたまま入った。
#   「commit は緑で出す」は元から書いてあった規則で、**回す物が無かった**のが原因。
#   6 秒。非ゼロ(赤 1 / 未測定 2)はどちらも止める = 測れない時は止まる側へ倒れる。
bash "$ROOT/rc-backend/tools/commit-suite-gate.sh" || exit $?

# ★2026-08-05 追加: 空回りする検査を**書いた瞬間**に捕まえる。
#   本体 = rc-backend/tools/vacuous-gate.sh(追跡されるのはそちら)
#   対照 = rc-backend/test/vacuous-gate-controls.sh(11 本)
#   経緯: `tools/vacuous-scan.py` を一日かけて作り直したのに、**それを呼ぶ物が
#   repo のどこにも無かった**(grep で確認)。走るのは私が手で叩いた時だけ =
#   「検証スクリプトが在る」は「検証された」ではない。0.19 秒。
#   非ゼロ(錨なし 1 / 未測定 2)はどちらも止める。降ろすなら RC_VACUOUS_OK に理由を書く。
bash "$ROOT/rc-backend/tools/vacuous-gate.sh" || exit $?

# ★2026-08-07 追加: **上の段落と同じ病気の2件目**。
#   本体 = rc-backend/tools/port-coverage-gate.sh(追跡されるのはそちら)
#   対照 = rc-backend/test/port-coverage-controls.sh(道具の側を 36 本)
#   経緯: `tools/port-coverage.py` にも対照が在り、掃きにも登録されていたのに、
#   **道具そのものを呼ぶ物が repo のどこにも無かった**。結果、出口が 0 から 2 へ
#   落ちても誰も気付かないまま残っていた(実測 2026-08-07。前に緑を記録したのは
#   2026-08-05)。`vacuous-scan.py` が同じ形を免れているのは門が在るからで、
#   設計の差ではない。0.2 秒。非ゼロ(赤 1 / 未測定 2)はどちらも止める。
#   ★`python3 …` と直に書かない理由は皮の頭に書いた —— 上の対照は
#     bash "$ROOT/rc-backend/tools/<名前>.sh" の形から門を**数え上げる**ので、
#     直書きはその網に掛からない(実測: 直書きのまま回したら対照が 3 本倒れた)。
bash "$ROOT/rc-backend/tools/port-coverage-gate.sh" || exit $?

# ★2026-08-07 追加: 上の2件を**個別に足すのをやめて**、同じ病気を機械で挙げる。
#   本体 = rc-backend/tools/orphan-instrument-scan.sh
#   対照 = rc-backend/test/orphan-instrument-scan-controls.sh(14 本)
#   経緯: `vacuous-scan.py`(08-05)と `port-coverage.py`(08-07)は、どちらも
#   「対照は在る・掃きにも居る・けれど道具を撃つ者が居ない」で、見つけ方は両方とも
#   **私が偶々気付いた**だった。3件目を偶然に頼らない為に、対照の宣言
#   (`# controls-for:`)から組を作り、撃つ者が居ない道具を数える側へ回した。
#   ★狭めている: 対象は path で撃たれ得る拡張子だけ(実測 08-07 で 92 行中 72)。
#     Swift は project.yml の glob でまとめて compile されるので file 名で呼ばれる事が
#     原理的に無く、名前照合を掛ければ 11 本全部が偽の孤児になる。外した件数は毎回出る。
#   2.3 秒。非ゼロ(赤 1 / 未測定 2)はどちらも止める。
bash "$ROOT/rc-backend/tools/orphan-instrument-scan.sh" || exit $?

# ★2026-08-03 追加(同日2件目): **この commit が触れた対照**を回す。
#   本体 = rc-backend/tools/staged-controls-gate.sh
#   対照 = rc-backend/test/staged-controls-gate-controls.sh(15 本)
#   経緯: commit 45e0c8b は `tools/mutation-verdict.sh` と その対照を**同じ commit で**
#   足したのに、対照を最後まで通した事が一度も無かった。後で回したら3本倒れ、
#   道具の側に本物の欠陥が在った(assert が失敗を全部 0 で返していた)。
#   上の門は `npm test` しか見ない —— `test/*-controls.sh` は `npm test` の一部ではない
#   (回す物は `tools/run-controls.sh`)ので、45e0c8b はここを素通りしていた。
#   ★安い門(6秒)を先に置いて、高い門(触れた対照。長い物は 90〜200 秒)を後に置く。
#   順番はここが**両方 exec ではない**理由そのもの: 前の門が exec だと後ろが永久に走らない。
#   非ゼロ(赤 1 / 未測定 2)はどちらも止める。
exec bash "$ROOT/rc-backend/tools/staged-controls-gate.sh"
