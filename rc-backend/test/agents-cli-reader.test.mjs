// `claude agents --json` を読む層の検査(2026-09-04)。
//
// 此の module の存在理由は 1 つの区別に集約される: **「訊けなかった」と「0 件だった」を
// 同じ値にしない**。だから検査の重心も其処に置く —— 形の変換より、
// 読めなかった時に何を返すか。
import { test } from "node:test";
import assert from "node:assert/strict";
import { parseAgents, readAgents, crossCheck } from "../src/agentscli.mjs";

// 2026-09-04 に此の機械で実測した形(鍵の和集合と、対話中 / 背景の差)。
const REAL = JSON.stringify([
  { kind: "interactive", sessionId: "sess-aaaa", cwd: "/Users/x", pid: 4242, status: "idle",
    name: "remote-mini", startedAt: "2026-09-04T01:00:00Z" },
  { kind: "background", sessionId: "sess-bbbb", id: "cfdba636", cwd: "/Users/x", state: "blocked",
    name: "USA-preparation", startedAt: "2026-09-03T20:00:00Z" },
]);

test("実測した形をそのまま読める(対話中と背景で別の鍵が来る)", () => {
  const r = parseAgents(REAL);
  assert.equal(r.ok, true);
  assert.equal(r.sessions.length, 2);
  const [a, b] = r.sessions;
  assert.equal(a.kind, "interactive");
  assert.equal(a.pid, 4242);
  assert.equal(a.status, "idle");
  assert.equal(a.state, null, "対話中の行に背景側の語彙が生えている");
  assert.equal(b.kind, "background");
  assert.equal(b.id, "cfdba636", "`claude stop` が取る短い id が落ちている");
  assert.equal(b.state, "blocked");
  assert.equal(b.pid, null);
});

test("★読めなかった時は 0 件と別の値になる(此の module の存在理由)", () => {
  for (const [input, reason] of [["", "empty"], ["   ", "empty"], ["not json at all", "not-json"],
                                 ["{\"sessions\":[]}", "not-array"]]) {
    const r = parseAgents(input);
    assert.equal(r.ok, false, `${reason}: ok が true になっている`);
    assert.equal(r.reason, reason);
    assert.deepEqual(r.sessions, []);
  }
  // 本当に 0 件の時だけ ok:true
  const empty = parseAgents("[]");
  assert.equal(empty.ok, true);
  assert.deepEqual(empty.sessions, []);
});

test("★陰性対照: 空の一覧と読めない出力が同じ値なら此の検査は無意味", () => {
  const unreadable = parseAgents("not json at all");
  const empty = parseAgents("[]");
  assert.notDeepEqual(unreadable, empty, "2 つが同じ値 = 区別が実装されていない");
  assert.notEqual(unreadable.ok, empty.ok);
});

test("壊れた行は其の行だけ落として数える(1 行で一覧ごと落とさない)", () => {
  const r = parseAgents(JSON.stringify([
    { kind: "interactive", sessionId: "sess-ok" },
    { kind: "interactive" },                 // sessionId が無い = 突き合わせに使えない
    null,
    "not an object",
    { sessionId: "" },                       // 空文字は無いのと同じ
  ]));
  assert.equal(r.ok, true);
  assert.equal(r.sessions.length, 1);
  assert.equal(r.sessions[0].sessionId, "sess-ok");
  assert.equal(r.dropped, 4);
});

test("知らない鍵は運ばない(机が知らない物を電話へ渡さない)", () => {
  const r = parseAgents(JSON.stringify([
    { kind: "interactive", sessionId: "s1", secretToken: "leak-me", homeDir: "/Users/x" },
  ]));
  assert.deepEqual(Object.keys(r.sessions[0]).sort(),
    ["cwd", "id", "kind", "name", "pid", "sessionId", "startedAt", "state", "status"]);
});

test("知らない kind は `unknown` に倒す(将来 CLI が種別を増やした時に嘘を作らない)", () => {
  const r = parseAgents(JSON.stringify([{ kind: "cloud", sessionId: "s1" }]));
  assert.equal(r.sessions[0].kind, "unknown");
});

test("readAgents: 終了コードが 0 でなければ中身を読まない", () => {
  const r = readAgents({ run: () => ({ status: 1, stdout: "[]" }) });
  assert.equal(r.ok, false, "失敗した呼び出しの出力を読んでいる");
  assert.equal(r.reason, "exit-1");
});

test("readAgents: spawn が投げても throw せずに理由を返す", () => {
  const r = readAgents({ run: () => { throw new Error("ENOENT"); } });
  assert.equal(r.ok, false);
  assert.equal(r.reason, "spawn-failed");
});

test("readAgents: 呼び出し器を渡さない呼び手は fail closed", () => {
  const r = readAgents();
  assert.equal(r.ok, false);
  assert.equal(r.reason, "no-runner");
});

test("readAgents: 既定の引数は `agents --json`(呼ぶ物が変わったら検査が気づく)", () => {
  let seen = null;
  readAgents({ run: (cmd, args) => { seen = [cmd, args]; return { status: 0, stdout: "[]" }; } });
  assert.deepEqual(seen, ["claude", ["agents", "--json"]]);
});

test("crossCheck: 両方が読めた時だけ突き合わせる", () => {
  const agents = parseAgents(REAL);
  const r = crossCheck(["sess-aaaa", "sess-gone"], agents);
  assert.equal(r.ok, true);
  assert.deepEqual(r.both, ["sess-aaaa"]);
  assert.deepEqual(r.onlyInRegistry, ["sess-gone"], "台帳に残っている終わった会話が出ない");
  assert.deepEqual(r.onlyInCli, ["sess-bbbb"], "電話から作っていない会話が出ない");
});

test("★crossCheck: CLI が読めなければ何も主張しない(台帳を殺さない)", () => {
  const r = crossCheck(["sess-aaaa"], parseAgents("not json"));
  assert.equal(r.ok, false, "読めなかったのに突き合わせの結論を出している");
  assert.deepEqual(r.onlyInRegistry, [], "CLI が答えないだけで台帳の会話を『居ない』と言っている");
  assert.equal(r.reason, "not-json");
});

test("crossCheck: 台帳が空でも CLI 側は出る(片方が空でも壊れない)", () => {
  const r = crossCheck([], parseAgents(REAL));
  assert.equal(r.ok, true);
  assert.deepEqual(r.both, []);
  assert.deepEqual(r.onlyInCli, ["sess-aaaa", "sess-bbbb"]);
});
