#!/bin/bash
# 「変異の走行が今まさに動いているか」を判定する**唯一の場所**。
#   走行中 = exit 0 / **居ないと確認できた** = exit 1 / **測れなかった** = exit 2。
#
# ★2026-08-04、Codex の指摘で 2 を足した。それまでは `pgrep … && exit 0; exit 1` で、
#   1 が「居ない」と「pgrep が失敗した」の**両方**を意味していた。`pgrep` の終了コードは
#   0=一致 / 1=不一致 / **2=構文エラー** / **3=致命的エラー**で、後ろ2つは「判らなかった」。
#   それを「居ない」に丸めると、判定不能の時に配備の門が**開く**(fail-open)。
#   守りの向きは「判らないなら止める」でなければならないので、呼ぶ側は
#   **exit が丁度 1 の時だけ**先へ進む事。0 と 2+ は等しく「進むな」である。
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

# ★`--who` = 「誰に当たったか」を、**引数を出さずに**言う(2026-08-04)。
#   この判定は `pgrep -f` = argv 全体への一致なので、`CMD="python3 -u …/mutation-controls.py"`
#   の様に**文字列としてその名を持っているだけ**のシェルにも当たる(Codex 指摘)。当たった
#   側は走行ではないので、配備は「走行中」と言って**恒久的に塞がる** —— 2026-08-02 に
#   実際に起きた詰まりと同じ形である。塞がった人が最初に要るのは「本当に python か」で、
#   それは実行体の名前だけで判る。
#   ★argv は絶対に出さない: 無関係なコマンド行が当たっている場合、そこに何が書かれて
#     いるかは判らない(過去に `pgrep -lf` が OAuth の秘密を transcript へ吐いた)。
#     `comm` は実行体の名前だけなので、当たった物が何であっても安全に見せられる。
if [ "${1:-}" = "--who" ]; then
    for p in $(pgrep -f "$PAT" 2>/dev/null); do
        ps -o pid=,comm= -p "$p" 2>/dev/null
    done
    exit 0
fi

pgrep -f "$PAT" >/dev/null 2>&1
rc=$?
case "$rc" in
    0) exit 0 ;;   # 走行中
    1) exit 1 ;;   # 一致なし = 居ないと確認できた
    *) # pgrep 自体が失敗した(構文 2 / 致命 3 / 見た事のない値)。
       # 此処で 1 を返すと「居ない」と読まれて門が開く。判らないなら止める。
       echo "mutation-run-live: pgrep が exit=$rc で失敗した = 走行の有無を測れていない" >&2
       exit 2 ;;
esac
