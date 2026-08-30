#!/bin/bash
# deploy-observer-to-friday.sh — friday の `~/rc-observer/tools/` を repo に追随させる。
#
# ── なぜ別の台本なのか(2026-08-30)───────────────────────────────────────────
# `deploy-to-friday.sh` は **`~/rc-backend/` しか運ばない**。監視器は別ディレクトリ
# (`~/rc-observer/`)に住み、別の launchd label(`com.fleet.rc-health-observer`)で走るので、
# あの台本の守備範囲の外に落ちていた。その死角のせいで、friday の `health-observer.sh` は
# repo より **139 行・22 日**古いまま動き、`KEY_PEER` が人間向けラベルを機体名として
# 引きに行って失敗し、**毎日** Tom の Discord へ「監視が壊れている」を投げていた
# (実発火 2026-08-28 11:18 / 2026-08-29 11:19。台帳 CF-7 / H-4)。
#
# ★依存物を**一緒に**運ぶのが此の台本の要点。`health-observer.sh` だけを配ると、
#   新版は `funnel-exposure-check.sh` が無い時に **閾値なしで** 通知を撃つ枝を持つ
#   (`health-observer.sh` の `[ ! -x "$EXP_CHECK" ]`)ので、日1回の誤報が **10 分毎**に化ける。
#   その枝は `test/health-observer-controls.sh` の §8 が測っている。
#
# ★配った事の**証拠は此の台本が出さない**。`tools/observer-parity-check.sh` が独立に測る ——
#   配る側の自己申告は、配れた事の証拠にならない(rc-backend 側の配備台本と同じ思想)。
#
# 使い方:
#   bash tools/deploy-observer-to-friday.sh            # 退避 -> 配る -> 独立の一致検査
#   bash tools/deploy-observer-to-friday.sh --dry-run  # 何が変わるかだけ見る(転送しない)
#
# 終了コード: 0=配って一致 / 1=失敗 / 2=測れなかった
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # = rc-backend/(FILES が src/ に跨る為)
HOST="${RC_OBSERVER_HOST:-athenas}"
DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

# 運ぶ物 = observer が実行時に読む物の**連鎖ぜんぶ**。`observer-parity-check.sh` と同じ列挙。
#
# ★2026-08-30、Codex の指摘で訂正した。初版は「`health-step.mjs` は friday に在るが
#   repo に無い」と書いて除外していたが**事実と逆**で、`git ls-files` に
#   `tools/health-step.mjs` も `src/health.mjs` も在る。確かめずに書いた一文を除外の根拠に
#   していた為、判定の本体(`health-step.mjs` → `src/health.mjs`)が古くても
#   「一致」と言う台本になっていた —— 防ごうとしている壊れ方の一段上での再演。
FILES=(tools/health-observer.sh tools/funnel-exposure-check.sh tools/tailnet-key-expiry.sh
       tools/health-step.mjs src/health.mjs)

