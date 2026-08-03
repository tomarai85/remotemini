#!/bin/bash
# `tools/mutation-verdict.sh` の対照。
#
# この道具は「**長い測定を門の外へ出す**」為に在るので、壊れ方も1つに決まっている:
#   **今の木の物ではない判定を、今の木の緑として返す。**
# それが起きる経路は3つ在って、対照はそこを狙う:
#   (a) 指紋が覆う範囲が狭い(tools/ を見ていない、等)→ 直した後も古い緑が残る
#   (b) 走行が最後まで行っていないのに記録する      → 途中の値を判定にする
#   (c) 判定が無い時に 0 を返す                      → 「測っていない」を「異常なし」に丸める
#
# ── 本物の木を一切汚さない ────────────────────────────────────────────────
# (a) を測るには「木を1文字変えたら判定が失効するか」を見るしかないが、それを**この repo の
# 木**でやると、走っている変異の走行が変異ごとに写している最中の木を触る事になる。
# 変異の走行は「この木には既知の欠陥が無い」の証明なので、走行中に木が動けば
# **その証明はどちらの木も説明しない**。だから対照は最初に木を丸ごと砂場へ写し、
# 触るのは写しだけにする。`src/` に1文字足す対照が在るのはその為で、写しなら安全。
#
# ── 呼び口の規則(tools/run-controls.sh の頭に在る2行)をここでも守る ────────
#  (1) 入力は本物の生成元から取る。→ 緑の判定は**本物の `mutation-controls.py` を
#      1件だけ回して**作る(手で書いた log を食わせない)。要約行が欠けた log も、
#      本物の走行を `timeout` で切って作る = 手書きしない。
#  (2) 直す前の版で赤になるか個別に見る。→ 変異表は §M。
#
# ── §M 変異表(**`test/verdict-mutants.sh` が当てる**) ────────────────────
# ★2026-08-03 訂正: 此処には「`scratchpad/verdict-mutants.sh` が当てる」と書いてあったが、
#   **その file は存在しなかった**。表は 8 行の散文で、回す物が無い ——
#   DESIGN (19)「規則は、それを回す物が無いと効かない」の同日 5 回目。
#   回す物を `test/` へ据えた(`scratchpad/` は commit されないので次のセッションには無い)。
#   fp-no-tools    指紋から tools/ を落とす            → 5-b が赤
#   fp-no-test     指紋から test/ を落とす             → 5-c が赤
#   fp-no-src      指紋から src/ を落とす              → 5-d が赤
#   no-summary     要約行の確認を外す                  → 6 が赤
#   assert-green   判定が無い時に 0 を返す             → 1 が赤
#   assert-rc      exit_code を見ずに常に 0            → 7 が赤
#   sel-ignore     selector の食い違いを見ない         → 8 が赤
#   fp-empty-ok    空入力の指紋を受け入れる            → 4 が赤
#
# ★照合は必ず **ng() 側の文言**で書く。ok() のラベルで照合すると、実際は赤なのに
#   「緑」と出る(2026-08-03 に §10 の変異表で2回踏んだ)。
#
# 終了コード: 0=緑 / 1=赤 / 2=未測定。
# 実測: 既定 70〜100 秒(本物の走行を2回起こす)。`RC_VERDICT_CTL_FAST=1` で §1-4 だけ
# 回すが、その時は**必ず 2(未測定)で返す** —— 速い方を緑と読ませない。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

