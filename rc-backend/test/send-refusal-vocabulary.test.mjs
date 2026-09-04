// 送信を断る理由に、電話へ出す文が**必ず在る**事を数える。
//
// ── なぜ要るか(2026-09-04 実測)────────────────────────────────────────────
// `server.mjs` の `SEND_REFUSAL` には長く「injector.send() の reason と 1:1」と
// 書いてあったが、**其れを確かめる物は何も無かった**。同日、入力欄に人の下書きが
// 残っている時に断る `composer-busy` を注入層へ足した時、私は此の表に文を足し忘れた。
// 結果、電話に出るのは `SEND_REFUSAL.unknown` の文:
//
//     "No composer field found (starting up, a different screen, or the pane is gone)."
//
// 入力欄は**在る**。在るのに無いと言う、事実として誤りの文が、断りの理由として出る。
// しかも断り自体は正しく効いているので、検査は全部緑のまま通る —— 誰も気付けない。
//
// ★此の型は「層を1つ足した時、其の層の**言葉**を足し忘れる」であって、注意深さでは
//   防げない。防ぐのは、reason を作る側(inject.mjs)から数えて表の鍵と突き合わせる此の検査。
//
// ★**import ではなく本文を読む**。`server.mjs` は読み込まれた時点で `listen` する
//   (末尾の `server.listen(PORT, BIND, …)`)ので、検査が import すると本番の起動と
//   同じ事が起きて終わらない —— 実際に 1 度踏んで気付いた。e2e が別プロセスとして
//   `spawn` しているのは同じ理由で、此の file を import している検査は 1 本も無い。
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const src = (rel) => readFileSync(join(ROOT, rel), "utf8");
const INJECT = src("src/inject.mjs");
const SERVER = src("src/server.mjs");

/**
 * 送信経路が返し得る reason を、注入層の**本文から**数える。
 *
 * 見分け方: `sent: false` を返す行のうち `delivered:` を持つ物が送信経路。
 * `applied:` を持つ物は選択経路(`CHOICE_REFUSAL` の担当)で、両者は `sent:false` と
 * `reason` を共有していて文字列では見分けが付かない(`pane-busy` は両方に出る)。
 *
 * ★文字列で書かれていない物が 1 つ在る: `reason: s0.state.toLowerCase()`。画面の分類が
 *   そのまま理由になる形で、状態の一覧は `classifyScreen` の @returns から取る ——
 *   手で書くと、状態が増えた日に此の検査が古い一覧のまま緑になる。
 */
function sendRefusalReasons() {
  const out = new Set();
  let sawDynamic = false;
  for (const line of INJECT.split("\n")) {
    if (!line.includes("sent: false") || !line.includes("delivered:")) continue;
    const lit = line.match(/reason:\s*"([a-z-]+)"/);
    if (lit) { out.add(lit[1]); continue; }
    if (/reason:\s*s\d\.state\.toLowerCase\(\)/.test(line)) { sawDynamic = true; continue; }
    assert.fail(`送信経路の断りに、読めない reason が在る: ${line.trim()}`);
  }
  if (sawDynamic) for (const s of screenStates()) out.add(s.toLowerCase());
  return out;
}

/** `classifyScreen` が名乗る画面の状態。`SENDABLE` は其の場では断りにならないので除く。 */
function screenStates() {
  const m = INJECT.match(/@returns \{\{state:((?:"[A-Z]+"\|?)+)/);
  assert.ok(m, "classifyScreen の @returns から状態の一覧が読めない(注釈の形が変わった)");
  const all = [...m[1].matchAll(/"([A-Z]+)"/g)].map((x) => x[1]);
  assert.ok(all.includes("SENDABLE"), `状態の一覧に SENDABLE が無い: ${all.join("|")}`);
  return all.filter((s) => s !== "SENDABLE");
}

/** `SEND_REFUSAL` の中身を本文から取る。返すのは 鍵 -> **文の生の綴り**(連結や引用符ごと)。 */
function refusalTable() {
  const start = SERVER.indexOf("const SEND_REFUSAL = {");
  assert.ok(start > 0, "SEND_REFUSAL の宣言が見つからない(名前か形が変わった)");
  const end = SERVER.indexOf("\n};", start);
  assert.ok(end > start, "SEND_REFUSAL の閉じが見つからない");
  const block = SERVER.slice(start, end);
  const table = new Map();
  // 鍵は行頭(2 字下げ)の `name:` か `"name":`。値は次の鍵までの全部。
  const keys = [...block.matchAll(/^ {2}"?([a-z][a-z-]*)"?:/gm)];
  for (let i = 0; i < keys.length; i++) {
    const from = keys[i].index + keys[i][0].length;
    const to = i + 1 < keys.length ? keys[i + 1].index : block.length;
    table.set(keys[i][1], block.slice(from, to));
  }
  return table;
}

test("送信経路が返す断りの理由は、全て電話に出す文を持つ", () => {
  const reasons = sendRefusalReasons();
  assert.ok(reasons.size >= 5, `理由が数えられていない(${reasons.size} 件)。数え方が壊れた疑い`);
  const table = refusalTable();
  const missing = [...reasons].filter((r) => !table.has(r));
  assert.deepEqual(
    missing, [],
    `断れるのに文が無い理由が在る。電話には SEND_REFUSAL.unknown の文(「入力欄が見つからない」)が出る: ${missing.join(", ")}`,
  );
});

test("電話に出す文の側にも、返り得ない理由は置かない", () => {
  // ★逆向き。使われない文が残ると「此の断りは在る」と読めてしまい、
  //   次に断りを足す人が「もう文が在る」と誤読する。
  const reasons = sendRefusalReasons();
  const orphan = [...refusalTable().keys()].filter((k) => !reasons.has(k));
  assert.deepEqual(orphan, [], `注入層が返さない理由の文が残っている: ${orphan.join(", ")}`);
});

test("断りの文は、送っていない事を必ず書く", () => {
  // ★文面の**内容**まで縛るのは 1 点だけ: 「送っていない」と読める事。断りを受けた人が
  //   最初に知りたいのは其れで、無いと再送していいのか判らない。言い回しは縛らない
  //   (縛ると文を良くする度に検査が赤くなる)。
  for (const [reason, text] of refusalTable()) {
    assert.ok(text.length >= 40, `${reason} の文が短すぎる: ${text}`);
    const saysNotSent = /nothing was sent|nothing ran|was not pressed|did not land|no composer field/i.test(text);
    assert.ok(saysNotSent, `${reason} の文が「送っていない」と言っていない: ${text}`);
  }
});
