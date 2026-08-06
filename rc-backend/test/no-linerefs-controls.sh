#!/bin/bash
# controls-for: test/no-linerefs.test.mjs
# `test/no-linerefs.test.mjs` の**届く範囲**を測る対照。
#
# ── なぜ要るか ──────────────────────────────────────────────────────────
# 2026-08-05: 電話側(`ios/`)の注釈が backend の code を行番号で引いていて、
# **16件が別の行を指していた**。この検査は 8/03 から在ったのに1件も報告していない。
# 走査していたのが rc-backend だけで、ios は隣の木だったから。
#
# ★守りが「無い」のではなく「**届いていない**」欠陥は、緑の顔で素通りする。
#   検査自身を走らせても判らない —— 走らせれば緑なのだから。判るのは
#   **欠陥を1件植えて、赤くなるか**を見た時だけである。それがこの対照。
#
# ── 測る4つ ────────────────────────────────────────────────────────────
#   ① 電話側の木に行番号を1件植えると**赤**            (= 走査が ios に届いている)
#   ② 植えなければ緑                                    (= ①が巻き添えでない)
#   ③ ios の居ない**部分木**で走らせても緑              (= 変異走行を巻き添えにしない)
#   ④ ios は在るのに中身が空だと**赤**                  (= 木ごとの下限が効いている)
#
# ★③が要る理由(実測、この対照の初回で捕まえた): 完全な木では解決する引用を
#   注釈に書くと、**作業コピーの中でだけ赤**になる。commit の門は通り、変異走行の
#   中で落ちる。`test/mutation-controls.py` の凍結の節に在るとおり、走行中にこの
#   検査が落ちると**以降の変異が全部「検出」と記録される** —— 素通りが丸ごと隠れ、
#   要約は「素通り 0件」と書く。壊れ方が緑の方向に出るので、後から気付けない。
#
# ★④が要る理由: 木が2つになった時、下限を**合計**で持つと片方の walk が丸ごと
#   空振りしても、もう片方の件数で下限を越える。0件が緑の下に隠れる形は、
#   この repo が 2026-08-05 に4回踏んだ欠陥そのもの(DESIGN §2.18-10)。
#
# ★live の木には**足すだけ**で、既存の file には一度も触らない。`sed -i` で壊して
#   戻す造りを採らない理由は `tools/prove-control.sh` の頭に在るとおり —— 復元の
#   失敗が repo を壊れたまま残す。足した物は消えたか**不在を確認**して終わる。
#
# 終了コード: 0 = 全部期待どおり / 1 = どれかが違う / 2 = 測れなかった
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$(cd "$ROOT/.." && pwd)"
TEST="${RC_LINEREF_TEST:-$ROOT/test/no-linerefs.test.mjs}"
IOS="${RC_LINEREF_IOS_DIR:-$REPO/ios}"
NODE="${RC_NODE_BIN:-node}"

pass=0; fail=0
ok() { pass=$((pass+1)); echo "PASS  $1"; }
ng() { fail=$((fail+1)); echo "FAIL  $1  ($2)"; }

[ -f "$TEST" ] || { echo "測れない: 検査本体が居ない ($TEST)"; exit 2; }
if [ ! -d "$IOS" ]; then
    # 部分木で回されている。①②④は電話側の木が要るので**測れない**。
    # 0 に丸めない —— 「測っていない」を緑と言い張るのが、この repo で一番高く付く嘘。
    echo "測れない: 電話側の木が居ない ($IOS) = 部分木で回されている"
    exit 2
fi

# 植えた物を必ず落とす。名前は衝突しない形にして、消し残しは最後に**不在で**確かめる。
PLANT="$IOS/Sources/__no_linerefs_control_probe.swift"
# ⑤ 用。**dir を1つ足す**だけで、中身は要らない(範囲の検査は木の直下の名前を見る)。
PLANTDIR="$IOS/__no_linerefs_control_unlisted"
SCRATCH="$(mktemp -d /tmp/rc-nolineref.XXXXXX)" || exit 2
cleanup() {
    /bin/rm -f "$PLANT" 2>/dev/null
    /bin/rmdir "$PLANTDIR" 2>/dev/null
    find "$SCRATCH" -type f -print0 2>/dev/null | xargs -0 /bin/rm -f 2>/dev/null
    find "$SCRATCH" -type d -depth -exec /bin/rmdir {} \; 2>/dev/null
}
trap cleanup EXIT

run_test() {  # <検査 file> -> 終了コードだけ返す
    "$NODE" --test "$1" >"$SCRATCH/out.txt" 2>&1
    echo $?
}

