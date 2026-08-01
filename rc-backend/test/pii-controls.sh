#!/bin/bash
# check-no-pii.sh の対照。使い捨ての git repo を建てて、検査が **緑にも赤にもなる**事と、
# 赤の時に**正しい物だけ**を名指しする事を確かめる。
# 本題は2つ:
#   C4  = 「commit した後に作業ツリーから消したアドレス」を捕まえるか(push が運ぶ物)
#   C12 = メール検査から**除外**した `*.ts.net` を、種類2が拾っているか(除外の行き先)
set -u
# 検査の本体。**負の対照**(見張りを外した版を当てて、対照が緑へ倒れる事を確かめる)の為に
# 差し替えられる様にしてある。差し替えは対照を取る時だけで、通常運転では使わない。
SCRIPT="${PII_SCRIPT:-$(cd "$(dirname "$0")/../tools" && pwd)/check-no-pii.sh}"
ROOT=$(mktemp -d /tmp/pii-ctl.XXXXXX)
# ★途中で落ちても消す。この台本は edith でも走り(verify-on-edith.sh の4段目)、
#   作る場所は rc-verify の使い捨て dir の**外**なので、最後の1行での rm では
#   「実運用機に検査用のゴミを置かない」約束が中断時に破れる。trap で閉じる。
trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0

# 本物に見せる値。実在しない物を使い、tailnet IP は CGNAT 100.64/10 の中から選ぶ。
# ★さらに**完成形の文字列をこの台本の中に書かない**。この台本は追跡ファイルなので、
#   完成形を書くと検査が自分の対照台本を赤にする(= 常に赤 = 必ず無視される検査になる)。
#   実行時に組み立て、完成形は使い捨ての fixture の中にだけ現れる様にする。
_D=gmail; _T=com; _N=9; _NET=net
REAL_MAIL="real.person@${_D}.${_T}"          # 本物に見せるメール(実在しない)
TAILIP="100.77.42.${_N}"                     # CGNAT 100.64/10 の中の値(実在しない)
MAGIC="zzhost.tail0ffff.ts.${_NET}"          # MagicDNS の形(実在しない)

mk() { # mk <name> -> 空の git repo を作って cd 先を返す
  d="$ROOT/$1"; mkdir -p "$d/rc-backend/tools"
  git -C "$d" init -q
  git -C "$d" config user.email "ctl@example.com"; git -C "$d" config user.name ctl
  cp "$SCRIPT" "$d/rc-backend/tools/check-no-pii.sh"
  echo "$d"
}
run() { ( cd "$1" && bash rc-backend/tools/check-no-pii.sh 2>&1 ); }
chk() { # chk <label> <expected_exit> <actual_exit> <must_contain|-> <must_not_contain|-> <out>
  local l=$1 ee=$2 ae=$3 yes=$4 no=$5 out=$6 ok=1
  [ "$ee" = "$ae" ] || { ok=0; echo "  x 終了コード: 期待 $ee / 実際 $ae"; }
  [ "$yes" = "-" ] || grep -q "$yes" <<<"$out" || { ok=0; echo "  x 出力に無い: $yes"; }
  [ "$no"  = "-" ] || ! grep -q "$no" <<<"$out" || { ok=0; echo "  x 出力に有ってはいけない: $no"; }
  if [ $ok = 1 ]; then echo "OK  $l"; pass=$((pass+1)); else echo "NG  $l"; fail=$((fail+1)); printf '%s\n' "$out" | sed 's/^/     | /'; fi
}

echo "=== check-no-pii.sh 対照 ==="

# ---- 種類1: 個人のメールアドレス ----------------------------------------

