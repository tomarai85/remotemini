// tail.mjs の unit test — **本物のファイル**で回す。
// ここだけ fixture 文字列でなく実ファイルを使うのは意図的で、この module が引き受けている
// 難しさが「文字列の解釈」ではなく「ファイルが追記だと信じない」事そのものだから。
// inode の差し替えや切り詰めは、偽の fs を作ると**自分の思い込みを検査するだけ**になる。
import { test } from "node:test";
import assert from "node:assert/strict";
import { appendFileSync, mkdtempSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { JsonlTail, formatPollCursor, pollDecision, resumeDecision, sliceCompleteLines } from "../src/tail.mjs";

const L = (o) => `${JSON.stringify(o)}\n`;
const user = (t) => L({ type: "user", message: { content: t } });
const dir = () => mkdtempSync(join(tmpdir(), "rc-tail-"));

test("完全な行だけを切り出す(改行までしか消費しない)", () => {
  const a = sliceCompleteLines(Buffer.from('{"a":1}\n{"b":2'));
  assert.equal(a.chunk.toString(), '{"a":1}\n');
  assert.equal(a.consumed, 8);
  const b = sliceCompleteLines(Buffer.from('{"a":1'));
  assert.equal(b.consumed, 0);
});

test("初回の poll は末尾に位置を合わせ、過去分は流さない", () => {
  const d = dir();
  const p = join(d, "s.jsonl");
  writeFileSync(p, user("むかしの発言"));
  const t = new JsonlTail({ path: p });
  const r = t.poll();
  assert.equal(r.ok, true);
  assert.equal(r.reset, false);
  assert.deepEqual(r.records, []); // スナップショットは /history の仕事
  rmSync(d, { recursive: true });
});

test("追記した行が返り、offset がその行の終わりまで進む", () => {
  const d = dir();
  const p = join(d, "s.jsonl");
  writeFileSync(p, user("既存"));
  const t = new JsonlTail({ path: p });
  t.poll();
  const before = t.offset;
  appendFileSync(p, user("あたらしい"));
  const r = t.poll();
  assert.equal(r.records.length, 1);
  assert.equal(r.records[0].obj.message.content, "あたらしい");
  assert.equal(r.records[0].end, before + Buffer.byteLength(user("あたらしい")));
  assert.equal(t.offset, r.records[0].end);
  // 2 回目は何も返らない(同じ行を二度流さない)
  assert.equal(t.poll().records.length, 0);
  rmSync(d, { recursive: true });
});

test("書き込み途中の行は返さない。改行が来た時に初めて返る", () => {
  const d = dir();
  const p = join(d, "s.jsonl");
  writeFileSync(p, "");
  const t = new JsonlTail({ path: p });
  t.poll();
  appendFileSync(p, '{"type":"user","message":{"content":"とちゅ');
  assert.equal(t.poll().records.length, 0, "半端な行を JSON.parse に渡していない");
  appendFileSync(p, 'う"}}\n');
  const r = t.poll();
  assert.equal(r.records.length, 1);
  assert.equal(r.records[0].obj.message.content, "とちゅう");
  rmSync(d, { recursive: true });
});

test("多バイト文字が続く追記でも文字が割れない", () => {
  const d = dir();
  const p = join(d, "s.jsonl");
  writeFileSync(p, "");
  const t = new JsonlTail({ path: p });
  t.poll();
  const long = "折り紙の鶴を折る手順を説明します。".repeat(20);
  appendFileSync(p, user(long));
  const r = t.poll();
  assert.equal(r.records[0].obj.message.content, long);
  assert.equal(t.offset, r.records[0].end);
  rmSync(d, { recursive: true });
});

test("壊れた行は飛ばし、同じ塊の他の行は返す", () => {
  const d = dir();
  const p = join(d, "s.jsonl");
  writeFileSync(p, "");
  const t = new JsonlTail({ path: p });
  t.poll();
  appendFileSync(p, `${user("まえ")}これは JSON ではない\n${user("あと")}`);
  const r = t.poll();
  assert.equal(r.records.length, 2);
  assert.deepEqual(r.records.map((x) => x.obj.message.content), ["まえ", "あと"]);
  rmSync(d, { recursive: true });
});

test("切り詰め(size が offset より小さい)は reset。差分を作らない", () => {
  const d = dir();
  const p = join(d, "s.jsonl");
  writeFileSync(p, user("いち") + user("に"));
  const t = new JsonlTail({ path: p });
  t.poll();
  writeFileSync(p, user("あ")); // 短く書き直し
  const r = t.poll();
  assert.equal(r.reset, true);
  assert.equal(r.error, "truncated");
  assert.deepEqual(r.records, []);
  rmSync(d, { recursive: true });
});

test("同じ inode・同じ長さで中身だけ書き直されたら、印の不一致で reset", () => {
  const d = dir();
  const p = join(d, "s.jsonl");
  writeFileSync(p, user("いち"));
  const t = new JsonlTail({ path: p });
  t.poll();
  // 長さを変えずに中身を差し替える(サイズだけ見ていると素通りする形)
  writeFileSync(p, user("にい"));
  const r = t.poll();
  assert.equal(r.reset, true);
  assert.equal(r.error, "checkpoint-mismatch");
  rmSync(d, { recursive: true });
});

test("rename での差し替え(inode 変化)は reset", () => {
  const d = dir();
  const p = join(d, "s.jsonl");
  writeFileSync(p, user("いち"));
  const t = new JsonlTail({ path: p });
  const first = t.poll();
  const other = join(d, "new.jsonl");
  writeFileSync(other, user("いち") + user("に")); // 長い = 縮小では検出できない
  renameSync(other, p);
  const r = t.poll();
  assert.equal(r.reset, true);
  assert.equal(r.error, "generation-changed");
  assert.notEqual(r.generation, first.generation);
  rmSync(d, { recursive: true });
});

test("ファイルがまだ無くても例外にせず、現れたらそこから始める", () => {
  const d = dir();
  const p = join(d, "not-yet.jsonl");
  const t = new JsonlTail({ path: p });
  const r0 = t.poll();
  assert.equal(r0.ok, false);
  assert.equal(r0.error, "ENOENT");
  assert.deepEqual(r0.records, []);
  writeFileSync(p, user("さいしょ")); // 最初の発言で jsonl が生まれる
  assert.deepEqual(t.poll().records, [], "現れた時点は位置合わせだけ");
  appendFileSync(p, user("つぎ"));
  assert.equal(t.poll().records[0].obj.message.content, "つぎ");
  rmSync(d, { recursive: true });
});

test("一度に読む量には上限があり、残りは次の poll で続きから来る", () => {
  const d = dir();
  const p = join(d, "s.jsonl");
  writeFileSync(p, "");
  const t = new JsonlTail({ path: p, maxChunk: 200 });
  t.poll();
  const lines = [user("あ".repeat(50)), user("い".repeat(50)), user("う".repeat(50))];
  appendFileSync(p, lines.join(""));
  const r1 = t.poll();
  assert.ok(r1.records.length >= 1 && r1.records.length < 3, `上限で区切られる: ${r1.records.length}`);
  const seen = [...r1.records];
  for (let i = 0; i < 5 && seen.length < 3; i++) seen.push(...t.poll().records);
  assert.equal(seen.length, 3, "続きは次の poll で来る(取りこぼさない)");
  assert.deepEqual(
    seen.map((x) => x.obj.message.content),
    ["あ".repeat(50), "い".repeat(50), "う".repeat(50)],
  );
  rmSync(d, { recursive: true });
});

// --- SSE 再接続の判定(嘘の連続性を作らない為の唯一の分岐)-------------------
test("何も持っていない購読は初回。since=0 も初回として扱う", () => {
  assert.deepEqual(resumeDecision("", 3), { kind: "fresh" });
  assert.deepEqual(resumeDecision("0", 3), { kind: "fresh" });
  assert.deepEqual(resumeDecision(undefined, 3), { kind: "fresh" });
});

test("同じ世代の id は差分で繋ぐ", () => {
  assert.deepEqual(resumeDecision("3.7", 3), { kind: "resume", seq: 7 });
});

test("違う世代の id では繋がない(seq が振り直された後の嘘の追いつきを塞ぐ)", () => {
  assert.equal(resumeDecision("2.7", 3).kind, "gap");
  assert.equal(resumeDecision("2.7", 3).why, "epoch-mismatch");
});

test("ワーカー経路の素の数字を tmux 経路の追いつきに使わない", () => {
  // Number("7") は素直に 7 になるので、世代を見ないと**別の配信の seq で繋がって**しまう
  assert.equal(resumeDecision("7", 3).kind, "gap");
});

test("形が壊れた id は繋がない", () => {
  assert.equal(resumeDecision("3.", 3).kind, "gap");
  assert.equal(resumeDecision("3.x", 3).kind, "gap");
  assert.equal(resumeDecision("...", 3).kind, "gap");
});

// --- long-poll の栞 ---------------------------------------------------------
// 電話の本線はこちら(SSE は互換用に残るだけで本番の利用者は0人、DESIGN §2.36)。
test("栞は経路が読める形で組まれ、そのまま読み戻せる", () => {
  assert.equal(formatPollCursor({ route: "tmux", token: "a1b2", seq: 7, screenRev: 3 }), "t.a1b2.7.3");
  assert.equal(formatPollCursor({ route: "worker", token: "z9", seq: 4 }), "w.z9.4.0");
  assert.deepEqual(pollDecision("t.a1b2.7.3", "tmux", "a1b2"), { kind: "resume", seq: 7, screenRev: 3 });
  assert.deepEqual(pollDecision("w.z9.4.0", "worker", "z9"), { kind: "resume", seq: 4, screenRev: 0 });
});

test("栞を持たない初回は fresh(毎回 gap を出して gap を無意味にしない)", () => {
  assert.deepEqual(pollDecision("", "tmux", "a1"), { kind: "fresh" });
  assert.deepEqual(pollDecision(undefined, "tmux", "a1"), { kind: "fresh" });
  assert.deepEqual(pollDecision(null, "worker", "z9"), { kind: "fresh" });
});

test("再起動を跨いだ栞は繋がない(token が変わる)", () => {
  // ★これが `resumeDecision` 側に実在した欠陥の poll 版。連番 epoch だと再起動後も
  //   同じ値が出て、古い栞が黙って「追いついた」になる。
  assert.equal(pollDecision("t.a1b2.7.3", "tmux", "c3d4").kind, "gap");
  assert.equal(pollDecision("t.a1b2.7.3", "tmux", "c3d4").why, "epoch-mismatch");
});

test("経路が入れ替わったら繋がない(seq の空間が別物)", () => {
  // tmux で開いていた会話の pane が閉じられ worker 経路に落ちた場合。数字は有効に**見える**。
  assert.equal(pollDecision("t.a1b2.7.3", "worker", "a1b2").why, "route-changed");
  assert.equal(pollDecision("w.a1b2.7.0", "tmux", "a1b2").why, "route-changed");
});

test("形が壊れた栞・長すぎる栞は繋がない", () => {
  assert.equal(pollDecision("t.a1.7", "tmux", "a1").why, "cursor-malformed"); // 節が3つ
  assert.equal(pollDecision("t.a1.7.3.9", "tmux", "a1").why, "cursor-malformed"); // 節が5つ
  assert.equal(pollDecision("t.a1.x.3", "tmux", "a1").why, "cursor-malformed");
  assert.equal(pollDecision("t.a1.7.x", "tmux", "a1").why, "cursor-malformed");
  assert.equal(pollDecision("t.a1.-1.0", "tmux", "a1").why, "cursor-malformed");
  assert.equal(pollDecision(`t.a1.7.${"9".repeat(200)}`, "tmux", "a1").why, "cursor-too-long");
});

test("0 は有効な seq(`resumeDecision` の since=0 と違い、栞は空文字だけが初回)", () => {
  // 栞は不透明で電話は自分で作らない。`0` を初回扱いにすると、seq 0 の直後の poll が
  // **毎回**履歴読み直しになる。
  assert.deepEqual(pollDecision("t.a1.0.0", "tmux", "a1"), { kind: "resume", seq: 0, screenRev: 0 });
});
