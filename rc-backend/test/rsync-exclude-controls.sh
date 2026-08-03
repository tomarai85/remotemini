#!/bin/bash
# `tools/deploy-to-edith.sh` の対照・第3弾 = **旗が本当に効くか**を本物の rsync で測る。
#
# なぜ要るか(2026-08-03): 第1弾(構造検査)は「4つの脚に `--exclude '.git/'` が**書いてある**」
# までしか言えず、第2弾(挙動検査)は偽 rsync を PATH に置くので**転送そのものが起きない**。
# つまり両弾を合わせても「旗が実際に他人の `.git/` を守る」は**仮定のまま**だった。
# その空白は第1弾の頭に自分で書いてある(「これでも言えない事」)。ここがその穴を塞ぐ。
#
# 守っている物: edith の `/Users/edith/rc-backend/.git` と `.gitignore`。
# これは**私が作った物ではない**(2026-08-03 12:52 に fleet の整備が置いた)。
# 配備は `rsync -a --delete` で本番の木を上書きするので、除外が効かなければ**消える**。
#
# ── 型と、言える事・言えない事 ────────────────────────────────────────────
# 型 = 実測(本物の rsync を砂場で走らせる)。
#   言える  = この host の rsync は、台本に書かれている**その option 文字列**で
#             宛先側の `.git/` と `.gitignore` を残し、それ以外は `--delete` する。
#   言えない = edith 側の rsync が同じか(別個体)。それは `RC_RSYNC_EXCL_WHERE=edith`
#             (= `test/rsync-exclude-edith-controls.sh`)で測る。**既定の緑に含めない。**
#
# ── 連鎖の話(この対照が実際に守っている不変条件)──────────────────────────
# 戻し用の写しは `live -> snapshot` を**除外付き**で作る = 写しには `.git/` が無い。
# だから戻し `snapshot -> live` の脚が除外を落とすと、**戻した瞬間に他人の `.git/` が消える**。
# 「写しに無い」と「消える」が繋がるのはこの一点。M2 が前半、M1 が後半を押さえる。
#
# ★入力(規則 (1)): option 文字列は手で書かず**本物の台本から抜く**。
#   台本の旗を変えれば、ここで走る rsync の旗も変わる = 写しを持たない。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPLOY="${DEPLOY_SCRIPT:-$ROOT/tools/deploy-to-edith.sh}"
WHERE="${RC_RSYNC_EXCL_WHERE:-local}"
EDITH="${RC_EDITH_HOST:-edith@10.0.0.0}"

[ -f "$DEPLOY" ] || { echo "★台本が読めない: $DEPLOY = 測定不成立"; exit 2; }

pass=0; fail=0
chk() { # chk <名前> <期待> <実際>
  local name=$1 want=$2 got=$3
  if [ "$want" = "$got" ]; then echo "OK  $name"; pass=$((pass+1))
  else echo "NG  $name"; echo "      期待=$want 実際=$got"; fail=$((fail+1)); fi
}

