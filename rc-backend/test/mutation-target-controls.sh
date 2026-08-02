#!/bin/bash
# `tools/check-mutation-targets.sh` が**緑にも赤にもなる**事の確認。
#
# なぜ書くか: この検査は普段いつも緑なので、**壊れていても緑**なら誰も気付けない。
#   「常に緑を出す検査」は 2026-08-02 に別件で実際に作ってしまった型(DESIGN §2.18-10)。
#   だから的を1つ**わざと外して**、赤が出る事を先に確かめる。
#
# ★★設計上いちばん大事な点: **本物の木を一切触らない**。使い捨ての複製の中だけで壊す。
#   初版は本物を書き換えて trap で戻す形で、その trap が `mutation-controls.py` を
#   **805 行 → 0 行に消した**(`mktemp` の空ファイルを、中身を入れる前に張った trap が
#   上書きした。詳細は DESIGN §2.18-10(7))。戻す仕掛けを正しく書くより、
#   **戻す必要が無い形にする**方が強い。`test/pii-controls.sh` が先に採っていた型。
set -uo pipefail
SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ★ここに「走行中は測れないので降りる(exit 2)」を置いていたが、**前提が事実と違った**ので
#   外した(2026-08-02 17:1x)。「走行中は `src/` が壊れている」と書いていたが、
#   変異台本は `tempfile.mkdtemp` + `copytree` で**複製の中だけ**を壊す
#   (test/mutation-controls.py:716-719、走行中の node の cwd を lsof で実測して確認)。
#   本物の `src/` は無傷なので、ここで作る複製も正しく、走行中でも測れる。
#
#   ★この降り方には副作用があった: 「未測定」は緑でも赤でもないので正直な形に見えるが、
#   実際には**走行中の 85 分間、この対照が一度も走らない**という事だった。
#   そして (7)(8) の事故はまさにその窓の中で起きた。**測れない窓を作る事自体が穴**。
#   偽の前提で作った門は、正直な三値で報告しても穴のままになる。

SB="$(mktemp -d /tmp/muttgt-ctl.XXXXXX)"
cleanup() { [ -n "${SB:-}" ] && [ -d "$SB" ] && /bin/rm -rf -- "$SB"; }
trap cleanup EXIT INT TERM

# 検査が見るのは src/ の本文と test/mutation-controls.py の的だけ。その2つと検査本体を写す。
mkdir -p "$SB/tools" "$SB/test"
cp -R "$SRC_ROOT/src" "$SB/src"
cp "$SRC_ROOT/test/mutation-controls.py" "$SB/test/"
cp "$SRC_ROOT/tools/check-mutation-targets.sh" "$SB/tools/"
cp "$SRC_ROOT/tools/mutation-run-live.sh" "$SB/tools/"   # ← 検査が呼ぶ判定。写し忘れると複製側が落ちる
CHECK="$SB/tools/check-mutation-targets.sh"
TARGET="$SB/test/mutation-controls.py"

pass=0; fail=0
ok() { pass=$((pass+1)); echo "PASS  $1"; }
ng() { fail=$((fail+1)); echo "FAIL  $1  ($2)"; }

# --- 1) 複製した木では緑である事 ---
if bash "$CHECK" >/dev/null 2>&1; then ok "今の木では緑(的が全部当たる)"
else ng "今の木では緑" "exit!=0 — 本当に的が外れているなら先にそちらを直す"; fi

# --- 2) 的を1つ外したら赤になる事(これが本体) ---
python3 - "$TARGET" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text(encoding="utf-8")
needle = 'MUT = ['
assert needle in s, "MUT の並びが見つからない(この対照の前提が崩れている)"
bogus = needle + '\n ("W98 対照用のわざと外した的", SRV, "__NEVER_PRESENT_IN_SOURCE__", "x"),'
p.write_text(s.replace(needle, bogus, 1), encoding="utf-8")
PY
if bash "$CHECK" >/dev/null 2>&1; then ng "的を外したら赤" "exit=0 — **検査が的の欠落を見ていない**"
else ok "的を外したら赤(欠落を捕まえる)"; fi

# --- 3) `--only` が**何を選んだか**を曖昧にしない事(2026-08-02 追加)---
#
# なぜ要るか: 初版の `--only` は**題名の部分一致だけ**だった。`--only R` は題名に大文字 R を
#   含むだけの M55/M67/M68/X6 まで拾い、4件の筈が9件・353 秒。時間の無駄より重いのは、
#   報告表に**選んでいない族が混ざる**事 —— 「R 族を測った」と「たまたま一緒に回った」が
#   区別できなくなる。計器が何を測ったか言えなくなるのは、この台本が防ぐべき当の病気。
#
# ★この対照が**空振りしない**事を先に確かめる(下の 3-0)。もし「題名に R を含む非R族」が
#   1件も存在しなければ、3-1 は直っていなくても緑になる。**弁別できる状況である事**を
#   測ってから、弁別を測る。
DRY() {  # $1 = --only の語(空なら全件) → 「的の照合: N件」の N を返す
    local out
    if [ -z "$1" ]; then out="$(python3 "$SRC_ROOT/test/mutation-controls.py" --dry 2>&1)"
    else out="$(python3 "$SRC_ROOT/test/mutation-controls.py" --dry --only "$1" 2>&1)"; fi
    printf '%s\n' "$out" | sed -n 's/^的の照合: \([0-9]*\)件.*/\1/p' | tail -1
}

