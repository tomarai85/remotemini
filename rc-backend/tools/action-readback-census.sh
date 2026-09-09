#!/bin/bash
# controls-for: rc-backend/tools/action-readback-census.sh
#
# ★宣言は**自分だけ**にする(2026-09-09、広げて踏んだ)。最初は
#   `controls-for: rc-backend/tools ios/tools` と書いたが、`controls-for:` は
#   「此の file が変わったら私を回せ」であると同時に、`orphan-instrument-scan` からは
#   **「私が此の道具を走らせている」**と読まれる —— 結果、両 dir の道具に付いていた
#   `no-operator:` の印(= 誰も走らせない、という**事実の宣言**)が一斉に
#   「腐った印」に化けた。台帳は道具を走らせていないので、其の読まれ方は嘘。
#   ★代わりに **commit の門に載せる**(`pre-commit-gates.sh`)。新しい変更する台本が
#     足された commit で必ず走るので、宣言を広げずに同じ効き目が出る。
#
# **状態を変える台本が、変えた結果を読み戻しているか**の台帳。
#
# ── なぜ要るか(2026-09-09)────────────────────────────────────────────────
# 此の repo の観測器の設計全体が「**配った台本の自己申告は、配った証拠ではない**」に
# 乗っている(`observer-parity-check.sh` の頭、2026-08-30 の事故 —— friday が 22 日
# 古い `health-observer.sh` を走らせていたのを、別レーンの md5 の突き合わせだけが
# 捕まえた)。だが「どの台本が読み戻しているか」を**母集団として**数えた事は一度も
# 無かった。数えていない母集団は、穴が在っても在ると言えない。
#
# ★之は自動分類器ではない。語の一致で判定すると、其の語に**言及しているだけ**の
#   台本を巻き込む(memory: `method_a_prefix_is_a_shape_a_secret_is_a_shape_with_a_body`)。
#   実際 `deploy-observer-to-friday.sh` は粗い走査では「読み戻し 0」に見えたが、
#   独立の一致検査で読み戻していた。だから **候補は機械が挙げ、判定は人が書く**。
#   判定の無い候補が 1 本でも在れば赤。台帳が痩せる事も、黙って埋まる事も無い。
#
# 語彙(判定):
#   readback      変えた後に**状態を読み直して**確かめる(何を読むかを理由に書く)
#   atomic        変える命令**そのものの結果**が観測(`mkdir` の錠、`mv` の成否)
#   sandbox       砂場の写しだけを変え、走行の最後にバイト一致で確認する
#                 (共有の復旧区間 + Z。`rc-backend/test/mutation-recovery-copy.test.mjs` が縛る)
#   not-mutating  変更の語は註や文字列の中だけ。註の外に変更の行が無い
#   no-readback   本当に読み戻していない。**理由(20 文字以上)が要る**
#
# 出力: .harness/evidence-2026-09-08/action-readback-census.tsv
# 終了コード: 0=全候補に判定が在る / 1=判定の無い候補が在る / 2=測れなかった
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="${RC_CENSUS_OUT:-$ROOT/.harness/evidence-2026-09-08/action-readback-census.tsv}"
DIRS=("$ROOT/rc-backend/tools" "$ROOT/ios/tools")
# ★註の**外**に、外の状態を変える命令が在るか。此処は候補を挙げるだけで、判定はしない。
# ★**継ぎ目ごしの呼び出しも候補にする**(Codex 2026-09-09)。字面だけを見る検出は
#   `tool=defaults; "$tool" write …` の形をすり抜ける —— 此の repo は其の書き方を
#   実際に使う(`SSH_BIN="${RC_DELIVERY_SSH:-ssh}"` 等)ので、理論上の穴ではない。
#   既定値で変更の道具を名指ししている行も候補に挙げる(実在 1 本: delivery-check)。
#   ★`ssh` は入れない —— 読み取りにも使う道具なので、入れると候補が「外へ出る台本」
#     全部へ広がり、判定の要求が薄まる。曖昧でない物だけを足す。
MUT_RE='launchctl (bootstrap|bootout|kickstart|load|unload)|rsync |scp |simctl (install|erase|boot)|/bin/(mv|cp) |git (checkout|push) |defaults write|PlistBuddy -c .Set|:-(rsync|scp|launchctl|defaults|PlistBuddy)[}"]'
FLOOR="${RC_CENSUS_FLOOR:-20}"

