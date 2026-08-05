#!/bin/bash
# controls-for: src/server.mjs src/worker.mjs src/tail.mjs
#
# 何を守る対照か —— **rc-backend が再起動した時、再起動前の栞が「追いついた」と
# 黙って受け入れられない事**。Sprint 6.5 の「再起動を挟む」脚の、サーバ側の関節。
#
# 電話が持つ栞は `t.<epoch>.<seq>.<screenRev>`。再起動を跨いで嘘を防いでいるのは
# **epoch が process ごとに違う事**、その一点だけである。ここが連番だと ——
#   再起動 → epoch が 0 に戻る → 再起動前の栞 `t.0.57.0` が**偶然一致する**
#   → `pollDecision` は `resume(seq:57)` を返す → サーバの ring は空なので「差分なし」
#   → 電話は「最新です」と表示したまま**永久に凍る**。
# 赤くなる所がどこにも無い。これが此の系で最悪の壊れ方(静かな嘘)である。
#
# ★この穴は SSE 側に**実在していた**(`feedEpochSeq` は 0 起点の連番だった。経緯は
#   `src/tail.mjs` の `formatPollCursor` 直前の注釈)。
#   直した事は source の注釈に書かれているが、**誰も測っていなかった** ——
#   `newEpochToken` を変異させる検査は 2026-08-06 時点で1本も無い(mutation-controls.py
#   は `pollDecision` 側の epoch 比較しか壊さない)。判定の側だけを固めても、
#   判定に渡る**値**が退化したら判定は正しく「一致」と答える。
#
# 測り方: 本物の byte から `newEpochToken` を切り出し、**別々の process で**呼ぶ。
#   同じ process で2回呼んで違う事を見ても再起動の証明にならない(連番でも違う)。
#   process を分けて初めて「再起動しても被らない」が測れる。
#
# 経路は2本ある。両方に同じ穴が開けられる:
#   tmux   `f.epoch`            = server.mjs の newEpochToken()
#   worker `manager.generation` = worker.mjs の既定値
# 対照は両方を回す。片方だけ直すのが一番起きやすい壊れ方だから。
#
# ★逆向きの対照も置く: `JsonlTail.generation` は `${dev}-${ino}` で、これは
#   **再起動で変わってはいけない**(file の同一性。変わったら毎回「別の file だ」と
#   誤検知する)。3つ目の「generation」を同じ物と読み違えて一緒に乱数化する改変は、
#   この検査が赤で止める。
#
# 終了コード: 0 = 守られている / 1 = 破れている / 2 = 測れていない
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

for rel in src/server.mjs src/worker.mjs src/tail.mjs; do
    if [ ! -f "$ROOT/$rel" ]; then
        echo "UNMEASURED  読む file が無い: $rel"
        exit 2
    fi
done

PROBE="$(mktemp -t restart-epoch-probe).mjs"
trap '/bin/rm -f "$PROBE"' EXIT

cat > "$PROBE" <<'PROBEEOF'
// 二役ある。
//   --emit-<route> <mode>  … 世代の印を1つだけ刷って終わる(**別 process** で呼ばれる)
//   --verify <mode>        … 自分を何度も起こして印を集め、本物の pollDecision に掛ける
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const ROOT = process.env.RC_ROOT;
const SELF = process.argv[1];
const [, , cmd, mode = "normal"] = process.argv;

/** 本物の byte から世代の印を作る式を切り出す。写しは持たない。 */
function mintersFor(mode) {
  const server = readFileSync(join(ROOT, "src", "server.mjs"), "utf8");
  const worker = readFileSync(join(ROOT, "src", "worker.mjs"), "utf8");

  const H = "function newEpochToken() {";
  const a = server.indexOf(H);
  if (a < 0) return { err: "server.mjs から newEpochToken を切り出せない" };
  const end = server.indexOf("\n}", a);
  if (end < 0) return { err: "newEpochToken の閉じが見つからない" };
  let tmuxSrc = server.slice(a, end + 2);

  const WH = "this.generation = generation ||";
  const wa = worker.indexOf(WH);
  if (wa < 0) return { err: "worker.mjs から generation の既定値を切り出せない" };
  const wend = worker.indexOf(";", wa);
  if (wend < 0) return { err: "worker.mjs の generation 行の終わりが無い" };
  // `this.generation = generation || <式>` の <式> だけを取る
  let workerExpr = worker.slice(wa + WH.length, wend).trim();

  if (mode === "mutated") {
    // 歴史上の穴を植え直す: process ごとの乱数 → 0 起点の連番。
    // process は毎回新しいので、連番は**毎回同じ値**を返す = 再起動で被る。
    const t0 = tmuxSrc;
    tmuxSrc = tmuxSrc.replace(/return .*;/, "return String(SEQ++);");
    if (tmuxSrc === t0) return { err: "tmux 側の壊す先が当たらない" };
    const w0 = workerExpr;
    workerExpr = "String(SEQ++)";
    if (workerExpr === w0) return { err: "worker 側の壊す先が当たらない" };
  }

  return {
    tmux: new Function("randomBytes", "SEQ", tmuxSrc + "\nreturn newEpochToken;"),
    workerExpr,
  };
}

async function emit(route, mode) {
  const { randomBytes } = await import("node:crypto");
  const m = mintersFor(mode);
  if (m.err) {
    process.stderr.write("SLICE-FAIL " + m.err + "\n");
    process.exit(3);
  }
  if (route === "tmux") {
    process.stdout.write(String(m.tmux(randomBytes, 0)()));
  } else {
    process.stdout.write(String(new Function("randomBytes", "SEQ", "return " + m.workerExpr + ";")(randomBytes, 0)));
  }
}