# C1 緑の対照。これが赤になる検査は「常に赤」= 必ず無視される様になる。
#    伏字のメール + tailnet **でない** IP を置く(検査が IP を何でも拾わない事も同時に見る)。
d=$(mk c1); printf 'user rc-fixture-usr@example.com\nbind 127.0.0.1\nlan 192.168.11.5\n' > "$d/f.md"
git -C "$d" add -A; git -C "$d" commit -qm c
out=$(run "$d"); chk "C1 伏字 + tailnet でない IP -> 緑" 0 $? "なし" - "$out"

# C2 赤の対照 = 本物1件。緑にしかならない検査でない事の証明。
d=$(mk c2); printf "account: $REAL_MAIL\n" > "$d/f.md"
git -C "$d" add -A; git -C "$d" commit -qm c
out=$(run "$d"); chk "C2 本物1件 -> 赤・名指し" 1 $? "$REAL_MAIL" - "$out"

# C3 同一ファイルに本物と伏字が混在。ファイル単位で除外すると本物ごと見逃す形。
d=$(mk c3); printf "fixture rc-fixture-usr@example.com\nreal $REAL_MAIL\n" > "$d/f.md"
git -C "$d" add -A; git -C "$d" commit -qm c
out=$(run "$d"); chk "C3 混在 -> 本物だけを名指し(伏字は挙げない)" 1 $? "$REAL_MAIL" "rc-fixture-usr@example.com" "$out"

# C4 ★本題。commit した後に作業ツリーから消す = 作業ツリーは綺麗、履歴には残る。
#    第1段だけの検査はここで緑を出す(= 8/1 以前の姿)。
d=$(mk c4); printf "account: $REAL_MAIL\n" > "$d/f.md"
git -C "$d" add -A; git -C "$d" commit -qm c1
printf 'account: (伏せた)\n' > "$d/f.md"; git -C "$d" add -A; git -C "$d" commit -qm c2
out=$(run "$d"); chk "C4 履歴だけに残る -> 赤(履歴として報告)" 1 $? "履歴(push が運ぶのはこちら" - "$out"
grep -q "作業ツリー(まだ安く直せる)" <<<"$out" \
  && { echo "NG  C4b 作業ツリーは綺麗なのに作業ツリー欄が出ている"; fail=$((fail+1)); } \
  || { echo "OK  C4b 作業ツリー欄は出ない(綺麗な物を赤と言わない)"; pass=$((pass+1)); }

# C5 追跡していないファイルは対象外(node_modules 等で必ず誤検出が出ると検査が無視される)
d=$(mk c5); printf 'x rc-fixture-usr@example.com\n' > "$d/f.md"
git -C "$d" add -A; git -C "$d" commit -qm c
printf "untracked $REAL_MAIL\n" > "$d/scratch.txt"
out=$(run "$d"); chk "C5 未追跡ファイルは見ない -> 緑" 0 $? "なし" - "$out"

# ---- 道具が「見ていないのに なし と言う」形 ------------------------------

# C6 ★git repo の外 = 判定不能。ここで緑を出すと「本物が目の前にあるのに なし」になる。
#    verify-on-edith.sh は .git を除いて rsync するので、edith では必ずこの形で走る。
#    コピー先を**ファイル名まで**書く。dir だけ渡すと元の名前で置かれ、`$SCRIPT` を
#    差し替えた時(= 負の対照)だけ「ファイルが無い」で exit 127 になり、対照が壊れる。
d="$ROOT/c6"; mkdir -p "$d/rc-backend/tools"; cp "$SCRIPT" "$d/rc-backend/tools/check-no-pii.sh"
printf "account: $REAL_MAIL\n" > "$d/f.md"
out=$(run "$d"); chk "C6 repo の外 -> 緑を出さずに落ちる(exit 2)" 2 $? "判定不能" "なし" "$out"