# ★継ぎ目に**測定にならない物**が入っていないか先に見る(2026-08-05 に踏んだ)。
#   `RC_LINEREF_TEST` へ空 file を差した時、`node --test` は検査0件で 0 を返す。
#   すると「植えても緑」= ①が赤くなり、対照は**古い版を測った顔**をする。
#   実際には何も走っていない。`tools/prove-control.sh` の頭に在るとおり、
#   壊し方が下手で対象に辿り着けなかった時の非ゼロは測定ではない。
sane_test_file() {  # <検査 file> -> 検査が実際に走ったか
    [ -s "$1" ] || return 1
    "$NODE" --test "$1" >"$SCRATCH/sane.txt" 2>&1
    local n
    n="$(grep -E '^# tests [0-9]+' "$SCRATCH/sane.txt" | grep -oE '[0-9]+$' | head -1)"
    [ -n "$n" ] && [ "$n" -ge 3 ]
}
if ! sane_test_file "$TEST"; then
    echo "測れない: 継ぎ目の検査 file が走っていない ($TEST) = 空か、検査が3件未満"
    exit 2
fi

# ── ② 先に「植えない状態が緑」を確かめる ────────────────────────────────
# 順序が逆だと、①の赤が**元から赤かった**のか植えた所為なのか区別が付かない。
[ -e "$PLANT" ] && { echo "測れない: 目印の file が既に在る ($PLANT)"; exit 2; }
if [ "$(run_test "$TEST")" = "0" ]; then
    ok "② 植えなければ緑(①の赤が巻き添えでない事の前提)"
else
    ng "② 植えなければ緑" "植える前から赤い。この対照は何も測れない"
    # ★何が赤いのかを**その場で**出す。捨てると診断できない赤になる。
    #   実測 2026-08-05: `run-controls.sh` の中でこの行が1度出て、単独で回すと
    #   7回連続で緑だった。out.txt を捨てていたので、その1回が
    #   「引用が1件壊れていた」のか「木の直下に別の対照の残骸が在った」のかが
    #   **もう判らない**。次に出た時は判る様にしておく(再現待ちの為の計測器)。
    echo "--- 検査本体が何を言って落ちたか(先頭40行)------------------"
    grep -vE '^(ok|# (Subtest|tests|suites|pass|cancelled|skipped|todo|duration))' "$SCRATCH/out.txt" | head -40
    echo "--- 木の直下に在る物(範囲の検査はここを見ている)------------"
    ls -1 "$IOS" | head -30
    echo "-------------------------------------------------------------"
    exit 1
fi

# 走査範囲の名乗りが、実際に電話側の木を含んでいるか。
if grep -q '走査した木: rc-backend + ios' "$SCRATCH/out.txt"; then
    ok "② 走査範囲の名乗りに電話側の木が入っている"
else
    ng "② 走査範囲の名乗り" "$(grep -o '走査した木[^"]*' "$SCRATCH/out.txt" | head -1)"
fi

# ── ① 電話側の木に行番号を1件植える → 赤くなるか ──────────────────────
# 綴りは連結で組み立てる。この対照 file 自身も走査の対象なので、
# 「見つかってはいけない綴り」を1バイトもここに置かない(検査本体と同じ作法)。
REF="server"".""mjs"":""209"
{
    echo "// 対照が植えた行。この行が在る間、検査は赤でなければならない。"
    echo "// 出所は $REF を見よ"
} > "$PLANT"

if [ "$(run_test "$TEST")" != "0" ]; then
    ok "① 電話側の木に行番号を植えると赤(= 走査が ios に届いている)"
else
    ng "① 電話側の木に行番号を植えると赤" \
       "植えても緑 = 検査は ios を見ていない。2026-08-05 に 16件を素通りさせた状態"
fi

# 赤の中身が**植えた物**か。件数だけ見て「赤いから測れている」と言わない。
if grep -q "$REF" "$SCRATCH/out.txt"; then
    ok "① 赤の中身が植えた行を名指ししている(別の理由で赤いのではない)"
else
    ng "① 赤の中身" "植えた綴りが報告に出ない = 別の理由で落ちている"
fi

/bin/rm -f "$PLANT"
if [ "$(run_test "$TEST")" = "0" ]; then
    ok "① 落とせば緑に戻る(木を汚したまま終わっていない)"
else
    ng "① 落とせば緑に戻る" "植えた物を消しても赤いまま"
fi

# ── ③ ios の居ない部分木で緑か(変異走行を巻き添えにしない) ─────────────
# 変異走行は `shutil.copytree(rc-backend)` で写すので、隣の ios は写しに居ない。
# ここが赤い造りだと、走行の**全件**が「検出」に化ける。
COPY="$SCRATCH/partial/rc"
mkdir -p "$COPY"
for d in src test tools package.json; do
    [ -e "$ROOT/$d" ] && cp -R "$ROOT/$d" "$COPY/" 2>/dev/null