# ── 本番の木に触る rsync の脚から option 文字列を抜く ──────────────────────
# `"$live"` を source か dest に持つ行が対象(第1弾の E0 と同じ集合)。
# `rsync ` の後から**最初の path 変数**の手前までが option。
legs() {
  /usr/bin/grep -nE '^[^#]*rsync ' "$DEPLOY" | /usr/bin/grep '"\$live"' \
    | /usr/bin/sed -E 's/^[0-9]+:.*rsync //; s/ "\$[a-z].*$//'
}
# ★`mapfile` は bash 4 以降。macOS の /bin/bash は 3.2 なので使えない(黙って空配列になる)。
LEG_OPTS=()
while IFS= read -r _l; do [ -n "$_l" ] && LEG_OPTS+=("$_l"); done < <(legs)
N_LEGS=${#LEG_OPTS[@]}
if [ "$N_LEGS" -ne 4 ]; then
  echo "★本番の木に触る rsync の脚が 4 本ではない(実測 $N_LEGS 本)= 測定不成立"
  echo "  台本の形が変わった。ここを直してから緑を名乗る事。"
  exit 2
fi

# ★eval に渡す前の関門。抜き出しが壊れて余計な物が混じったら**走らせない**。
for o in "${LEG_OPTS[@]}"; do
  if printf '%s' "$o" | LC_ALL=C /usr/bin/grep -q "[^-A-Za-z0-9 ./'=]"; then
    echo "★option の抜き出しが壊れている: [$o] = 測定不成立"
    echo '  ドル記号・back-quote・セミコロン・縦棒 等が混じった物は eval に渡さない。'
    exit 2
  fi
done

# ── 砂場で本物の rsync を走らせる小片 ──────────────────────────────────────
# 手元でも edith でも**同じ文**を走らせる(写しを2つ持たない)。option は base64 で運ぶ
# ので、`'.git/'` の引用が ssh の層を通っても壊れない。
PROBE="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/rsxprobe.XXXXXX")"
cleanup() { [ -n "${PROBE:-}" ] && [ -f "$PROBE" ] && /bin/rm -f "$PROBE"; return 0; }
trap cleanup EXIT
/bin/cat > "$PROBE" <<'PROBE_SH'
#!/bin/sh
# $1 = base64 の option 文字列 / $2 = A(宛先に .git が在る) | B(送り元に .git が在る)
set -u
OPTS="$(printf '%s' "$1" | base64 -d 2>/dev/null || printf '%s' "$1" | base64 -D)"
D="$(mktemp -d "${TMPDIR:-/tmp}/rsxwork.XXXXXX")" || { echo "ERR=mktemp"; exit 3; }
mkdir -p "$D/src" "$D/dst"
printf 'new\n' > "$D/src/a.txt"
if [ "$2" = A ]; then
  # 宛先が「他人の .git を持つ本番の木」。送り元には無い。
  mkdir -p "$D/dst/.git"
  printf 'old\n'  > "$D/dst/stale.txt"
  printf 'HEAD\n' > "$D/dst/.git/HEAD"
  printf 'x\n'    > "$D/dst/.gitignore"
else
  # 送り元が本番の木、宛先は空の写し先(= 戻し用の写しを作る脚)。
  mkdir -p "$D/src/.git"
  printf 'HEAD\n' > "$D/src/.git/HEAD"
  printf 'x\n'    > "$D/src/.gitignore"
  printf 'old\n'  > "$D/dst/stale.txt"
fi
eval "rsync $OPTS \"\$D/src\"/ \"\$D/dst\"/" >/dev/null 2>&1
echo "RC=$?"
[ -f "$D/dst/.git/HEAD" ]  && echo "GIT=yes"     || echo "GIT=no"
[ -f "$D/dst/.gitignore" ] && echo "IGN=yes"     || echo "IGN=no"
[ -f "$D/dst/stale.txt" ]  && echo "STALE=left"  || echo "STALE=gone"
[ -f "$D/dst/a.txt" ]      && echo "NEW=arrived" || echo "NEW=missing"
echo "RSYNC=$(command -v rsync)"
find "$D" -type f -print0 | xargs -0 rm -f
find "$D" -depth -type d -print0 | xargs -0 -n1 rmdir 2>/dev/null
echo "LEFT=$(find "$D" 2>/dev/null | wc -l | tr -d ' ')"
PROBE_SH

probe() { # probe <option 文字列> <A|B> -> "RC=0 GIT=yes ..." を1行で
  local b64
  b64="$(printf '%s' "$1" | /usr/bin/base64 | /usr/bin/tr -d '\n')"
  if [ "$WHERE" = edith ]; then
    ssh -o ConnectTimeout=10 -o BatchMode=yes "$EDITH" "sh -s -- '$b64' '$2'" < "$PROBE" 2>/dev/null \
      | /usr/bin/tr '\n' ' '
  else
    /bin/sh "$PROBE" "$b64" "$2" 2>/dev/null | /usr/bin/tr '\n' ' '
  fi
}
field() { printf '%s' "$1" | /usr/bin/tr ' ' '\n' | /usr/bin/grep "^$2=" | /usr/bin/cut -d= -f2; }

# 4本の脚の option が全部同じなら実走は1回で足りる。違っていたら全部走らせる。
UNIQ="$(printf '%s\n' "${LEG_OPTS[@]}" | /usr/bin/sort -u)"
N_UNIQ="$(printf '%s\n' "$UNIQ" | /usr/bin/wc -l | /usr/bin/tr -d ' ')"

