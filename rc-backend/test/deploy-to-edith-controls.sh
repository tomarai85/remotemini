#!/bin/bash
# `tools/deploy-to-edith.sh` の対照(第1弾 = **他人の成果物を消さない**回りだけ)。
#
# なぜ要るか(2026-08-03): この repo で一番賭け金が高い道具(本番の木を上書きする 600 行)に
# 対照が1本も無かった。`staged-controls-gate.sh` が (c) の枝で
# 「対照を導けない道具: deploy-to-edith」と名指しして見えた。
#
# ★実際に1件見つけた: `FOREIGN=(--exclude '.git/' --exclude '.gitignore')` が
#   **一度も展開されていなかった**(使用 0 回)。本当の保護は remote heredoc の中の
#   **リテラル4箇所**が担っていて、配列は「正本に見える写し」として置かれているだけ。
#   `FOREIGN` に3つ目を足した人は「全部の脚を直した」と信じて、実際には何も変わらない。
#   ★これは私の doctrine そのままの形 —— 「基準がよそに正本がある一覧の写しなら、
#     両方直すのでなく**写しを持たない形**へ」。配列は消し、不変条件は**この対照が持つ**。
#
# ★この対照の**限界を先に書く**(型 = 構造検査であって挙動検査ではない):
#   測っているのは「台本の文字列にどの旗が書かれているか」。
#   捕まえられる = 脚を足して除外を書き忘れた / 除外を消した / 写しが増えた。
#   捕まえられない = rsync が旗の通りに振る舞わない / 宛先の綴りが間違っている。
#   後者を測るには偽 ssh + 偽 rsync で実走させる必要が在り、それは第2弾。
#   前者(旗の通りに振る舞うか)は第3弾 `test/rsync-exclude-controls.sh` が実測で塞いだ。
#   **ここで「配備は安全」とは言えない。言えるのは「4つの脚が除外を持っている」だけ。**
#
# 型 = 差替型。`${DEPLOY_SCRIPT:-…}` の継ぎ目から旧版を差し込める(prove-control.sh 用)。
#
# ★入力(規則 (1)「入力は本物の生成元から取る」): 手で書いた行ではなく**本物の台本**を読む。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPLOY="${DEPLOY_SCRIPT:-$ROOT/tools/deploy-to-edith.sh}"

[ -f "$DEPLOY" ] || { echo "★台本が読めない: $DEPLOY = 測定不成立"; exit 2; }

pass=0; fail=0
chk() { # chk <名前> <期待> <実際>
  local name=$1 want=$2 got=$3
  if [ "$want" = "$got" ]; then echo "OK  $name"; pass=$((pass+1))
  else echo "NG  $name"; echo "      期待=$want 実際=$got"; fail=$((fail+1)); fi
}

# ── 本番の木に触る rsync の脚を数える ─────────────────────────────────────
# `"$live"` を source か dest に持つ rsync の行。行継続は使っていないので1行で足りる
# (使い始めたら E0 が倒れるので、その時に此処を直す = 黙って取りこぼさない)。
legs() { /usr/bin/grep -nE '^[[:space:]]*(if ! )?rsync .*"\$live"' "$DEPLOY"; }
N_LEG=$(legs | /usr/bin/grep -c . )

# ★注記を数に入れない。**自分の注記に自分で当たる**のがこの型の定番の事故で、
#   実際に踏んだ: この対照の説明文に「`FOREIGN[@]` の使用 0 回」と書いた所為で
#   `grep -c 'FOREIGN\[@\]'` が 1 を返し、**壊した版でも E4 が緑**になった
#   (= 陰性対照が黙って無効化された)。以後、本数を数える検査は全部この関門を通す。
ncode() { /usr/bin/grep -vE '^[[:space:]]*#' "$DEPLOY" | /usr/bin/grep -c "$1"; }

