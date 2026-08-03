#!/bin/bash
# warn-ledger.sh — 「門ではない検査」の結果を**捨てずに最後まで持ち帰る**帳面。source して使う。
#
# なぜ要るか(2026-08-03、§7-P-g の直後に同じ形を配備台本の中で見つけた):
#   `deploy-to-edith.sh` は警告の段を3つ持っていて、どれも `|| true` で終わっていた。
#   `|| true` 自体は正しい —— edith の自動ログインが切れている事は、コードを配る妨げに
#   ならない。**門にしない**判断は変えない。だが「門にしない」と「信号を捨てる」は別で、
#   台本はその2つを一緒にやっていた:
#     - 終了コードは `|| true` が飲み込む(下流に何も残らない)
#     - 文面は 579 行の配備 log の**真ん中**を流れて行く
#     - 最後の行は `say "完了"` だけ。赤かった段が在っても「完了」としか出ない
#   9b の注釈自身が「2026-08-20 以降 edith に物理で触れないので、**変わった事に気付ける
#   場所が要る**」と書いている。log の真ん中は、気付ける場所ではない。
#
#   これは §7-P-g(判定は正しく作れていたのに、持ち帰る所で捨てていた)と同じ一族。
#   あちらは `if ! cmd; then rc=$?` の1行、こちらは `|| true` + 要約が無い事。
#
# 使い方:
#   . "$(dirname "$0")/warn-ledger.sh"
#   wl_init
#   wl_run "鍵の期限" ssh "$EDITH" "/bin/bash '$LIVE/tools/tailnet-key-expiry.sh'"
#   …
#   wl_report        # 最後に1回。**呼ばないと帳面は何もしない**
#
# `wl_run` は**常に 0 を返す**(門ではないので、呼び側の `set -e` を殺さない)。
# `wl_report` は 0=全部緑 / 1=赤が在る / 2=測れなかった段が在る を返す。
# 呼び側はそれを見て止めても良いし、無視しても良い —— **選べる形にしておく**のが要点で、
# `|| true` は選択肢ごと消していた。
#
# ★終了コードの読み方(ここが帳面の本体):
#   0        緑
#   2        未測定(検査が「測れなかった」と自分で言った)
#   255      届かなかった(ssh が繋がらない)。**これも未測定**だが理由が違うので別の文言。
#            ssh は繋がらない時に 255 を返すので、赤と混ぜると
#            「edith が答えない」を「edith の停電対策が壊れている」と読む事になる
#   その他   赤
#
#   ★125-127 は使わない。`timeout` が使う番号と衝突するが、この帳面は `timeout` を
#   噛ませていない。噛ませる時は**その時に**分類を足す事(黙って赤に落とさない)。

# 名前と rc を1行ずつ持つ。連想配列を使わないのは bash 3.2(macOS 既定)で動かす為。
_WL_ROWS=""
_WL_STARTED=0

wl_init() { _WL_ROWS=""; _WL_STARTED=1; }

# wl_run <表示名> <命令...>
wl_run() {
    local name="$1"; shift
    if [ "$_WL_STARTED" -ne 1 ]; then
        echo "warn-ledger: wl_init を呼ばずに wl_run が呼ばれた(帳面が始まっていない)" >&2
        return 0
    fi
    # ★終了コードは**生んだ場所の直後**で取る。2026-08-03 に `tools/mutation-verdict.sh` で
    #   踏んだのがここで、`if ! cmd; then rc=$?` にすると `$?` は常に 0 になる(§7-P-g)。
    #   ★かつ `"$@"` を裸で置かない —— 呼び側が `set -e`(配備台本はそう)だと、
    #     段が非零を返した瞬間に**台本ごと死ぬ**。「門ではない」と言いながら最強の門になる。
    #     `cmd || rc=$?` は左辺が条件の位置に居るので `set -e` が発火せず、
    #     かつ `$?` は cmd の物(`if !` と違って `!` を通っていない)。実測で確認済。
    local rc=0
    "$@" || rc=$?
    _WL_ROWS="${_WL_ROWS}${name}	${rc}
"
    return 0
}

# 呼び側が自分で rc を持っている時(既に走らせた後)に足す口。
wl_add() {
    local name="$1" rc="$2"
    if [ "$_WL_STARTED" -ne 1 ]; then
        echo "warn-ledger: wl_init を呼ばずに wl_add が呼ばれた(帳面が始まっていない)" >&2
        return 0
    fi
    _WL_ROWS="${_WL_ROWS}${name}	${rc}
"
    return 0
}

wl_report() {
    if [ "$_WL_STARTED" -ne 1 ]; then
        # ★ここを 0 にしない。「警告が 0 件だった」と「帳面が一度も始まっていない」は別。
        #   前者は緑、後者は**この帳面が呼ばれていない**という測定の失敗。
        echo ""
        echo "=== 警告の帳尻 ==="
        echo "★帳面が始まっていない(wl_init が呼ばれていない)= 警告の段を1つも測っていない"
        return 2
    fi
    if [ -z "$_WL_ROWS" ]; then
        echo ""
        echo "=== 警告の帳尻 ==="
        echo "★1 段も記録されていない = 警告の段が全部飛ばされたか、記録の呼び方が壊れている"
        return 2
    fi

    local green=0 red=0 unm=0 red_names="" unm_names="" name rc mark
    echo ""
    echo "=== 警告の帳尻(門ではない。ここでは止めない)==="
    while IFS=$'\t' read -r name rc; do
        [ -n "$name" ] || continue
        case "$rc" in
            0)   mark="緑     "; green=$((green+1)) ;;
            2)   mark="未測定 "; unm=$((unm+1));  unm_names="${unm_names} ${name}" ;;
            255) mark="届かず "; unm=$((unm+1));  unm_names="${unm_names} ${name}(ssh)" ;;
            *)   mark="★赤   "; red=$((red+1));  red_names="${red_names} ${name}" ;;
        esac
        printf '  %s %-34s rc=%s\n' "$mark" "$name" "$rc"
    done <<EOF
$_WL_ROWS
EOF

    if [ "$red" -gt 0 ]; then
        # ★日本語を `$var` の直後に置かない(変数名が伸びる)。この repo で2度踏んでいる。
        echo "★赤が ${red} 件:${red_names}"
        echo "  配備は通した(門ではない)。**放置すると次の配備まで誰も見ない** —— 今直す事。"
    fi
    if [ "$unm" -gt 0 ]; then
        echo "★測れなかったのが ${unm} 件:${unm_names}"
        # ★ここに「緑ではない」と書かない。表の緑印と同じ字なので、
        #   「緑と言っていない事」を測る対照が**この行に当たって**偽の赤になる。
        #   同じ罠を 2026-08-03 に G8 / S5 で2回踏んでいる ——
        #   **否定形を含む語を、分類語そのもので書かない**。
        echo "  無事という意味ではない。「壊れているか判らない」という意味。"
    fi
    if [ "$red" -gt 0 ]; then return 1; fi
    if [ "$unm" -gt 0 ]; then return 2; fi
    # ★緑の判定だけに出る綴りにする(見出し「警告の帳尻」と**前置きを共有しない**)。
    #   共有していると、対照が「緑と言っていない事」を測れない —— 見出しに当たってしまう。
    echo "警告の段はどれも異常なし(${green}/${green})"
    return 0
}
