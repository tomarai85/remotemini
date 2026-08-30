#!/bin/bash
# controls-for: .harness/push-readiness-check.sh
#
# push-readiness-check.sh の**挙動**対照。本物の repo では回さない ——
# 本物は今 NOT READY(履歴に機械の識別子が在る)なので、其れだけを見ていると
# **大きさの腕が一度も赤くなった事が無いまま**「効いている」と読める。
# 砂場の git repo に台本を写し、腕ごとに発火させる。
#
#   C1 全部きれい            → READY(rc=0)
#   C2 上限超の blob         → NOT READY。**その file を名指しする**
#   C3 警告域の blob         → 警告は出すが READY(警告で止めない)
#   C4 PII の検査が赤        → NOT READY
#   C5 PII の検査が無い      → NOT READY(**測れていない**を「きれい」と読まない)
#   C6 git repo でない       → rc=2
#   C7 台本自身が push しない(読み取り専用である事を綴りで押さえる)
#   C8 history の**過去**に在る大 blob も見る(HEAD だけ見ていない事)
#
# ★C8 が要る理由: push が運ぶのは history であって作業木ではない。
#   一度 commit して消した大 file は `HEAD` からは見えないが、初回 push では飛ぶ。
#
# 使い方: bash rc-backend/test/push-readiness-controls.sh
# 終了コード: 0=全部緑 / 1=1本でも赤
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # = repo 根
SUT="$HERE/.harness/push-readiness-check.sh"
[ -f "$SUT" ] || { echo "測る対象が無い: $SUT"; exit 1; }

pass=0; fail=0
ok() { echo "PASS  $1"; pass=$((pass + 1)); }
ng() { echo "FAIL  $1  ($2)"; fail=$((fail + 1)); }
SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT

# 砂場の repo を作る。$1 = 名前 / 以降は「作る file 名:バイト数」
mk_repo() {
    local name="$1"; shift
    local r="$SB/$name"
    mkdir -p "$r/.harness"
    cp "$SUT" "$r/.harness/"
    ( cd "$r" && git init -q && git config user.email t@example.invalid && git config user.name t )
    local spec f n
    for spec in "$@"; do
        f="${spec%%:*}"; n="${spec##*:}"
        mkdir -p "$r/$(dirname "$f")"
        head -c "$n" /dev/zero | tr '\0' 'x' > "$r/$f"
        ( cd "$r" && git add -A && git commit -qm "add $f" )
    done
    printf '%s' "$r"
}
pii_ok()   { printf '#!/bin/bash\nexit 0\n' > "$1"; chmod +x "$1"; }
pii_red()  { printf '#!/bin/bash\necho "見つかった: 例の識別子"\nexit 1\n' > "$1"; chmod +x "$1"; }

run_in() {  # run_in <repo> <PRC_HARD> <PRC_SOFT> <pii path or ->
    local r="$1" h="$2" s="$3" p="$4"
    ( cd / && PRC_HARD="$h" PRC_SOFT="$s" PRC_PII_BIN="$p" bash "$r/.harness/push-readiness-check.sh" 2>&1 )
}

# ── C1 全部きれい ─────────────────────────────────────────────────────────
R="$(mk_repo clean "src/a.txt:100")"; pii_ok "$SB/pii-ok.sh"
out="$(run_in "$R" 10000 5000 "$SB/pii-ok.sh")"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "^== READY"; then
    ok "C1 きれいな repo は READY(rc=0)"
else ng "C1 READY" "rc=$rc / $(printf '%s' "$out" | tail -1)"; fi

# ── C2 上限超の blob ★大きさの腕 ─────────────────────────────────────────
R="$(mk_repo toobig "src/a.txt:100" "big/huge.bin:20000")"
out="$(run_in "$R" 10000 5000 "$SB/pii-ok.sh")"
if printf '%s' "$out" | grep -q "NOT READY" && printf '%s' "$out" | grep -q "huge.bin"; then
    ok "C2 上限超の blob で NOT READY、その file を名指しする"
else ng "C2 上限超で NOT READY" "$(printf '%s' "$out" | grep -E 'READY|huge' | tr '\n' ' ')"; fi

# ── C3 警告域は止めない ───────────────────────────────────────────────────
# ★警告で止めると、50MB の画像1枚で永久に NOT READY になり、道具ごと無視される。
R="$(mk_repo warnonly "src/a.txt:100" "big/mid.bin:7000")"
out="$(run_in "$R" 10000 5000 "$SB/pii-ok.sh")"
if printf '%s' "$out" | grep -q "^== READY" && printf '%s' "$out" | grep -q "警告"; then
    ok "C3 警告域は警告を出すが READY のまま(警告で止めない)"
else ng "C3 警告域" "$(printf '%s' "$out" | grep -E 'READY|警告' | tr '\n' ' ')"; fi

# ── C4 PII が赤 ───────────────────────────────────────────────────────────
R="$(mk_repo piired "src/a.txt:100")"; pii_red "$SB/pii-red.sh"
out="$(run_in "$R" 10000 5000 "$SB/pii-red.sh")"
printf '%s' "$out" | grep -q "NOT READY" \
  && ok "C4 PII の検査が赤なら NOT READY" || ng "C4 PII 赤" "$(printf '%s' "$out" | tail -1)"

# ── C5 PII の検査が無い ★測れていない ≠ きれい ───────────────────────────
R="$(mk_repo piimissing "src/a.txt:100")"
out="$(run_in "$R" 10000 5000 "$SB/no-such-pii.sh")"
if printf '%s' "$out" | grep -q "NOT READY" && printf '%s' "$out" | grep -q "測れていない"; then
    ok "C5 PII の検査が無ければ NOT READY(測れていないを『きれい』と読まない)"
else ng "C5 PII 不在" "$(printf '%s' "$out" | tail -1)"; fi

# ── C6 git repo でない ────────────────────────────────────────────────────
NR="$SB/notrepo"; mkdir -p "$NR/.harness"; cp "$SUT" "$NR/.harness/"
( cd / && bash "$NR/.harness/push-readiness-check.sh" >/dev/null 2>&1 )
[ $? -eq 2 ] && ok "C6 git repo でなければ rc=2(測定不成立)" || ng "C6 非 repo" "rc=$?"

# ── C7 台本自身が push しない ─────────────────────────────────────────────
# ★「読み取り専用」は註記ではなく綴りで押さえる。監査の道具が書き込みを覚えたら
#   それは監査ではない。
if grep -qE 'git +(push|remote +add|commit|fetch)' "$SUT"; then
    ng "C7 読み取り専用" "$(grep -nE 'git +(push|remote +add|commit|fetch)' "$SUT" | head -1)"
else ok "C7 台本に push / remote add / commit / fetch が無い(読み取り専用)"; fi

# ── C8 history の過去に在る大 blob も見る ★中核 ──────────────────────────
# 一度 commit してから消す。`HEAD` からは見えないが push は運ぶ。
R="$(mk_repo deleted "src/a.txt:100" "big/gone.bin:20000")"
( cd "$R" && git rm -q big/gone.bin && git commit -qm "remove the big one" )
out="$(run_in "$R" 10000 5000 "$SB/pii-ok.sh")"
if printf '%s' "$out" | grep -q "gone.bin"; then
    ok "C8 消した後でも history の大 blob を見つける(HEAD だけ見ていない)"
else ng "C8 history を見る" "作業木から消えた blob を見落とした = push が運ぶ物を測れていない"; fi

echo ""
echo "PUSH-READINESS-CONTROLS: pass=$pass fail=$fail"
exit $(( fail > 0 ))