# 3-0) 弁別できる状況か = 「R 族でないのに題名に R を含む的」が実在するか
decoys="$(grep -cE '^ *\("[MWXP][0-9]+[ (][^"]*R' "$SRC_ROOT/test/mutation-controls.py" || true)"
if [ "${decoys:-0}" -ge 1 ]; then
    ok "弁別できる状況(題名に R を含む非R族が ${decoys}件 実在する)"
else
    ng "弁別できる状況" "囮が0件 — 下の族選択の対照は**直っていなくても緑**になる。空振り"
fi

# 3-1) 族選択が族だけを選ぶ(囮を拾わない)
want_r="$(grep -cE '^ *\("R[0-9]+[ (]' "$SRC_ROOT/test/mutation-controls.py" || true)"
got_r="$(DRY R)"
if [ "$got_r" = "$want_r" ]; then ok "族選択 --only R = ${got_r}件(並びの R 族と一致)"
else ng "族選択 --only R" "選ばれた ${got_r}件 ≠ 並びの R 族 ${want_r}件 — 囮を拾っているか取りこぼしている"; fi

# 3-2) 番号選択はちょうど1件(M1 が M10..M103 を巻き込まない)
got_m1="$(DRY M1)"
if [ "$got_m1" = "1" ]; then ok "番号選択 --only M1 = 1件(M10..M103 を巻き込まない)"
else ng "番号選択 --only M1" "${got_m1}件 — 前方一致で巻き込んでいる"; fi

# 3-3) 絞らない時は全件(絞りの実装が既定を壊していない事)
#
# ★族の頭文字を**ここに書き写さない**。本体の起動段の正規表現から取り出す。
#   2026-08-02 に現物で踏んだ: ここが `[MWXPR]` 固定だったので、H 族(生存信号の判定層)を
#   13枚足した瞬間にこの対照だけが赤くなった —— 並びも走行も正しく、**数え方が古かった**。
#   同じ一覧が2つの file に居ると、族を足す作業が必ず片方を置き去りにする。
#   取り出しに失敗したら空になり、下の grep が0件を返して**赤で止まる**(黙って緑にならない)。
ALPHA="$(sed -n 's/.*re\.match(r"\[\([A-Z][A-Z]*\)\]\\d+.*/\1/p' "$SRC_ROOT/test/mutation-controls.py" | head -1)"
if [ "${#ALPHA}" -ge 3 ]; then
    ok "族の頭文字を本体から取り出せた(${ALPHA} — 写しを持たない)"
else
    ng "族の頭文字の取り出し" "取れたのは「${ALPHA}」— 本体の起動段の形が変わった。下の全件検査は当てにならない"
fi
got_all="$(DRY '')"; want_all="$(grep -cE "^ *\\(\"[${ALPHA}][0-9]+[ (]" "$SRC_ROOT/test/mutation-controls.py" || true)"
if [ "$got_all" = "$want_all" ]; then ok "既定(--only 無し)= ${got_all}件 = 並びの全件"
else ng "既定は全件" "${got_all}件 ≠ 並びの ${want_all}件"; fi

# 3-4) 当たらない語は**赤で止まる**(緑に丸めない)。★パイプ越しの $? は tail の値なので使わない
python3 "$SRC_ROOT/test/mutation-controls.py" --dry --only __NO_SUCH_TARGET__ >/dev/null 2>&1
if [ "$?" -ne 0 ]; then ok "当たらない語は exit≠0(測れていない事を隠さない)"
else ng "当たらない語で止まる" "exit=0 — 0件を緑として報告している"; fi

# --- 4) 本物の木を一切触っていない事(この対照自身の安全性) ---
if [ -s "$SRC_ROOT/test/mutation-controls.py" ] && \
   [ "$(wc -c < "$SRC_ROOT/test/mutation-controls.py")" -gt 1000 ]; then
    ok "本物の mutation-controls.py は無傷(空にも短くもなっていない)"
else
    ng "本物が無傷" "★対照が本物を壊した — 初版と同じ事故"
fi

echo ""
echo "MUTATION-TARGET-CONTROLS: pass=$pass fail=$fail"
exit $(( fail > 0 ))
