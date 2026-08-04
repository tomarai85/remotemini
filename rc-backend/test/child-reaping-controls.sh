#!/bin/bash
# 変異台本が**中断された時に子を残さない**事の確認。
#
# なぜ要るか(実際に起きた事): 台本は変異1件ごとに `node test/e2e-local.mjs` を起こし、
#   それは**ポートを掴むサーバ**を上げる。台本が途中で殺されて子が生き残ると、その
#   ポートを掴んだ孤児が残る。実測で **pid 45236 が port 8861 を 11時間33分**保持していて、
#   後続の走行はサーバを上げられず → 要約行が出ず → 終了コードだけ見て
#   **「変異を検出した」と数えた**。守れていない物を守れたと報告する経路。
#
# ★測り方の肝: 「今 node が走っているか」では測れない(他人の node が常に居る)。
#   だから**殺す前に、その python の子孫の pid を控えておき**、殺した後にその pid が
#   生きているかだけを見る。自分が起こした物しか触らない = 他人のプロセスに一切触れない。
#
# ★対照として、**直す前の版**(subprocess.run のまま・信号処理なし)を使い捨ての複製に
#   作って同じ手順を踏む。そこで孤児が残らなければ、この対照は何も測っていない。
#
# ══════════════════════════════════════════════════════════════════════════
# ★★この台本自身が一度事故った。同じ形を二度と書かない為に経緯をここに置く(2026-08-02)
#
#   初版の `descendants()` はこう書いていた:
#       if (want[ppid[pids[i]]]) want[pids[i]] = 1
#   awk は**配列を参照した瞬間にそのキーを作る**。`want[<その ppid>]` が空値で生える。
#   `if` 自体は正しく偽になるので気付けない。しかし最後の `for (p in want)` は
#   「一度でも**参照された**キー」を全部回すので、返り値は
#   **マシン上に存在する全ての親 pid**(実測 77個 = tomtim 60 / root 14)になった。
#   対照は「生き残り 76個 / 78個」と報告した —— ほぼ同数なのが唯一の手掛かりだった。
#
#   その pid の列は `cleanup` の `kill -9` に繋がっていた。実害が出なかったのは
#   **偶然**で、`measure` を `$( )` の中で呼んでいた為 `STRAY` への代入が部分shell に
#   閉じ込められ、親の `cleanup` は空の列を回しただけだったから(実測で確認: 事故後に
#   再起動した root プロセス 0個 / 事故前から生存 tomtim 406・root 138)。
#   つまり「返り値の受け渡しを直す」だけをやっていたら、次の走行で本当に飛んでいた。
#
#   得た規則(この台本に機械として埋めた物):
#     (a) `in` 演算子を使う。参照でキーが生える形は書かない。
#     (b) **pid の導出は、信号を送る前に既知の木で自己検査する**。落ちたら測定不成立
#         (終了コード2)で止まり、kill には一切進まない。
#     (c) **合図を送る直前に、その pid が本当に自分の物か照合する**。ここでは
#         「作業ディレクトリが砂場の下か」を lsof で見る。照合できない pid は
#         **殺さずに報告する**(閉じる側に倒す)。pid 使い回しにもこれで耐える。
# ══════════════════════════════════════════════════════════════════════════
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

pass=0; fail=0
ok() { pass=$((pass+1)); echo "PASS  $1"; }
ng() { fail=$((fail+1)); echo "FAIL  $1  ($2)"; }

SB=""
SELFTEST_PIDS=""

# ---- 片付け(削除は再帰強制を使わず、名指しの rm -f + rmdir だけで行う)----
purge_sandbox() {
    [ -n "$SB" ] && [ -d "$SB" ] || return 0
    case "$SB" in
        /tmp/reap-ctl.*|/private/tmp/reap-ctl.*) : ;;
        *) echo "  (砂場の path が想定の形でないので消さない: $SB)" >&2; return 0 ;;
    esac
    /usr/bin/find "$SB" -type f -print0 2>/dev/null | /usr/bin/xargs -0 /bin/rm -f 2>/dev/null
    /usr/bin/find "$SB" -type l -print0 2>/dev/null | /usr/bin/xargs -0 /bin/rm -f 2>/dev/null
    /usr/bin/find "$SB" -depth -type d 2>/dev/null | while IFS= read -r d; do /bin/rmdir "$d" 2>/dev/null; done
}

