#!/bin/bash
# commit に**触れた対照**が入っているなら、その対照を commit の前に一度通す。
#
# なぜ要るか(2026-08-03 に2回踏んだ):
#   ① commit `25f8e09` は対照を2本足したが `npm test` を回さず、赤いまま入った
#      → `tools/commit-suite-gate.sh`(単体の一式)で塞いだ
#   ② commit `45e0c8b` は `tools/mutation-verdict.sh` と
#      `test/mutation-verdict-controls.sh` を**同じ commit で**足したのに、
#      その対照を**最後まで通した事が一度も無かった**。後で回したら §7〜§9 の
#      3 本が倒れ、道具の側に本物の欠陥が在った(assert が失敗を全部 0 で返す)。
#      ★①の門は `npm test` しか見ないので、②は素通りする —— `test/*-controls.sh` は
#      `npm test` の一部ではない(走らせる物は `tools/run-controls.sh` の方)。
#
#   どちらも「規則が無かった」のではない。**回す物が無かった**(DESIGN (19))。
#   対照を書いた commit と、対照を通した commit は別、というのが②の教訓。
#
# 全部(`run-controls.sh` の 19 本)を毎 commit 回すのは**しない**。実測で 5 分を超え、
# 使えない検査は外される —— hook 本体の注釈と同じ理由。代わりに範囲を「この commit が
# 触れた物」に絞る。触れていない対照が壊れるのは、触れた物の commit では起きない。
#
# 選び方(2 通り。どちらも file の実在を確かめてから回す):
#   (a) `rc-backend/test/*-controls.sh` が staged → それを回す
#   (b) staged な file を「見張る」と**宣言している**対照 → それを回す
#       (★②はこちら側。対照に触らず道具だけ直す事が在る)
#   (c) 宣言している対照が1本も無い `tools/*` は**黙って見逃さず、名前を出す**。止めはしない
#       —— 止めると対照の無い道具に触る commit が全部通らなくなる。見えれば足せる。
#
# ★★(b) を「名前から導く」から「対照が宣言する」へ替えた(2026-08-05、実測して塞いだ)。
#   旧: `tools/<名前>.sh` → `test/<名前>-controls.sh` が在れば回す。
#   これは **名前が一致した時だけ**当たる。実測した穴(`STAGED_LIST_CMD` で4通り撃った):
#     staged: tools/deploy-to-edith.sh    → 1 本回って「触れた対照は全部緑(1/1)」
#             …実際にこの道具を見張る対照は **4 本**在る(behavior / rsync-exclude /
#               rsync-exclude-edith / deploy-to-edith)。3 本は回らないのに **1/1 の緑**
#     staged: tools/check-no-pii.sh       → 0 本(対照は `pii-controls.sh`。名前が違う)
#     staged: tools/live-fork-check.mjs   → 0 本、注記も出ない(`case` が `*.sh` だけ)
#     staged: test/mutation-controls.py   → 0 本(5 本在る)。注記も出ない
#   ここで一番悪いのは 3 本目でも 4 本目でもなく **1 本目**。0 本なら「触れた対照は無い」と
#   出るので気付けるが、1/1 は**緑の顔で 3 本の欠落を隠す**。分母が「在る対照の数」でなく
#   「導けた対照の数」だったので、導出が痩せると分母も一緒に痩せて、比は常に満点になる。
#   —— 今夜3件目の同じ形(DESIGN §2.18-10「守りの届く範囲が、欠陥と一緒に縮む」)。
#
#   直し方も同じ = **欠陥の後も生き残る側から導く**。名前の一致は偶然なので、対照自身に
#   「私は何を見張っているか」を書かせる(`# controls-for: <path> …`、rc-backend からの
#   相対。glob 可、複数可)。宣言は対照の中に1箇所だけ在るので写しにならない。
#   そして**宣言の無い対照を staged で止める**(下の `undecl`)—— 宣言を忘れた対照は
#   「静かに回らない対照」そのもので、旧実装の穴と同じ物になる。書く瞬間に止めれば、
#   corpus に穴の在る対照が入る道が塞がる。
#
# 残余リスク(承知の上): 既存の宣言が**道具の改名で古くなる**と、その対照は回らなくなる。
#   改名は道具を staged にするので (c) の注記が出る = 見える。宣言先が実在しない対照は
#   下で名前を出し、staged なら止める。
#
# 終了コード: 0=緑(または対象なし) / 1=赤 / **2=測れなかった**。
#   2 を 0 に丸めない。hook は非ゼロで止まるので、測れない時は止まる側へ倒れる。
#
# 継ぎ目(対照が差し込む口): RC_GATE_ROOT / STAGED_LIST_CMD
set -uo pipefail

