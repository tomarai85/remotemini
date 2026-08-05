#!/bin/bash
# `xcodebuild test` の log を読んで、**何件測ったか**を判定して印字する。
#
#   usage: sim-log-summary.sh <log-path> <xcodebuild-rc>
#   終了コード: 0 = 緑 / 1 = 赤(テストが落ちた) / 2 = 測っていない
#
# ── なぜ build.sh の中ではなく別ファイルか ────────────────────────────
# build.sh の中に在ると、この判定を測るのに本物の `xcodebuild`(数分)が要る。
# 測るのに本番が要る造りだと、対照は書かれない。log を引数で受ける形にすれば
# **作り物の log** で全分岐を測れる(`test/wire-shape-controls.sh` と同じ作法)。
#
# ── 直した欠陥(2026-08-05、実測して見つけた)────────────────────────
# 旧: `grep -E 'Executed [0-9]+ tests' "$LOG" | tail -1`
#
# test bundle が2本(単体 97件 / UI 3件)在ると、**最後の bundle の行**だけを拾う。
# 100件走った run が「Executed 3 tests」と印字される。実測: Sprint 2 完了時の log で
# 旧版は 3 と出し、本当の件数を知るには log を grep し直す必要が在った ——
# Sprint 1 と Sprint 2 の Generator / Evaluator が**4者とも別々にその手間を踏んでいる**。
#
# ★本当に危ないのはそこではない。単体 bundle が**1件も起動しなかった** run でも、
#   UI bundle さえ緑なら「Executed 3 tests, with 0 failures」と出て**緑に見える**。
#   97件が消えた事が要約に出ない。DoD が読むのはこの1行なので、これは偽の緑の道である。
#
# 新: `Test Case '...' passed/failed` の**印**を数える。bundle を跨いでも
# 二重に数えない。`Test Suite ... Executed N tests` を足す方法は採れない ——
# あの行は suite / .xctest bundle / All tests の**3階層で同じ数を繰り返す**ので、
# 素朴に足すと二重・三重に数える(この log では 97 が2回、3 が3回出ている)。
#
# ── 二つ目の欠陥(2026-08-05 夕、変異の再測の最中に実測)────────────────
# 上の「新」は当初 **行頭**(`^Test Case`)で数えていた。本物の log では
# `xcodebuild` が OS の log(NSURLSession の `-1003` 等)を**改行を挟まずに**
# 吐くので、印が行の途中に来る事が在る。実測: 227件の run で 4件がそうなり、
# 要約は **226件** と印字した(log 自身は 227 と書いている)。
#
# ★数がずれるのは実害の小さい方。同じ綴りで `failed` も数えているので、
#   **落ちた検査の印が OS log と同じ行に乗ると、失敗が 0件として数えられる**。
#   その run は `XC_RC != 0` の道に落ちて赤にはなるが、文面は
#   「テスト以外の所で落ちている」になり、**倒れた検査の名前を1つも出さない**。
#   変異検査では「どの検査が捕まえたか」が成果物なので、これは
#   殺した変異を生存と読む道である。
#
# ★対照(`sim-log-summary-control.sh`)が捕まえられなかった理由がそのまま教訓:
#   作り物の log が**本物より綺麗**で、印は必ず行頭に在った。⑧を足した。
#
# 加えて `started` と `passed/failed/skipped` の数を突き合わせる。始まったのに
# 終わりを報告しない検査(途中で落ちた process)は、**分母から黙って消える**。
#   実測(2026-08-05、本物の 230 件の run): started 230 / passed 229 / failed 1 で一致。
#   ★代償を承知の上: 検査が落ちて `xcodebuild` が**再試行**した run は
#     started > finished になるので 2(未測定)になる。xcodebuild 自身はそれを
#     緑と呼ぶが、此処では呼ばない —— 落ちてから通った run は「通った」ではない。
#     `--sim` が非0で返る回数はその分増える。理由は必ず文面に名前が出る。
#
# ★0件は緑ではない。rc=0 でも `Test Case` が1行も無ければ 2(未測定)を返す。
#   「1件も測っていない」が「失敗0件」として通る道を塞ぐ為。
#
# コンパイル error とテスト失敗の見分けは列番号で付ける: swiftc は
# `file:line:col: error:`、XCTest は `file:line: error:`。この log で他にこの形は無い。
# (旧 build.sh が `| tail -3` だった頃、両者は同じ `** TEST FAILED **` と同じ exit 65 に
#  潰れていた。変異検査で「殺した」と「そもそもコンパイルが通っていない」が
#  区別できなくなる = 測っていない run が緑の証拠として通る。)
set -uo pipefail

LOG="${1:-}"
XC_RC="${2:-0}"

[ -n "$LOG" ] || { echo "usage: $0 <log-path> <xcodebuild-rc>" >&2; exit 2; }
[ -f "$LOG" ] || { echo "==> 測れない: log が無い ($LOG)"; exit 2; }

compile_errors=$(grep -cE ':[0-9]+:[0-9]+: (error|fatal error): ' "$LOG" 2>/dev/null || true)