# E0 ★脚の本数そのものを釘付けにする。増えた時に**この対照が落ちて気付く**為。
#    落ちたら「脚が増えた」= 新しい脚が除外を持っているか人が見て、数を更新する。
chk "E0 ★本番の木に触る rsync は 4 本(増減したら見直す合図)" 4 "$N_LEG"

# E1/E2 ★その全部が2つとも除外する。1本でも欠けると他人の .git を消しうる。
chk "E1 ★全ての脚が .git/ を除外" "$N_LEG" "$(legs | /usr/bin/grep -c -- "--exclude '\.git/'")"
chk "E2 ★全ての脚が .gitignore を除外" "$N_LEG" "$(legs | /usr/bin/grep -c -- "--exclude '\.gitignore'")"

# E3 ★複製を取る脚(live が **source** 側)も除外する。
#    ここを忘れると「複製に他人の .git が入り、戻す時に本番へ書き戻す」= 逆から壊す。
chk "E3 ★複製を取る脚(live が source)も 1 本在り除外を持つ" 1 \
    "$(legs | /usr/bin/grep -- '"\$live"/ "\$base' | /usr/bin/grep -c -- "--exclude '\.gitignore'")"

# E4 ★「正本に見える写し」を置かない。
#    展開されない `FOREIGN=(…)` が在ると、そこを直した人は全部直したと信じる。
n_def=$(ncode '^FOREIGN=(')
n_use=$(ncode 'FOREIGN\[@\]')
if [ "$n_def" -eq 0 ] || [ "$n_use" -gt 0 ]; then e4=yes; else e4=no; fi
chk "E4 ★展開されない除外の一覧を置かない(定義 0 か、定義したなら使う)" "yes" "$e4"

# ── 錠の札に実名を入れない ────────────────────────────────────────────────
# この機械の `hostname -s` には Tom の実名が入っている(実測)。札は edith に書かれ、
# 配備の出力は `.harness/evidence-*/` に **commit する**ので、生値だと repo に実名が入る。
chk "E5 ★札は hostname の digest 経由(生値を入れない)" 1 \
    "$(ncode 'OWNER=.*shasum')"
chk "E6 ★札の式に hostname の生値展開が無い" 0 \
    "$(ncode 'OWNER=.*\$(hostname')"

# ── 止まるべき所で止まる ──────────────────────────────────────────────────
# E7: 変異の走行中は配備しない。判定は `mutation-run-live.sh` に一本化されている
#     (素の pgrep 直書きに戻すと無関係な shell に当たって恒久的に塞がる、を踏んだ後)。
#     ★**呼び出しの行**を数える。名前の出現回数だと注記3行でも緑になる(実際 3 回出る)。
#     ★2026-08-04、呼び方を変えたので此処も変えた。変えた理由を2つとも釘付けにする:
#       (a) 判定が 0/1/2 を返す様になった(2 = 測れなかった)。`if <判定>; then 止める` は
#           「0 以外は全部進んでよい」の意味なので、**測れなかった時に配備が通る**。
#           門が答えるべきは「進んでよいと確認できたか」= 丁度 1 の時だけ進む。
#       (b) 裸で置くと `set -e` が非零で台本ごと殺す。この判定は 1 を返すのが正常なので、
#           裸に置いた瞬間に配備が毎回そこで死ぬ(実際に一度そう書いて behavior 対照が
#           B0a/B0c/B1c… 一斉に赤くなった)。`cmd || rc=$?` が唯一安全な形。
chk "E7 ★変異の走行判定を専用台本に委ねている(門としての呼び出しが1本)" 1 \
    "$(ncode '^bash .*mutation-run-live.sh" || _mrl=')"
chk "E7b ★その門は「丁度 1 = 居ないと確認できた」時だけ進む(未測定で開かない)" 1 \
    "$(ncode '\$_mrl" -ne 1 ')"