ROOT="${RC_GATE_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null)}"
[ -n "$ROOT" ] && [ -d "$ROOT" ] || { echo "staged-controls-gate: repo の根が判らない = 測れていない"; exit 2; }
LIST_CMD="${STAGED_LIST_CMD:-git diff --cached --name-only}"

staged="$(cd "$ROOT" && eval "$LIST_CMD" 2>/dev/null)"
# ★`--all-controls`(下の口)は staged に一切依らない = 空でも答えられる。
#   この門を「何が対照か」を知る為だけに呼ぶ側が在るので、そこを staged の有無で
#   止めない。止める側の意味は変えていない —— 選択・判断の道は下でそのまま空を弾く。
if [ -z "$staged" ] && [ "${1:-}" != "--all-controls" ]; then
    echo "staged-controls-gate: staged の一覧が空 = 測れていない(何を触ったか判らない)"
    exit 2
fi

sel=""; orphan=""; exempt=0
add_sel() { case " $sel " in *" $1 "*) ;; *) sel="$sel $1" ;; esac; }

# ── 宣言の一覧を1度だけ作る(対照 → 見張る対象)────────────────────────────
#   macOS の /bin/bash は 3.2 = 連想配列が無い。添字配列を2本、同じ位置で対にする。
#   `${arr[@]}` は空の時 `set -u` で落ちるので、長さ `${#arr[@]}` と添字だけで回す。
#
# ★★木を2つ見る(2026-08-05 の第2波)。此処は `rc-backend/test/` だけを見ていたので、
#   **`ios/` が丸ごと見えなかった** —— ios の対照3本も、それが見張る ios の道具も、
#   staged にした所で1本も選ばれない。実害は commit `c1617f7` に出ている: ios の file を
#   3本 staged にした commit が「触れた対照 1 本を回す … 全部緑(1/1)」と印字した。
#   選ばれた1本は `tools/run-controls.sh` を触った事で当たった別物で、
#   **ios 側は1本も測っていない**。この header の上の方に書いてある「1/1 は緑の顔で
#   欠落を隠す」と**同じ形が、名前ではなく木の軸で再発した**。
#   前の直しが浅かった訳ではなく、直した軸が1本だけだった。
#
# 宣言の基点は木ごとに違う(既存の宣言を書き換えない為):
#   rc-backend/test/*-control*.sh → 宣言は **rc-backend からの相対**(tools/foo.sh)
#   ios/tools/*-control*.sh       → 宣言は **repo の根からの相対**(ios/tools/foo.sh)
# ios 側を根からにするのは、ios の対照が backend の道具を見張る事が在り得るから
# (逆向きは既に注釈で起きている)。基点を根に取れば両方書ける。
CTLS=(); DECLS=(); BASES=()
# 拾い方は2つ。**名前**で拾うか、**宣言**で拾うか(SCAN_SPECS の3つ目で指定)。
#
# ★2026-08-07: 「対照であるか」を名前で、「何を見張るか」を宣言で決めていた =
#   一覧が2本在る形。実際にズレていた: `tools/serve-decision-check.sh` と
#   `tools/rc-backend-launch-check.sh` は**本物の負の対照**(前者は全ケースを旧判定にも
#   通して退行を捕まえる / 後者は偽の tailscale と node を噛ませて起動ラッパを駆動する)
#   なのに、名前の末尾が -check.sh で置き場が `tools/` なので、この門から見ると**ただの道具**
#   だった。つまり起動ラッパを直す commit は、対照を1本も回さずに通っていた。
#   ラッパを壊した時の症状は「edith の上では全部緑、電話からだけ永久に到達できない」
#   (`rc-backend-launch-check.sh` の冒頭がそう書いている)= 一番気付けない形。
#
#   直し方として「名前の glob を広げる」「`tools/` を走査 dir に足す」を先に測って両方捨てた:
#     - `*-check.sh` を足す -> `ios/tools/live-*-check.sh` を巻き込む(edith が要る = commit で回せない)
#     - `tools/` を名前で走査 -> `run-controls.sh` `staged-controls-gate.sh`
#       `prove-control.sh` `prove-all-controls.sh` が対照扱いになり、宣言が無いので
#       **全 commit が落ちる**(門が自分自身を対照だと言い出す)
#   だから名前ではなく**宣言を持つ事**を条件にする。宣言を書いた file だけが対照になる。
_scan_ctls() { # $1=対照の居る dir(根から) $2=宣言の基点(根から。空 = 根そのもの) $3=name|decl
    local d="$1" base="$2" mode="${3:-name}" _c decl pat='*-control*.sh'
    [ "$mode" = decl ] && pat='*.sh'
    for _c in "$ROOT/$d"/$pat; do
        [ -f "$_c" ] || continue
        decl="$(/usr/bin/sed -n 's/^# *controls-for:[[:space:]]*//p' "$_c" | /usr/bin/tr '\n' ' ')"
        # 宣言で拾う木では、宣言の無い file は対照ではない(道具と門自身を弾く)。
        # 名前で拾う木では、宣言が無い事**それ自体**を下の `undecl` が赤にする。
        if [ "$mode" = decl ] && [ -z "${decl// /}" ]; then continue; fi
        CTLS+=("$d/${_c##*/}")
        BASES+=("$base")
        DECLS+=("$decl")
    done
}
# glob を `*-controls.sh` から `*-control*.sh` へ広げてある: ios 側は単数形
# (ui-fixture-absence-control.sh)。rc-backend 側の集合は変わらない(実測 34 本 → 34 本)。
# ★この名前を backtick で囲まない事。囲むと「引いた名前が実在するか」の検査が走り、
#   ios の居ない**写しの木**(変異走行が使う)でだけ赤くなる —— commit の門は通って
#   走行の中で落ちる形になる。今夜これで2度倒した。