echo "── 台本から抜いた option(脚 $N_LEGS 本 / 種類 $N_UNIQ)──"
printf '   %s\n' "${LEG_OPTS[@]}"

# ── X: 脚ごとに、その option 文字列が「守る」側に居るか ────────────────────
i=0
for o in "${LEG_OPTS[@]}"; do
  i=$((i+1))
  out="$(probe "$o" A)"
  rs="$(field "$out" RSYNC)"
  [ -n "$rs" ] || { echo "★rsync が見つからない(WHERE=$WHERE)= 測定不成立"; echo "$out"; exit 2; }
  chk "X${i}a 脚${i}: 宛先の .git/HEAD が残る"        "yes"     "$(field "$out" GIT)"
  chk "X${i}b 脚${i}: 宛先の .gitignore が残る"       "yes"     "$(field "$out" IGN)"
  # ★空振り防止: 何も起きなくても .git は残る。**delete と転送が実際に起きた**事を釘付ける。
  chk "X${i}c 脚${i}: ★空振り防止 — 除外外の古い file は消えている" "gone"    "$(field "$out" STALE)"
  chk "X${i}d 脚${i}: ★空振り防止 — 新しい file は届いている"       "arrived" "$(field "$out" NEW)"
  chk "X${i}e 脚${i}: rsync 自体は成功している"       "0"       "$(field "$out" RC)"
  chk "X${i}f 脚${i}: 砂場を残していない"             "0"       "$(field "$out" LEFT)"
done

# ── M2: 写しを作る脚は .git を**運ばない**(連鎖の前半)────────────────────
out_b="$(probe "${LEG_OPTS[0]}" B)"
chk "M2a 写しを作る側: 送り元の .git は写しに入らない"   "no"      "$(field "$out_b" GIT)"
chk "M2b 写しを作る側: 送り元の .gitignore も入らない"   "no"      "$(field "$out_b" IGN)"
chk "M2c 写しを作る側: 普通の file は入る(空振り防止)"   "arrived" "$(field "$out_b" NEW)"

# ── N: 陰性対照 — 旗を外したら本当に消えるか ──────────────────────────────
# 消えないなら、上の X は「守っている」のではなく「そもそも消えない」を見ているだけ。
if [ "${RC_RSYNC_EXCL_NEG:-1}" = "1" ]; then
  # ★末尾の空白を `*` にしてある。`' '` を必須にすると**行末の最後の 1 本が削り残る**。
  #   実際に踏んだ(2026-08-03): `--exclude '.gitignore'` だけ生き残り、N2 が「消えない」と
  #   赤を出した —— 主題ではなく**陰性対照の側**の欠陥だった。
  STRIPPED="$(printf '%s' "${LEG_OPTS[0]}" | /usr/bin/sed "s/--exclude '[^']*' *//g")"
  # ★N0 は「元と違う」では**弱すぎる**。1本でも削れれば通ってしまい、削り残しを見逃す。
  #   見るべきは性質: 削った後に `--exclude` が**1本も残っていない**事。
  chk "N0 ★空振り防止: 削った文字列に --exclude が1本も残っていない" "0" \
      "$(printf '%s' "$STRIPPED" | /usr/bin/grep -c -- '--exclude')"
  out_n="$(probe "$STRIPPED" A)"
  chk "N1 ★陰性: 旗を外すと .git/HEAD は消える"   "no" "$(field "$out_n" GIT)"
  chk "N2 ★陰性: 旗を外すと .gitignore も消える"  "no" "$(field "$out_n" IGN)"
fi

echo "--- 合計: PASS $pass / FAIL $fail ---"
echo "    測った rsync: $(printf '%s' "$(probe "${LEG_OPTS[0]}" A)" | /usr/bin/tr ' ' '\n' | /usr/bin/grep '^RSYNC=' | /usr/bin/cut -d= -f2-) (WHERE=$WHERE)"
[ "$WHERE" = edith ] || echo "    ★edith 側の rsync は**ここでは測っていない**(別個体)= RC_RSYNC_EXCL_WHERE=edith"
[ "$fail" = 0 ]