# ★検査が落ちたら**自分で戻す**(Codex の指摘3)。初版は「戻す先」を印字して終わっていたが、
#   それは**壊れた本番を置いたまま人を待つ**形。無人で回る台本が production を壊したまま
#   帰るのは、配らないより悪い。
rollback() {
    echo "=== ROLLBACK: 退避から戻す(.bak-$STAMP)==="
    ssh -o ConnectTimeout=15 -o BatchMode=yes "$HOST" \
        "cd \$HOME/rc-observer/tools/.bak-$STAMP 2>/dev/null || exit 9
         cp health-observer.sh funnel-exposure-check.sh tailnet-key-expiry.sh health-step.mjs \
            \$HOME/rc-observer/tools/ 2>/dev/null
         cp health.mjs \$HOME/rc-observer/src/ 2>/dev/null
         cd \$HOME/rc-observer/tools && chmod +x ./*.sh 2>/dev/null; echo restored" \
      && echo "戻した" \
      || echo "★戻せなかった。手で: cp ~/rc-observer/tools/.bak-$STAMP/* ~/rc-observer/tools/"
    # 戻した事も**測る**(戻したという宣言を証拠にしない)。
    bash "$HERE/tools/observer-parity-check.sh" >/dev/null 2>&1 \
      && echo "  ※戻した結果 repo と一致した(= 配る前も一致していた事になる。列挙を疑う事)" \
      || echo "  ※戻した結果はまだ repo とずれている(= 配る前の状態に戻った)"
}

for f in "${FILES[@]}"; do
    [ -f "$HERE/$f" ] || { echo "repo に $f が無い = 配れない"; exit 2; }
done

echo "=== 1. 今のずれ ==="
bash "$HERE/tools/observer-parity-check.sh"; before=$?
if [ "$before" -eq 0 ]; then
    echo "既に一致している。配らない(無駄な再起動を起こさない)"
    exit 0
fi
[ "$before" -eq 2 ] && { echo "測れないまま配らない(届かない先へ配ると壊した事にすら気付けない)"; exit 2; }

if [ "$DRY" -eq 1 ]; then
    echo "=== --dry-run: 上のずれを直す為に ${#FILES[@]} 本を送る(実行しない)==="
    exit 0
fi

echo "=== 2. 退避(上書きの前に、戻せる形を作る)==="
STAMP="$(date +%Y%m%d-%H%M%S)"
ssh -o ConnectTimeout=10 -o BatchMode=yes "$HOST" \
    "mkdir -p \$HOME/rc-observer/tools/.bak-$STAMP && cd \$HOME/rc-observer && \
     for f in ${FILES[*]}; do [ -f \"\$f\" ] && cp \"\$f\" \"tools/.bak-$STAMP/\$(basename \"\$f\")\"; done; \
     ls \$HOME/rc-observer/tools/.bak-$STAMP" || { echo "退避に失敗 = 配らない"; exit 1; }

echo "=== 3. 配る ==="
# ★宛先で `$HOME` を使わない(2026-08-30、実測で踏んだ)。`ssh` は remote shell を通すので
#   `$HOME` が展開されるが、転送の宛先は sftp のパスとして扱われ、
#   `remote mkdir "$HOME/..."` と**そのままの文字列**で失敗する。実 path を先に引く。
RHOME="$(ssh -o ConnectTimeout=10 -o BatchMode=yes "$HOST" 'printf %s "$HOME"')" || {
    echo "宛先の HOME を引けない = 配らない"; exit 2; }
[ -n "$RHOME" ] || { echo "宛先の HOME が空 = 配らない"; exit 2; }
# FILES は `tools/…` と `src/…` に跨るので、相対 path を保ったまま1本ずつ置く。
for f in "${FILES[@]}"; do
    ( cd "$HERE" && scp -q "$f" "$HOST:$RHOME/rc-observer/$f" ) \
      || { echo "転送に失敗: $f"; rollback; exit 1; }
done
ssh -o ConnectTimeout=10 -o BatchMode=yes "$HOST" \
    "cd \$HOME/rc-observer/tools && chmod +x ./*.sh" || { echo "実行権を付けられない"; rollback; exit 1; }

echo "=== 4. 一致したか(独立の測り手)==="
bash "$HERE/tools/observer-parity-check.sh"; after=$?
[ "$after" -ne 0 ] && { echo "配ったのに一致しない"; rollback; exit 1; }

echo "=== 5. 配った物が実際に走るか(--dry-run で1回)==="
# ★「file が置けた」は「動く」ではない。通知は出さずに1周させて、
#   `監視が壊れている` を撃たない事まで見る(依存物が欠けていれば此処で判る)。
# ★自己検査は **nonce + 隔離 state + 単一 ssh** で行う(2026-08-30、Codex の指摘2)。
#
#   初版は「本番ログの行数を前後で数えて差分を読む」形だった。3つ壊れていた:
#   (a) `ssh "… | tail -5"` は **`tail` の終了コード**を返すので、観測器が exit 3 で
#       死んでも成功に見えた。
#   (b) 本番ログを読むので、**launchd の定時実行**(600秒毎)が窓に挟まると、
#       配った版が1行も書かなくても緑になる = 偽陽性。
#   (c) `--dry-run` は通知を出さないだけで**本番の state は書く**。実際この日、
#       検査の為の dry-run が `key-checked` を書き換え、日次の鍵チェックの時刻が
#       11:18 から 00:29 へ動いた。検査が本番の予定を動かすのは副作用として重い。
#
#   直し: `RC_HEALTH_STATE` を一時 path へ差すと、派生する mark 全部
#   (broken / last-ok / key-checked / exposure)が一緒に逃げる —— `health-observer.sh` の
#   `BROKEN_MARK` / `OK_MARK` / `KEY_MARK` / `EXP_MARK` が全部 `${...:-$STATE.…}` の形で
#   `STATE` から派生している為(行番号でなく綴りで引く: 行は動くが此の派生の形は動かない)。
#   ログも一時 path。判定は **rc=0 かつ その走行だけが書ける nonce がログに在る事**の両方。
#   ★「走った」の証拠は **隔離した一時ログに中身が在る事**そのもの。
#   初版は nonce を RC_HEALTH_HOST で渡してログに現れる事を期待したが、**実測したら
#   observer は健全時に HOST を1行も書かなかった**(書くのは「ok — 鳴らさない」等だけ)。
#   期待で組んだ印は印にならない。一時ログは**この走行しか書けない**ので、
#   中身が在る事自体が印になり、launchd の定時実行(本番ログへ書く)とも混ざらない。
#
# ★★remote へ渡す文字列の中に**コメントを置かない**(2026-08-30、同じ日に2回踏んだ)。
#   二重引用符の中ではバッククォートが**コマンド置換**として手元の shell で実行される。
#   1回目: 註で RC_HEALTH_HOST をバッククォートで括り → `RC_HEALTH_HOST: command not found`。
#   2回目: **その事故を説明する註を、同じ文字列の中に**書いて再演した(括りが2つ在ったので2行)。
#   ★原因の切り分けでも1回外した: 症状が env 代入の行に出たので「行継続の欠落」と推測して
#     書き換えたが、直らなかった。**症状の出る場所は原因の場所とは限らない。**
#   註は remote 文字列の外(此処)に置く。
NONCE="selftest-$STAMP-$RANDOM"
selftest="$(ssh -o ConnectTimeout=25 -o BatchMode=yes "$HOST" \
    "T=\$(mktemp -d) || exit 90
     env RC_HEALTH_STATE=\"\$T/state.json\" RC_HEALTH_LOG=\"\$T/observer.log\" RC_HEALTH_HOST='$NONCE' bash \$HOME/rc-observer/tools/health-observer.sh --dry-run >\"\$T/out\" 2>&1
     rc=\$?
     echo \"SELFTEST_RC:\$rc\"
     [ -s \"\$T/observer.log\" ] && grep -qE '鳴らさない|鍵の残日数|公開面' \"\$T/observer.log\" && echo 'SELFTEST_NONCE:yes'
     grep -h '監視が壊れている' \"\$T/observer.log\" \"\$T/out\" 2>/dev/null | head -2
     /bin/rm -rf \"\$T\"")"
echo "$selftest"
case "$selftest" in
    *"SELFTEST_RC:0"*) ;;
    *) echo "★配った版が 0 で帰らなかった"; rollback; exit 1 ;;
esac
case "$selftest" in
    *"SELFTEST_NONCE:yes"*) ;;
    *) echo "★配った版がこの走行の印を1つも書かなかった = **走った証拠が無い**(空を正常と読まない)"
          rollback; exit 1 ;;
esac
if printf '%s' "$selftest" | grep -q "監視が壊れている"; then
    echo "★配った版が『監視が壊れている』を出した"
    rollback; exit 1
fi

echo "=== 完了(退避 = ~/rc-observer/tools/.bak-$STAMP)==="
exit 0