done
# ★写した木の中身も**継ぎ目の版に差し替える**。差し替えないと、③④だけが常に
#   live の版を測る事になり、`prove-control.sh` で古い版を差しても③④は緑のまま
#   —— 「対照は赤くなった」の内訳を読まずに済ませると、測れていない項目が
#   緑の下に残る。2026-08-05 の初回でこの形を作りかけた。
cp "$TEST" "$COPY/test/no-linerefs.test.mjs"
if [ -d "$SCRATCH/partial/ios" ]; then
    ng "③ 部分木の作り方" "写しの隣に ios が居る = 変異走行の形になっていない"
else
    if [ "$(run_test "$COPY/test/no-linerefs.test.mjs")" = "0" ]; then
        ok "③ ios の居ない部分木でも緑(変異走行を巻き添えにしない)"
    else
        ng "③ ios の居ない部分木でも緑" \
           "部分木で赤 = 変異走行の中だけで落ち、以降の変異が全部『検出』に化ける"
    fi
    # ★綴りを丸ごと固定しない。2026-08-07 に木を1つ足した(repo 直下の台本の置き場)
    #   だけで此処が偽の赤になった —— 名乗りは `ios,harness` へ育つのが正常で、
    #   **対照の側が木の一覧を手で写していた**。写しは木が動く度に腐る、という
    #   この検査本体の主題を、対照が自分でやっていた形。
    #   歯は残す: 名乗りが消えるか ios が名指しされなくなれば赤。
    if grep -qE '居なかった木: [^(]*ios[^(]*\(部分木\)' "$SCRATCH/out.txt"; then
        ok "③ 減った走査範囲を log に名乗っている(黙って減らしていない)"
    else
        ng "③ 減った走査範囲の名乗り" "部分木である事が出力に出ない"
    fi
fi

# ── ④ ios は在るが .swift が1枚も無い → 赤か(木ごとの下限) ─────────────
# 合計で下限を持っていると、ここが緑になる = 0件が隠れる。
EMPTY="$SCRATCH/empty"
mkdir -p "$EMPTY/rc-backend" "$EMPTY/ios/Sources"
for d in src test tools package.json; do
    [ -e "$ROOT/$d" ] && cp -R "$ROOT/$d" "$EMPTY/rc-backend/" 2>/dev/null
done
cp "$TEST" "$EMPTY/rc-backend/test/no-linerefs.test.mjs"   # ③と同じ理由で差し替える
if [ "$(run_test "$EMPTY/rc-backend/test/no-linerefs.test.mjs")" != "0" ]; then
    ok "④ 電話側の木が空なら赤(木ごとの下限が効いている)"
else
    ng "④ 電話側の木が空なら赤" \
       "空でも緑 = 下限を合計で持っている。片方の walk が死んでも気付けない"
fi

# ── ⑤ 一覧に無い dir を足す → 赤か(範囲が木と一致している事の検査) ──────────
# なぜ要るか(2026-08-05): `ios/UITests` は `dirs` に無く、UI の検査 3 本は
# **この検査からも Sprint 4 の DoD の台本からも見えていなかった**。どちらも
# 「一覧に書いた物」を見ていて「木に実際に在る物」を見ていない。一覧に1つ足すだけでは
# 次に増えた dir で同じ事が起きるので、検査本体に「一覧が木と一致しているか」を入れた。
#
# ★検査本体の中にも陰性対照(関数へ直接名前を渡す形)は在るが、それが証明するのは
#   **関数**であって、関数が**本物の木に繋がっている**事ではない。ここで実際に木へ
#   足して初めて配線まで測れる。今夜 DoD の台本で同じ理由の1行を足したのと同じ形。
mkdir -p "$PLANTDIR"
if [ "$(run_test "$TEST")" != "0" ]; then
    ok "⑤ 一覧に無い dir を足すと赤(範囲が木と一致している事を見ている)"
else
    ng "⑤ 一覧に無い dir を足すと赤" \
       "足しても緑 = 新しい dir が黙って走査の外に落ちる。UITests がそうだった状態"
fi
if grep -q '__no_linerefs_control_unlisted' "$SCRATCH/out.txt"; then
    ok "⑤ 赤の中身が足した dir を名指ししている(別の理由で赤いのではない)"
else
    ng "⑤ 赤の中身" "足した dir の名前が報告に出ない = 別の理由で落ちている"
fi
/bin/rmdir "$PLANTDIR"
if [ "$(run_test "$TEST")" = "0" ]; then
    ok "⑤ 落とせば緑に戻る"
else
    ng "⑤ 落とせば緑に戻る" "消しても赤いまま"
fi

cleanup
if [ -e "$PLANTDIR" ]; then
    ng "後始末" "足した dir が残っている: $PLANTDIR"
fi
if [ -e "$PLANT" ]; then
    ng "後始末" "植えた file が残っている: $PLANT"
fi

echo "--- 合計: PASS $pass / FAIL $fail ---"
[ "$fail" -eq 0 ] || exit 1
exit 0
