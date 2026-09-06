// `GET /api/sessions` が持つ **2 本目の生存信号**の検査(2026-09-06)。
//
// ── 何を測るか ──────────────────────────────────────────────────────────
// 机はセッションの生死を tmux の画面から再構成している。CLI 自身も同じ事を
// `claude agents --json` で公開しているので、机はそれを**並べて**持つ。
// 測るのは「一致するか」ではなく、**一致を言えない時に何を返すか**:
//   ・まだ読めていない / 失敗した / 古い → `ok:false` + 理由。配列は空
//   ・行の `cliSeen` は `true` / `false` / **`null`(言えない)** の 3 値
// ★此の機能で一番静かに壊れるのは「訊けなかった」が「CLI が知らない = 終わった会話」に
//   化ける道で、化けても画面は綺麗なまま = 壊れた事は後からしか判らない。
//   だから重心を其処に置き、陰性対照を 2 つ立てる(器の側と写像の側)。
//
// ── なぜ `src/server.mjs` を import しないか ────────────────────────────
// あの file は **import した瞬間に listen する**。だから器(`src/agentscache.mjs`)と
// 封筒(`src/wire.mjs`)を直に呼ぶ。ハンドラが其の 2 つを本当に通っているかは
// `test/wire-key-agreement.test.mjs` の原文の錨が別に見張っている(役割を分ける)。
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  AGENTS_STALE_MS,
  AGENTS_TTL_MS,
  agentsChildEnv,
  cliSeenIndex,
  positiveMs,
  agentsSnapshot,
  cliSeenFor,
  makeAgentsCache,
  readOutcome,
} from "../src/agentscache.mjs";
import { agentsCliBody, agentsCliView, sessionRow, sessionsBody } from "../src/wire.mjs";

// 2026-09-04 に実測した形(対話中 / 背景で別の鍵が来る)。此の検査は突き合わせしか
// 使わないので `sessionId` 以外は最小に留める —— 形の網羅は `test/agents-cli-reader.test.mjs` の役目。
const cliJson = (...ids) => JSON.stringify(ids.map((id) => ({ kind: "interactive", sessionId: id })));

/** 微少タスクを全部流す。器は `then → catch → finally` の 3 段なので 1 tick では足りない。 */
const flush = async () => {
  for (let i = 0; i < 3; i++) await new Promise((r) => setImmediate(r));
};

/**
 * 時計と子プロセスを注入した器。**本物の `claude` は一度も起きない**。
 *
 * `waiting` に解決していない読みが積まれるので、「何本 起こしたか」と
 * 「まだ答えていない読みが在るか」を数で言える。
 */
function harness({ ttlMs = AGENTS_TTL_MS, staleMs = AGENTS_STALE_MS } = {}) {
  const clock = { t: 1_700_000_000_000 };
  const calls = [];
  const waiting = [];
  const exec = (cmd, args, opts) => {
    calls.push({ cmd, args, opts });
    return new Promise((resolve, reject) => waiting.push({ resolve, reject }));
  };
  const cache = makeAgentsCache({ exec, now: () => clock.t, ttlMs, staleMs, cmd: "fake-claude" });
  return {
    clock,
    calls,
    cache,
    spawns: () => calls.length,
    unanswered: () => waiting.length,
    async settle(stdout) {
      waiting.shift().resolve({ stdout });
      await flush();
    },
    async breakIt(err) {
      waiting.shift().reject(err);
      await flush();
    },
  };
}

const timeoutErr = () => Object.assign(new Error("child killed"), { killed: true, signal: "SIGKILL" });

// ── ① 器: 非同期・キャッシュ・単発化 ─────────────────────────────────────

test("最初の要求は `pending`(0 件ではない)で、読みを 1 本だけ起こす", () => {
  const h = harness();
  const first = h.cache.read(["A"]);
  assert.equal(first.ok, false, "まだ何も読めていないのに ok を名乗っている");
  assert.equal(first.reason, "pending");
  assert.deepEqual([first.both, first.onlyInRegistry, first.onlyInCli], [[], [], []]);
  assert.equal(first.at, null, "一度も成功していないのに時刻が在る");
  assert.equal(first.ageMs, null);
  assert.equal(h.spawns(), 1);
  assert.equal(h.calls[0].cmd, "fake-claude", "注入した cmd を使っていない");
  assert.deepEqual(h.calls[0].args, ["agents", "--json"]);
});

