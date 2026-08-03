#!/bin/bash
# `test/rsync-exclude-controls.sh` を **edith 側の rsync** で走らせる版。
#
# なぜ別 file か: 入れ替えと戻しの rsync は remote heredoc の中 = **edith の binary** が走る。
# 手元(Jervis)で測っても言えるのは手元の話だけ。同じ文を向こうで走らせて初めて
# 「edith の `/Users/edith/rc-backend/.git` は配備で消えない」が観測値になる。
#
# 砂場は edith 側の `mktemp -d` で作り、小片の最後で自分で消して `LEFT=0` を出す
# (= 残置していない事を**向こうが**報告する)。edith に恒久的な物は置かない。
#
# 中身は1本の台本を共有する(写しを2つ持たない = 片方だけ直す事故が起きない)。
# 届かない時は親が 2(未測定)/ssh の失敗で落ちる。**緑にはならない。**
exec env RC_RSYNC_EXCL_WHERE=edith \
     /bin/bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/rsync-exclude-controls.sh" "$@"