pass=0; fail=0; UNMEASURED=""
ok(){ pass=$((pass+1)); printf '  OK %s\n' "$1"; }
ng(){ fail=$((fail+1)); printf '  NG %s\n     期待[%s] 実際[%s]\n' "$1" "$2" "$3"; }
# chk(名前, 実際, 期待)。`ng` は (名前, 期待, 実際) の順なので入れ替えて渡す
# —— 揃えないと赤の行が「期待」と「実際」を逆に表示し、読んだ人が反対方向を直す。
chk(){ [ "$2" = "$3" ] && ok "$1" || ng "$1" "$3" "$2"; }
# ★切り口で不正な UTF-8 を作らない。`head -c` は多バイト文字の途中で切るので、そのまま出すと
#   この出力を読む道具(`test/verdict-mutants.sh` の awk)が変換に失敗して**その先を読まなくなる**。
#   赤の行が読めなくなるのではなく、**後ろの赤が消える**のが厄介な所。`iconv -c` で欠片を落とす。
cut200(){ printf '%s' "$1" | head -c 200 | iconv -c -f UTF-8 -t UTF-8 2>/dev/null; }
has(){ case "$2" in *"$3"*) ok "$1" ;; *) ng "$1" "…$3… を含む" "$(cut200 "$2")" ;; esac; }

SB="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/verdictctl.XXXXXX")" && pwd -P)"
cleanup(){
    [ -n "${SB:-}" ] && [ -d "$SB" ] || return 0
    find "$SB" -type f -print0 2>/dev/null | xargs -0 /bin/rm -f 2>/dev/null
    find "$SB" -depth -type d -print0 2>/dev/null | xargs -0 -n1 /bin/rmdir 2>/dev/null
    return 0
}
trap cleanup EXIT

# ── 木は**丸ごと**写す(2.2MB)。`src/ test/ tools/ package.json` だけに絞らない。
#    理由は 2 つで、後者が本題:
#      ① 検査の一部(注釈の行番号 / backtick の file 名)は木の**散文**を走査するので、
#         部分的な写しでは走査の対象数が変わり、測っている物がずれる。
#      ② ★**薄い写しは診断を曇らせた**(実測 2026-08-03)。この対照が
#         「無変異の木で検査が落ちた」で止まった時、私は原因を「写しが薄いから」と読んで
#         丸ごと写しに直した —— が、丸ごと写しでも同じ 2 件が落ちた。本当の原因は
#         `tools/mutation-verdict.sh` の注釈が repo 外の file を行番号つきで引いていた事、
#         つまり**私の書いた散文が repo の規則に違反していた**だけ。写しの厚みは無関係。
#         教訓は「砂場が本物と違う所を残すと、赤の出所を砂場のせいにできてしまう」。
#         砂場は本物と同じにしておく。差分を消してから初めて赤が診断になる。
T="$SB/tree"; mkdir -p "$T"
cp -R "$ROOT"/. "$T"/ 2>/dev/null
TOOL="$T/tools/mutation-verdict.sh"
[ -f "$TOOL" ] || { echo "★写しに道具が無い($TOOL)。測れない"; exit 2; }

VD="$SB/verdicts"
run(){ RC_VERDICT_DIR="$VD" /bin/bash "$TOOL" "$@" 2>&1; }
rc_of(){ RC_VERDICT_DIR="$VD" /bin/bash "$TOOL" "$@" >/dev/null 2>&1; echo $?; }
# 写しの中の file を1文字だけ動かして戻す(指紋が覆っているかを見る唯一の手)
touch_and_check(){   # $1=写しからの相対パス $2=足す行
    local f="$T/$1" r
    printf '%s\n' "$2" >> "$f"
    r="$(rc_of assert --only M1)"
    python3 - "$f" "$2" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]); tail = sys.argv[2] + "\n"
s = p.read_text()
if s.endswith(tail):
    p.write_text(s[: -len(tail)])
PY
    echo "$r"
}

echo "── 1. 判定が無い時は **未測定(2)**。緑にも赤にも丸めない ──"
o="$(run assert --only M1)"; r="$(rc_of assert --only M1)"
chk "  終了コード 2" "$r" "2"
has "  「未測定」と言う" "$o" "未測定"

echo "── 2. list は判定ゼロでも落ちない(= 道具そのものが門にならない) ──"
chk "  終了コード 0" "$(rc_of list)" "0"

