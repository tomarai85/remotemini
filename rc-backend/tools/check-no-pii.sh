#!/bin/bash
# remote を付けた瞬間に開示になる物を push の直前で止める。
#
# 見ている物は2種類。**別の物なので別に報告する**(混ぜると片方の判断が他方に紛れる):
#   1. 個人のメールアドレス  … 人の識別子
#   2. 機械の入口の名前       … tailnet の IP(CGNAT 100.64/10)と MagicDNS(*.ts.net)
#
# ★2026-08-01 に範囲を2回広げた。どちらも同じ形の穴だった = **検査の範囲が、検査の目的より狭い**。
#   1回目: `test/fixtures` しか見ていなかったが、同じアドレスが `DESIGN.md` の本文にもあった。
#   2回目: `<user>@<host>.tail<id>.ts.net` を「メールではない」としてメール検査から**除外**したが、
#          除外した先を**誰も見ていなかった**。除外は穴を開ける行為なので、外した物の
#          行き先を必ず作る。これが 2 の由来。
#          (この註釈に本物の MagicDNS 名を書かないのは、検査の道具自身が検査対象を
#           増やさない為。道具が自分で赤を作ると、赤の意味が薄まる)
#
# 生 capture の中の物と、本文に意図して書いた物は扱いが違う:
#   - 生 capture     -> 行ごと削らず**同じ桁数の伏字**へ(桁がずれると罫線・箱の判定が変わる)
#   - 本文の中の記述 -> 消すと意味が壊れる事がある。その時は「この repo を公開しない」を選ぶ
# 台本はどちらか判定できないので、**止めて人に決めさせる**。それが正しい fail-closed。
#
# 使い方: そのまま実行(exit 1 = 上のどちらかが残ったまま remote に出そうとしている)。
#   git 側への取り付け: .git/hooks/pre-push から呼ぶ(取り付け済み。hooks は追跡されないので
#   clone し直した時はこの行を自分で入れ直す事)。
set -u
# ★git repo の外では**緑を出さずに落ちる**(exit 2)。
#   `cd "$(git rev-parse ...)"` は git が落ちると `cd ""` になり、bash では成功して
#   その場に留まる。すると `git ls-files` も空を返し、**本物のアドレスが目の前にあるのに
#   「なし」で exit 0** を出す。この「常に通る検査」の型は 8/01 に繰り返し踏んでいる
#   (経緯と件数 = WORKLOG.md 2026-08-01)。ここもその1つで、自分で作った物。
#   `verify-on-edith.sh` は `.git` を除いて rsync するので、edith では確実にこの形になる。
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)
if [ -z "${root:-}" ]; then
  echo "PII 検査: **判定不能** — git repo の中で走っていない($(dirname "$0"))。" >&2
  echo "  この検査は追跡ファイルと履歴を見るので、repo の外では何も見ずに緑を出してしまう。" >&2
  echo "  緑と誤解される位なら落ちる方が正しいので exit 2。押す側の木で走らせる事。" >&2
  exit 2
fi
cd "$root" || exit 2

# --- 種類1: 個人のメールアドレス ---
PAT_MAIL='[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
# 伏字として使う宛先だけを除外する。RFC 2606 / RFC 6761 が**文書用に予約**している名前 =
# 誰の物にもなり得ないので、これが残っていても開示にならない。
# ここを「それらしい偽アドレス」まで広げると検査が意味を失うので、予約名だけに限る。
# ★`.ts.net` をここから外すのは「メールではない」からで、「出して安全」だからではない。
#   外した先は下の PAT_MACH が受ける。**除外しっ放しにしない**のがこの2段構えの理由。
SAFE_MAIL='@(example\.(com|net|org)|[A-Za-z0-9.-]+\.(example|invalid|test|localhost)|[A-Za-z0-9.-]+\.ts\.net)$'

# --- 種類2: 機械の入口の名前 ---
# tailnet の IP は CGNAT 100.64/10 に限る。`100.` で始まる数字を何でも拾うと
# バージョン番号などで誤検出が出て、検査ごと無視される様になる。第2オクテットを 64-127 に絞る。
# MagicDNS は `<host>.tail<id>.ts.net`。`\b` は BSD の grep -E では効かない(実測)ので使わない。
PAT_MACH='(100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}|[A-Za-z0-9-]+\.tail[0-9a-z]+\.ts\.net)'
# ★ローカルの絶対パス(`/Users/tomtim` 等)は**意図して対象外**。この repo の文書には18箇所あり、
#   消すと文書が読めなくなる = 直せない赤。**常に赤の検査は必ず無視される様になる**ので、
#   直せない物を混ぜない。パスは機械への入口ではなく、機械の中の地図。開示の重みが違う。
#   この判断自体が「緑が何を保証していないか」の一部なので、緑の時の文言にも書いてある。

PAT_ANY="($PAT_MAIL|$PAT_MACH)"