# ── 三つ目の欠陥(2026-08-05 夜、Sprint 5 の run で実測)────────────────
# 二つ目を直した後も、290件 の run が **289件** と出た。差の1件を log から探すと、
# 印の綴りが `est Case '-[...]' passed` になっていた —— OS log の書き込みが
# **印の途中で改行を挟んだ**ので、`T` の1文字だけが前の行の末尾に残っている。
#   ...localizedDescripT
#   est Case '-[RemoteMiniTests.ConversationViewModelTests testLoadEarlier...]' passed
# ⑧(印が行の**後ろ**に繋がる)と同じ現象の、1バイト違う切れ方である。
#
# ★だから錨を `Test ` から外し、`Case '-[...]' <動詞> (` の方に置く。この木の印は
#   580件すべて `-[Suite test名]` の形なので、`-[` を要求すれば錨は緩まない
#   (`Test ` の5文字は情報を持たない —— 落ちても何も判らなくならない)。
#   改行が `Case` や検査名の内側に落ちた場合は此処では拾えないが、その run は
#   下の「始まった数 ≠ 終わった数」で 2(未測定)になる。**取りこぼしは黙って
#   緑にならない**方に倒れる、という形は保つ。
#
# ★騒音そのものは元から断った(`ConversationViewModelTests` の `SilentPollFetching`)。
#   此処を直すのは要約の基準を下げる為ではない —— 綴りが1文字欠けた時に
#   **失敗の印が飲まれる**方が本当の危険だから。飲まれると失敗は0件と数えられ、
#   run は「テスト以外の所で落ちている」に化けて、倒れた検査の名前が1つも出ない。
#   変異検査ではそれは「殺した変異を生存と読む」道である。
#
# ★行数(`grep -c`)ではなく**出現数**(`grep -o | wc -l`)。行頭の錨を外した以上、
#   1行に印が2つ乗る形が有り得る(OS log + 印 + 別の印)。行で数えると其処で1件失う。
marker_count() {   # $1 = passed | failed | skipped
    grep -oE "Case '-\[[^']*' $1 \(" "$LOG" 2>/dev/null | wc -l | tr -d ' '
}
tc_pass=$(marker_count passed)
tc_fail=$(marker_count failed)
# XCTSkip はこの木では今の所0本だが、数えないと「始まった数 > 終わった数」の
# 突き合わせが skip を**消えた検査**と誤認する。将来 skip が入った瞬間に
# 偽の未測定を出す形にしない。
tc_skip=$(marker_count skipped)
tc_total=$((tc_pass + tc_fail + tc_skip))
tc_started=$(grep -oE "Case '-\[[^']*' started" "$LOG" 2>/dev/null | wc -l | tr -d ' ')

if [ "$compile_errors" -gt 0 ]; then
    echo "==> ビルドが通っていない(コンパイル error ${compile_errors}件)= テストは1件も測っていない"
    grep -E ':[0-9]+:[0-9]+: (error|fatal error): ' "$LOG" | head -10
    exit 2
fi

if [ "$tc_total" -eq 0 ]; then
    # ★此処に backtick を書かない。二重引用符の中の backtick は**コマンド置換として走る**
    #   (`Test Case` は「Test を実行する」になる)。この repo で何度か踏んでいる形。
    echo "==> ★測っていない: 「Test Case」の行が1件も無い(xcodebuild rc=${XC_RC})"
    echo "    緑ではない。bundle が起動しなかった可能性を先に潰す事"
    exit 2
fi

# 始まったのに終わりを報告していない検査が在る = その分は測っていない。
# 「失敗0件」と名乗る前に止める(消えた検査は分母からも消えるので、
#  件数だけ見ていると気付けない)。
if [ "$tc_started" -gt "$tc_total" ]; then
    echo "==> ★測り切っていない: 始まった ${tc_started}件 に対し、終わりを報告したのは ${tc_total}件"
    echo "    差の $((tc_started - tc_total)) 件は結果を出していない(process が途中で落ちた可能性)。緑ではない"
    # 未測定は赤より強いので此処で止めるが、既に判っている失敗は道連れにしない。
    # 「測り切っていない」だけ出して倒れた検査の名前を伏せると、診断の手掛かりが減る。
    if [ "$tc_fail" -gt 0 ]; then
        echo "    (同じ run で ${tc_fail}件は失敗として報告されている)"
        grep -oE "Case '-\[[^']*' failed \([0-9.]+ seconds\)" "$LOG" | head -20
    fi
    exit 2
fi

if [ "$tc_fail" -gt 0 ]; then
    echo "==> テスト ${tc_total}件 実行 / **失敗 ${tc_fail}件**"
    grep -oE "Case '-\[[^']*' failed \([0-9.]+ seconds\)" "$LOG" | head -20
    exit 1
fi

# rc が0でないのにテストは全部通っている = テスト以外の所で落ちている
# (bundle の起動失敗、シミュレータの死、後処理の失敗)。緑と呼ばない。
if [ "$XC_RC" -ne 0 ]; then
    echo "==> テスト ${tc_total}件 実行 / 失敗0件、だが xcodebuild は rc=${XC_RC} で終わっている"
    echo "    テスト以外の所で落ちている。緑ではない"
    exit 1
fi

echo "==> テスト ${tc_total}件 実行 / 失敗 0件"
exit 0