# ★★★2026-08-05: 走査先の一覧を **1本にする**(根治。band-aid を止めた)。
#
#   `.harness/` を足そうとして判った事: この門は同じ一覧を**手で同期する形で3箇所**
#   持っていた —— ①走査 dir の呼び出し ②「この staged path は見る木か」の case
#   ③「この staged path は対照そのものか」の case。①だけ広げても ② が
#   `rc-backend/*|ios/*` で弾くので、`.harness` の対照は**発見されても一度も回らない**。
#   実測: ① だけ足した状態で `STAGED_LIST_CMD='printf .harness/dod-sprint-3.sh'` を
#   撃つと「触れた対照は無い」。
#
#   これが 2026-08-02(`tools/` 欠落)/ 08-05 朝(`.git/hooks/pre-commit` の絞り込み)
#   と**同じ形が4回**続いた真因。1箇所広げた人は「広げた」と思い、残りが黙って縮める。
#   だから広げ方を直すのではなく、**一覧を1つにして残り2箇所を導出**する。
# 形は `走査 dir|宣言の基点|拾い方`。3つ目は省略可(既定 = name = 名前で拾う)。
SCAN_SPECS=(
    "rc-backend/test|rc-backend"        # 宣言は rc-backend からの相対(tools/foo.sh)
    "ios/tools|"                        # 宣言は repo の根から(ios/tools/foo.sh)
    ".harness|"                         # 同上。harness の道具は木を跨いで見張る
    "rc-backend/tools|rc-backend|decl"  # ★道具と対照が同居する木。宣言を持つ物だけ拾う
)
TREES=()   # 「この staged path を見るか」を決める木(走査 dir の第1成分)
for _spec in "${SCAN_SPECS[@]}"; do
    _d="${_spec%%|*}"; _rest="${_spec#*|}"; _b="${_rest%%|*}"; _m="${_rest#*|}"
    [ "$_m" = "$_b" ] && _m=name        # 3つ目が無い(= 2 field)時は名前で拾う
    _scan_ctls "$_d" "$_b" "$_m"
    _t="${_d%%/*}"
    case " ${TREES[*]-} " in *" $_t "*) ;; *) TREES+=("$_t") ;; esac