# ファイル単位でなく**一致した文字列単位**で除外する。ファイル単位で外すと、
# 同じファイルに本物と伏字が混ざった時に本物ごと見逃す。
#
# 対象は **git が追跡しているファイルだけ**。node_modules や作業中の一時ファイルは
# push されないので見る必要が無く、見ると必ず誤検出が出て検査が無視される様になる。
#
# ★一覧の取得が**失敗した時に緑を出さない**。`git ls-files` が落ちると一覧が空になり、
#   「見るファイルが1つも無い」= 「PII なし」として exit 0 が出る。見ていないだけなのに。
#   同じ形を何度も踏んでいるので、取得の成否を必ず見る。
#
# ★★`files=$(git ls-files -z)` と**変数に入れてはいけない**。bash のコマンド置換は
#   NUL を黙って捨てる(実測: bash で長さ 1883 / zsh で 1930、差 47 = ちょうどファイル数)。
#   区切りが消えるので `read -d ''` は 0 件になり、**作業ツリー段が丸ごと空回りする**。
#   2026-08-01 に実際にこの状態で走っていた。対照14枚は全部緑のままだった —
#   対照が置いたアドレスは commit もされるので、**履歴段が代わりに拾っていた**からで、
#   「段が死んでいる」事を見分けられる対照が1枚も無かった(→ C14 を足した)。
#   プロセス置換のまま食わせれば NUL は保たれる。件数も後で突き合わせる。
# ★`git ls-files | grep -c .` と繋ぐと `$?` は **grep の物**になる。grep -c は 0 件でも
#   exit 1 を返すので、「追跡0件(orphan 直後などで正当)」を「一覧の取得に失敗」と
#   取り違える(C9 が実際にこれで落ちた)。git 自身の終了コードを見る。
tracked_list=$(git ls-files); rc=$?
if [ "$rc" -ne 0 ]; then
  echo "PII 検査: **判定不能** — git ls-files が失敗した(exit=$rc)。" >&2
  exit 2
fi
tracked_n=$(printf '%s\n' "$tracked_list" | grep -c .)

# scan_tree <抽出する正規表現> <除外する正規表現|-> -> "<file>\t<一致1> <一致2> ..." を行で出し、
# 最後に `#SCANNED\t<実際に読んだ件数>` を出す。件数は飾りではなく**この段が空回りしていない事の
# 計器**で、呼び出し側が追跡ファイル数と突き合わせて、合わなければ判定不能で落とす。
scan_tree() {
  local pat=$1 safe=$2 f bad n=0
  while IFS= read -r -d '' f; do
    n=$((n+1))
    [ -f "$f" ] || continue                          # 削除済み・symlink 切れは飛ばす
    grep -qIE "$pat" "$f" 2>/dev/null || continue    # -I = バイナリは飛ばす
    if [ "$safe" = "-" ]; then
      bad=$(grep -ohE "$pat" "$f" | sort -u)
    else
      bad=$(grep -ohE "$pat" "$f" | sort -u | grep -vE "$safe")
    fi
    [ -n "$bad" ] && printf '%s\t%s\n' "$f" "$(echo "$bad" | tr '\n' ' ')"
  done < <(git ls-files -z)
  printf '#SCANNED\t%s\n' "$n"
}
# 件数の突き合わせ。0 件で緑を出すのが今夜10件目の事故だったので、**数を見ずに信用しない**。
# ★切り分けを関数にしない。`f() { X=...; }` を `$(f)` で呼ぶとサブシェルになり、
#   代入は親に戻らない(`set -u` で unbound variable になって初めて気付いた。これも今夜の型)。
raw_mail=$(scan_tree "$PAT_MAIL" "$SAFE_MAIL")
raw_mach=$(scan_tree "$PAT_MACH" -)
n_mail=$(printf '%s\n' "$raw_mail" | sed -n 's/^#SCANNED	//p')
n_mach=$(printf '%s\n' "$raw_mach" | sed -n 's/^#SCANNED	//p')
hits_mail=$(printf '%s\n' "$raw_mail" | sed '/^#SCANNED/d' | sed '/^$/d')
hits_mach=$(printf '%s\n' "$raw_mach" | sed '/^#SCANNED/d' | sed '/^$/d')
if [ "$n_mail" != "$tracked_n" ] || [ "$n_mach" != "$tracked_n" ]; then
  echo "PII 検査: **判定不能** — 作業ツリー段が全ファイルを読めていない。" >&2
  # ★`${}` を省かない。`$n_mach。` の様に変数の直後へ日本語を書くと、bash は
  #   後続のバイトまで変数名として読み、`unbound variable` で落ちる(`set -u`)。
  #   そうなると **判定不能(2) が exit 1 = 赤 に化ける**。この行はエラー経路にしか
  #   無いので、2026-08-01 に逆対照で作業ツリー段を殺すまで一度も実行されていなかった。
  echo "  追跡 ${tracked_n} 件に対し、実際に読んだのは 種類1=${n_mail} / 種類2=${n_mach}。" >&2
  echo "  0 件なら NUL 区切りが壊れている(コマンド置換に通すと bash が NUL を捨てる)。" >&2
  exit 2
fi