# C7/C8 ★git 側が**エラーで**落ちた時。「一致なし」と同じ扱いにすると、履歴やファイル
#        一覧を一切見ないまま緑が出る(commit が増えて引数が ARG_MAX を超えた時に実際に
#        起きる形)。見ていないだけなのに「なし」と言う = 今夜の型そのもの。
REALGIT=$(command -v git)
stub() { # stub <dir> <失敗させる副コマンド>
  mkdir -p "$1/bin"
  cat > "$1/bin/git" <<EOF
#!/bin/bash
for a in "\$@"; do
  case "\$a" in -*|$1) continue ;; esac
  [ "\$a" = "$2" ] && exit 128
  break
done
exec $REALGIT "\$@"
EOF
  chmod +x "$1/bin/git"
}
run_stub() { ( cd "$1" && PATH="$1/bin:$PATH" bash rc-backend/tools/check-no-pii.sh 2>&1 ); }

d=$(mk c7); printf 'x rc-fixture-usr@example.com\n' > "$d/f.md"
git -C "$d" add -A; git -C "$d" commit -qm c; stub "$d" grep
out=$(run_stub "$d"); chk "C7 履歴走査が失敗 -> 緑を出さずに落ちる(exit 2)" 2 $? "履歴の走査に失敗" "なし" "$out"

d=$(mk c8); printf 'x rc-fixture-usr@example.com\n' > "$d/f.md"
git -C "$d" add -A; git -C "$d" commit -qm c; stub "$d" ls-files
out=$(run_stub "$d"); chk "C8 ファイル一覧の取得が失敗 -> 落ちる(exit 2)" 2 $? "git ls-files が失敗" "なし" "$out"

# C9 ★HEAD が未生成でも他の ref には commit がある木(`git checkout --orphan` 直後)。
#    条件を「HEAD があるか」で書くと履歴段を丸ごと飛ばす。push が運ぶのは ref であって
#    HEAD ではないので、ここで緑を出すと本物を積んだまま押せてしまう。
d=$(mk c9); printf "account: $REAL_MAIL\n" > "$d/f.md"
git -C "$d" add -A; git -C "$d" commit -qm c
git -C "$d" checkout -q --orphan fresh; git -C "$d" rm -rq --cached . ; rm -f "$d/f.md"
out=$(run "$d"); chk "C9 HEAD 未生成・ref には本物 -> 赤(履歴として報告)" 1 $? "履歴(push が運ぶのはこちら" - "$out"

# ---- 種類2: 機械の入口の名前 --------------------------------------------
# 8/01 に見つけた穴: `*.ts.net` を「メールではない」としてメール検査から**除外**したが、
# 除外した先を誰も見ていなかった。**除外は穴を開ける行為**なので、外した物の行き先を作る。

# C10 tailnet の IP。
d=$(mk c10); printf "host $TAILIP\n" > "$d/f.md"
git -C "$d" add -A; git -C "$d" commit -qm c
out=$(run "$d"); chk "C10 tailnet の IP -> 赤・種類2として" 1 $? "種類2" - "$out"

# C11 CGNAT の外(100.10.x / 100.200.x)は tailnet ではない。ここを拾うと誤検出だらけになる。
d=$(mk c11); printf 'ver 100.10.0.1\nver 100.200.0.1\nver 100.128.0.1\n' > "$d/f.md"
git -C "$d" add -A; git -C "$d" commit -qm c
out=$(run "$d"); chk "C11 CGNAT 外の 100.x -> 緑(何でも拾わない)" 0 $? "なし" - "$out"

# C12 ★seam。メールの正規表現に掛かるが SAFE で外れる値。**外れた先で拾われる**事を見る。
#     種類1として報告してもいけない(メールではない)。両方の性質を1枚で見る対照。
d=$(mk c12); printf "ssh zz@$MAGIC\n" > "$d/f.md"
git -C "$d" add -A; git -C "$d" commit -qm c
out=$(run "$d"); chk "C12 MagicDNS -> 赤・種類2(種類1では報告しない)" 1 $? "種類2" "種類1" "$out"

