#!/bin/bash
# controls-for: tools/wire-shape.mjs
# `tools/wire-shape.mjs` が**中身を伏せるか**を測る対照。
#
# ── なぜ要るか ──────────────────────────────────────────────────────────
# この道具は本番の一覧を叩く。一覧には会話の題・直近の発言・作業 dir が載る =
# Tom の仕事の中身そのもの。伏せ方が壊れても**出力は今までどおり綺麗に見える**ので、
# 壊れた事は「出てはいけない物が出た後」にしか判らない。それでは遅い。
#
# ★網も鍵も要らない。道具の `-`(標準入力)口を使う —— 畳み方と伏せ方は網と無関係な
#   純粋な処理なので、本番を叩かずに測れる。測るのに本番が要る造りだと、対照は書かれない。
#
# ── 測る5つ ────────────────────────────────────────────────────────────
#   ① 伏せる鍵(title / lastPrompt / cwd / text / subtitle / **paneFault.detail**)の値が出ない
#   ② 出してよい鍵(route / kind / short / **paneFault.reason**)の値は**出る**(= ①の錨)
#   ③ 一部の要素にしか無い鍵は `(N/M)` が付く            (= optional を必須と読ませない)
#   ④ 形の違う要素を混ぜても、片方の形に**畳まない**
#   ⑤ 鍵が無い時に網の口は 2(未測定)で止まる            (= 鍵無しで本番へ飛ばない)
#
# ★②が要る理由: 「出てはいけない物が出ていない」は、道具が**何も出さなくても**緑になる。
#   出てよい物が出ている事を同時に測って初めて、①の緑が意味を持つ。
#
# ★赤くなる事の実測(2026-08-05): `RC_WIRESHAPE_TOOL` に**畳む様に壊した写し**
#   (変種を最初の1つだけ採り、欠けの `(N/M)` も付けない版)を差して回したところ
#   ②③④が赤・①⑤が緑 = 狙った3つだけが倒れた。巻き添えではない。
#   ①も同じ口で実測: `VALUE_KEYS` に `"detail"` を足した写しを差すと
#   `FAIL ① (出た: SENTINEL-DETAIL)` の1本だけが赤、②③④⑤は緑のまま。
#   = 5本とも「壊せば赤くなる」事が測ってある。
#
# 終了コード: 0 = 全部期待どおり / 1 = どれかが違う / 2 = 測れなかった
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# ★測る対象を差し替えられる口。`tools/prove-control.sh` が**壊した写し**を差して
#   「この対照は本当に赤くなるのか」を測る為に要る。口が無いと、証明する唯一の手が
#   live の道具を `sed -i` で壊す事になり、復元に失敗した時 repo が壊れたまま残る
#   (`prove-control.sh` の頭に在る作法。`RC_LINEREF_TEST` と同じ形)。
TOOL="${RC_WIRESHAPE_TOOL:-$ROOT/tools/wire-shape.mjs}"
NODE="${RC_NODE_BIN:-node}"

pass=0; fail=0
ok() { pass=$((pass+1)); echo "PASS  $1"; }
ng() { fail=$((fail+1)); echo "FAIL  $1  ($2)"; }

[ -f "$TOOL" ] || { echo "測れない: 道具が居ない ($TOOL)"; exit 2; }
command -v "$NODE" >/dev/null 2>&1 || { echo "測れない: node が居ない"; exit 2; }

SCRATCH="$(mktemp -d /tmp/rc-wireshape.XXXXXX)" || exit 2
cleanup() {
    find "$SCRATCH" -type f -print0 2>/dev/null | xargs -0 /bin/rm -f 2>/dev/null
    find "$SCRATCH" -type d -depth -exec /bin/rmdir {} \; 2>/dev/null
}
trap cleanup EXIT

# 本番の一覧と同じ形。中身は全部**目印**にしてある(出たら一発で判る)。
# ★目印を「秘密らしい文字列」にしない —— 失敗した時にこの台本自身が目印を印字するので、
#   本物を混ぜると対照が漏洩経路になる(「秘密を守る検査が、失敗の説明で秘密を刷る」型)。
cat >"$SCRATCH/payload.json" <<'JSON'
{
  "sessions": [
    {
      "id": "SENTINEL-ID",
      "title": "SENTINEL-TITLE",
      "cwd": "SENTINEL-CWD",
      "lastPrompt": "SENTINEL-PROMPT",
      "updatedAt": "2026-08-05T00:00:00.000Z",
      "metadataIncomplete": false,
      "live": { "route": "tmux", "pane": "SENTINEL-PANE", "screen": "SENDABLE", "limited": false },
      "display": { "route": { "kind": "tmux", "short": "机・静か", "text": "SENTINEL-TEXT", "screen": "SENDABLE" },
                   "subtitle": "SENTINEL-SUBTITLE" }
    },
    {
      "id": "SENTINEL-ID2",
      "title": "SENTINEL-TITLE2",
      "cwd": "SENTINEL-CWD2",
      "lastPrompt": null,
      "updatedAt": "2026-08-05T00:00:00.000Z",
      "metadataIncomplete": false,
      "fromRegistryOnly": true,
      "live": { "route": "worker", "worker": "SENTINEL-WORKER", "state": "idle", "queued": 0 },
      "display": { "route": { "kind": "worker", "short": "ワーカー・idle", "text": "SENTINEL-TEXT2", "screen": "" },
                   "subtitle": "SENTINEL-SUBTITLE2" }
    }
  ],
  "scan": { "scope": "all", "limit": 0, "files": 2, "read": 2, "cached": 0, "examined": 2 },
  "display": { "scan": "SENTINEL-SCANLINE" },
  "paneFault": { "reason": "tmux-missing", "detail": "SENTINEL-DETAIL" }
}
JSON

