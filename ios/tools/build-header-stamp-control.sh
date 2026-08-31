#!/bin/bash
# controls-for: ios/Sources/Core/BackendSession.swift
#
# 「電話が出す全部の要求が版を名乗る」構造の対照。
#
# ── なぜ構造を測るのか(2026-08-31)────────────────────────────────────────
# 挙動そのもの(header が実際に載るか)は `ios/Tests/Core/AppBuildHeaderTests.swift`
# が simulator で測る。此の台本が別に在るのは、**挙動が正しくても構造が崩れると
# 静かに戻る**からで、其の形を今日 実際に踏んだ:
#   名乗りは `SessionsClient` の一覧取得**1箇所だけ**に在り、他の口は全部 `build=-`。
#   検査は一覧の要求を測っていたので緑のまま、机側では
#   「最後の app 行」を読む道具が名乗らない行を掴んで **版を取り違えた**。
# client を1つ足した日に名乗りが消える形を潰すには、**押す場所が1つである事**を
# 測るしかない —— 「全部の client を測る」検査は、新しい client を足した日に
# 書き忘れる側へ倒れる。
#
#   S1 ★`ios/Sources` の中で `X-App-Build` を書くのは **1 file だけ**
#   S2 ★其の 1 file は `BackendSession.swift`(通り道)である
#   S3 ★押すのは `data(for:)` の中(client が個別に呼ぶ口ではない)
#   S4 ★束から読む規則が純関数に出ている(束を立てずに測れる = 検査が書ける)
#   S5 ★名乗れない時に**空文字を送らない**(nil で分岐している)
#   S6 挙動の検査が存在し、通り道(`data(for:)`)を撃っている
#   S7 ★押印が**代入として**在る(header 名を読むだけの形と区別する)
#
# ★★此の台本が測れない事(2026-08-31、自分の変異で見つけた):
#   **構造は挙動ではない**。`if false, let build = appBuild {` の様に条件だけを
#   偽にする変異を植えても、header 名も `setValue(build,` も `appBuild` も
#   file の上には残るので、S1-S7 は全部 緑のままだった(S7 は代入の**存在**しか見ない)。
#   挙動を measure するのは `ios/Tests/Core/AppBuildHeaderTests.swift` で、
#   走るのは `bash ios/tools/build.sh --sim`(simulator が要るので門からは回せない)。
#   **全部緑を「押印が効いている」と読まない事**。此の台本が言えるのは
#   「押す場所が1つで、其れが通り道に在る」までで、其の1箇所が実際に押すかは
#   simulator の検査だけが言える。
#
# 使い方: bash ios/tools/build-header-stamp-control.sh
# 終了コード: 0=全部緑 / 1=1本でも赤
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # = ios/
SRC="$HERE/Sources/Core/BackendSession.swift"
TEST="$HERE/Tests/Core/AppBuildHeaderTests.swift"
[ -f "$SRC" ] || { echo "測る対象が無い: $SRC"; exit 1; }

pass=0; fail=0
ok() { echo "PASS  $1"; pass=$((pass + 1)); }
ng() { echo "FAIL  $1  ($2)"; fail=$((fail + 1)); }

# ★綴りは連結で組み立てる。生で置くと、此の台本自身が S1 の走査に引っ掛かる
#   (`mutation-freeze-controls.sh` が 2026-08-03 に同じ結論を書いている)。
H="X-App""-Build"

# ── S1 押す場所は1つ ──────────────────────────────────────────────────────
# ★数えるのは「文字列を含む file」ではなく「**押している file**」(2026-08-31 に直した)。
#   註記で header の名を出しただけの file を数えると、経緯を書くたびに赤くなる ——
#   実際、役を通り道へ移した時に `SessionsClient` へ書いた1行の註記で S1 が赤くなった。
#   同じ型を `mutation-worktree-gate` の G3 が先に書いている(註記だけの台本は挙げない)。
STAMP="setValue(.*forHTTPHeaderField: \"$H\")"
n="$(grep -rlE "$STAMP" "$HERE/Sources" 2>/dev/null | wc -l | tr -d ' ')"
if [ "$n" = "1" ]; then ok "S1 ★版を名乗る場所は Sources の中で 1 file だけ"
else ng "S1 押す場所の数" "$n file が書いている = client ごとに散っている(足し忘れが起きる形)"; fi

