#!/bin/bash
# mutation-sandbox.sh — 変異対照が**作業中の木を1バイトも触らずに**測る為の土台。
# `source` して使う(単体では何もしない)。
#
# ── なぜ要るか(CF-12 / CF-21)──────────────────────────────────────────────
# 変異対照は `ios/Sources/**` をその場で書き換えて測り、`trap` で戻す。走行が殺されると
# trap は走らず、変異が木に残る。実際に起きた: 3本の変異が残り、**焼く3分前**に
# `git status` で気付いた —— 単体も UI も、その間ずっと緑だった。
#
# ── 何を選び、何を選ばなかったか(2026-08-30、Codex 査読)────────────────────
#   A 走行ごとに使い捨ての木     … 隔離は完全だが derived data が path 依存なので
#                                  **毎回コールドビルド**。今の掃引が既に約 25 分。
#   B **固定 path の砂場**(採用)… 初回だけ冷たく、以降は温かい。disk は 875MB 程度が1つ増える。
#   C その場で変異させたまま     … 費用 0 だが「露出している窓」は消えない ——
#     台帳で復旧可能にする         其の間に別のビルド・索引・人が変異を観測しうる。
#                                  ★C は**深層防御としては有効**(既存の残骸検知器が其の層)。
#                                  A/B と守る物が違うので、置き換えではなく重ねる。
#
# ★Codex の一線: 之が証明するのは「**この対照は snapshot H に対して走った**」であって
#   「今 出荷される物」ではない。出荷経路には独自の clean-tree / 残骸の事前検査が要る ——
#   其れは `ios/tools/adhoc-ota.sh` の汚れ検査と `mutation-residue-check.sh` が持っている。
#   此の file が肩代わりしていると読まない事。
#
# ★同期は **fail-closed**。B の本当の危険は砂場が本物からずれる事で、其の時 対照は
#   **出荷される物ではないコード**に対して緑を出す —— 此の repo が何度も踏んだ型。
#   だから: 全ビルド入力を `--delete` 付きで同期 → 指紋を突き合わせ → 走行後に
#   **本物の側の指紋を取り直す**(走行中に変わっていたら結果は stale)。
#
# ── 使い方 ──────────────────────────────────────────────────────────────────
#   . "$IOS/tools/mutation-sandbox.sh"
#   ms_prepare || exit 2          # 同期して検める。以降 $MS_TREE が砂場の ios/
#   … $MS_TREE/Sources/… を書き換えて $MS_TREE でビルド …
#   ms_assert_live_unchanged || exit 2
#   (片付けは呼ぶ側の trap で ms_release)
#
# 砂場の置き場は**repo の外**。`ios/` の下に置くと、生成木の走査に巻き込まれる道が残る。
# no-operator: `source` される土台で、単体で走る物ではない。呼び手は
#   `ios/tools/inflight-sentence-control.sh` と `list-return-refresh-control.sh`
#   (借金を減らすたびに増える)。挙動は其れらの対照が回る時に一緒に測られる ——
#   同期が壊れれば `ms_prepare` が測定不成立で落ち、呼び手が 2 で止まる。
set -uo pipefail

MS_ROOT="${RC_MUTATION_SANDBOX:-$HOME/.rc-mutation-sandbox}"
MS_TREE="$MS_ROOT/ios"
MS_LOCK="$MS_ROOT/.lock"
MS_LIVE_IOS=""
MS_HASH_BEFORE=""

# ★同期する物は**ビルド入力の全部**。Swift だけを写すと、`project.yml` や資産を
#   変えた日に砂場が古い定義でビルドし、緑が別の版を指す(Codex の指摘2)。
#   ここに足し忘れる事が此の設計の唯一の急所なので、一覧は1箇所にだけ置く。
MS_INPUTS="Sources Tests UITests Assets.xcassets project.yml Info.plist"

ms__live_ios() {
    [ -n "$MS_LIVE_IOS" ] && { printf '%s' "$MS_LIVE_IOS"; return 0; }
    local d; d="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    MS_LIVE_IOS="$d"; printf '%s' "$d"
}

# ビルド入力の指紋。**同じ物を本物と砂場の両方で取る**(別々の取り方だと突き合わせが嘘になる)。
ms__fingerprint() {  # ms__fingerprint <ios dir>
    local base="$1" p
    for p in $MS_INPUTS; do
        [ -e "$base/$p" ] || continue
        if [ -d "$base/$p" ]; then
            find "$base/$p" -type f -print0 2>/dev/null | LC_ALL=C sort -z \
                | xargs -0 shasum -a 256 2>/dev/null | sed "s|$base/||"
        else
            shasum -a 256 "$base/$p" 2>/dev/null | sed "s|$base/||"
        fi
    done | shasum -a 256 | awk '{print $1}'
}

# ★`rm -rf` は使わない(この環境の禁止事項)。file を消してから dir を深い順に畳む。
ms__wipe() {  # ms__wipe <dir>
    [ -n "${1:-}" ] && [ -d "$1" ] || return 0
    find "$1" ! -type d -print0 2>/dev/null | xargs -0 /bin/rm -f 2>/dev/null
    find "$1" -depth -type d -exec /bin/rmdir {} + 2>/dev/null
    return 0
}

ms_release() {
    [ -n "${MS_LOCK:-}" ] && [ -d "$MS_LOCK" ] || return 0
    # ★**自分の錠だけ**返す。他人の錠を返すと、走っている相手の下で砂場が入れ替わる。
    local owner=""
    [ -f "$MS_LOCK/pid" ] && owner="$(cat "$MS_LOCK/pid" 2>/dev/null)"
    [ -n "$owner" ] && [ "$owner" != "$$" ] && return 0
    /bin/rm -f "$MS_LOCK/pid" 2>/dev/null
    /bin/rmdir "$MS_LOCK" 2>/dev/null
    return 0
}

