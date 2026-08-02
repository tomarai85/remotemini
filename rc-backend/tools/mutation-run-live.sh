#!/bin/bash
# 「変異の走行が今まさに動いているか」を判定する**唯一の場所**。
#   走行中 = exit 0 / 動いていない = exit 1。
#
# なぜ独立した file にするか(2026-08-02):
#   同じ判定が `tools/deploy-to-edith.sh` `tools/check-mutation-targets.sh`
#   `test/mutation-target-controls.sh` の3箇所に**複製**されていて、その3つが
#   揃って同じ欠陥を持っていた。複製された判定は、片方だけ直して片方が腐る。
#
# ★直した欠陥: 素の `pgrep -f 'mutation-controls\.py'` は
#   **その文字列を含むあらゆるコマンド行**に当たる。実測(同日)で当たった物:
#     - `vim test/mutation-controls.py` のような編集セッション
#     - `until ! pgrep -f mutation-controls.py; do sleep 10; done` という**待ち受け自身**
#   最後のは自己参照で、待ち受けが**永久に終わらない**(自分が自分を見つける)。
#   そして `deploy-to-edith.sh` はこの判定で配備を**拒否**するので、
#   無関係なシェルが1つ残っているだけで**配備が恒久的に塞がる**。
#   安全側に倒れる(fail-closed)判定でも、恒久的に詰まるなら壊れている。
#
# 正しい形 = 「python が実引数として mutation-controls.py を渡されている」に限定する。
#   実測した本物の argv は Homebrew の framework 経由なので `python3` では当たらない:
#     /opt/homebrew/.../Python.framework/.../MacOS/Python test/mutation-controls.py
#   よって `[Pp]ython[0-9.]*` + 空白 + パス、で見る。
#   走行を起こした親シェル(`... && python3 test/mutation-controls.py > log` の zsh)にも
#   当たるが、それは**本当に走行中にだけ生きている**ので当たって正しい。
#
# ★★2026-08-02 夜に見つけた**逆向きの穴**(偽陰性)。上の欠陥は「余計な物に当たる」だったが、
#   こちらは「本物に当たらない」= **配備の門が黙って開く**方向なので害が重い。
#     実測: /opt/homebrew/.../MacOS/Python -u test/mutation-controls.py --only X
#   `[^ ]*` は空白を跨げないので、`python` と台本パスの間に `-u` が挟まった瞬間に外れる。
#   私はこの pattern で「走っていない」と読み、**走行中にもう1本起動した**(2本が同じ
#   ログへ tee して混ざった)。`deploy-to-edith.sh` も同じ判定なので、`-u` 付きの走行中は
#   拒否せず配備していた。
#   なぜ対照が捕まえなかったか = 対照3の囮が `python3 <台本>` の**旗なしの形だけ**だった。
#   → 旗を跨げる形にし、対照に `-u` 付きの囮(3b)を足した。**穴と同じ形の対照を置く**。
PAT='[Pp]ython[0-9.]*( +-[^ ]+)* +[^ ]*mutation-controls\.py'

if pgrep -f "$PAT" >/dev/null 2>&1; then
    exit 0    # 走行中
fi
exit 1        # 動いていない
