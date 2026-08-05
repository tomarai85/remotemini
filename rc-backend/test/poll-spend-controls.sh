#!/bin/bash
# controls-for: test/e2e-local.mjs
#
# 何を守る対照か —— **e2e の待ち道具が「使い切った」を赤の本文に出す事**。
#
# `pollUntilScreen` は画面が1枚来るまで poll を撃ち直す。来なければ回数を使い切って
# 最後に来た物を返し、呼び側の check が赤くなる。ここで**回数を使い切ったのかどうか**を
# 言わないと、赤は3通りに読めてしまう ——
#   (a) その画面には成らなかった(本当に壊れている)
#   (b) 10 回撃ったが遅い機械で間に合わなかった(測れていない)
#   (c) 呼び方を間違えて 1 回で抜けた(検査の側の欠陥)
# 見分けが付かないと、次に直す人は「眠りを足す」band-aid に引き寄せられる。
# 正しい直し方は**回数を増やす**事なので、その一言まで含めて赤に出す。
#
# ★この対照は**本体のバイトを切り出して**回す(写しを持たない)。写しを持つと、
#   本体を書き換えた時に写しだけが古くなり、対照は古い形を緑に保ち続ける。
#   切り出せなくなったら 2(測れていない)で落ちる = 黙って緑にならない。
#
# ★負の対照つき: 切り出した source を**その場で壊して**(使い切りを常に false にする)
#   同じ検査群を回し、**赤くなる事**を見る。壊しても緑なら、この検査は飾りである。
#
# 終了コード: 0 = 守られている / 1 = 破れている / 2 = 測れていない
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TARGET="$ROOT/rc-backend/test/e2e-local.mjs"

if [ ! -f "$TARGET" ]; then
    echo "UNMEASURED  読む file が無い: rc-backend/test/e2e-local.mjs"
    exit 2
fi

PROBE="$(mktemp -t poll-spend-probe).mjs"
trap '/bin/rm -f "$PROBE"' EXIT

cat > "$PROBE" <<'PROBEEOF'
// 本体から `POLL_SPEND` / `pollSpend` / `pollUntilScreen` を切り出し、偽の poll で回す。
// argv[2] が "mutated" の時は、切り出した source の「使い切り」を潰してから回す(負の対照)。
import { readFile } from "node:fs/promises";

const target = process.argv[2];
const mode = process.argv[3] || "normal";
const src = await readFile(target, "utf8");

const HEAD = "/** `pollUntilScreen` が何回撃ったかの置き場";
const TAIL = "      if (r && typeof r === \"object\") r[POLL_SPEND] = { rounds, tries, exhausted: true };\n      return r;\n    };";
const a = src.indexOf(HEAD);
const b = src.indexOf(TAIL);
if (a < 0 || b < 0) {
  console.log("UNMEASURED  切り出せない(本体の形が変わった)。錨: " + HEAD.slice(0, 24));
  process.exit(2);
}
let block = src.slice(a, b + TAIL.length);

if (mode === "mutated") {
  // 使い切りを常に「使い切っていない」と言わせる。これが緑のまま通るなら検査は飾り。
  const before = block;
  block = block.replace("{ rounds, tries, exhausted: true }", "{ rounds, tries, exhausted: false }");
  if (block === before) {
    console.log("UNMEASURED  壊す先が当たらない(負の対照が空撃ちになる)");
    process.exit(2);
  }
}

const make = new Function("pollD", block + "\nreturn { pollUntilScreen, pollSpend };");

let pass = 0;
let fail = 0;
const chk = (name, ok, detail) => {
  if (ok) { pass++; console.log("  PASS  " + name); }
  else { fail++; console.log("  FAIL  " + name + "  " + (detail === undefined ? "" : detail)); }
};

// 1. 1回目で来る
{
  let n = 0;
  const { pollUntilScreen, pollSpend } = make(async () => { n++; return { cursor: "c" + n, screen: { pane: "%28" } }; });
  const r = await pollUntilScreen("s");
  chk("1回目で来たら撃ち直しは1回", n === 1 && /1\/10 回で来た/.test(pollSpend(r)), pollSpend(r));
  chk("1回目で来たら使い切りとは書かない", !/使い切った/.test(pollSpend(r)), pollSpend(r));
}
// 2. want が永久に満たされない = 使い切り
{
  let n = 0;
  const { pollUntilScreen, pollSpend } = make(async () => { n++; return { cursor: "c" + n, screen: { pane: "%28" } }; });
  const r = await pollUntilScreen("s", { tries: 3, want: (s) => s.pane === "%29" });
  chk("来ない時は回数を使い切る", n === 3, "撃った回数=" + n);
  chk("使い切った事が赤の本文に出る", /3\/3 回を..使い切った/.test(pollSpend(r)), pollSpend(r));
  chk("直し方(回数を増やす・眠りではない)が本文に在る",
    /回数を増やす/.test(pollSpend(r)) && /眠り/.test(pollSpend(r)), pollSpend(r));
}
// 3. screen が永久に来ない
{
  let n = 0;
  const { pollUntilScreen, pollSpend } = make(async () => { n++; return { cursor: "c" + n, screen: null }; });
  const r = await pollUntilScreen("s", { tries: 2 });
  chk("画面が来なくても使い切りとして名乗る", n === 2 && /2\/2 回を..使い切った/.test(pollSpend(r)), pollSpend(r));
}
// 4. この道具を通っていない物は「記録なし」と言う(黙って緑に見せない)
{
  const { pollSpend } = make(async () => ({}));
  chk("負の対照: 素の物には記録なしと言う", /記録なし/.test(pollSpend({ screen: null })), pollSpend({ screen: null }));
  chk("負の対照: null でも落ちない", /記録なし/.test(pollSpend(null)), String(pollSpend(null)));
}
// 5. Symbol は JSON に乗らない = 既存の検査文が1文字も変わらない
{
  let n = 0;
  const { pollUntilScreen } = make(async () => { n++; return { cursor: "c" + n, screen: { pane: "%28" }, items: [] }; });
  const j = JSON.stringify(await pollUntilScreen("s"));
  chk("JSON に spend / rounds / exhausted が出ない", !/rounds|exhausted|spend/.test(j), j);
  chk("元の欄はそのまま", JSON.parse(j).screen.pane === "%28" && JSON.parse(j).cursor === "c1", j);
}

console.log("  == PASS " + pass + " / FAIL " + fail);
process.exit(fail === 0 ? 0 : 1);
PROBEEOF

echo "== 本物: 使い切りが赤の本文に出るか =="
node "$PROBE" "$TARGET" normal
NORMAL=$?
if [ "$NORMAL" -eq 2 ]; then
    echo
    echo "UNMEASURED  本体から切り出せなかった。錨を付け直す事。"
    exit 2
fi

echo
echo "== 負の対照: 使い切りを潰したら赤くなるか =="
node "$PROBE" "$TARGET" mutated
MUTATED=$?
if [ "$MUTATED" -eq 2 ]; then
    echo
    echo "UNMEASURED  壊す先が当たらない。負の対照が空撃ちになっている。"
    exit 2
fi

echo
if [ "$NORMAL" -ne 0 ]; then
    echo "FAIL  本物が赤い。待ち道具が使い切りを名乗っていない。"
    exit 1
fi
if [ "$MUTATED" -eq 0 ]; then
    echo "FAIL  使い切りを潰しても緑のまま = この検査群は飾りである。"
    exit 1
fi
echo "PASS  本物は緑、壊すと赤(負の対照が効いている)。"
exit 0