# E8: `--dry-run` は仮置きの rsync までで終わる。本番の木を書く段へ進ませない。
#     行番号で見る = 「exit が在る」だけでは、書いた後の exit でも通ってしまう。
dry_exit=$(/usr/bin/grep -n '(dry-run。ここで終わり)' "$DEPLOY" | /usr/bin/cut -d: -f1 | /usr/bin/head -1)
first_live=$(legs | /usr/bin/cut -d: -f1 | /usr/bin/head -1)
chk "E8 ★dry-run の脱出は本番の木に触る前に在る" "yes" \
    "$([ -n "$dry_exit" ] && [ -n "$first_live" ] && [ "$dry_exit" -lt "$first_live" ] && echo yes || echo no)"

# E9: 戻しの rsync は終了状態を見る。見ないと「戻した」と言って版が混ざったまま進む。
chk "E9 ★戻しの rsync が終了状態を取る" 2 \
    "$(ncode 'rsync .*"\$snapshot"/ "\$live"/ || back_rc=\$?')"

# ── E10-E13 ★陰性対照 ─────────────────────────────────────────────────────
# 上が緑なのは、見分けているからか **どの綴りにも当たる書き方**をしているからか。
# 台本を壊した複製を作って、狙った項だけが落ちる事を見せる。
TMP="$(/usr/bin/mktemp -d /tmp/rc-deployctl.XXXXXX)"
trap '/usr/bin/find "$TMP" -type f -print0 2>/dev/null | /usr/bin/xargs -0 /bin/rm -f 2>/dev/null; /bin/rmdir "$TMP" 2>/dev/null' EXIT

mutate_run() { # mutate_run <sed式> -> 壊した版で自分を回し、NG の名前を返す
  local expr="$1" f="$TMP/deploy.sh"
  /usr/bin/sed "$expr" "$DEPLOY" > "$f"
  DEPLOY_SCRIPT="$f" /bin/bash "$ROOT/test/deploy-to-edith-controls.sh" 2>&1 \
    | /usr/bin/sed -n 's/^NG  \([A-Z0-9]*\) .*/\1/p' | /usr/bin/tr '\n' ' '
}

if [ "${RC_DEPLOY_CTL_NEG:-1}" = "1" ]; then
  # ★壊す場所は**中身で指す**。行番号で指すと、台本に注記を足しただけで sed が空振りし、
  #   「壊した版でも赤が出ない」= 陰性対照が**黙って無効化**される(実際に踏んだ:
  #   除外の注記を 12 行足した途端、354 行目が別の行になって E10/E11 が空を返した)。

  # 仮置き→本番の脚から `.gitignore` の除外を落とす -> E2 が落ちる(E1 は落ちない = 綴りを見分けている)
  got=$(RC_DEPLOY_CTL_NEG=0 mutate_run "/\"\$stage\"\/ \"\$live\"\//s/ --exclude '\.gitignore'//")
  chk "E10 ★陰性: .gitignore の除外を1本落とすと E2 だけが落ちる" "E2 " "$got"

  # `.git/` の除外を落とす -> E1 だけ
  got=$(RC_DEPLOY_CTL_NEG=0 mutate_run "/\"\$stage\"\/ \"\$live\"\//s/--exclude '\.git\/' //")
  chk "E11 ★陰性: .git/ の除外を1本落とすと E1 だけが落ちる" "E1 " "$got"

  # 使われない FOREIGN 配列を戻す -> E4 だけ
  got=$(RC_DEPLOY_CTL_NEG=0 mutate_run "s/^# 私の物ではない2つ.*/FOREIGN=(--exclude '.git\/')/")
  chk "E12 ★陰性: 展開されない一覧を足すと E4 だけが落ちる" "E4 " "$got"

  # 札を生の hostname に戻す -> E5 と E6 の両方(digest が消え、生値が現れる)
  got=$(RC_DEPLOY_CTL_NEG=0 mutate_run 's|^OWNER=.*|OWNER="deploy-$(hostname -s)-$$"|')
  chk "E13 ★陰性: 札を生の hostname に戻すと E5/E6 が落ちる" "E5 E6 " "$got"
fi

echo "--- 合計: PASS $pass / FAIL $fail ---"
[ "$fail" = 0 ]