# ── S2 其れは通り道 ───────────────────────────────────────────────────────
f="$(grep -rlE "$STAMP" "$HERE/Sources" 2>/dev/null | head -1)"
case "${f##*/}" in
    BackendSession.swift) ok "S2 ★押しているのは通り道(BackendSession)" ;;
    *) ng "S2 押す場所" "${f:-無し} = client 側で押している" ;;
esac

# ── S3 `data(for:)` の中 ─────────────────────────────────────────────────
# 関数の本体だけを切り出して探す(file のどこかに在る、では通り道である事を測れない)。
body="$(/usr/bin/awk '/func data\(for request: URLRequest\)/{f=1} f{print} f&&/^    }$/{exit}' "$SRC")"
if printf '%s' "$body" | grep -q "$H"; then ok "S3 ★押すのは data(for:) の中"
else ng "S3 押す位置" "data(for:) の外で押している = 通り道を素通りする経路が残る"; fi

# ── S7 ★読むだけでなく**代入**が在る ─────────────────────────────────────
# S3 は header の名が本体に在る事しか言わない —— 名は「既に入っているか」を
# 調べる側にも出るので、押す行を消しても S3 は緑のままになる。
if printf '%s' "$body" | grep -q "setValue(build, forHTTPHeaderField: \"$H\")"; then
    ok "S7 ★押印が代入として在る(名を読むだけの形と区別できる)"
else ng "S7 代入の有無" "setValue(build, …) が data(for:) の中に無い = 押していない"; fi

# ── S8/S9 ★役も同じ通り道で1箇所(2026-08-31)────────────────────────────────
# 版と**同じ疎らさ**を役も持っていた。`/api/account` が役を名乗らないと机は
# `client=app` と記録し、電話の版を見る枝が誤報を出す(実測 2 通)。
R="X-RC""-Role"
RSTAMP="setValue(.*forHTTPHeaderField: \"$R\")"
rn="$(grep -rlE "$RSTAMP" "$HERE/Sources" 2>/dev/null | wc -l | tr -d ' ')"
if [ "$rn" = "1" ]; then ok "S8 ★役を押す場所も Sources の中で 1 file だけ"
else ng "S8 役を押す場所の数" "$rn file = client ごとに散っている(足し忘れが起きる形)"; fi
if printf '%s' "$body" | grep -qE "$RSTAMP"; then ok "S9 ★役の押印も data(for:) の中"
else ng "S9 役の押す位置" "data(for:) の外で押している = 通り道を素通りする経路が残る"; fi

# ── S4 規則が純関数に出ている ────────────────────────────────────────────
if grep -q 'static func normalizedBuild' "$SRC"; then
    ok "S4 ★名乗ってよい値の規則が純関数(束を立てずに測れる)"
else ng "S4 規則の置き場" "束から直に読む形 = 規則だけを測れない"; fi

# ── S5 名乗れない時は送らない ────────────────────────────────────────────
# `if … == nil, let build = appBuild` の形 = nil なら押さない。
if printf '%s' "$body" | grep -q 'let build = appBuild'; then
    ok "S5 ★名乗れない時は送らない(空文字を送らない)"
else ng "S5 nil の扱い" "nil を空文字などに丸めている可能性 = 机が『版 = 空』を読む"; fi

# ── S6 挙動の検査が在り、通り道を撃っている ──────────────────────────────
if [ -f "$TEST" ] && grep -q 'data(for:' "$TEST" && grep -q 'appBuild: nil' "$TEST"; then
    ok "S6 挙動の検査が在り、通り道を撃ち、陰性対照(nil)も持つ"
else ng "S6 挙動の検査" "${TEST} が無い / 通り道を撃っていない / 陰性対照が無い"; fi

echo ""
echo "BUILD-HEADER-STAMP-CONTROL: pass=$pass fail=$fail"
exit $(( fail > 0 ))