done
NCTL=${#CTLS[@]}

# ── 口: 見つけた対照を**全部**列挙する(2026-08-07)────────────────────────────
# なぜ足したか: 掃きの走行(`tools/run-controls.sh`)が「一覧に無い対照」を数える時、
# 走査 dir だけを此処の SCAN_SPECS から取り出して、**拾い方(3列目)は自前の名前 glob**
# を当てていた。上の注釈が名前 glob を測って捨てた理由をそのまま踏んでいる:
#   実測 2026-08-07:
#     偽陽性 4件 = tools/{run-controls,staged-controls-gate,prove-control,prove-all-controls}.sh
#                  (宣言が無いのに名前が当たる = 門が自分自身を対照だと言う)
#     偽陰性 2件 = tools/rc-backend-launch-check.sh / tools/serve-decision-check.sh
#                  (宣言は在るが名前が当たらない)。後者は**どの一覧にも無く、
#                  一度も回っていなかった** —— 「一度も回らない対照」を捕まえる為の
#                  検査が、まさにその1本を構造的に隠していた。
# ★直し方として「走行側で3列目も取り出す」を先に捨てた。それは述語の**写しが2枚**に
#   なるだけで、5回連続の再発を作ったのと同じ手。持っている側に聞く形にする。
# ★この口は `--would-select` と同じ規律で**判断しない**: undecl の停止も edith の除外も
#   通さず、見つけた物をそのまま出す。判断は本番の走行が出すのが正しい。
if [ "${1:-}" = "--all-controls" ]; then
    for _c in ${CTLS[@]+"${CTLS[@]}"}; do printf '%s\n' "$_c"; done
    exit 0
fi

# 導出①: staged path がこの門の見る木の中に在るか
_in_tree() {
    local _t
    for _t in "${TREES[@]}"; do
        case "$1" in "$_t"/*) return 0 ;; esac
    done
    return 1
}
# 導出②: staged path が**発見済みの対照そのもの**か(pattern の一覧を持たない。
#   走査で実際に見つけた物と突き合わせる = 定義上ズレようが無い)
_is_ctl() {
    local i=0
    while [ "$i" -lt "$NCTL" ]; do
        [ "${CTLS[$i]}" = "$1" ] && return 0
        i=$((i+1))
    done
    return 1
}

# staged な path を、その対照の基点から見た形に直す。基点の木の外なら**空**を返す
# (= その対照の宣言とは照合しない)。
_key() { # $1=staged path(根から) $2=基点
    case "$2" in
        "") printf '%s' "$1" ;;
        *)  case "$1" in "$2"/*) printf '%s' "${1#"$2"/}" ;; esac ;;
    esac
}

# ★ここから先は **path 展開を止める**(2026-08-05、S18 が実際に捕まえた)。
#   宣言を単語に割る `for _d in ${DECLS[$i]}` は引用しない = 分割と同時に **glob 展開**も
#   起きる。`tools/*.plist` と書いた宣言が、比較の前に**その時の cwd の実在 file 名**へ
#   化けていた —— 砂場で測っているのに本物の repo の plist に展開されていた。
#   `case` の右辺の pattern 照合は `set -f` の影響を受けないので、宣言側の glob は効いたまま。
set -f

# 宣言先が実在しない対照を拾う(glob は素通し = 何にも当たらない glob は判定しない)。
stale=""
i=0
while [ "$i" -lt "$NCTL" ]; do
    for _d in ${DECLS[$i]}; do
        # `external:…` = repo の外に在る道具(`~/.claude/tools/remote-mini.sh` 等)。
        #   staged な path からは原理的に選べないので、実在も照合もしない。**書かせる**のは
        #   「宣言し忘れ」と「そもそも repo に無い」を区別する為 —— 空欄だと前者に見える。
        case "$_d" in external:*|*[*?[]*) continue ;; esac
        _b="${BASES[$i]}"
        [ -e "$ROOT/${_b:+$_b/}$_d" ] || stale="$stale ${CTLS[$i]##*/}→${_d}"
    done
    i=$((i+1))
done

undecl=""
while IFS= read -r f; do
    [ -n "$f" ] || continue
    _in_tree "$f" || continue          # 導出①(SCAN_SPECS から。手書きの木一覧は持たない)

    hit=0
    # (a) 対照そのものが staged —— 導出②
    if _is_ctl "$f" && [ -f "$ROOT/$f" ]; then         # 削除された対照は回さない
        add_sel "$f"; hit=1
        # ★宣言の無い対照は「静かに回らない対照」になる。書く瞬間に止める。
        i=0
        while [ "$i" -lt "$NCTL" ]; do
            if [ "${CTLS[$i]}" = "$f" ] && [ -z "${DECLS[$i]// /}" ]; then
                undecl="$undecl ${f##*/}"
            fi
            i=$((i+1))
        done
    fi

    # (b) この file を見張ると宣言している対照(名前の一致には頼らない)
    i=0
    while [ "$i" -lt "$NCTL" ]; do
        # 基点が違えば見る形も違う。木の外なら空が返り、照合しない。
        k="$(_key "$f" "${BASES[$i]}")"
        if [ -n "$k" ]; then
            for _d in ${DECLS[$i]}; do
                # `case` の右辺は**引用しない** = 宣言側の glob をそのまま効かせる為
                case "$k" in $_d) add_sel "${CTLS[$i]}"; hit=1; break ;; esac
            done
        fi
        i=$((i+1))
    done

    # (c) 見張る物が1本も無い道具は名前を出す(止めない)
    if [ "$hit" -eq 0 ] && [ -f "$ROOT/$f" ]; then
        case "$f" in
            # ★`.harness/*.sh` も入れる: 木を足した時に**注記の側だけ痩せる**のを塞ぐ。
            #   走査と選択は SCAN_SPECS から導出されるが、此処は「道具らしい path」の
            #   形の話なので導出できない。木を足したら1行足す事(この行が忘れられても
            #   commit は止まらない = 静かに分母が痩せる形なので、対照 S38 で見張る)。
            rc-backend/tools/*|rc-backend/test/*.py|ios/tools/*|.harness/*.sh)
                # ★2026-08-07: 「対照が要らない理由」を**その file 自身に**書けば名前を
                #   引っ込める。理由は 12 字以上でないと数えない —— 空白や `x` で黙らせ
                #   られるなら、免除は必ず判子になる。短い理由は免除にならず名前が残る
                #   ので、判子を押しても何も買えない(門を止める必要が無い = 自己強制)。
                # 区切りは `|`。行頭の飾りに `/` が入る(`// no-control:`)ので、
                # `/` を区切りにすると bracket の中で切れる実装が在る。
                _nc="$(/usr/bin/sed -n 's|^[#/[:space:]*]*no-control:[[:space:]]*||p' "$ROOT/$f" \
                       | /usr/bin/head -1)"
                _nc="${_nc#"${_nc%%[![:space:]]*}"}"      # 前後の空白を落とす
                _nc="${_nc%"${_nc##*[![:space:]]}"}"
                if [ "${#_nc}" -ge 12 ]; then
                    exempt=$((exempt+1))
                else
                    orphan="$orphan ${f##*/}"
                fi
                ;;
        esac
    fi
