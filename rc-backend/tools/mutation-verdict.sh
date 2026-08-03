#!/bin/bash
# mutation-verdict.sh — 変異の判定を**木の指紋に紐付けて**保存し、後で秒で読み直す。
#
# ── 何の為に在るか ────────────────────────────────────────────────────────
# `/loop` の門(`~/.claude/tools/loop-replan-gate.sh`)は verify を **300 秒で打ち切る**。
# 実装は `min(max(int(t.get("verify_timeout_s")` で始まる 1 行の**上限側の定数**で、
# task 側の `verify_timeout_s` をいくら上げても 300 で頭打ちになる(行番号では引かない
# —— 番号は書いた瞬間から写しなので、grep で辿れる綴りの方を目印にする)。
# ところが `218-11-interrupt` の verify は
#     npm test && python3 test/mutation-controls.py --only M104,M105,M106,M107,M108,M109,W14
# で、変異 7 件 x 約 65 秒 = **455 秒**。門の下では必ず途中で殺される。
#
# 殺された走行の終了コードを「赤」と読むのも「緑」と読むのも間違いで、正しくは**未測定**。
# ここで一番危ないのは、時間に負けた事を理由に検査を薄める事 —— 変異の件数を削れば
# verify は 300 秒に収まるが、それは「測る量を減らして門を通した」だけで、
# 通った事が何も意味しなくなる。
#
# → 測定そのものは減らさない。**測る場所を門の外へ出す**。
#     record: 門の外(背景の走行)で本物の 455 秒を回し、結果を指紋つきで保存する
#     assert: 門の中で、保存された判定が**今の木の物か**を確かめて秒で答える
#
# ── 指紋が覆う範囲(ここを間違えると偽の緑になる)──────────────────────────
# 判定は「この木には既知の欠陥が無い」という主張なので、**走行の結果を変え得る物**が
# 全部指紋に入っていなければならない。入れたのは4つ:
#   src/         変異が当たる先
#   test/        変異を殺す検査。`test/mutation-controls.py` 自身もここ = 的の一覧が
#                変われば `--only` が選ぶ集合も変わるので、指紋が動くのが正しい
#   tools/       ★見落としやすい。`npm test` は `test/reply-route.test.mjs` が
#                `../tools/live-http-check.mjs` を **import** し、
#                `test/live-tools-send-guard.test.mjs` が実物の `tools/live-*.mjs` を
#                読む。tools/ を外すと「検査が読んでいる物を指紋が見ていない」= 偽の緑
#   package.json `npm test` が何を回すかの定義
#
# 副作用として、tools/ を1文字直すだけで判定が失効する。**それで正しい**。
# 失効の方向は「緑と言えなくなる」であって「赤と言う」ではないので、うるさいだけで危なくない。
# 逆(指紋を狭くして失効しにくくする)は、直接に偽の緑を作る。
#
# ── 終了コード ────────────────────────────────────────────────────────────
#   0 = 判定が在り、今の木の物で、素通り 0 件
#   1 = 判定が在り、今の木の物だが、**素通りが在った**(= 赤)
#   2 = **未測定**。判定が無い / 今の木の物ではない / 走行が最後まで行っていない
#       2 を緑に丸めない。この道具の存在理由がそこにある。
#
# ── 使い方 ────────────────────────────────────────────────────────────────
#   bash tools/mutation-verdict.sh record --only M104,M105,M106,M107,M108,M109,W14
#   bash tools/mutation-verdict.sh assert --only M104,M105,M106,M107,M108,M109,W14
#   bash tools/mutation-verdict.sh list
#
# `record` は**長い**(選んだ変異 x 約 65 秒)。背景で走らせる事。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2
VDIR="${RC_VERDICT_DIR:-$ROOT/.harness/mutation-verdicts}"
PY="${RC_PYTHON:-python3}"

die() { printf '%s\n' "$*" >&2; exit 2; }

