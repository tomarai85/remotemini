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
# 新: `Test Case '...' passed/failed` の行を数える。**1件 = 1行**で、bundle を跨いでも
# 二重に数えない。`Test Suite ... Executed N tests` を足す方法は採れない ——
# あの行は suite / .xctest bundle / All tests の**3階層で同じ数を繰り返す**ので、
# 素朴に足すと二重・三重に数える(この log では 97 が2回、3 が3回出ている)。
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
tc_pass=$(grep -cE "^Test Case .* passed \(" "$LOG" 2>/dev/null || true)
tc_fail=$(grep -cE "^Test Case .* failed \(" "$LOG" 2>/dev/null || true)
tc_total=$((tc_pass + tc_fail))

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

if [ "$tc_fail" -gt 0 ]; then
    echo "==> テスト ${tc_total}件 実行 / **失敗 ${tc_fail}件**"
    grep -E "^Test Case .* failed \(" "$LOG" | head -20
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
