# live-* の3本が共有する「自分が建てた会話の名前」の決め方(2026-08-28)。
#
# ★名前が `live-` で始まらない理由: `rc-backend/test/live-exit-codes.test.mjs` が
#   「`live-*` で対照でない物 = **計器**。計器は上限で 3 を返す事」を機械で見張っている。
#   此れは共有ライブラリで計器ではないので、`live-` を名乗ると其の不変条件が嘘になる。
#   門を緩めるのではなく、名乗りの方を正した。初版は live- で始まる名前を付けて出し、
#   実際に「7本目の計器が黙って増えた」として commit を止められている。
#
# ★なぜ1箇所に集めるか: 同じ判定を3本が各々持つと、1本だけ直した日に残り2本が
#   黙って古びる —— 此の repo が `SESSION_ROUTE_RE`(reqlog.mjs)で明文化している型。
#   **source して使う**(実行しない)。
#
# ★何を守るか: Codex 2026-08-27 が名指しした **crash-orphan と ABA/TOCTOU**。
#   `up` の後にプロセスが SIGKILL / 停電 / SSH 切断で死ぬと `trap` は走らず、
#   tmux セッションと登録簿が残る。その後の走行が**名前の接頭辞で自分の物を当てに行く**と、
#   孤児を掴んで cleanup で殺す。
#   2026-08-28 実測: 孤児は実在した(`rc-e2e-20260828…`、16:06 に建って残っていた)。
#   `live-poll-check.sh` が実際に `list-sessions | grep '^rc-e2e-' | tail -1` で
#   引いていた —— 姉家族2本(send / interrupt)は最初から `up` の1行目を読んでいて、
#   1本だけがずれていた。
#
# ★`up` の stdout の契約(`rc-backend/tools/disposable-session.mjs`):
#   **1行目 = セッション名 / 2行目 = 会話 id。それだけ**(あちらに
#   「余計な字を混ぜない」と書いてある)。診断は全部 stderr。
#
# ★名前に入っている 19 桁の乱数が守るのは**再利用(ABA)**であって**権限**ではない。
#   friday に居る誰でも `tmux ls` で名前は読める。此処の脅威は「自分が Tom の本物の
#   会話を殺す」事故であって、机の上の攻撃者ではない。権限の話をしたくなったら、
#   `disposable-session.mjs` 側に capability を足すのが正しい場所。
#   今在る fail-closed は2段: 此処(名前が使い捨ての形でなければ空を返す)と
#   あちら(`down` が使い捨ての名前でなければ畳まない)。

# session_from_up <up の stdout 全文>
#   1行目だけを見る。使い捨ての名前でなければ**空**を返す(呼ぶ側が止まる)。
#   探しに行かない事が此の関数の全部 —— 見つからない時に代わりを探す枝を作らない。
session_from_up() {
  local first
  first="$(printf '%s\n' "${1:-}" | sed -n 1p | tr -d '[:space:]')"
  case "$first" in
    rc-e2e-*) printf '%s' "$first" ;;
    *) printf '' ;;
  esac
}