echo "── 3. 引数の守り ──"
chk "  record に --only が無い = 2" "$(rc_of record)" "2"
chk "  知らない部分命令 = 2" "$(rc_of frobnicate)" "2"
# ★`--only` を値なしで置く。旧実装は `shift 2` を書いていて、残り1個の時に
#   **失敗した上に shift もしない** = 無限ループ。ここは戻ってくる事自体が対照。
to_rc=0; timeout 10 env RC_VERDICT_DIR="$VD" /bin/bash "$TOOL" assert --only >/dev/null 2>&1 || to_rc=$?
chk "  値の無い --only で戻ってくる(無限ループしない)" \
    "$([ "$to_rc" -eq 124 ] && echo hung || echo returned)" "returned"

echo "── 4. 指紋が空入力の定数にならない(find が何も返さない時) ──"
# 本物の失敗の形を再現する: `find` が 1 件も出さずに終わる。旧 remote-mini.sh は
# これで **常に sha256(\"\") を返し**、「木は変わっていない」と言い続けていた。
mkdir -p "$SB/bin"
printf '#!/bin/bash\nexit 0\n' > "$SB/bin/find"; chmod +x "$SB/bin/find"
o="$(PATH="$SB/bin:$PATH" RC_VERDICT_DIR="$VD" /bin/bash "$TOOL" assert --only M1 2>&1)"
r=0; PATH="$SB/bin:$PATH" RC_VERDICT_DIR="$VD" /bin/bash "$TOOL" assert --only M1 >/dev/null 2>&1 || r=$?
chk "  終了コード 2" "$r" "2"
has "  指紋を採れない事を言う" "$o" "指紋"
# ★assert の終了コードだけ見ると足りない。守りを外しても assert は「その指紋の判定が無い」で
#   2 を返すので、**偶然 2 が出ているだけ**の状態と区別が付かない。`list` は指紋そのものを
#   印字するので、そこに sha256("") が現れたら「定数を本物の指紋として扱った」= 見たかった壊れ方。
#
#   ★ここは一度書き損じている(2026-08-03): 判定の入れ物を作らずに `list` を呼んでいたので、
#     `list` は「判定はまだ 1 件も無い」で先に 0 を返し、指紋を採る所まで行っていなかった。
#     終了コードは確かに 0 だったが、それは**守りが緩いから**ではなく**通り道が違うから**。
#     道具の欠陥として読みかけたのはこちらの設定の誤り。→ 入れ物を作ってから呼ぶ。
VDFP="$SB/verdicts-fp"      # §5 の「判定 json が 1 件」を汚さない為に別の入れ物
mkdir -p "$VDFP"; printf '{}\n' > "$VDFP/dummy.json"
o="$(PATH="$SB/bin:$PATH" RC_VERDICT_DIR="$VDFP" /bin/bash "$TOOL" list 2>&1)"
r=0; PATH="$SB/bin:$PATH" RC_VERDICT_DIR="$VDFP" /bin/bash "$TOOL" list >/dev/null 2>&1 || r=$?
chk "  list も指紋を採れないなら 2" "$r" "2"
case "$o" in
    *e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855*)
        ng "  list が空入力の定数を指紋として印字しない" "その綴りが出ない事" "$(cut200 "$o")" ;;
    *)  ok "  list が空入力の定数を指紋として印字しない" ;;
esac

if [ "${RC_VERDICT_CTL_FAST:-0}" = "1" ]; then
    echo ""
    echo "── 5〜9: **回していない**(RC_VERDICT_CTL_FAST=1)。本物の走行が要る ──"
    UNMEASURED="fast-mode(§5-9 未実施)"
else

echo "── 5. 本物の走行で判定を作る(変異 1 件・実測 60〜90 秒) ──"
# ★手で書いた log を食わせない。この道具が守るのは「本物の走行の結果」なので、
#   入力が偽物なら守れているかは分からない(run-controls.sh の規則 1)。
rec_rc=0
o="$(run record --only M1)" || rec_rc=$?
chk "  record の終了コード 0" "$rec_rc" "0"
has "  判定を記録したと言う" "$o" "判定を記録"
n="$(find "$VD" -name '*.json' -type f 2>/dev/null | wc -l | tr -d ' ')"
chk "  判定 json が 1 件できた" "$n" "1"
J="$(find "$VD" -name '*.json' -type f 2>/dev/null | head -1)"