# ---- 合図を送ってよい pid か = 作業ディレクトリが砂場の下にあるか ----
#   台本(python)の cwd は $SB/w-*、その孫(npm / node)の cwd は TMPDIR=$SB/tmp-* の下の
#   作業複製。どちらも砂場の下。照合できなければ**殺さない**。
owned_by_sandbox() {   # $1 = pid
    [ -n "$SB" ] || return 1
    local cwd
    cwd="$(/usr/sbin/lsof -a -p "$1" -d cwd -Fn 2>/dev/null | /usr/bin/sed -n 's/^n//p' | head -1)"
    [ -n "$cwd" ] || return 1
    case "$cwd" in "$SB"/*|"$SB") return 0 ;; *) return 1 ;; esac
}

reap_stray() {
    local f="$SB/stray.txt" p refused=0 killed=0
    [ -f "$f" ] || return 0
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        kill -0 "$p" 2>/dev/null || continue
        if owned_by_sandbox "$p"; then
            kill -9 "$p" 2>/dev/null && killed=$((killed+1))
        else
            refused=$((refused+1))
            echo "  ★合図を拒否: pid $p は砂場の下で走っていない(照合できない物は殺さない)" >&2
        fi
    done < "$f"
    [ "$killed" -gt 0 ] && echo "  (孤児 ${killed}個を片付けた)" >&2
    [ "$refused" -gt 0 ] && echo "  (照合できず残した pid が ${refused}個ある —— 手で確認する事)" >&2
    return 0
}

# ★自己検査の片付けは**導出に頼らない**。`descendants` が正しいかを決める前に
#   その出力を kill に渡すのは、事故そのものの再演になる。だから目印の command 行と
#   **完全一致**する自分の user のプロセスだけを落とす(木を辿らない)。
kill_selftest_marks() {
    /bin/ps -u "$(id -un)" -o pid=,command= | awk '
        { pid = $1; $1 = ""; sub(/^ +/, "")
          if ($0 == "sleep 2073" || $0 == "sleep 2074") print pid }' \
    | while IFS= read -r p; do kill -9 "$p" 2>/dev/null; done
}

cleanup() {
    for p in $SELFTEST_PIDS; do kill -9 "$p" 2>/dev/null; done   # 自己検査で自分が起こした物
    kill_selftest_marks
    reap_stray
    purge_sandbox
}
trap cleanup EXIT INT TERM

# ★`pwd -P` で**実体の path** にしておく。mktemp は /tmp/... を返すが lsof が報告する
#   cwd は /private/tmp/... なので、そのまま照合すると **全部「自分の物でない」判定**になり、
#   閉じる側に倒れた結果 **孤児を消さずに残す**(この対照が撒き散らす側に回る)。
#   書いた直後に気付いたので実走行前に直した。
SB="$(cd "$(mktemp -d /tmp/reap-ctl.XXXXXX)" && pwd -P)"
: > "$SB/stray.txt"

# ---- 子孫の pid を集める(ps を1回読んで親子表を作り、幅優先で降りる)----
#   ★`in` を使う。`want[ppid[p]]` と**参照**するとキーが生えるので絶対に書かない。
descendants() {   # $1 = 根の pid
    /bin/ps -eo pid=,ppid= | awk -v root="$1" '
      { ppid[$1] = $2; pids[NR] = $1 }
      END {
        want[root] = 1
        # 深さは高々数段なので、表を数回舐めれば収束する
        for (pass = 0; pass < 8; pass++)
          for (i = 1; i <= NR; i++) {
            p = pids[i]
            if (!(p in want) && (ppid[p] in want)) want[p] = 1
          }
        for (p in want) if (p != root) print p
      }'
}

alive() { kill -0 "$1" 2>/dev/null; }

# ══ 0) 導出そのものの自己検査 ══════════════════════════════════════════
#   既知の木を作って `descendants` に掛ける。ここが落ちたら**測定不成立**で止まる。
#   信号を送る道具を、信号を送る前に検査する —— 事故の再発防止はこの1本。
selftest_descendants() {
    # 木: A(sh) → B(sh) → C(sleep 2073)。同時に、A の子孫では**ない**兄弟 D(sleep 2074)。
    /bin/sh -c '/bin/sh -c "sleep 2073" & wait' >/dev/null 2>&1 &
    local A=$!
    /bin/sh -c 'sleep 2074' >/dev/null 2>&1 &
    local D=$!
    SELFTEST_PIDS="$A $D"
    sleep 1

    local got n
    got="$(descendants "$A")"
    n="$(printf '%s\n' "$got" | grep -c '[0-9]')"

    # (i) 数が現実的か —— 壊れていた版はここで 70件超を返した
    if [ "$n" -gt 8 ]; then
        echo "  自己検査: 子孫が ${n}個 = 多すぎる(全親プロセスを拾う欠陥の再発)" >&2
        return 1
    fi
    # (ii) 目印(sleep 2073)が入っているか = 本当に降りられているか
    local found=0 p
    for p in $got; do
        /bin/ps -o command= -p "$p" 2>/dev/null | grep -q 'sleep 2073' && found=1
    done
    if [ "$found" -ne 1 ]; then
        echo "  自己検査: 既知の孫(sleep 2073)を拾えていない" >&2
        return 1
    fi
    # (iii) 無関係な兄弟 D と pid 1 と自分自身が混ざっていないか
    for p in $got; do
        if [ "$p" = "$D" ] || [ "$p" = "1" ] || [ "$p" = "$$" ]; then
            echo "  自己検査: 子孫でない pid $p が混ざっている" >&2
            return 1
        fi
    done

    # ★順序と手段の両方が肝(8/02 に両方間違えた)。
    #   初版は「根を殺す → 子孫を辿る」の順で書いたので、根が ps から消えた後に辿る事になり
    #   孫(sleep 2073)が1個孤児として残った —— **この対照が防ぎたい現象を、対照の後始末で
    #   やっていた**(実測: pid 89899 が生き残り、手で落とした)。
    #   そして辿り直すのではなく目印一致で落とす。ここは `descendants` の正しさを
    #   まだ「たった今確かめ終えた」段階なので、片付けを導出に依存させない方が筋が通る。
    kill -9 $SELFTEST_PIDS 2>/dev/null
    SELFTEST_PIDS=""
    kill_selftest_marks
    echo "  自己検査: 既知の木で子孫 ${n}個・目印あり・無関係 pid なし" >&2
    return 0
}

if ! selftest_descendants; then
    echo "UNMEASURED  pid の導出が自己検査に落ちた —— **一切の合図を送らずに止める**"
    echo ""
    echo "CHILD-REAPING-CONTROLS: 測定不成立(緑ではない)"
    exit 2
fi
ok "pid の導出が既知の木で正しい(この検査に通るまで kill には進まない)"

# ---- 1回の測定: $1 = 台本の path, $2 = 見出し → 生き残り pid を stray.txt に足し、件数を返す ----
measure() {
    local script="$1" label="$2" work="$SB/w-$2"
    /bin/mkdir -p "$work" "$SB/tmp-$2"
    # 台本が要る物だけ複製(node_modules は台本自身も複製しないので要らない)
    rsync -a --exclude node_modules --exclude .git --exclude .harness "$ROOT/" "$work/" >/dev/null 2>&1
    /bin/cp "$script" "$work/test/mutation-controls.py"

    # ★TMPDIR を砂場へ向ける。直す前の版は SIGTERM で atexit が走らないので
    #   作業コピー(mkdtemp)を残す —— 既定の TMPDIR に置くと、この対照自身が
    #   「消し忘れた木」を撒く事になる。砂場の中に落としておけば片付けで一緒に消える。
    #   合図の照合(owned_by_sandbox)もこの配置に依存している。
    # ★走行の印も砂場へ向ける(2026-08-04)。ここで走るのは**模擬**の走行 —— 写した木の
    #   中の、しかも信号処理を剥がした版である。既定の `/tmp/rc-backend-mutation-run.lock`
    #   を掴ませると2つ困る:
    #     - 測定中の 90 秒、本物の配備が「模擬の走行」に塞がれる(安全側だが意味が嘘)
    #     - 負の対照は SIGKILL 相当で落ちるので atexit が走らず、**印が /tmp に残る**。
    #       対照が自分の外へ痕跡を撒く事になる(この file の TMPDIR の教訓と同じ形)。
    #   本物の走行が2本同時に立たない事は `test/mutation-run-live-controls.sh` が
    #   本物の書き手で測っている。ここはその性質を測る場所ではない。
    ( cd "$work" && export TMPDIR="$SB/tmp-$label" RC_MUTATION_LOCK="$SB/mut-$label.lock" \
        && exec python3 test/mutation-controls.py --only R5 ) >/dev/null 2>&1 &
    local py=$!

    # e2e の子が実際に上がるまで待つ(最大 90 秒)。上がる前に殺したら何も測っていない。
    local kids="" seen_e2e=0 i
    for ((i = 0; i < 180; i++)); do
        kids="$(descendants "$py")"
        if [ -n "$kids" ] && /bin/ps -o command= -p $(echo "$kids" | tr '\n' ' ') 2>/dev/null | grep -q 'e2e-local\.mjs'; then
            seen_e2e=1; break
        fi
        alive "$py" || break
        sleep 0.5
    done

    if [ "$seen_e2e" -ne 1 ]; then
        kill -9 "$py" 2>/dev/null
        # ★注記は stderr へ。stdout は**返り値そのもの**なので、ここに1行混ぜると
        #   呼び手の `[ "$now" = "SKIP" ]` が成立しなくなる(書きかけて踏んだ)。
        echo "  (${label}: e2e の子を掴めなかった = この回は測定が成立しなかった)" >&2
        echo "SKIP"
        return
    fi

    kids="$(descendants "$py")"
    kill -TERM "$py" 2>/dev/null
    sleep 3

    local survivors=""
    for k in $kids; do
        if alive "$k"; then
            survivors="$survivors $k"
            # ★ファイル経由で親へ渡す。measure は `$( )` の中 = 部分shell なので
            #   変数への代入は親に届かない(初版はここで片付けが空回りしていた)。
            echo "$k" >> "$SB/stray.txt"
        fi
    done
    echo "$(echo $survivors | wc -w | tr -d ' ')"
}

# --- 1) 今の版: 中断しても子が残らない ---
now="$(measure "$ROOT/test/mutation-controls.py" now)"
if [ "$now" = "SKIP" ]; then
    ng "今の版で孤児が残らない" "e2e の子を掴めず測定が成立しなかった"
elif [ "$now" = "0" ]; then
    ok "今の版: SIGTERM で子孫が全部落ちる(生き残り 0)"
else
    ng "今の版で孤児が残らない" "生き残り ${now}個 — 群ごとの始末が効いていない"
fi

# --- 2) 負の対照: 直す前の版なら孤児が残る(= この対照が実際に見分けている証明)---
/bin/cp "$ROOT/test/mutation-controls.py" "$SB/old.py"
python3 - "$SB/old.py" <<'PY'
import sys, pathlib, re
p = pathlib.Path(sys.argv[1]); s = p.read_text(encoding="utf-8")
# 信号処理を外す(直す前 = 既定の始末)
s2 = s.replace("""for _sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
    signal.signal(_sig, _on_signal)""", "pass  # 直す前の版: 信号処理なし")
assert s2 != s, "信号処理の登録が見つからない(負の対照の前提が崩れている)"
# 子を独立した群にせず、群ごとの始末もしない = 元の subprocess.run 相当へ戻す。
# ★本文を丸ごと写して `replace` すると、**引数が1つ増えただけで負の対照が死ぬ**。
#   実際に死んだ(2026-08-04 検出): 時間切れの仕事で `suites(dst, timeout_fatal=True)` に
#   なり docstring も入ったので、写した4行はどこにも一致しなくなった。
#   この対照が守っている当の失敗(判定の写しは腐る)を、対照自身がやっていた。
#   だから写しを捨てて **`suites` の本体の中の `run_child(...)` 呼び出しだけ**を
#   形で狙う。本数(2本)は固定で確かめる —— 増減したらそれは前提の変化なので赤にする。
m = re.search(r'^def suites\(.*?(?=^\S)', s2, re.M | re.S)
assert m, "suites の定義が見つからない(負の対照の前提が崩れている)"
body, n = re.subn(
    r'run_child\(\s*(\[[^\]]*\])\s*,\s*dst\s*,\s*"[^"]*"[^)]*\)',
    r'subprocess.run(\1, cwd=dst, capture_output=True, text=True)', m.group(0))
assert n == 2, f"suites の中の run_child 呼び出しが 2 本ではない(見つかった={n} 本)"
s3 = s2[:m.start()] + body + s2[m.end():]
p.write_text(s3, encoding="utf-8")
print("直す前の版を作った(信号処理なし / subprocess.run)")
PY

old="$(measure "$SB/old.py" old)"
if [ "$old" = "SKIP" ]; then
    ng "負の対照" "e2e の子を掴めず測定が成立しなかった — 1) の緑は根拠にならない"
elif [ "$old" = "0" ]; then
    ng "負の対照(直す前の版なら残る)" "生き残り 0 — **この対照は何も見分けていない**"
else
    ok "負の対照: 直す前の版では孤児が ${old}個 残る(= この対照は実際に見分けている)"
fi

# ★孤児の片付けを**要約行より前**に済ませる。trap 任せだと片付けの報告が要約の後に出て、
#   `run-controls.sh` が拾う「最終行」が `pass=3 fail=0` ではなく片付けの注記になる
#   (実測でそうなった)。trap 側は異常終了用に残す —— 二度呼んでも空回りするだけ。
reap_stray

echo ""
echo "CHILD-REAPING-CONTROLS: pass=$pass fail=$fail"
exit $(( fail > 0 ))