# ── 木の指紋 ──────────────────────────────────────────────────────────────
# `find … -print0 | sort -z | xargs -0 shasum` の形にするのは、`find` の返す順序が
# 環境依存だから(順序が違うだけで指紋が変わると、この道具は毎回「未測定」を返す置物になる)。
#
# ★空入力を検出して門を閉じる側へ倒す。`shasum` は入力が無くても
#   `e3b0c442…`(= sha256(""))を返すので、**探せていないのに定数の指紋**が出る。
#   定数の指紋は「木が変わっていない」と読まれるので、これが一番危ない失敗。
#   同型の欠陥を `~/.claude/tools/remote-mini.sh` の fingerprint() で 2026-08-03 に
#   実際に踏んでいる(BSD find が `-newermt` を解釈できず 1 件も出さずに死んでいた)。
EMPTY_SHA256="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
tree_fp() {
    local n out
    n="$(find src test tools package.json -type f -not -path '*/node_modules/*' 2>/dev/null | wc -l | tr -d ' ')"
    if [ "${n:-0}" -eq 0 ]; then
        echo "★指紋を採る対象が 1 件も見つからない(cwd=$PWD)" >&2
        return 1
    fi
    out="$(find src test tools package.json -type f -not -path '*/node_modules/*' -print0 2>/dev/null \
           | sort -z | xargs -0 shasum -a 256 2>/dev/null | shasum -a 256 | cut -d' ' -f1)"
    if [ -z "$out" ] || [ "$out" = "$EMPTY_SHA256" ]; then
        echo "★指紋が空入力のハッシュになった(= ${n} 件在る筈なのに読めていない)" >&2
        return 1
    fi
    printf '%s\n' "$out"
}

# `--only M104,M105` を file 名に使える形へ。選び方が違えば別の判定 = 別の file。
sel_slug() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'; }

vpath() { printf '%s/%s-%s.json\n' "$VDIR" "$1" "$(sel_slug "$2")"; }

# ── 引数 ──────────────────────────────────────────────────────────────────
CMD="${1:-}"; shift 2>/dev/null || true
SEL=""
while [ $# -gt 0 ]; do
    case "$1" in
        --only)
            # ★`shift 2` を書かない。残りが 1 個の時 `shift 2` は**失敗した上に shift も
            #   しない**ので、この while が回り続ける。2026-08-03 に実際に CPU を焼いた。
            [ $# -ge 2 ] || die "--only の後に語が無い"
            SEL="$2"; shift; shift ;;
        *) die "知らない引数: $1" ;;
    esac
done

case "$CMD" in
  record)
    [ -n "$SEL" ] || die "record には --only が要る(全件の判定は full 走行の log が正本)"
    mkdir -p "$VDIR" || die "判定の置き場を作れない: $VDIR"

    # ★走行中に木が動いたら、その走行は**どちらの木も説明しない**。
    #   台本は変異ごとに木を写し直すので、前半と後半で違う木を測る事になる。
    #   だから前後で指紋を採って、変わっていたら記録しない。
    before="$(tree_fp)" || die "走行前の指紋を採れない"
    echo "走行前の指紋: $before"
    echo "選んだ変異: --only $SEL"
    echo "(これは長い。変異1件あたり約 65 秒)"
    echo ""

    log="$VDIR/run-$(date +%Y%m%d-%H%M%S)-$(sel_slug "$SEL").log"
    rc=0
    "$PY" test/mutation-controls.py --only "$SEL" > "$log" 2>&1 || rc=$?
    after="$(tree_fp)" || die "走行後の指紋を採れない(記録しない)"

    if [ "$before" != "$after" ]; then
        echo "★走行中に木が変わった($before → $after)。" >&2
        echo "  この走行は送った木も今の木も説明しないので、判定として記録しない。" >&2
        echo "  log は残す: $log" >&2
        exit 2
    fi

    # ★終了コードだけを信じない。台本が最後まで行った証拠は**要約行が在る事**。
    #   途中で殺された走行も終了コードは付くので、コードだけ見ると
    #   「測れなかった」を「測った」と読む事になる —— この道具が潰す為に在る病気そのもの。
    if ! grep -q '^素通りした変異:' "$log"; then
        echo "★要約行(「素通りした変異:」)が無い = 走行が最後まで行っていない。記録しない。" >&2
        echo "  log 末尾:" >&2
        tail -5 "$log" | sed 's/^/    /' >&2
        exit 2
    fi

    missed="$(grep '^素通りした変異:' "$log" | tail -1 | sed 's/^素通りした変異: *//')"
    # 実際に何件回したか。`--only` の語が同じでも的の一覧が増えれば件数は変わる
    # (その場合 test/ の指紋も動くので判定は失効するが、**人が読める様に**数を残す)。
    ran="$(grep -o '★--only [^(]*(\([^)]*\)): [0-9]*/[0-9]* 件' "$log" | grep -o ': [0-9]*/' | tr -d ': /' | head -1)"

    out="$(vpath "$after" "$SEL")"
    "$PY" - "$out" "$after" "$SEL" "$rc" "$missed" "${ran:-0}" "$log" <<'PYJSON'
