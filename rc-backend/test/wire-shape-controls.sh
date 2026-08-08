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
# ── 測る物 ──────────────────────────────────────────────────────────────
#   ① 伏せる鍵(title / lastPrompt / cwd / text / subtitle / **paneFault.detail**)の値が出ない
#   ② 出してよい鍵(route / kind / short / **paneFault.reason**)の値は**出る**(= ①の錨)
#   ③ 一部の要素にしか無い鍵は `(N/M)` が付く            (= optional を必須と読ませない)
#   ④ 形の違う要素を混ぜても、片方の形に**畳まない**
#   ⑤ 鍵が無い時に網の口は 2(未測定)で止まる            (= 鍵無しで本番へ飛ばない)
#   ⑥ `{id}` に差し込んだ session id が**出力に出ない**
#   ⑦ 印字されるのは差し込む前の雛形                     (= ⑥の錨。無出力を緑と読ませない)
#   ⑧ 差し込みが**実際に起きている**(偽サーバに届いた道で測る)
#   ⑧-b `RC_SESSION_INDEX` で何本目かを選べる
#   ⑨ 一覧に無い番号は 2(未測定)                        (= 赤と未測定を混ぜない)
#   ⑩ 復旧語彙(`code` / `errno`)の値は**読める** / ⑩-b その隣の自由文は潰れる
#   ⑪ `RC_EXPECT_STATUS` と違う status の本文は**畳まない**
#   ⑫ 期待と一致すれば 200 以外でも畳む(= ⑪の錨) / ⑫-b それでも自由文は潰れる
#   ⑬ ★`RC_METHOD` が id 解決の一覧引きへ**伝播しない** / ⑬-b 本番の口には効いている
#   ⑭ 送った本文(`RC_BODY`)の中身は出ない / ⑭-b バイト数は出る / ⑭-c 400 の自由文も潰れる
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
# ★`{id}` の口(⑥〜⑨)も同じ口で実測(2026-08-05)。**旧版と比べるだけでは足りない** ——
#   旧版は `{id}` を知らないので偽サーバが 404 を返し、4本まとめて倒れる = どの検査が
#   何を見分けているのかが判らない。見分けたいのは旧版ではなく**雑な実装**なので、
#   狙い撃ちの変異を4つ作って1本ずつ当てた:
#     | 差した物                                   | 倒れた検査          |
#     | 差し込み**済み**の道を印字する版           | ⑥ ⑦(この2本だけ) |
#     | id を解決せず固定文字列を差し込む版        | ⑧ ⑧-b ⑨          |
#     | `RC_SESSION_INDEX` を見ず常に 0 本目の版   | ⑧-b ⑨             |
#     | 範囲外を 1(赤)で返す版                    | ⑨(これだけ)      |
#   ⑧ の単独の見分け役は2つ目、⑨ の単独は4つ目。⑧-b と ⑨ は3つ目で同時に倒れるが、
#   4つ目で ⑨ だけが倒れる = 2本は別の物を測っている。
#
# ★⑩〜⑭(status を狙う口 / 打ち込む口)も同じ作法で実測(2026-08-05):
#     | 差した物                                    | 倒れた検査              |
#     | 一覧引きが `RC_METHOD` を継ぐ版             | ⑬ ⑬-b + ⑭ ⑭-b(巻添)  |
#     | `RC_EXPECT_STATUS` を見ず何でも畳む版       | ⑪(これだけ)           |
#     | 200 以外は畳まない旧作法の版                | ⑫ + ⑭ ⑭-b(巻添)      |
#     | 送った本文を出力に載せる版                  | ⑭(これだけ)           |
#     | 本番の口にも method が効かない版            | ⑬-b + ⑭ ⑭-b(巻添)    |
#     | `code`/`errno` を `VALUE_KEYS` から外した版 | ⑩ ⑫                    |
#   ★⑬ と ⑬-b が**別の物を測っている**事は5つ目で確定 —— ⑬-b だけが倒れて ⑬ は緑。
#     1つ目では2本とも倒れるが、あれは一覧引きが POST になって解決ごと死ぬから
#     (= 巻き添えの ⑭ ⑭-b も同じ理由)。⑫ と ⑩ の分離は3つ目(⑫ だけ倒れる)。
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
      "display": { "route": { "kind": "tmux", "short": "SHORT-KEPT", "text": "SENTINEL-TEXT", "screen": "SENDABLE" },
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
      "display": { "route": { "kind": "worker", "short": "SHORT-KEPT2", "text": "SENTINEL-TEXT2", "screen": "" },
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
#
# ★`SHORT-KEPT` は**わざと production に無い形**にしてある(2026-08-08)。以前は
#   `机・静か` `ワーカー・idle` と、いかにも本物らしい札が書いてあった。此の台本が測るのは
#   鍵の形であって文言ではないので値は何でもよいのだが、本物らしい札は**本番の文言の
#   3枚目の写し**として読まれ、実際どちらも production が出せない文字列に腐っていた
#   (`机・静か` は `workPhrase` に無く、`ワーカー・idle` は S8-19 で `ワーカー・未起動` に
#   なった)。同じ夜に、電話の fixture が本番より綺麗な札を出していた事で1件見逃していた
#   ので、此処も**一目で合成と分かる値**に替える。文言の正本は
#   `.harness/fixture-label-parity-controls.sh` が1本だけ見張る。
missing=""
for s in '\"tmux\"' '\"worker\"' '\"SHORT-KEPT\"' '\"SENDABLE\"' '\"tmux-missing\"'; do
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

# ── ⑥⑦⑧⑨ `{id}` の口 —— 偽のサーバを立てて測る ──────────────────────
# 会話ごとの口(`/api/sessions/{id}/history` 等)は URL に session id が要る。
# 道具はそれを**自分で一覧から引いて差し込む**ので、①〜⑤(標準入力の口)では
# 一行も通らない新しい経路が増えた。ここだけは網を通さないと測れないので、
# 本番ではなく**この台本が立てた偽のサーバ**を叩かせる。
#
# ★⑧が要る理由: 「id が出力に出ない」(⑥)は、道具が**id を解決しなくても**緑になる。
#   偽サーバに届いた道を記録して、差し込みが実際に起きた事を別に測る。
#   ⑦は「そもそも何も出力していない」を⑥の緑と見分ける錨。
FAKE="$SCRATCH/fake-server.mjs"
cat >"$FAKE" <<'JS'
import { createServer } from "node:http";
import { readFileSync, writeFileSync, appendFileSync } from "node:fs";
const [portFile, logFile, payloadFile] = process.argv.slice(2);
const listing = readFileSync(payloadFile, "utf8");
const srv = createServer((req, res) => {
  // ★method も記録する。`RC_METHOD` が id 解決の一覧引きまで伝播していないかは、
  //   道だけ見ても判らない(どちらも `/api/sessions` を叩く)。
  appendFileSync(logFile, `${req.method} ${req.url}\n`);
  const head = { "content-type": "application/json" };
  if (req.url === "/api/sessions" && req.method === "GET") {
    res.writeHead(200, head); res.end(listing); return;
  }
  // 200 以外を**狙って**観測する為の口。本文には語彙と自由文を両方載せる。
  if (/^\/api\/sessions\/[^/]+\/input$/.test(req.url) && req.method === "POST") {
    res.writeHead(400, head);
    res.end(JSON.stringify({
      error: "text required",
      display: { kind: "error", text: "SENTINEL-DISPLAYTEXT" },
    }));
    return;
  }
  if (req.url === "/api/nope") {
    res.writeHead(404, head);
    res.end(JSON.stringify({ error: "SENTINEL-ERRORTEXT", code: "NO_SUCH_ROUTE" }));
    return;
  }
  if (/^\/api\/sessions\/[^/]+\/history\?limit=50$/.test(req.url)) {
    res.writeHead(200, head);
    res.end(JSON.stringify({
      history: [{ role: "user", text: "SENTINEL-HTEXT", display: { who: "Tom" } }],
      truncated: true,
    }));
    return;
  }
  res.writeHead(404, head); res.end("{}");
});
srv.listen(0, "127.0.0.1", () => writeFileSync(portFile, String(srv.address().port)));
JS

PORTFILE="$SCRATCH/port"; HITLOG="$SCRATCH/hits.txt"
: > "$HITLOG"
"$NODE" "$FAKE" "$PORTFILE" "$HITLOG" "$SCRATCH/payload.json" >"$SCRATCH/fake.log" 2>&1 &
FAKE_PID=$!
# ★job 表から外す —— 外さないと、後で止めた時に shell が "Terminated: 15" を
#   **要約行の後ろに**刷る。検査は全部緑なのに最後の1行が異常に見える形になり、
#   読む側が緑を疑う(=計器としての値が落ちる)。
disown "$FAKE_PID" 2>/dev/null
# ★この pid だけを止める(自分で起こした子。`pkill node` の様な名前での薙ぎ払いはしない)。
cleanup_fake() { kill "$FAKE_PID" >/dev/null 2>&1; }
trap 'cleanup_fake; cleanup' EXIT

waited=0
while [ ! -s "$PORTFILE" ] && [ "$waited" -lt 50 ]; do sleep 0.1; waited=$((waited+1)); done
if [ ! -s "$PORTFILE" ]; then
    echo "測れない: 偽のサーバが上がらなかった"
    cat "$SCRATCH/fake.log"
    echo; echo "PASS $pass / FAIL $fail"
    exit 2
fi
PORT="$(cat "$PORTFILE")"

# 鍵は偽物。★本物らしい形にしない —— 失敗時にこの台本が環境ごと刷る事故を作らない。
run_fake() { # $1=RC_SESSION_INDEX  $2=出力先
    env RC_KEY=SENTINEL-KEY RC_HOST=127.0.0.1 RC_PORT="$PORT" RC_SESSION_INDEX="$1" \
        "$NODE" "$TOOL" '/api/sessions/{id}/history?limit=50' >"$2" 2>&1
}

run_fake 0 "$SCRATCH/id0.txt"
rc0=$?

if [ "$rc0" -ne 0 ]; then
    ng "⑥ 差し込んだ id は出力に出ない" "道具が落ちた (rc=$rc0)"
    ng "⑦ 印字されるのは差し込む前の雛形" "同上"
    ng "⑧ 差し込みが実際に起きている" "同上"
    cat "$SCRATCH/id0.txt"
else
    if grep -q 'SENTINEL-ID' "$SCRATCH/id0.txt"; then
        ng "⑥ 差し込んだ id は出力に出ない" "出た = 値を出さない道具が id だけ出す形になっている"
    else
        ok "⑥ 差し込んだ id は出力に出ない"
    fi
    # 雛形がそのまま出ている = 何を叩いたかは判るが、どの会話かは判らない。
    if grep -qF '/api/sessions/{id}/history' "$SCRATCH/id0.txt"; then
        ok "⑦ 印字されるのは差し込む前の雛形(⑥が空振りでない)"
    else
        ng "⑦ 印字されるのは差し込む前の雛形" "雛形が出ていない = ⑥は何も出ていないだけかもしれない"
    fi
    if grep -qF '/api/sessions/SENTINEL-ID/history?limit=50' "$HITLOG"; then
        ok "⑧ 一覧の 0 本目の id が実際に URL へ差し込まれた"
    else
        ng "⑧ 一覧の 0 本目の id が実際に URL へ差し込まれた" "偽サーバに届いた道: $(tr '\n' ' ' <"$HITLOG")"
    fi
fi

# 選べる事の確認 —— 1 本目を指せば2つ目の id が使われる。
: > "$HITLOG"
run_fake 1 "$SCRATCH/id1.txt"
if grep -qF '/api/sessions/SENTINEL-ID2/history?limit=50' "$HITLOG"; then
    ok "⑧-b RC_SESSION_INDEX=1 は 1 本目を指す(0 本目に固定されていない)"
else
    ng "⑧-b RC_SESSION_INDEX=1 は 1 本目を指す" "届いた道: $(tr '\n' ' ' <"$HITLOG")"
fi

# 一覧に無い番号を指したら 2(未測定)。★1(赤)と混ぜない: 「形が空だった」と
# 「形を観測できなかった」を同じ籠に入れると、観測できていない事が結果として通る。
run_fake 9 "$SCRATCH/id9.txt"
if [ "$?" -eq 2 ]; then
    ok "⑨ 一覧に無い番号は 2(未測定)で止まる"
else
    ng "⑨ 一覧に無い番号は 2(未測定)で止まる" "0/1 で返る = 測れなかった事が測れた事に紛れる"
fi

# ── ⑩ 復旧語彙は値が読める / 隣の自由文は潰れる ─────────────────────────
# 電話は `code` で**画面を移す**ので、値が読めないと「404 が来た」までしか判らず
# `SESSION_NOT_FOUND`(一覧へ戻る)と `NO_SUCH_ROUTE`(client の path のバグ)が
# 線の上で見分けられない = 観測として役に立たない。
# ★同じ本文の隣に自由文を置いて**同時に**測る。「`code` の為に伏せ方を緩めた」形に
#   なっていれば、こちらが赤くなる。
printf '%s' '{"error":"SENTINEL-FREETEXT","code":"SESSION_NOT_FOUND","errno":"ENOENT"}' \
    | "$NODE" "$TOOL" - >"$SCRATCH/vocab.txt" 2>&1
if grep -qF '\"SESSION_NOT_FOUND\"' "$SCRATCH/vocab.txt" && grep -qF '\"ENOENT\"' "$SCRATCH/vocab.txt"; then
    ok "⑩ 復旧語彙(code / errno)の値は読める"
else
    ng "⑩ 復旧語彙(code / errno)の値は読める" "潰れている = 401/404 の意味が線から判らない"
fi
if grep -q 'SENTINEL-FREETEXT' "$SCRATCH/vocab.txt"; then
    ng "⑩-b 語彙の隣の自由文は潰れる" "出た = 語彙を通す為に伏せ方が緩んでいる"
else
    ok "⑩-b 語彙の隣の自由文は潰れる(⑩の為に伏せ方を緩めていない)"
fi

# ── ⑪ 期待と違う status の本文は畳まない ────────────────────────────────
# ★これが無いと、401 を見に行った実行が 404 の形を印字し、その出力が「401 の形」として
#   記録に残る。**観測を記録として信じられるか**が此処に懸かっている。
env RC_KEY=SENTINEL-KEY RC_HOST=127.0.0.1 RC_PORT="$PORT" RC_EXPECT_STATUS=401 \
    "$NODE" "$TOOL" /api/nope >"$SCRATCH/wrongstatus.txt" 2>&1
rcw=$?
if [ "$rcw" -eq 1 ] && ! grep -qF '\"NO_SUCH_ROUTE\"' "$SCRATCH/wrongstatus.txt"; then
    ok "⑪ 期待と違う status(401 を狙って 404)では畳まずに 1 で落ちる"
else
    ng "⑪ 期待と違う status では畳まずに 1 で落ちる" \
       "rc=$rcw / 本文を畳んだ = 別の status の形が観測として記録に残る"
fi

# ── ⑫ 期待と一致すれば 200 以外でも畳む(⑪の錨) ───────────────────────
# ★⑪だけだと「何も畳まない道具」でも緑になる。狙って当てた時に**出る**事を同時に測る。
env RC_KEY=SENTINEL-KEY RC_HOST=127.0.0.1 RC_PORT="$PORT" RC_EXPECT_STATUS=404 \
    "$NODE" "$TOOL" /api/nope >"$SCRATCH/expect404.txt" 2>&1
rce=$?
if [ "$rce" -eq 0 ] && grep -qF '\"NO_SUCH_ROUTE\"' "$SCRATCH/expect404.txt"; then
    ok "⑫ 狙った status(404)なら畳んで出す(⑪が空振りでない)"
else
    ng "⑫ 狙った status なら畳んで出す" "rc=$rce / 形が出ない = 401/404 は一度も観測できない"
fi
if grep -q 'SENTINEL-ERRORTEXT' "$SCRATCH/expect404.txt"; then
    ng "⑫-b 200 以外を畳んでも自由文は潰れる" "出た = 非 200 の本文が素通しになっている"
else
    ok "⑫-b 200 以外を畳んでも自由文は潰れる"
fi

# ── ⑬ ★RC_METHOD が id 解決の一覧引きへ伝播しない ──────────────────────
# 中で `METHOD` を読む造りにすると、会話の口を POST で観測しようとしただけで
# `/api/sessions` へ POST が飛ぶ = **観測の道具が副作用を持つ**。
: > "$HITLOG"
env RC_KEY=SENTINEL-KEY RC_HOST=127.0.0.1 RC_PORT="$PORT" RC_SESSION_INDEX=0 \
    RC_METHOD=POST RC_BODY='{"text":"SENTINEL-BODYTEXT"}' RC_EXPECT_STATUS=400 \
    "$NODE" "$TOOL" '/api/sessions/{id}/input' >"$SCRATCH/post.txt" 2>&1
rcp=$?
# ★`grep -x`(行まるごと一致)。部分一致だと `POST /api/sessions/SENTINEL-ID/input` が
#   「一覧へ POST した」に当たって、常に赤い検査になる。
if grep -qx 'GET /api/sessions' "$HITLOG" && ! grep -qx 'POST /api/sessions' "$HITLOG"; then
    ok "⑬ RC_METHOD は本番の口だけに効く(一覧引きは GET のまま)"
else
    ng "⑬ RC_METHOD は本番の口だけに効く" "届いた: $(tr '\n' ' ' <"$HITLOG")"
fi
if grep -qx 'POST /api/sessions/SENTINEL-ID/input' "$HITLOG"; then
    ok "⑬-b RC_METHOD が本番の口には実際に効いている(⑬が空振りでない)"
else
    ng "⑬-b RC_METHOD が本番の口には実際に効いている" "届いた: $(tr '\n' ' ' <"$HITLOG")"
fi

# ── ⑭ 送った本文の中身は出力に出ない(バイト数だけ) ────────────────────
if [ "$rcp" -ne 0 ]; then
    ng "⑭ 送った本文の中身は出力に出ない" "道具が落ちた (rc=$rcp): $(tr '\n' ' ' <"$SCRATCH/post.txt")"
elif grep -q 'SENTINEL-BODYTEXT' "$SCRATCH/post.txt"; then
    ng "⑭ 送った本文の中身は出力に出ない" "出た = 打ち込んだ文面が観測の記録に残る"
else
    ok "⑭ 送った本文の中身は出力に出ない"
fi
# ★「出ていない」の錨。バイト数を名乗っている = 本文を送った事自体は記録されている。
if grep -q 'バイト送信' "$SCRATCH/post.txt"; then
    ok "⑭-b 送った事はバイト数で記録される(⑭が無出力ではない)"
else
    ng "⑭-b 送った事はバイト数で記録される" "本文を送った痕跡が出力に無い"
fi
# ★返ってきた 400 の中の自由文も潰れている事(⑫-b の非 200 経路を打ち込み側でも確認)
if grep -q 'SENTINEL-DISPLAYTEXT' "$SCRATCH/post.txt"; then
    ng "⑭-c 400 の本文の自由文も潰れる" "出た = display.text が素通しになっている"
else
    ok "⑭-c 400 の本文の自由文も潰れる"
fi

echo
echo "PASS $pass / FAIL $fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
