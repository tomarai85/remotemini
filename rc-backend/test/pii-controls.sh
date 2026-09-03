#!/bin/bash
# controls-for: tools/check-no-pii.sh
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

# C13b regex の**エスケープ形**(検査コードが持つ `/host\.tail<id>\.ts\.net/`)。2026-09-03 に公開写しの
#      予行で見つけた穴: `.` を素の文字として要求する regex は此の形を素通しし、伏字化した全履歴に
#      507 箇所 残った(`health.test.mjs` の assert が同じ名前をエスケープ形で持っていた)。
#      完成形は書かない(上と同じ理由)。backslash は bash の "" の中で `\\.` -> `\.` になる。
MAGIC_ESC="zzhost\\.tail0ffff\\.ts\\.${_NET}"
d=$(mk c13b); printf 'assert.match(msg, /%s/);\n' "$MAGIC_ESC" > "$d/t.mjs"
git -C "$d" add -A; git -C "$d" commit -qm c
out=$(run "$d"); chk "C13b regex エスケープ形の MagicDNS -> 赤・種類2" 1 $? "種類2" - "$out"

# C13c ホスト部の無い wildcard 形 `*.tail<id>.ts.net`。`*` は英数でないので旧 regex はここも抜けた。
d=$(mk c13c); printf 'allow *.tail0ffff.ts.%s\n' "$_NET" > "$d/f.md"
git -C "$d" add -A; git -C "$d" commit -qm c
out=$(run "$d"); chk "C13c wildcard 形 *.tail<id>.ts.net -> 赤・種類2" 1 $? "種類2" - "$out"

# C13d 緑の対照: `tail` の付く普通の語を拾わない(拾うと常に赤 = 無視される検査になる)。
d=$(mk c13d); printf 'tail -f app.log\ncocktail.tsx\nretail.ts\n' > "$d/f.md"
git -C "$d" add -A; git -C "$d" commit -qm c
out=$(run "$d"); chk "C13d tail の付く普通の語 -> 緑" 0 $? "なし" - "$out"

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

# ---- 種類3: この機械の名前 ----------------------------------------------
# 2026-08-03 追加。`tools/deploy-to-edith.sh` の錠の札が `deploy-$(hostname -s)-…` で、
# この機械の短い hostname には実名が入っている。札は配備の標準出力に出て、その出力は
# 証拠として commit する物なので、実名が repo に入る所だった。**検査は捕まえられなかった**。
#
# ★照合する値をこの台本に書けない(書けば追跡ファイルが実名を持つ = 検査が自分の対照を赤にする)。
#   検査と同じく走行時に取る。上の REAL_MAIL 等を組み立てで書いているのと同じ理由。
HOST_SELF="$(hostname -s 2>/dev/null || true)"
if [ "${#HOST_SELF}" -lt 6 ]; then
  # ★飛ばした事を**黙らせない**。「対照が0件で緑」を緑と読ませない。
  echo "SKIP C17-C20 この機械の hostname が 6 文字未満 = 種類3 の対照は走らせられない"
else

# C17 ★本題。追跡ファイルに hostname がある -> 赤で、種類3 として名指しし、
#     **しかも一致した文字列(= 実名)を出力に出さない**。
#     最後の1つがこの対照の要。`report()` を使い回す実装は前2つを満たしたまま
#     ここで落ちる —— 守っている物を失敗の文で出すのが、この repo で既に踏んだ型。
d=$(mk c17); printf 'lock owner = deploy-%s-1234\n' "$HOST_SELF" > "$d/f.md"
git -C "$d" add -A; git -C "$d" commit -qm c
out=$(run "$d"); chk "C17 hostname が木にある -> 赤・種類3 として報告・実名は出さない" 1 $? \
  "種類3: この機械の名前" "$HOST_SELF" "$out"

# C18 緑の対照。hostname が無い木で種類3 の節を出さない。
#     「常に節が出る」実装は C17 だけなら通ってしまう。
d=$(mk c18); printf 'user rc-fixture-usr@example.com\nbind 127.0.0.1\n' > "$d/f.md"
git -C "$d" add -A; git -C "$d" commit -qm c
out=$(run "$d"); chk "C18 hostname が無い -> 種類3 の節は出ない(綺麗な物を赤と言わない)" 0 $? \
  "この機械の名前 なし" "== 種類3" "$out"

# C19 履歴だけに残る形。種類1/2 は履歴を見るのに種類3 だけ作業ツリー止まり、では片肺
#     (C13 が種類2 について見ているのと同じ穴)。push が運ぶのは履歴の方。
d=$(mk c19); printf 'lock owner = deploy-%s-1234\n' "$HOST_SELF" > "$d/f.md"
git -C "$d" add -A; git -C "$d" commit -qm c1
printf 'lock owner = (伏せた)\n' > "$d/f.md"; git -C "$d" add -A; git -C "$d" commit -qm c2
out=$(run "$d"); chk "C19 履歴だけに hostname -> 赤(履歴として報告)・実名は出さない" 1 $? \
  "履歴(push が運ぶのはこちら)" "$HOST_SELF" "$out"

# C20 ★**経路名の中に**名前がある形。中身は綺麗でも file 名で漏れる。
#     「一致文字列は出さない」を file 名の側で破る実装を落とす為の対照で、
#     C17 は素通しする(C17 の fixture の経路には名前が無い)。
d=$(mk c20); printf 'nothing sensitive here\n' > "$d/${HOST_SELF}-backup.md"
git -C "$d" add -A; git -C "$d" commit -qm c
out=$(run "$d"); chk "C20 経路名に hostname -> 名指しするが、経路も伏せて出す" 1 $? \
  "<この機械の名前>" "$HOST_SELF" "$out"

# C21h ★**別の理由で赤い時に、種類3 を見た事を言うか**。
#      この検査は §8-3 の2件で定常的に赤なので、赤の枝が普段の枝。
#      種類3 の開示は元々**緑の枝にしか無かった** —— 普段まず通らない側に置いてあった。
#      その状態だと、赤い報告の中で種類3 は綺麗とも未検査とも言わずただ黙る。
#      C17-C20 は全部「hostname の当たりがある赤」なので、この穴を1本も踏まない。
#      沈黙を「問題なし」と読ませる形はこのコードベースで繰り返し踏んでいるので対照を置く。
d=$(mk c21h); printf 'contact rc-fixture-usr@example.com\nnode 10.0.0.0\n' > "$d/f.md"
git -C "$d" add -A; git -C "$d" commit -qm c
out=$(run "$d"); chk "C21h 別の理由で赤・hostname は綺麗 -> 見た上で綺麗と明言する" 1 $? \
  "一致なし(見た上で綺麗)" "$HOST_SELF" "$out"

fi

echo "--- 合計: PASS $pass / FAIL $fail ---"
[ "$fail" = 0 ]