if [ "$n" != "1" ]; then
    echo "  ★判定が作れていないので §5-a 以降は測れない"
    UNMEASURED="record が判定を作れなかった"
else

echo "  5-a. 直後の assert は緑"
chk "    終了コード 0" "$(rc_of assert --only M1)" "0"

echo "  5-b. **tools/ を1行変えたら失効する**(= 指紋が tools/ を覆っている)"
# 覆っていないと、`npm test` が読む `tools/live-http-check.mjs` を壊しても
# 古い緑が返り続ける。`test/reply-route.test.mjs` が実際にそれを import している。
chk "    終了コード 2(未測定)" "$(touch_and_check tools/live-http-check.mjs '// ctl touch')" "2"
chk "    戻した後は緑に戻る" "$(rc_of assert --only M1)" "0"

echo "  5-c. **test/ を1行変えたら失効する**(= 変異を殺す検査そのもの)"
chk "    終了コード 2(未測定)" "$(touch_and_check test/mutation-controls.py '# ctl touch')" "2"
chk "    戻した後は緑に戻る" "$(rc_of assert --only M1)" "0"

echo "  5-d. **src/ を1行変えたら失効する**(= 変異が当たる先)"
chk "    終了コード 2(未測定)" "$(touch_and_check src/server.mjs '// ctl touch')" "2"
chk "    戻した後は緑に戻る" "$(rc_of assert --only M1)" "0"

echo "── 6. 要約行が無い走行は**記録しない** ──"
# 本物の走行を `timeout` で切って作る(手書きの log を使わない)。
printf '#!/bin/bash\nexec timeout 3 %s "$@"\n' "$(command -v python3)" > "$SB/bin/py-cut"
chmod +x "$SB/bin/py-cut"
o6="$(RC_PYTHON="$SB/bin/py-cut" run record --only M1)"; r6=0
RC_PYTHON="$SB/bin/py-cut" RC_VERDICT_DIR="$VD" /bin/bash "$TOOL" record --only M1 >/dev/null 2>&1 || r6=$?
chk "  終了コード 2" "$r6" "2"
has "  最後まで行っていないと言う" "$o6" "最後まで行っていない"
n6="$(find "$VD" -name '*.json' -type f 2>/dev/null | wc -l | tr -d ' ')"
chk "  判定 json は増えていない" "$n6" "1"

echo "── 7. 素通りが在る判定は **赤(1)**。未測定(2)でも緑(0)でもない ──"
python3 - "$J" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["exit_code"] = 1; d["survivors"] = "['M1 …']"
json.dump(d, open(sys.argv[1], "w"), ensure_ascii=False, indent=2)
PY
chk "  終了コード 1" "$(rc_of assert --only M1)" "1"
python3 - "$J" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["exit_code"] = 0; d["survivors"] = "なし"
json.dump(d, open(sys.argv[1], "w"), ensure_ascii=False, indent=2)
PY
chk "  戻した後は緑に戻る" "$(rc_of assert --only M1)" "0"

echo "── 8. 中身を書き換えた判定は**未測定**(file 名と食い違う) ──"
python3 - "$J" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["selector"] = "M999"
json.dump(d, open(sys.argv[1], "w"), ensure_ascii=False, indent=2)
PY
chk "  終了コード 2" "$(rc_of assert --only M1)" "2"

echo "── 9. 壊れた json は緑にしない ──"
printf 'not json at all' > "$J"
chk "  終了コード 2" "$(rc_of assert --only M1)" "2"

fi
fi

echo ""
if [ -n "$UNMEASURED" ]; then
    echo "VERDICT-CONTROLS: pass=$pass fail=$fail  ★未測定($UNMEASURED)= **緑ではない**"
    exit 2
fi
echo "VERDICT-CONTROLS: pass=$pass fail=$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
