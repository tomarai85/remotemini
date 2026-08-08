// 同期で子を起こす呼び出しに、諦める時刻が付いているか(2026-08-08、監査 R-1)
//
// ★なぜ**静的**に見るのか。`execFileSync` を直に書いている場所は `src/server.mjs` の中に在り、
//   この file は **import した瞬間に listen する** = 単体検査から呼べない。呼べない物の面は
//   source を読むしか無い。tmux 実行器の側(`exec` を注入する形)は
//   `test/inject.test.mjs` の「★tmux の子には諦める時刻が要る」が opts を掴んで見ている。
//
// ★何を守っているか。`execFileSync` は **event loop ごと止める**。上限の無い呼び出しが1つでも
//   固まると、サーバは `/healthz` を含めて何も返さなくなり、机に手が届かない30日間は
//   ssh で入るまで電話が死ぬ。だから守るのは「速さ」ではなく「**必ず戻ってくる事**」。
//
// この検査は**新しい呼び出しが増えた時**に効く。今在る4つは全部通っているので、
// 陰性対照(どれか1つから `timeout:` を外すと赤くなる)で本物である事を確かめてある。
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const SRC = join(dirname(fileURLToPath(import.meta.url)), "..", "src");
/** 同期で子を起こす API。**非同期版は対象外**(event loop を止めないので性質が違う)。 */
const SYNC_EXEC = ["execFileSync", "execSync", "spawnSync"];

/**
 * `name(` の開き括弧から対応する閉じ括弧までを返す。括弧の数を数えるだけ。
 * 文字列リテラルの中の括弧までは見ないので厳密ではないが、**引数の中に釣り合わない
 * 括弧を書いた時に「短く切れる」= 見落とす方向ではなく赤くなる方向**に倒れる。
 */
function callArgsAt(text, openIdx) {
  let depth = 0;
  for (let i = openIdx; i < text.length; i++) {
    if (text[i] === "(") depth++;
    else if (text[i] === ")") {
      depth--;
      if (depth === 0) return text.slice(openIdx + 1, i);
    }
  }
  return null; // 閉じていない = 走査の失敗。呼び出し側で赤にする
}

/** src/ 全体から同期 exec の呼び出しを拾う。import 行と型注釈のコメントは数えない。 */
function syncExecCalls() {
  const found = [];
  for (const f of readdirSync(SRC).filter((n) => n.endsWith(".mjs")).sort()) {
    const text = readFileSync(join(SRC, f), "utf8");
    for (const name of SYNC_EXEC) {
      let from = 0;
      for (;;) {
        const at = text.indexOf(`${name}(`, from);
        if (at < 0) break;
        from = at + name.length;
        // 直前が `.` や英数字なら別の識別子の一部(`myExecFileSync(` 等)
        const prev = at > 0 ? text[at - 1] : "";
        if (/[A-Za-z0-9_.$]/.test(prev)) continue;
        const line = text.slice(0, at).split("\n").length;
        const args = callArgsAt(text, at + name.length);
        found.push({ file: f, line, name, args });
      }
    }
  }
  return found;
}

test("★同期で子を起こす呼び出しには、諦める時刻が要る", () => {
  const calls = syncExecCalls();

  // 分母を検査自身に言わせる。0 件になったら**走査が壊れた**のであって「安全になった」ではない。
  assert.ok(calls.length >= 3,
    `同期 exec の呼び出しが ${calls.length} 件しか見つからない = 走査が壊れている疑い`);

  const naked = [];
  for (const c of calls) {
    assert.ok(c.args !== null, `${c.file}:${c.line} の ${c.name}( が閉じていない`);
    if (!/\btimeout\s*:/.test(c.args)) naked.push(`${c.file}:${c.line} ${c.name}`);
  }
  assert.deepEqual(naked, [],
    "上限の無い同期 exec が在る。1つ固まるとサーバ全体(/healthz を含む)が黙る");
});

test("★諦める時に送る signal は TERM ではない(TERM を無視して固まっている子が相手)", () => {
  const naked = syncExecCalls()
    .filter((c) => c.args && !/killSignal\s*:\s*["']SIGKILL["']/.test(c.args))
    .map((c) => `${c.file}:${c.line} ${c.name}`);
  assert.deepEqual(naked, [],
    "既定の SIGTERM だと、TERM を握り潰す子には上限が効かない(戻らないまま待ち続ける)");
});