"$NODE" "$TOOL" - <"$SCRATCH/payload.json" >"$SCRATCH/out.txt" 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then
    echo "測れない: 道具が標準入力の口で落ちた (rc=$rc)"
    cat "$SCRATCH/out.txt"
    exit 2
fi

# ── ① 伏せる鍵の値が出ていない ────────────────────────────────────────
leaked=""
# ★`SENTINEL-DETAIL` = `paneFault.detail`。**此処が一番危ない鍵**である —— 故障の説明は
#   自由記述で、tmux の pane 名や作業 dir の path をそのまま載せうる。`reason` は閉じた語彙
#   なので値を残すが、`detail` は残さない。この2つを同じ本文で同時に測る事に意味が在る
#   (「`paneFault` の中は全部伏せる/全部出す」のどちらに倒しても、片方が赤くなる)。
for s in SENTINEL-TITLE SENTINEL-PROMPT SENTINEL-CWD SENTINEL-TEXT SENTINEL-SUBTITLE SENTINEL-SCANLINE SENTINEL-PANE SENTINEL-WORKER SENTINEL-DETAIL; do
    grep -q "$s" "$SCRATCH/out.txt" && leaked="$leaked $s"
done
if [ -z "$leaked" ]; then
    ok "① 伏せる鍵の値は出力に出ない"
else
    ng "① 伏せる鍵の値は出力に出ない" "出た:$leaked"
fi

# ── ② 出してよい鍵の値は出る(①の錨) ────────────────────────────────
# ★探す形は `\"tmux\"`(引用符ごと)。道具は「値を残した」事を引用符で名乗るので、
#   裸の `tmux` を探すと**鍵の名前**に当たって緑になる —— 実際に初回はそれで
#   `"worker"` だけが通り、他3つが赤くなって取り違えが出た(鍵 `worker` に当たっていた)。
missing=""
for s in '\"tmux\"' '\"worker\"' '\"机・静か\"' '\"SENDABLE\"' '\"tmux-missing\"'; do
    grep -qF "$s" "$SCRATCH/out.txt" || missing="$missing $s"
done
if [ -z "$missing" ]; then
    ok "② 出してよい鍵の値は出る(①が空振りでない)"
else
    ng "② 出してよい鍵の値は出る" "出ていない:$missing"
fi

# ── ③ 一部にしか無い鍵は (N/M) が付く ────────────────────────────────
if grep -q 'fromRegistryOnly (1/2)' "$SCRATCH/out.txt"; then
    ok "③ 片方にしか無い鍵は (1/2) と名乗る"
else
    ng "③ 片方にしか無い鍵は (1/2) と名乗る" "必須と見分けが付かない形で出ている"
fi

# ── ④ 形の違う要素を片方へ畳まない ────────────────────────────────────
# tmux 行と worker 行は鍵の集合が違う。畳んでしまうと「どちらの経路でも同じ形」という
# 嘘の観測になり、電話側は1つの struct で書いて worker 行を取りこぼす。
if grep -qF '"pane"' "$SCRATCH/out.txt" && grep -qF '"worker"' "$SCRATCH/out.txt"; then
    ok "④ 経路で形が違う事が出力に残る"
else
    ng "④ 経路で形が違う事が出力に残る" "片方の形へ畳まれている"
fi

# ── ⑤ 鍵が無い時、網の口は 2(未測定)で止まる ───────────────────────
# ★網へ飛ぶ前に止まる事を測る。ここが 0/1 だと「鍵無しで本番を叩いた」が緑に紛れる。
env -u RC_KEY "$NODE" "$TOOL" /api/sessions >"$SCRATCH/nokey.txt" 2>&1
if [ "$?" -eq 2 ]; then
    ok "⑤ 鍵が無ければ 2(未測定)で止まる"
else
    ng "⑤ 鍵が無ければ 2(未測定)で止まる" "止まらない = 鍵無しで網へ飛ぶ道が在る"
fi

echo
echo "PASS $pass / FAIL $fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