# --- 第2段: 履歴 ---------------------------------------------------------
# push が運ぶのは作業ツリーではなく**履歴**。作業ツリーだけ見る検査は、「一度 commit して
# 後で消したアドレス」を必ず見逃す。git の履歴は追記のみで、後から消すには履歴の書き換え
# (= 承認ゲート)が要る。つまり**作業ツリーの緑は、押した時に何も出ない事を意味しない**。
# 8/1 に fixture の伏字化を「最初の commit の前」に済ませたのはこの理由。
hraw=""
# ★条件は「HEAD があるか」ではなく「**到達できる commit があるか**」。HEAD で判定すると、
#   `git checkout --orphan` 直後の様に HEAD が未生成でも他の ref には commit がある木で
#   履歴段を丸ごと飛ばす。push が運ぶのは ref であって HEAD ではない。
revs=$(git rev-list --all) || { echo "PII 検査: **判定不能** — git rev-list が失敗した。" >&2; exit 2; }
if [ -n "$revs" ]; then
  # 小さい repo 用の素朴な走査(全 commit x 全 tree)。数千 commit 規模になったら
  # `git rev-list --objects --all` + `cat-file --batch` へ書き換える事。
  # `git grep` は 0=一致あり / 1=一致なし / 2以上=エラー。**エラーを「一致なし」と
  # 同じ扱いにすると、履歴を一切見ないまま緑が出る**(commit 数が増えて引数が
  # ARG_MAX を超えた時などに実際に起きる)。エラーは判定不能として落とす。
  # 2種類まとめて1回で走査する(履歴の走査が一番重い)。仕分けは下でやる。
  hraw=$(git grep -IE "$PAT_ANY" $revs -- 2>/dev/null); grc=$?
  if [ "$grc" -gt 1 ]; then
    echo "PII 検査: **判定不能** — 履歴の走査に失敗した(git grep exit=$grc)。" >&2
    echo "  commit 数が増えて引数が長すぎる可能性。走査を rev-list --objects 方式へ書き換える事。" >&2
    exit 2
  fi
fi

# hist_of <抽出する正規表現> <除外する正規表現|-> -> "<一致の一覧>\t<箇所数>\t<例>" を1行で
hist_of() {
  local pat=$1 safe=$2 bad lines
  [ -n "$hraw" ] || return 0
  if [ "$safe" = "-" ]; then
    bad=$(printf '%s\n' "$hraw" | grep -ohE "$pat" | sort -u)
  else
    bad=$(printf '%s\n' "$hraw" | grep -ohE "$pat" | sort -u | grep -vE "$safe")
  fi
  [ -n "$bad" ] || return 0
  # 一致を**そのままの文字列**として照合する(-F)。正規表現として渡すと `.` が
  # 任意文字になり、件数と例が微妙にずれる。数える物を数える。
  lines=$(printf '%s\n' "$hraw" | grep -F -f <(printf '%s\n' "$bad"))
  printf '%s\t%s\t%s\n' \
    "$(echo "$bad" | tr '\n' ' ')" \
    "$(printf '%s\n' "$lines" | grep -c . )" \
    "$(printf '%s\n' "$lines" | head -1 | cut -d: -f1,2)"
}
hist_mail=$(hist_of "$PAT_MAIL" "$SAFE_MAIL")
hist_mach=$(hist_of "$PAT_MACH" -)

if [ -z "$hits_mail$hits_mach$hist_mail$hist_mach" ]; then
  echo "PII 検査: 作業ツリー・履歴とも 個人のメールアドレス / tailnet の名前 なし"
  echo "  (この緑が保証しないもの: ローカルの絶対パス・機械の中の構成・文書の中身。公開の可否は別途)"
  exit 0
fi

echo "PII 検査: **remote に出すと開示になる物が残っている**" >&2

# report <見出し> <作業ツリーの hits> <履歴の1行>
report() {
  [ -n "$2$3" ] || return 0
  echo "" >&2; echo "== $1 ==" >&2
  if [ -n "$2" ]; then
    echo "-- 作業ツリー(まだ安く直せる) --" >&2
    printf '%s\n' "$2" | while IFS=$'\t' read -r f addrs; do echo "  $f: $addrs" >&2; done
  fi
  if [ -n "$3" ]; then
    IFS=$'\t' read -r a n ex <<<"$3"
    echo "-- 履歴(push が運ぶのはこちら。消すには履歴の書き換え = 承認ゲート) --" >&2
    echo "  $a (${n} 箇所, 例 ${ex})" >&2
  fi
}
report "種類1: 個人のメールアドレス" "$hits_mail" "$hist_mail"
report "種類2: 機械の入口の名前(tailnet IP / MagicDNS)" "$hits_mach" "$hist_mach"

if [ -z "$(git remote)" ]; then
  echo "" >&2
  echo "-- 現状 remote 無し = この検査はまだ一度も push を止めていない。上は「remote を" >&2
  echo "   付ける時に決める事の一覧」であって、今起きている漏洩ではない。--" >&2
fi
cat >&2 <<'MSG'

remote へ出す前に、1件ずつどちらかを選ぶ事:
  - 実機の生 capture(fixture)  -> 行ごと削らず**同じ桁数の伏字**へ置換する
  - 設計文書の本文にある記述     -> 消すと意味が壊れるなら、この repo を公開しない側を選ぶ
MSG
exit 1