/** 別 process を1つ起こして印を1つ貰う。= 1回の再起動。 */
function restartAndTakeToken(route, mode) {
  const r = spawnSync(process.execPath, [SELF, "--emit-" + route, mode], {
    encoding: "utf8",
    env: { ...process.env, RC_ROOT: ROOT },
  });
  if (r.status === 3) return { err: (r.stderr || "").trim() };
  if (r.status !== 0) return { err: "子 process が " + r.status + " で落ちた: " + (r.stderr || "").trim() };
  return { token: r.stdout.trim() };
}

async function verify(mode) {
  const { pollDecision, formatPollCursor } = await import(pathToFileURL(join(ROOT, "src", "tail.mjs")).href);

  let pass = 0;
  let fail = 0;
  const chk = (name, ok, detail) => {
    if (ok) { pass++; console.log("  PASS  " + name); }
    else { fail++; console.log("  FAIL  " + name + (detail === undefined ? "" : "  —— " + detail)); }
  };

  const RESTARTS = 8;
  for (const route of ["tmux", "worker"]) {
    const tokens = [];
    for (let i = 0; i < RESTARTS; i++) {
      const r = restartAndTakeToken(route, mode);
      if (r.err) {
        console.log("UNMEASURED  " + r.err);
        process.exit(2);
      }
      tokens.push(r.token);
    }

    const uniq = new Set(tokens);
    chk(
      `[${route}] ${RESTARTS} 回再起動して世代の印が ${RESTARTS} 通り`,
      uniq.size === RESTARTS,
      `${uniq.size} 通りしか出ていない = 再起動で被る。再起動前の栞が「追いついた」と受け入れられる`,
    );
    chk(
      `[${route}] 印に区切りの "." を含まない`,
      tokens.every((t) => !t.includes(".") && t.length > 0),
      `栞は "." で4つに割る。印に "." が入ると epoch-mismatch ではなく cursor-malformed に化ける: ${tokens[0]}`,
    );

    // 再起動の関節そのもの: A で刷った栞を、**1回再起動した後の** B のサーバに出す。
    // ★ b は「A と違う印」を**探して**はいけない。探すと、印が全部同じ(= 壊れている)時に
    //   「跨ぐ相手が居ない」で逃げてしまい、肝心の**嘘そのもの**を誰も見ない。
    //   b は常に2回目の再起動の印。壊れていれば a と一致し、嘘が出力に出る。
    const [a, b] = [tokens[0], tokens[1]];
    const cursor = formatPollCursor({ route, token: a, seq: 57, screenRev: 3 });
    const across = pollDecision(cursor, route, b);
    chk(
      `[${route}] 再起動前の栞は繋がらない(gap/epoch-mismatch)`,
      across.kind === "gap" && across.why === "epoch-mismatch",
      `${JSON.stringify(across)} —— resume が返った = ring は空なので「差分なし」、電話は「最新です」のまま永久に凍る`,
    );

    // 「常に gap」でも上は緑になる。同じ世代なら繋がる事を並べて初めて意味が出る。
    const within = pollDecision(cursor, route, a);
    chk(
      `[${route}] 負の対照: 同じ世代の栞はちゃんと繋がる(常に gap ではない)`,
      within.kind === "resume" && within.seq === 57 && within.screenRev === 3,
      JSON.stringify(within),
    );
  }

  // 3つ目の generation。此処だけは**再起動で変わってはいけない**。
  const tail = readFileSync(join(ROOT, "src", "tail.mjs"), "utf8");
  const devIno = /this\.generation = `\$\{st\.dev\}-\$\{st\.ino\}`/.test(tail);
  const tailRandom = /this\.generation\s*=\s*randomBytes/.test(tail);
  chk(
    "[file] JsonlTail.generation は dev-ino のまま(乱数にすり替わっていない)",
    devIno && !tailRandom,
    "file の同一性は再起動で変わってはいけない。乱数化すると毎回「別の file だ」と誤検知する",
  );

  console.log("  == PASS " + pass + " / FAIL " + fail);
  process.exit(fail === 0 ? 0 : 1);
}

if (cmd === "--emit-tmux") await emit("tmux", mode);
else if (cmd === "--emit-worker") await emit("worker", mode);
else if (cmd === "--verify") await verify(mode);
else { console.log("UNMEASURED  使い方が違う"); process.exit(2); }
PROBEEOF

echo "== 本物: 再起動しても世代の印が被らないか =="
RC_ROOT="$ROOT" node "$PROBE" --verify normal
NORMAL=$?
if [ "$NORMAL" -eq 2 ]; then
    echo
    echo "UNMEASURED  切り出せなかった。錨を付け直す事。"
    exit 2
fi

echo
echo "== 負の対照: 印を連番に戻したら赤くなるか(歴史上の穴を植え直す) =="
RC_ROOT="$ROOT" node "$PROBE" --verify mutated
MUTATED=$?
if [ "$MUTATED" -eq 2 ]; then
    echo
    echo "UNMEASURED  壊す先が当たらない。負の対照が空撃ちになっている。"
    exit 2
fi

echo
if [ "$NORMAL" -ne 0 ]; then
    echo "FAIL  本物が赤い。再起動を跨いで栞が繋がってしまう = 電話が凍る。"
    exit 1
fi
if [ "$MUTATED" -eq 0 ]; then
    echo "FAIL  印を連番に戻しても緑のまま = この検査群は飾りである。"
    exit 1
fi
echo "PASS  本物は緑、連番に戻すと赤(負の対照が効いている)。"
exit 0