# 判定表。`path|verdict|理由`。★理由は判定の**根拠**を書く(何を読み直すか / なぜ要らないか)。
# 判定表は隣の data file(理由は其の頭)。`path<TAB>verdict<TAB>理由`。
TABLE="${RC_CENSUS_TABLE:-$(dirname "${BASH_SOURCE[0]}")/action-readback-verdicts.tsv}"
[ -f "$TABLE" ] || { echo "action-readback-census: 判定表が無い: $TABLE = 測っていない"; exit 2; }
VERDICTS=()
while IFS= read -r _l; do
    case "$_l" in ""|"#"*) continue ;; esac
    VERDICTS+=("$(printf "%s" "$_l" | tr "\t" "|")")
done < "$TABLE"
# ★表が痩せたら判定しない(読み込みが壊れて「候補ゼロ扱い」になるのを防ぐ)。
[ "${#VERDICTS[@]}" -ge 20 ] || { echo "action-readback-census: 判定表を ${#VERDICTS[@]} 行しか読めない = 測っていない"; exit 2; }

command -v awk >/dev/null 2>&1 || { echo "action-readback-census: awk が居ない = 測っていない"; exit 2; }

# 候補を挙げる(判定はしない)。
cands=()
for d in "${DIRS[@]}"; do
    [ -d "$d" ] || continue
    for f in "$d"/*.sh; do
        [ -f "$f" ] || continue
        # 註の外に変更の行が在るか
        if grep -vE '^[[:space:]]*#' "$f" | grep -qE "$MUT_RE"; then
            cands+=("${f#"$ROOT"/}")
        fi
    done
done
if [ "${#cands[@]}" -lt "$FLOOR" ]; then
    echo "action-readback-census: 候補を ${#cands[@]} 本しか挙げられなかった(下限 $FLOOR)= 走査が壊れている。判定しない"
    exit 2
fi

mkdir -p "$(dirname "$OUT")" 2>/dev/null
missing=""; short=""; n=0
{
  printf 'path\tverdict\treason\n'
  for p in "${cands[@]}"; do
      row=""
      for v in ${VERDICTS[@]+"${VERDICTS[@]}"}; do
          case "$v" in "$p|"*) row="$v"; break ;; esac
      done
      if [ -z "$row" ]; then missing="$missing $p"; continue; fi
      verd="${row#*|}"; verd="${verd%%|*}"
      why="${row#*|}"; why="${why#*|}"
      # no-readback は理由 20 文字以上(此処だけは機械で縛る)
      if [ "$verd" = "no-readback" ] && [ "${#why}" -lt 20 ]; then short="$short $p"; fi
      printf '%s\t%s\t%s\n' "$p" "$verd" "$why"
      n=$((n+1))
  done
} > "$OUT"

if [ -n "$missing" ]; then
    echo "action-readback-census: ★判定の無い候補が在る(台帳が母集団に追いついていない):"
    for m in $missing; do echo "    $m"; done
    echo "  VERDICTS に 'path|verdict|理由' を足す事。語彙 = readback / atomic / sandbox / not-mutating / no-readback"
    exit 1
fi
if [ -n "$short" ]; then
    echo "action-readback-census: ★no-readback の理由が短すぎる(20 文字以上):$short"
    exit 1
fi
echo "action-readback-census: 候補 ${#cands[@]} 本 / 判定済み $n 本 -> ${OUT#"$ROOT"/}"
awk -F'\t' 'NR>1 {c[$2]++} END {for (k in c) printf "    %-14s %s\n", k, c[k]}' "$OUT"
exit 0