# C13 種類2も履歴を見ているか(種類1だけ履歴対応、では片肺)。
d=$(mk c13); printf "host $TAILIP\n" > "$d/f.md"
git -C "$d" add -A; git -C "$d" commit -qm c1
printf 'host (伏せた)\n' > "$d/f.md"; git -C "$d" add -A; git -C "$d" commit -qm c2
out=$(run "$d"); chk "C13 履歴だけに tailnet の名前 -> 赤" 1 $? "種類2" - "$out"

# ---- 段ごとの生存確認 -----------------------------------------------------

# C14 ★**作業ツリー段にしか捕まえられない**形。追跡ファイルを綺麗な状態で commit し、
#     その後ディスク上だけを汚す(commit しない)。履歴は綺麗なので履歴段は緑を出す。
#     これが無かったせいで、8/01 に**作業ツリー段が丸ごと空回りしていても対照が全部緑**
#     だった(C2/C3 のアドレスは commit されるので履歴段が代わりに拾っていた)。
#     「2つの段があって片方が死んでいる」は、両方を通る対照だけでは絶対に見えない。
d=$(mk c14); printf 'account: (綺麗)\n' > "$d/f.md"
git -C "$d" add -A; git -C "$d" commit -qm c
printf "account: $REAL_MAIL\n" > "$d/f.md"   # commit しない
out=$(run "$d"); chk "C14 作業ツリーだけが汚れている -> 赤(作業ツリーとして報告)" 1 $? "作業ツリー(まだ安く直せる)" "履歴(push が運ぶ" "$out"

# C15 追跡ファイルを1件も読めていない時は緑を出さない。上の C14 と対で、
#     「読んだ件数」という計器そのものが働いているかを見る。
d=$(mk c15); printf 'x rc-fixture-usr@example.com\n' > "$d/f.md"
git -C "$d" add -A; git -C "$d" commit -qm c; stub "$d" ls-files
out=$(run_stub "$d"); chk "C15 一覧が取れない -> 緑を出さない(exit 2)" 2 $? "判定不能" "とも 個人のメール" "$out"

# C16 ★「読んだ件数が追跡件数に足りない」経路を**本物のコードで**通す。
#     C15 は一覧の取得が失敗する形(git がエラー)だが、こちらは git が成功したまま
#     0 件を返す形 = 8/01 に踏んだ NUL の欠陥そのもの。この経路は逆対照で
#     作業ツリー段を殺すまで一度も実行された事が無く、実際に中の1行が
#     `unbound variable` で落ちて **判定不能(2) が 赤(1) に化けて**いた。
#     エラー経路は「書いてある」だけでは動かない。
stub_lsz_empty() { # `git ls-files -z` だけ空を返す(それ以外は本物)
  mkdir -p "$1/bin"
  cat > "$1/bin/git" <<EOF
#!/bin/bash
sub=""; want_z=0
# ★最初の非フラグ引数で break すると、後ろに来る \`-z\` を見ないまま素通しする
#   (副コマンドが先、フラグが後、という git の並びで実際に起きた)。全部見る。
for a in "\$@"; do
  case "\$a" in
    -z) want_z=1 ;;
    -*|$1) : ;;
    *) [ -z "\$sub" ] && sub="\$a" ;;
  esac
done
[ "\$sub" = "ls-files" ] && [ "\$want_z" = 1 ] && exit 0
exec $REALGIT "\$@"
EOF
  chmod +x "$1/bin/git"
}
d=$(mk c16); printf 'x rc-fixture-usr@example.com\n' > "$d/f.md"
git -C "$d" add -A; git -C "$d" commit -qm c; stub_lsz_empty "$d"
out=$(run_stub "$d"); chk "C16 追跡はあるのに1件も読めていない -> 判定不能(件数を出して落ちる)" 2 $? "実際に読んだのは" "とも 個人のメール" "$out"

echo "--- 合計: PASS $pass / FAIL $fail ---"
[ "$fail" = 0 ]