test("★飛んでいる間に来た要求は、待たされずに前の答えを受け取る(子は 1 本のまま)", async () => {
  const h = harness();
  h.cache.read(["A"]);
  h.cache.read(["A"]);
  h.cache.read(["A"]);
  assert.equal(h.spawns(), 1, "要求のたびに子が立っている(単発化が効いていない)");
  await h.settle(cliJson("A"));

  const fresh = h.cache.read(["A"]);
  assert.equal(fresh.ok, true);
  assert.deepEqual(fresh.both, ["A"]);
  assert.equal(h.spawns(), 1, "TTL の中なのに測り直している");

  // TTL を跨ぐと測り直しが**始まる**。始まっただけで、答えは前の物のまま。
  h.clock.t += AGENTS_TTL_MS;
  const during = h.cache.read(["A"]);
  assert.equal(h.spawns(), 2, "TTL を跨いでも測り直しが始まっていない");
  assert.equal(during.ok, true, "飛んでいる間に前の結果を捨てている");
  assert.deepEqual(during.both, ["A"]);
  assert.equal(h.unanswered(), 1, "2 本目がまだ答えていない前提が崩れている");
});

test("★★決して答えない読みが在っても、一覧は即答する(応答の速さが CLI に依存しない)", () => {
  const h = harness();
  const s = h.cache.read(["A"]);
  // `read` が await していれば此処には Promise が返る = 一覧が CLI を待つ造りになった合図。
  assert.equal(typeof s.then, "undefined", "`read` が Promise を返している = 一覧が CLI を待つ");
  assert.equal(s.reason, "pending");
  // 2 回目・3 回目も同じ速さで返る(ぶら下がった読みは 1 本のまま)。
  assert.equal(h.cache.read(["A"]).reason, "pending");
  assert.equal(h.cache.read(["A"]).reason, "pending");
  assert.equal(h.unanswered(), 1, "答えない読みが増えている = 要求ごとに子を立てている");
  assert.equal(h.spawns(), 1);
});

test("時間切れは `ok:false` / `timeout` で、配列は空・行は `null`", async () => {
  const h = harness();
  h.cache.read(["A", "B"]);
  await h.breakIt(timeoutErr());
  const s = h.cache.read(["A", "B"]);
  assert.equal(s.ok, false);
  assert.equal(s.reason, "timeout");
  assert.deepEqual([s.both, s.onlyInRegistry, s.onlyInCli], [[], [], []]);
  assert.equal(cliSeenFor(s, "A"), null, "読めなかったのに行が生死を名乗っている");
  assert.equal(cliSeenFor(s, "B"), null);
});

test("★成功の後の失敗は、古い成功ではなく失敗を名乗る(故障が『少し古い正常』の顔をしない)", async () => {
  const h = harness();
  h.cache.read(["A"]);
  await h.settle(cliJson("A"));
  assert.equal(h.cache.read(["A"]).ok, true);

  h.clock.t += AGENTS_TTL_MS;
  h.cache.read(["A"]); // 2 本目が始まる
  await h.breakIt(timeoutErr());
  const s = h.cache.read(["A"]);
  assert.equal(s.ok, false, "1 度失敗したのに、前の成功をそのまま出している");
  assert.equal(s.reason, "timeout");
  assert.ok(typeof s.at === "string", "最後に成功した時刻まで消している(古さが判らなくなる)");
  assert.ok(Number.isInteger(s.ageMs) && s.ageMs >= AGENTS_TTL_MS);
});

test("★古い成功は `stale`。古さは隠さない", async () => {
  const h = harness();
  h.cache.read(["A"]);
  await h.settle(cliJson("A"));
  h.clock.t += AGENTS_STALE_MS + 1;
  const s = h.cache.read(["A"]);
  assert.equal(s.ok, false, "60 秒より古い観測を現在形で出している");
  assert.equal(s.reason, "stale");
  assert.deepEqual(s.both, [], "古い時に配列を読ませている");
  assert.ok(typeof s.at === "string" && Number.isInteger(s.ageMs));
  assert.ok(s.ageMs > AGENTS_STALE_MS, "古さの数字が古さを語っていない");
  assert.equal(cliSeenFor(s, "A"), null);
});