# 砂場を本物に合わせ、合った事を確かめる。0=使ってよい / 2=測定不成立
ms_prepare() {
    local live; live="$(ms__live_ios)"
    mkdir -p "$MS_ROOT" 2>/dev/null || { echo "mutation-sandbox: 置き場を作れない: $MS_ROOT" >&2; return 2; }

    # ★**直列化**(Codex の指摘4)。砂場も derived data も共有なので、2本同時は互いを壊す。
    #   `mkdir` は原子的なので錠に使える。取れなければ持ち主を名指しして降りる。
    if ! mkdir "$MS_LOCK" 2>/dev/null; then
        # ★**持ち主の生死で取り直す**(2026-08-30、実測で詰まった)。
        #   錠を `mkdir` だけで持つと、走行が殺された1回で**以後すべてが詰まる** ——
        #   人が `rmdir` するまで全対照が「砂場が使用中」で測定不成立になる。
        #   実際に其れが起き、繰り延べ対照が 15 本 赤くなった。
        #   直列化の為の錠が、直列化ごと止める道具になっていた。
        local owner=""
        [ -f "$MS_LOCK/pid" ] && owner="$(cat "$MS_LOCK/pid" 2>/dev/null)"
        case "${owner:-}" in ''|*[!0-9]*) owner="" ;; esac
        if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
            echo "mutation-sandbox: 砂場が使用中(pid $owner が生きている)。同時に2本は走らせない" >&2
            return 2
        fi
        # 持ち主が居ない = 残骸。★取り直した事を**必ず言う**(黙って奪うと、
        #   本当に2本走っていた時に片方が黙って壊れる)。
        echo "mutation-sandbox: 錠の持ち主が居ない(pid=${owner:-不明})。残骸として取り直す" >&2
        /bin/rm -f "$MS_LOCK/pid" 2>/dev/null
        /bin/rmdir "$MS_LOCK" 2>/dev/null
        mkdir "$MS_LOCK" 2>/dev/null || {
            echo "mutation-sandbox: 錠を取り直せない($MS_LOCK)" >&2; return 2; }
    fi
    printf '%s' "$$" > "$MS_LOCK/pid" 2>/dev/null

    # ★**前の走行の変異が残っていないか**を先に見る(Codex の指摘4)。
    #   残ったまま同期すると、`--delete` で消えるとはいえ「消えた事」を誰も確かめない。
    mkdir -p "$MS_TREE" 2>/dev/null

    # 同期。`--delete` で**本物に無い物は砂場からも消す**。
    local p rc=0
    for p in $MS_INPUTS; do
        if [ -d "$live/$p" ]; then
            rsync -a --delete "$live/$p/" "$MS_TREE/$p/" 2>/dev/null || rc=1
        elif [ -f "$live/$p" ]; then
            rsync -a "$live/$p" "$MS_TREE/$p" 2>/dev/null || rc=1
        else
            # 本物に無い物は砂場からも消す(一覧に足したが repo から消えた場合)
            [ -e "$MS_TREE/$p" ] && { ms__wipe "$MS_TREE/$p"; /bin/rm -f "$MS_TREE/$p" 2>/dev/null; }
        fi
    done
    if [ "$rc" -ne 0 ]; then
        echo "mutation-sandbox: 同期に失敗した = 測定不成立" >&2; ms_release; return 2
    fi

    # ★突き合わせる。同期が通っただけでは「同じ」を意味しない。
    MS_HASH_BEFORE="$(ms__fingerprint "$live")"
    local got; got="$(ms__fingerprint "$MS_TREE")"
    if [ -z "$MS_HASH_BEFORE" ] || [ "$MS_HASH_BEFORE" != "$got" ]; then
        echo "mutation-sandbox: 砂場が本物と一致しない = 測定不成立" >&2
        echo "  本物=$MS_HASH_BEFORE 砂場=$got" >&2
        echo "  ★一致しない砂場で緑を出すと、**出荷されない版**に対する緑になる" >&2
        ms_release; return 2
    fi
    # ★**成功時は黙る**(2026-08-30)。最初は stdout、次に stderr へ書いたが、どちらも
    #   呼び手の出力を読む側を壊した —— `mutation-deferral-control.sh` は
    #   `--which` の出力を `2>&1` で丸ごと捕まえて本数を数えるので、
    #   **どちらの流れに書いても**混ざる。source される土台は、成功したら何も言わない。
    #   失敗は喋る(上の枝は全部 stderr へ書いて非ゼロで帰る)。
    #   指紋を人が見たい時は `RC_MUTATION_SANDBOX_VERBOSE=1`。
    [ -n "${RC_MUTATION_SANDBOX_VERBOSE:-}" ] && \
        echo "mutation-sandbox: 同期 ok(指紋 ${MS_HASH_BEFORE:0:12}… / $MS_TREE)" >&2
    return 0
}

# 走行が本物の木を1バイトも触っていない事を、走行後に確かめる。
# ★「触らない設計だから触っていない」は証明ではない —— 設計が守られたかを測る。
ms_assert_live_unchanged() {
    local live; live="$(ms__live_ios)"
    local now; now="$(ms__fingerprint "$live")"
    if [ "$now" != "$MS_HASH_BEFORE" ]; then
        echo "mutation-sandbox: ★走行中に**本物の木が変わった**。結果は信用できない" >&2
        echo "  前=$MS_HASH_BEFORE 後=$now" >&2
        echo "  (対照が本物を触ったか、別の何かが同時に触った。どちらでも結果は stale)" >&2
        return 1
    fi
    return 0
}