done <<EOF
$staged
EOF

# ---- 「回すなら何が回るか」だけ答えて帰る口(ここから)------------------------
# 何故要るか(2026-08-06 に初めて数えた): 呼ぶ側の `pre-commit-gates.sh` は
# 「この commit に門の対象が入っているか」を**手書きの regex** で当てていて、それが
# ここの `SCAN_SPECS` と**手で同期する 2 本目の一覧**になっていた。
# 全対照の宣言 75 本を 1 本ずつ当てた実測: 74 本は届き、`rc-backend/package.json` の
# 1 本だけが届かない —— その file だけの commit は、その対照どころか
# `npm test` の門(commit-suite-gate)ごと飛ぶ。
# ★regex に 1 行足すのは**手書き同期の 6 個目**で、5 回連続の再発を作ったのと同じ手。
#   代わりに「持っている側に聞く」形にする。一覧はこの file の `SCAN_SPECS` 1 本のまま、
#   届く範囲は下流の能力に自動で追随する。
# ★この口は**判断しない**。注記(orphan / stale)も停止(undecl)も出さず、選択だけ答える。
#   聞く側が要るのは有無だけで、注記も停止も**本番の走行**が出すのが正しい ——
#   ここで止めると「聞いただけ」で commit が落ちる。
#
# ★★`--list`(この file の下の方)と**似ているが別物**。足した後で気付いたので、
#   3 つ目を作らせない為に違いをここに書く。選択の道(`$sel`)は完全に共有していて、
#   別実装は持たない —— 違うのは**どこで帰るか**だけ:
#     `--would-select` = undecl の停止より**前**・edith の除外より**前**・装飾なし。
#     `--list`         = undecl で `exit 1`・edith 側を落とした後・`SEL` 付きの人向け。
#   呼ぶ側(`pre-commit-gates.sh`)にはこの口でなければならない理由が 2 つ在る:
#     ① `--list` は選択が空でも `触れた対照は無い` と喋る = 呼ぶ側の「空か」判定
#        (`[ -z "$(…)" ]`)が**常に非空**になり、絞り込みが素通しに化ける。
#     ② `--list` は edith 側を落とすので、落ちた結果が空だと呼ぶ側は「門ごと不要」と
#        読む。本当に要るのは `commit-suite-gate` の側 —— **落とす前**の答えが要る。
#   結果、この口の答えは `--list` の**上位集合**になる(対照 S47 で明示)。
#   commit を止める向きに外れるので、安全側。
# ★`set -f` はまだ効いている位置に置く(下の `set +f` より前)。`$sel` の分割で
#   path が glob 展開されない為。
if [ "${1:-}" = "--would-select" ]; then
    for _c in $sel; do printf '%s\n' "$_c"; done
    exit 0