test("子を注入しない器は投げずに `no-runner` を返す(検査が本物の claude を起こさない)", () => {
  const cache = makeAgentsCache();
  const s = cache.read(["A"]);
  assert.equal(s.ok, false);
  assert.equal(s.reason, "no-runner");
  assert.deepEqual(s.both, []);
});

test("★1 本目は時計の原点に関わらず立つ(『まだ一度も』を時刻 0 と混ぜない)", () => {
  // 書いた其の日に此の検査が捕まえた欠陥: 「最後に試した時刻」を 0 で持つと、
  // 原点の小さい時計(注入した物 / 単調時計)では `now() - 0 >= ttl` が偽になり、
  // **1 本目が永久に立たない** = 帯は `pending` のまま固まる。本番の `Date.now()` では
  // 起きないので、実機だけが緑という一番見つけにくい形。
  const calls = [];
  const cache = makeAgentsCache({
    exec: (...a) => { calls.push(a); return new Promise(() => {}); },
    now: () => 1,
  });
  const s = cache.read(["A"]);
  assert.equal(calls.length, 1, "1 本目が立っていない(時計の原点が TTL より小さい)");
  assert.equal(s.reason, "pending");
});

test("子の起動が同期で投げても、器は投げずに理由へ落とす", () => {
  const cache = makeAgentsCache({
    exec: () => { throw Object.assign(new Error("no such file"), { code: "ENOENT" }); },
    now: () => 1,
  });
  const s = cache.read(["A"]);
  assert.equal(s.ok, false);
  assert.equal(s.reason, "spawn-failed");
});

// ── ② 突き合わせの写像 ──────────────────────────────────────────────────

test("★台帳 {A,B} と CLI {A,C}: both=[A] / onlyInRegistry=[B] / onlyInCli=[C]", async () => {
  const h = harness();
  h.cache.read(["A", "B"]);
  await h.settle(cliJson("A", "C"));
  const s = h.cache.read(["A", "B"]);
  assert.equal(s.ok, true);
  assert.deepEqual(s.both, ["A"]);
  assert.deepEqual(s.onlyInRegistry, ["B"], "終わった疑いの在る会話を拾えていない");
  assert.deepEqual(s.onlyInCli, ["C"], "電話から作った物でない会話を拾えていない");
  assert.equal(s.dropped, 0);

  // 行の側。★**登録の無い行は `false` ではなく `null`** —— 突き合わせた事実が 1 つも無い。
  assert.equal(cliSeenFor(s, "A"), true);
  assert.equal(cliSeenFor(s, "B"), false);
  assert.equal(cliSeenFor(s, "Z"), null, "台帳に居ない行を『CLI が知らない』と断じている");

  // 一覧の 1 行に載る形(`live` に**足すだけ**で、既存の鍵は 1 つも動かない)。
  const live = { route: "tmux", pane: "%12", screen: "SENDABLE" };
  const row = sessionRow({ id: "A" }, { ...live, cliSeen: cliSeenFor(s, "A") }, undefined, null);
  assert.equal(row.live.cliSeen, true);
  assert.equal(row.live.route, "tmux", "既存の鍵が動いている(追加のみではない)");
  assert.equal(row.live.pane, "%12");
});

test("★★陰性対照(写像): `ok:false` で配列を読む版と、今の版が違う答えを出す", () => {
  // 器が配列を空にする前の形 —— 「読めなかったのに配列が残っている」を手で作る。
  // 此れは想像上の入力ではない: `agentsSnapshot` を 1 行変えれば実際に此の形が出る。
  const bad = {
    ok: false, reason: "timeout", at: null, ageMs: null,
    both: ["A"], onlyInRegistry: ["B"], onlyInCli: [], dropped: 0,
  };
  // 壊した写像 = `ok` を見ずに配列だけ読む版(= 此の検査が捕まえたい変異そのもの)。
  const broken = (a, id) => (a.both.includes(id) ? true : a.onlyInRegistry.includes(id) ? false : null);

  assert.equal(cliSeenFor(bad, "A"), null, "★`ok:false` なのに『生きている』と言っている");
  assert.equal(cliSeenFor(bad, "B"), null, "★`ok:false` なのに『終わった会話』と言っている");
  assert.equal(broken(bad, "A"), true, "罠の前提: 壊した写像は true を作る");
  assert.equal(broken(bad, "B"), false, "罠の前提: 壊した写像は false を作る");
  assert.notEqual(cliSeenFor(bad, "A"), broken(bad, "A"),
    "2 つが同じ答え = 此の検査は写像の `ok` の見張りを何も測っていない");
  assert.notEqual(cliSeenFor(bad, "B"), broken(bad, "B"));
});

