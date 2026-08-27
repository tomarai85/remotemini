#!/bin/bash
# controls-for: rc-backend/tools/rollback-friday.sh
# rollback-friday-control.sh — 戻しが **本当に木を戻す** 事を測る。2026-08-26 新設。
#
# ★rsync の戻しは**緑を偽装しやすい**。「rsync が 0 で帰った」も「file が在る」も、
#   何も戻していない実装で同じ様に出る。だから Codex 2026-08-26 の指定通り、
#   **3 種類の観測可能な差**を作って、3 つとも解消される事を要求する:
#     (a) 中身が違う file  → 中身が戻る
#     (b) 世代にしか無い file → 復活する
#     (c) 本番にしか無い file → **消える**(悪い版が足した物が残らない)
#   (c) が肝。`--delete` を落とした実装は (a)(b) だけなら緑のまま通る。
#
# ★偽 ssh と偽 curl で駆動する。本物の Friday も launchd も触らない。
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RB="$HERE/rollback-friday.sh"
[ -f "$RB" ] || { echo "★$RB が無い"; exit 2; }

fail=0; reds=0
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# --- 偽の「遠隔」= 手元の dir。偽 ssh は command をそのまま手元で実行する -----------
FAKE="$TMP/remote"
mkdir -p "$FAKE/rc-releases" "$FAKE/rc-backend" "$FAKE/.rc-backend"
cat >"$TMP/ssh" <<'STUB'
#!/bin/bash
# 引数を読み飛ばして、最後の1つ(= 遠隔で走る command)を手元で実行する。
while [ $# -gt 1 ]; do shift; done
exec /bin/bash -c "$1"
STUB
chmod +x "$TMP/ssh"
# 偽 curl: 戻した先の版を名乗る healthz を返す。
mk_curl() { printf '#!/bin/bash\nprintf %%s %s\n' "'{\"version\":\"$1\"}'" > "$TMP/curl"; chmod +x "$TMP/curl"; }
# launchctl は何もしない(再起動は此処の測定対象ではない)
printf '#!/bin/bash\nexit 0\n' > "$TMP/launchctl"; chmod +x "$TMP/launchctl"

SNAP="20260101-000000-goodrev"
build_world() {
    rm -rf "$FAKE/rc-releases" "$FAKE/rc-backend"; mkdir -p "$FAKE/rc-releases/$SNAP" "$FAKE/rc-backend"
    # 世代(良い版)
    printf 'goodrev\n'          > "$FAKE/rc-releases/$SNAP/DEPLOYED-REV"
    printf 'GOOD-CONTENT\n'     > "$FAKE/rc-releases/$SNAP/a.txt"      # (a) 中身が違う
    printf 'only-in-snapshot\n' > "$FAKE/rc-releases/$SNAP/onlysnap.txt" # (b) 世代にしか無い
    # 本番(壊れた版)
    printf 'badrev\n'           > "$FAKE/rc-backend/DEPLOYED-REV"
    printf 'BAD-CONTENT\n'      > "$FAKE/rc-backend/a.txt"
    printf 'left-by-bad-deploy\n' > "$FAKE/rc-backend/onlylive.txt"     # (c) 消えるべき
    # 同期木の**外**(触ってはいけない)
    printf 'SENTINEL\n' > "$FAKE/.rc-backend/api.key"
}

run_rb() {
    ( cd "$HERE" && env PATH="$TMP:$PATH" \
        RC_ROLLBACK_SSH="$TMP/ssh" RC_FRIDAY_HOST=fake \
        RC_REMOTE_HOME="$FAKE" \
        RC_ROLLBACK_RELEASES="$FAKE/rc-releases" \
        RC_ROLLBACK_LIVE="$FAKE/rc-backend" \
        RC_ROLLBACK_LOCK="$FAKE/.rc-backend/deploy.lock" \
        RC_ROLLBACK_PINS="$FAKE/rc-releases/.pinned" \
        RC_ROLLBACK_AUDIT="$FAKE/.rc-backend/rollback.log" \
        RC_ROLLBACK_HEALTH="http://fake/healthz" \
        /bin/bash "$RB" "$@" </dev/null 2>&1 )
}

echo "=== 1. 3種類の差が **3つとも** 解消される[本命] ==="
build_world; mk_curl goodrev
out="$(run_rb --to "$SNAP")"; rc=$?
reds=$((reds + 1))
a_ok=0; b_ok=0; c_ok=0; s_ok=0
grep -qx 'GOOD-CONTENT' "$FAKE/rc-backend/a.txt" 2>/dev/null && a_ok=1
[ -f "$FAKE/rc-backend/onlysnap.txt" ] && b_ok=1
[ ! -f "$FAKE/rc-backend/onlylive.txt" ] && c_ok=1
grep -qx 'SENTINEL' "$FAKE/.rc-backend/api.key" 2>/dev/null && s_ok=1
printf '  rc=%s  (a)中身が戻る=%s (b)復活=%s (c)★消える=%s (外の設定が無傷)=%s\n' \
    "$rc" "$a_ok" "$b_ok" "$c_ok" "$s_ok"
if [ "$rc" = 0 ] && [ "$a_ok$b_ok$c_ok$s_ok" = "1111" ]; then
    printf '  全部満たした  OK\n'
else
    printf '  ★満たしていない\n'; fail=1
fi

echo "=== 2. 健康確認が通らなければ **成功と言わない**[赤] ==="
build_world; mk_curl "someone-else"     # 版が違う物が答えている
out="$(run_rb --to "$SNAP")"; rc=$?
reds=$((reds + 1))
if [ "$rc" = 1 ] && printf '%s' "$out" | grep -q "healthz が goodrev を返さない"; then
    printf '  rc=1 で「戻したが健康でない」と言う  OK\n'
else
    printf '  ★rc=%s / 出力=%s\n' "$rc" "$(printf '%s' "$out" | tail -1)"; fail=1
fi

echo "=== 3. 途中で死んだ複製へは戻さない[負] ==="
build_world; mk_curl goodrev
mkdir -p "$FAKE/rc-releases/20260101-000001-half.partial"
printf 'half\n' > "$FAKE/rc-releases/20260101-000001-half.partial/DEPLOYED-REV"
out="$(run_rb --list)"
if printf '%s' "$out" | grep -q "half.partial"; then
    printf '  ★partial を戻せる物として並べた\n'; fail=1
else
    printf '  partial は並べない  OK\n'
fi
out="$(run_rb --to "20260101-000001-half.partial")"; rc=$?
reds=$((reds + 1))
[ "$rc" = 2 ] && printf '  partial への戻しを拒む  OK\n' || { printf '  ★拒まない(rc=%s)\n' "$rc"; fail=1; }

echo "=== 4. 名前で置き場の外を指せない[負] ==="
for bad in "../../etc" "a b" "x;rm -rf /"; do
    out="$(run_rb --to "$bad")"; rc=$?
    [ "$rc" = 2 ] || { printf '  ★通した: %s (rc=%s)\n' "$bad" "$rc"; fail=1; }
done
reds=$((reds + 1))
printf '  不正な名前は全部 exit 2  OK\n'

echo "=== 5. 間引きは固定した世代を消さない[本命の負] ==="
build_world
for i in 1 2 3 4 5; do
    d="$FAKE/rc-releases/2026010$i-000000-r$i"; mkdir -p "$d"; printf 'r%s\n' "$i" > "$d/DEPLOYED-REV"
done
run_rb --pin "$SNAP" >/dev/null
out="$(run_rb --prune 2)"
reds=$((reds + 1))
if [ -d "$FAKE/rc-releases/$SNAP" ]; then
    printf '  固定した世代が残った  OK\n'
else
    printf '  ★固定したのに消された(悪い配備が連続した時に最後の良品を失う形)\n'; fail=1
fi
left="$(ls -1 "$FAKE/rc-releases" | grep -v '^\.' | wc -l | tr -d ' ')"
printf '  残り %s 個(固定1 + keep2 = 3 を期待)\n' "$left"
[ "$left" = 3 ] || { printf '  ★数が合わない\n'; fail=1; }

echo "=== 5b. 固定が**1件だけ**の時に外せる[私が踏んだ形] ==="
# ★`grep -v` は残りが0行だと rc=1 を返す。`&& mv` に繋いだ実装は、固定が1件だけの時に
#   何も外さないまま「外した」と表示していた。`|| true` がそれを握り潰し、症状が出なかった。
build_world
run_rb --pin "$SNAP" >/dev/null
if ! grep -qxF "$SNAP" "$FAKE/rc-releases/.pinned" 2>/dev/null; then
    printf '  ★前提が作れていない(固定できていないので外す検査になっていない)\n'; fail=1
fi
out="$(run_rb --unpin "$SNAP")"; rc=$?
reds=$((reds + 1))
if [ "$rc" = 0 ] && ! grep -qxF "$SNAP" "$FAKE/rc-releases/.pinned" 2>/dev/null; then
    printf '  1件だけでも外れた  OK\n'
else
    printf '  ★外れていないのに rc=%s(固定一覧: [%s])\n' "$rc" "$(cat "$FAKE/rc-releases/.pinned" 2>/dev/null)"; fail=1
fi

echo "=== 6. --dry-run は何も変えない[負] ==="
build_world; mk_curl goodrev
run_rb --to "$SNAP" --dry-run >/dev/null
reds=$((reds + 1))
if grep -qx 'BAD-CONTENT' "$FAKE/rc-backend/a.txt" 2>/dev/null; then
    printf '  本番は無傷  OK\n'
else
    printf '  ★dry-run が本番を書き換えた\n'; fail=1
fi

echo
echo "  赤に倒れる入力: ${reds} 件"
[ "$reds" -lt 2 ] && { echo "  ★対照が空虚"; fail=1; }
echo
[ "$fail" = 0 ] && { echo "全ケース OK / FAIL 0"; exit 0; } || { echo "★赤あり"; exit 1; }