fi
# ---- 「回すなら何が回るか」だけ答えて帰る口(ここまで)------------------------

set +f   # 宣言の照合はここまで。以降は普通の展開に戻す

if [ -n "$orphan" ]; then
    echo "staged-controls-gate: 注記 — 対照を導けない道具:$orphan"
    # ★ここを二重引用符 + backtick で書くと `test/...` が**命令として実行される**
    #   (しかも `<名前>` は「名前」という file からの入力の意味になる)。
    #   この repo で既に同じ形を踏んでいるので、注記は単一引用符で出す。
    echo '  (対照の頭に `# controls-for: <この道具の path>` を足せば自動で回る。止めはしない)'
fi

# ★免除は**必ず本数を出す**。0 本の時だけ黙る。
#   理由: 此処が黙ると「名前が出ていない = 穴が無い」と読める。実際には
#   2026-08-02〜08-07 の5日間、注記は4本の本物の穴を正しく名指ししていたのに
#   9本の既知と混ざって読み飛ばされた —— 減らすべきは穴ではなく**紛れ**で、
#   紛れを消した代わりに「免れた物が何本在るか」は常に見える所へ出す。
if [ "$exempt" -gt 0 ]; then
    echo "staged-controls-gate: 注記 — 理由を宣言して免れた道具 ${exempt} 本(no-control:)"
fi

if [ -n "$stale" ]; then
    echo "staged-controls-gate: 注記 — 宣言先が実在しない対照:$stale"
    echo '  (道具を改名したなら宣言も付け替える事。宣言が外れた対照は誰にも呼ばれない)'
fi

if [ -n "$undecl" ]; then
    echo "staged-controls-gate: ★commit しない: 見張る対象を宣言していない対照:$undecl"
    echo '  対照の2行目あたりに1行足す(rc-backend からの相対。glob 可、複数可):'
    echo '    # controls-for: tools/deploy-to-edith.sh'
    echo '  宣言の無い対照は、その道具だけを直す commit で**静かに回らない**。'
    echo '  2026-08-05 に実測した穴がこれ(名前が一致する時だけ当たっていた)。'
    exit 1
fi

if [ -z "$sel" ]; then
    echo "staged-controls-gate: 触れた対照は無い"
    exit 0
fi

# ── edith 側の対照は**此処では回さない**(2026-08-05、選び方を宣言へ替えた副作用)────
#   宣言から選ぶ様にした結果、`test/mutation-controls.py` を触る commit が 6 本を選ぶ様に
#   なった。その中に `env-death` が居る = **ssh が通らないと 2(未測定)= commit が止まる**。
#   Tom は移動中に commit する(それがこの repo の目的そのもの)ので、機内で
#   `test/e2e-local.mjs` を1行直すと commit できない、という形になる。
#   だから edith 側は**名前を出して回さない**。黙って落とすと「触れた対照は全部緑」が
#   また分母の痩せた緑になるので、落とした事を毎回書く(この repo の「上限を黙って
#   掛けない」規則)。一覧の正本は `run-controls.sh` の `EDITH_CTLS` —— 写しを持たない。
EDITH_LIST=""
if [ -r "$ROOT/rc-backend/tools/run-controls.sh" ]; then
    EDITH_LIST="$(/usr/bin/sed -n '/^EDITH_CTLS=(/,/^)/p' "$ROOT/rc-backend/tools/run-controls.sh" \
        | /usr/bin/grep -oE '^ *test/[A-Za-z0-9._-]+\.sh' | /usr/bin/tr -d ' ' | /usr/bin/tr '\n' ' ')"