test("★★陰性対照(器): 読めなかった時の封筒と、本当に 0 件の封筒が別の値になる", async () => {
  const h = harness();
  h.cache.read([]);
  await h.settle("[]"); // 本当に 0 件
  const empty = h.cache.read([]);

  const g = harness();
  g.cache.read([]);
  await g.breakIt(timeoutErr()); // 訊けなかった
  const unreadable = g.cache.read([]);

  assert.equal(empty.ok, true, "0 件の観測を『読めなかった』側へ倒している");
  assert.equal(unreadable.ok, false);
  assert.notDeepEqual(empty, unreadable, "2 つが同じ値 = 区別が実装されていない");
  assert.notDeepEqual(agentsCliBody(empty).display, agentsCliBody(unreadable).display,
    "文面まで同じ = 帯を読んでも 2 つを見分けられない");
});

test("crossCheck へ渡す前に器が壊れていても、素通しの理由がそのまま出る", () => {
  // `agentsSnapshot` は `crossCheck` が `ok:false` を返した時に握り潰さない。
  const s = agentsSnapshot({ agents: { ok: false, sessions: [], reason: "not-array" }, at: 1000, reason: null }, ["A"], 1001);
  assert.equal(s.ok, false);
  assert.equal(s.reason, "not-array", "読めない中身を握り潰して ok:true にしている");
  assert.deepEqual(s.both, []);
});

test("落とした行の数は封筒に残る(1 行の欠けを黙って飲まない)", async () => {
  const h = harness();
  h.cache.read(["A"]);
  await h.settle(JSON.stringify([{ kind: "interactive", sessionId: "A" }, { kind: "interactive" }, null]));
  const s = h.cache.read(["A"]);
  assert.equal(s.ok, true);
  assert.equal(s.dropped, 2);
  assert.deepEqual(s.both, ["A"]);
});

// ── ③ 終わった子 1 回ぶんの読み分け ─────────────────────────────────────

test("終わり方ごとに別の語になる(答えなかった / 失敗した / 起動できなかった)", () => {
  assert.equal(readOutcome({ stdout: cliJson("A") }).ok, true);
  assert.equal(readOutcome({ err: timeoutErr() }).reason, "timeout");
  assert.equal(readOutcome({ err: Object.assign(new Error("x"), { code: "ETIMEDOUT" }) }).reason, "timeout");
  assert.equal(readOutcome({ err: Object.assign(new Error("x"), { code: "ENOENT" }) }).reason, "spawn-failed",
    "起動できなかった失敗が `exit-ENOENT` の様な在り得ない語になっている");
  assert.equal(readOutcome({ err: Object.assign(new Error("x"), { code: 2 }) }).reason, "exit-2");
  assert.equal(readOutcome({ stdout: "not json at all" }).reason, "not-json");
  assert.equal(readOutcome({ stdout: "" }).reason, "empty");
  // ★終了コードが 0 でない時に中身を読んでいない事(読むと「失敗」が「0 件」に化ける)
  assert.equal(readOutcome({ err: Object.assign(new Error("x"), { code: 3 }) }).ok, false);
});

test("子の PATH に置き場を足す(launchd の最小 env でも claude を掴める)— native install が先", () => {
  const env = agentsChildEnv({ HOME: "/Users/x", PATH: "/usr/bin" });
  // ★順序が本体(2026-09-06、Codex が friday で再現): `/opt/homebrew/bin/claude` は古い npm 版で
  //   `agents --json` を知らない。homebrew を先に置く写しは此処で赤になる。
  assert.deepEqual(env.PATH.split(":"), ["/Users/x/.local/bin", "/opt/homebrew/bin", "/usr/bin"]);
  // PATH が空(launchd の素の env)でも組める
  assert.deepEqual(agentsChildEnv({ HOME: "/Users/x" }).PATH.split(":"),
    ["/Users/x/.local/bin", "/opt/homebrew/bin"]);
  // 既に在る置き場を二重に積まない(そして既存の並びより **前** に来る = 古い版を追い越す)
  const twice = agentsChildEnv({ HOME: "/Users/x", PATH: "/opt/homebrew/bin:/usr/bin" });
  assert.equal(twice.PATH.split(":").filter((p) => p === "/opt/homebrew/bin").length, 1);
  assert.equal(twice.PATH.split(":")[0], "/Users/x/.local/bin");
  // HOME が無い env でも投げない —— そして os.homedir() で native install を補って**先頭**に置く
  //   (⑤ の検査が同じ事を独立に見る)。homebrew が先頭に来る形は、古い版を引く経路そのもの。
  const noHome = agentsChildEnv({ PATH: "/usr/bin" }).PATH.split(":");
  assert.ok(noHome[0].endsWith("/.local/bin"), noHome[0]);
  assert.equal(noHome[1], "/opt/homebrew/bin");
});