import json, sys, datetime
out, fp, sel, rc, missed, ran, log = sys.argv[1:8]
json.dump({
    "tree_fp": fp,
    "selector": sel,
    "exit_code": int(rc),
    "survivors": missed,
    "mutants_run": int(ran or 0),
    "recorded_at": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
    "log": log,
}, open(out, "w"), ensure_ascii=False, indent=2)
PYJSON
    echo ""
    echo "判定を記録: $out"
    echo "  指紋: $after"
    echo "  回した変異: ${ran:-不明} 件"
    echo "  素通り: $missed"
    exit "$rc"
    ;;

  assert)
    [ -n "$SEL" ] || die "assert には --only が要る"
    fp="$(tree_fp)" || exit 2
    p="$(vpath "$fp" "$SEL")"
    if [ ! -f "$p" ]; then
        echo "未測定: 今の木($fp)に対する --only $SEL の判定が無い。" >&2
        echo "  先に回す: bash tools/mutation-verdict.sh record --only $SEL" >&2
        echo "  (src/ test/ tools/ package.json のどれかを直せば判定は失効する = これは正常)" >&2
        exit 2
    fi
    # 保存側が壊れていたら未測定。読めない json を緑に丸めない。
    if ! "$PY" - "$p" "$fp" "$SEL" <<'PYCHK'
import json, sys
p, fp, sel = sys.argv[1:4]
try:
    d = json.load(open(p))
except Exception as e:
    print(f"判定を読めない({e})", file=sys.stderr); sys.exit(2)
if d.get("tree_fp") != fp or d.get("selector") != sel:
    print("判定の中身が file 名と食い違う(手で書き換えた跡)", file=sys.stderr); sys.exit(2)
print(f"判定: {d.get('recorded_at')} / 変異 {d.get('mutants_run')} 件 / "
      f"素通り {d.get('survivors')}")
sys.exit(0 if d.get("exit_code") == 0 else 1)
PYCHK
    then
        rc=$?
        [ "$rc" -eq 1 ] && echo "★素通りが在る = 赤。log を読む事: $(grep -o '"log": "[^"]*"' "$p" | cut -d'"' -f4)" >&2
        exit "$rc"
    fi
    echo "緑(この判定は今の木の物: $fp)"
    exit 0
    ;;

  list)
    [ -d "$VDIR" ] || { echo "判定はまだ 1 件も無い($VDIR)"; exit 0; }
    fp="$(tree_fp)" || exit 2
    echo "今の木の指紋: $fp"
    n=0
    for f in "$VDIR"/*.json; do
        [ -e "$f" ] || continue
        n=$((n+1))
        mark="(別の木)"
        case "$(basename "$f")" in "$fp"-*) mark="★今の木" ;; esac
        printf '  %-9s %s\n' "$mark" "$(basename "$f")"
    done
    [ "$n" -eq 0 ] && echo "  (判定はまだ 1 件も無い)"
    exit 0
    ;;

  *)
    die "使い方: mutation-verdict.sh {record|assert|list} [--only <選び方>]"
    ;;
esac