fi
deferred=""
if [ -n "$EDITH_LIST" ]; then
    keep=""
    for c in $sel; do
        case " $EDITH_LIST " in
            *" ${c#rc-backend/} "*) deferred="$deferred ${c##*/}" ;;
            *) keep="$keep $c" ;;
        esac
    done
    sel="$keep"
fi
if [ -n "$deferred" ]; then
    echo "staged-controls-gate: 此処では回さない(edith 側の対照):$deferred"
    echo '  手元では測れない(ssh が要る)。commit は止めない代わりに、配備の前に'
    echo '    bash rc-backend/tools/run-controls.sh --all'
    echo '  で回す事。**回していない = 緑ではない**。'
fi

if [ -z "$sel" ]; then
    echo "staged-controls-gate: 手元で回せる対照は無い"
    exit 0
fi

n=0; for c in $sel; do n=$((n+1)); done

# `--list` = **人向け**に選び方だけを見せて回さない(機械向けは上の `--would-select`。
#   違いは上のブロックに書いた: こちらは undecl で止まり、edith 側を落とした後を見せる)。
#   選択の当たり外れを測る時に本体を回すと
#   `copied-tree` が写した木で `npm test` を回す等で分単位になり、測りたい物(選択)と
#   関係無い所で待たされる。選択の道は完全に共有しているので、`--list` の結果は
#   本番の選択そのもの —— 別実装を持たない事がこの口の条件。
if [ "${1:-}" = "--list" ]; then
    echo "staged-controls-gate: 触れた対照 ${n} 本(--list = 回さない)"
    for c in $sel; do echo "  SEL    ${c##*/}"; done
    exit 0
fi

echo "staged-controls-gate: 触れた対照 ${n} 本を回す(長い物が在る。--no-verify は使わずに待つ事)"

red=0; unm=0; green=0; red_names=""; unm_names=""
for c in $sel; do
    t0=$(date +%s)
    out="$(cd "$ROOT" && bash "$c" 2>&1)"; rc=$?
    t1=$(date +%s)
    last="$(printf '%s' "$out" | /usr/bin/tail -1)"
    case "$rc" in
        0) green=$((green+1)); printf '  GREEN  %-36s %3ds  %s\n' "${c##*/}" "$((t1-t0))" "$last" ;;
        2) unm=$((unm+1)); unm_names="$unm_names ${c##*/}"
           printf '  UNMEA  %-36s %3ds  %s\n' "${c##*/}" "$((t1-t0))" "$last" ;;
        *) red=$((red+1)); red_names="$red_names ${c##*/}"
           printf '  RED    %-36s %3ds  %s\n' "${c##*/}" "$((t1-t0))" "$last"
           printf '%s' "$out" | /usr/bin/grep -E '^\s*(NG|not ok|★)' | /usr/bin/head -8 | /usr/bin/sed 's/^/         /' ;;
    esac
done

if [ "$red" -gt 0 ]; then
    # ★`$var` の直後に日本語を置くと、変数名がそこまで伸びて `unbound variable` になる
    #   (ロケール依存。この repo で既に踏んでいる)。展開は必ず `${var}` と書く。
    echo "staged-controls-gate: ★触れた対照が赤い(${red}本):${red_names}。commit を止めた"
    exit 1
fi
if [ "$unm" -gt 0 ]; then
    echo "staged-controls-gate: ★測れなかった対照が在る(${unm}本):$unm_names"
    echo "  緑ではない。条件が揃ってから回し直す事(変異の走行中など)"
    exit 2
fi
# ★緑の判定だけに出る綴りにする(「触れた対照 N 本を回す」の予告と**前置きを共有しない**)。
#   共有していると、対照が「緑と言っていない事」を測れない —— 予告の方に当たってしまう。
# ★分母は `$n`(= 選んだ本数)。旧版は `${green}/${green}` = **緑の数を緑の数で割って**
#   いたので、赤が無ければ常に満点だった。導出が痩せた時に比が痩せないのが穴の本体で、
#   宣言から選ぶ様にした今も、分母は「選んだ集合」であって「在る対照の総数」ではない
#   —— そこは (c) の注記と `undecl` の門で守る。
echo "staged-controls-gate: 触れた対照は全部緑(${green}/${n})"
exit 0