// ── ④ 封筒と文面 ────────────────────────────────────────────────────────

const ENVELOPE_KEYS = ["ageMs", "at", "both", "display", "dropped", "ok", "onlyInCli", "onlyInRegistry", "reason"];

test("★封筒は鍵を 1 つも欠かさない(渡し忘れ・古いサーバと見分けが付く様に)", () => {
  const ok = agentsSnapshot({ agents: { ok: true, sessions: [{ sessionId: "A" }], dropped: 0 }, at: 1000, reason: null }, ["A"], 1500);
  for (const input of [undefined, null, {}, "nonsense", ok, { ok: false, reason: "stale" }]) {
    assert.deepEqual(Object.keys(agentsCliBody(input)).sort(), ENVELOPE_KEYS,
      `鍵が欠けた入力: ${JSON.stringify(input)}`);
  }
  // 渡し忘れは「読めていない」へ倒す(0 件へ倒さない)
  assert.equal(agentsCliBody(undefined).ok, false);
  assert.equal(agentsCliBody(undefined).reason, "pending");
});

test("★封筒は `ok:false` の配列を必ず空にする(呼び側が何を入れても)", () => {
  const body = agentsCliBody({ ok: false, reason: "timeout", both: ["A"], onlyInRegistry: ["B"], onlyInCli: ["C"] });
  assert.deepEqual([body.both, body.onlyInRegistry, body.onlyInCli], [[], [], []]);
  assert.equal(cliSeenFor(body, "A"), null);
});

test("★文面は数を語る。読めなかった時は数の代わりに理由の語を出す", () => {
  const ok = agentsSnapshot(
    { agents: { ok: true, sessions: [{ sessionId: "A" }, { sessionId: "C" }], dropped: 0 }, at: 1000, reason: null },
    ["A", "B"], 1500,
  );
  const note = agentsCliView(ok).note;
  assert.match(note, /confirms 1 of 2/, "確認できた数と登録の数を言っていない");
  assert.match(note, /1 it no longer knows/, "CLI が知らない数を言っていない");

  for (const why of ["timeout", "pending", "stale", "spawn-failed", "exit-1"]) {
    const bad = agentsCliView({ ok: false, reason: why }).note;
    assert.ok(bad.includes(why), `理由の語 (${why}) が文面に出ていない`);
    assert.doesNotMatch(bad, /confirms/, "★読めなかったのに『何本 確認した』と語っている");
  }
  // 理由が空でも文は成立する(空の括弧を出さない)
  assert.match(agentsCliView(null).note, /unreadable/);
});

test("封筒に載る(`sessionsBody` を通っている)。既存の鍵は 1 つも動かない", () => {
  const before = sessionsBody({ sessions: [], scan: { files: 1, read: 1, cached: 0 }, paneFault: null, publishedBuild: 105, appBuild: "96" });
  assert.equal(before.agentsCli.ok, false, "渡さなかった時に ok を名乗っている");
  assert.equal(before.agentsCli.reason, "pending");
  assert.equal(typeof before.agentsCli.display.note, "string");
  // 追加のみ = 既存の鍵の意味が動いていない
  assert.deepEqual(before.sessions, []);
  assert.equal(before.paneFault, null);
  assert.ok(before.display.scan.length > 0);
  assert.ok(before.display.update.includes("105"), "帯の文面が壊れた(追加のみではない)");

  const ok = agentsSnapshot({ agents: { ok: true, sessions: [{ sessionId: "A" }], dropped: 0 }, at: 1000, reason: null }, ["A"], 1500);
  const after = sessionsBody({ sessions: [], scan: {}, paneFault: null, agentsCli: ok });
  assert.equal(after.agentsCli.ok, true);
  assert.deepEqual(after.agentsCli.both, ["A"]);
  assert.match(after.agentsCli.display.note, /confirms 1 of 1/);
});


// ── ⑤ Codex 2026-09-06 の 6 点(どれも「読めない」が「正常」の顔をする経路)───────────
test("log の口が投げても read() は投げない(器は壊れず、次の刻みで測り直す)", () => {
  let t = 0;
  const cache = makeAgentsCache({
    exec: () => { throw Object.assign(new Error("no such file"), { code: "ENOENT" }); },
    now: () => t,
    onError: () => { throw new Error("logger failed"); },
    ttlMs: 10,
  });
  let out;
  assert.doesNotThrow(() => { out = cache.read(["a"]); });
  assert.equal(out.ok, false);
  assert.equal(out.reason, "spawn-failed");
  t = 20;
  assert.doesNotThrow(() => { out = cache.read(["a"]); });   // 2 本目も投げない(inFlight が残っていない)
  assert.equal(out.ok, false);
});

test("時刻 0 の成功を『成功が無い』と読まない(epoch-0 でも stale になる)", () => {
  const st = { agents: { ok: true, sessions: [], dropped: 0 }, at: 0, reason: null };
  const snap = agentsSnapshot(st, [], 60_001, 60_000);
  assert.equal(snap.ok, false);
  assert.equal(snap.reason, "stale");
  assert.equal(snap.at, new Date(0).toISOString());
  assert.equal(snap.ageMs, 60_001);
  // まだ一度も成功していない = null は pending
  const none = agentsSnapshot({ agents: null, at: null, reason: null }, [], 5, 60_000);
  assert.equal(none.reason, "pending");
  assert.equal(none.at, null);
});

test("行の照合は Set の索引で(agentsCli でも索引でも同じ答え)", () => {
  const cli = { ok: true, both: ["a", "b"], onlyInRegistry: ["c"], onlyInCli: ["z"] };
  const idx = cliSeenIndex(cli);
  assert.ok(idx.both instanceof Set && idx.gone instanceof Set);
  for (const src of [cli, idx]) {
    assert.equal(cliSeenFor(src, "a"), true);
    assert.equal(cliSeenFor(src, "c"), false);
    assert.equal(cliSeenFor(src, "q"), null);
  }
  // 読めていない索引は全部 null
  const bad = cliSeenIndex({ ok: false, both: ["a"], onlyInRegistry: ["c"] });
  assert.equal(cliSeenFor(bad, "a"), null);
  assert.equal(cliSeenFor(bad, "c"), null);
});

test("ok:true なのに配列が無い / 配列でない封筒は『読めていない(malformed)』へ倒す", () => {
  for (const bad of [{ ok: true }, { ok: true, both: "x", onlyInRegistry: [], onlyInCli: [] }, { ok: true, both: [], onlyInRegistry: null, onlyInCli: [] }]) {
    const body = agentsCliBody(bad);
    assert.equal(body.ok, false);
    assert.equal(body.reason, "malformed");
    assert.deepEqual([body.both, body.onlyInRegistry, body.onlyInCli], [[], [], []]);
    assert.match(body.display.note, /could not be read/);
  }
  // 形の揃った成功は今までどおり
  const good = agentsCliBody({ ok: true, both: ["a"], onlyInRegistry: [], onlyInCli: [], at: "2026-09-06T00:00:00.000Z", ageMs: 1, dropped: 0 });
  assert.equal(good.ok, true);
});

test("設定の ms は正の有限だけ(負・0・NaN・無限は既定へ)", () => {
  assert.equal(positiveMs("-1", 10_000), 10_000);
  assert.equal(positiveMs("0", 10_000), 10_000);
  assert.equal(positiveMs("abc", 10_000), 10_000);
  assert.equal(positiveMs("Infinity", 10_000), 10_000);
  assert.equal(positiveMs(undefined, 10_000), 10_000);
  assert.equal(positiveMs("2500", 10_000), 2500);
  assert.equal(positiveMs(7, 10_000), 7);
});

test("HOME の無い env でも native install を先頭に置く(古い homebrew 版を追い越す)", () => {
  const env = agentsChildEnv({ PATH: "/usr/bin:/bin" });
  const first = env.PATH.split(":")[0];
  assert.ok(first.endsWith("/.local/bin"), first);
  assert.equal(env.PATH.split(":")[1], "/opt/homebrew/bin");
});
