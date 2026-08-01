// ペイン登録簿 — 「宛先を間違えない」ことだけを検査する。
//
// 出典: DESIGN.md §2.10(登録簿が必要な理由 = 2026-07-31 実測で cwd 一致もプロセス名も
//       会話を特定できないことが確定)。書き手は ~/.claude/statusline.sh の rc-backend ブロック。
//
// ここで守りたい事故は1つだけ: **別の会話に本文が入ること**。
// だから「決められない」を返すケースを、決められるケースより厚く検査する。
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  parseEntry,
  readRegistry,
  resolveSessionPane,
  registryOnlySessions,
  entryAlive,
  HEARTBEAT_TTL_MS,
} from "../src/registry.mjs";
import { looksLikeClaudePane, TmuxInjector } from "../src/inject.mjs";

const S1 = "1b5c9362-aaaa-bbbb-cccc-000000000001";
const S2 = "1b5c9362-aaaa-bbbb-cccc-000000000002";
const CWD = "/Users/Shared/dev/roundtrip";

// 実物と同じ形の登録内容(statusline.sh が printf で書く JSON)
const rec = (sid, pane, model = "Opus 5") =>
  JSON.stringify({ session_id: sid, pane, model });

// readRegistry に渡す偽 fs。{ "<name>": [text, mtimeMs] }
function fakeFs(files) {
  return {
    readdirSync: () => Object.keys(files),
    readFileSync: (p) => {
      const name = p.split("/").pop();
      if (!(name in files)) throw new Error("ENOENT");
      return files[name][0];
    },
    statSync: (p) => ({ mtimeMs: files[p.split("/").pop()][1] }),
  };
}

// cwd フォールバックは実物の resolvePane を使う(二重実装で乖離しないように)
const injectorFor = (paneList) =>
  new TmuxInjector({ tmux: { run: (a) => (a[0] === "list-panes" ? paneList : "") } });
const byCwd = (cwd, panes) => injectorFor("").resolvePane(cwd, panes);

// 下のテストの登録は mtimeMs が 1〜1000(小さい絶対値で新旧関係だけを表す)。
// 実時刻で判定させると全部「大昔の登録」になって死ぬので、now を揃えて渡す。
// 心拍そのものの検査は「登録の生死」節で now を明示して別に行う。
const NOW = 1000;
const resolve = (sessionId, cwd, entries, panes, extra = {}) =>
  resolveSessionPane({
    sessionId, cwd, entries, panes,
    isClaude: looksLikeClaudePane, resolveByCwd: byCwd,
    now: NOW, ttlMs: 5000, ...extra,
  });

const claudePane = (pane, path = CWD, tty = `/dev/ttys0${pane.slice(1)}`) =>
  ({ pane, command: "2.1.220", tty, path });

// ---- 1件のパース ----

test("statusline が書く実物の形をそのまま読める", () => {
  const e = parseEntry(
    JSON.stringify({ session_id: S1, pane: "%12", model: "Opus 5", tmux: "/tmp/s,42,0", pid: 777 }),
    1000,
  );
  assert.deepEqual(e, {
    sessionId: S1, pane: "%12", model: "Opus 5",
    server: "/tmp/s,42", // $TMUX の3つ目(クライアント番号)は世代と無関係なので落とす
    pid: 777,
    mtimeMs: 1000,
  });
});

test("同一性を書かない古い書き手の登録も読める(server/pid は空)", () => {
  const e = parseEntry(rec(S1, "%12"), 1000);
  assert.equal(e.server, "");
  assert.equal(e.pid, 0);
});

test("★pid / tmux が壊れていても登録全体は捨てない(心拍判定に落ちるだけ)", () => {
  const e = parseEntry(JSON.stringify({ session_id: S1, pane: "%12", tmux: "ごみ", pid: "777" }), 1);
  assert.equal(e.pane, "%12");
  assert.equal(e.server, "", "パターンに合わない $TMUX は無かった事にする");
  assert.equal(e.pid, 0, "文字列の pid は採らない");
});

test("書き込み途中の壊れた JSON は捨てる(次の周期で読み直せばよい)", () => {
  assert.equal(parseEntry('{"session_id":"' + S1, 1), null);
  assert.equal(parseEntry("", 1), null);
});

test("pane は %数字 のみ受け付ける(tmux の pane_id 形式)", () => {
  assert.equal(parseEntry(rec(S1, "work:0.0"), 1), null, "session:window.pane 形式は不可");
  assert.equal(parseEntry(rec(S1, "$(rm -rf /)"), 1), null);
  assert.equal(parseEntry(rec(S1, ""), 1), null);
  assert.equal(parseEntry(rec(S1, "%0"), 1).pane, "%0");
});

test("session_id が uuid の字種でない登録は捨てる", () => {
  assert.equal(parseEntry(rec("../../evil", "%1"), 1), null);
  assert.equal(parseEntry(rec("default", "%1"), 1), null);
});

// ---- ディレクトリの読み ----

test("登録簿が無くても落ちず、空配列(全会話が cwd 経路へ落ちるだけ)", () => {
  assert.deepEqual(readRegistry("/nope", { readdirSync: () => { throw new Error("ENOENT"); } }), []);
});

test("★ファイル名と中身の session_id が食い違う登録は捨てる(取り違えの温床)", () => {
  const files = {
    [`${S1}.json`]: [rec(S2, "%12"), 100], // 中身が別の会話を名乗っている
    [`${S2}.json`]: [rec(S2, "%13"), 200],
  };
  const got = readRegistry("/d", fakeFs(files));
  assert.equal(got.length, 1);
  assert.equal(got[0].sessionId, S2);
  assert.equal(got[0].pane, "%13");
});

test(".json 以外と壊れた1件は無視され、他の登録は生きる", () => {
  const files = {
    [`${S1}.json`]: [rec(S1, "%12"), 100],
    [`${S2}.json`]: ["{壊れ", 200],
    "README.txt": ["x", 300],
  };
  assert.deepEqual(readRegistry("/d", fakeFs(files)).map((e) => e.sessionId), [S1]);
});

// ---- 解決(ここが事故の分かれ目) ----

test("登録があり、そのペインが claude で、居場所も一致 -> 注入してよい", () => {
  const r = resolve(S1, CWD, [{ sessionId: S1, pane: "%12", mtimeMs: 100 }], [claudePane("%12")]);
  assert.deepEqual(r, { pane: "%12", reason: "ok", candidates: 1, source: "registry" });
});

test("★同じ cwd に claude が2つでも、登録があれば正しく特定できる(登録簿の本来の目的)", () => {
  const entries = [
    { sessionId: S1, pane: "%12", mtimeMs: 100 },
    { sessionId: S2, pane: "%13", mtimeMs: 200 },
  ];
  const panes = [claudePane("%12"), claudePane("%13")];
  assert.equal(resolve(S1, CWD, entries, panes).pane, "%12");
  assert.equal(resolve(S2, CWD, entries, panes).pane, "%13");
  // 登録が無ければ ambiguous で止まっていた場面
  assert.equal(resolve(S1, CWD, [], panes).reason, "ambiguous");
});

test("登録時のペインが消え、近くに claude も居ない -> tmux に居ない(ワーカー経路で安全)", () => {
  // claude は居るが**別の cwd**。この会話が生きている手掛かりが1つも無いので落として良い。
  const elsewhere = { pane: "%99", command: "2.1.220", path: "/somewhere/else" };
  const r = resolve(S1, CWD, [{ sessionId: S1, pane: "%12", mtimeMs: 100 }], [elsewhere]);
  assert.equal(r.pane, null);
  assert.equal(r.reason, "none");
});

test("★登録時のペインが消えたが、同じ cwd に名乗っていない claude が居る -> ワーカーを起こさない", () => {
  // 現実に起きる順序: rc-claude で開いて %12 を登録 → 終了 → 素の `claude --resume` で
  // %99 に開き直す。登録簿は %12 のまま古く、会話は %99 で生きている。ここでワーカーを
  // 起こすと同じ会話を2プロセスが触る(lost-update)。
  const r = resolve(S1, CWD, [{ sessionId: S1, pane: "%12", mtimeMs: 100 }], [claudePane("%99")]);
  assert.equal(r.pane, null, "推測で %99 に注入もしない");
  assert.equal(r.reason, "unregistered");
  assert.equal(r.source, "registry", "登録はあったが現実と合っていない、と区別できる");
});

test("★同じ cwd の claude を別の会話が名乗っていれば、それは警戒の材料にならない", () => {
  // %99 は S2 のものだと分かっている = S1 がそこで生きている可能性は消える。
  const entries = [{ sessionId: S1, pane: "%12", mtimeMs: 100 }, { sessionId: S2, pane: "%99", mtimeMs: 100 }];
  const r = resolve(S1, CWD, entries, [claudePane("%99")]);
  assert.equal(r.reason, "none");
});

test("★ペインは在るが claude が終了してシェルに戻っている -> 送らない(任意コマンド実行の防止)", () => {
  const panes = [{ pane: "%12", command: "zsh", path: CWD }];
  const r = resolve(S1, CWD, [{ sessionId: S1, pane: "%12", mtimeMs: 100 }], panes);
  assert.equal(r.pane, null);
  assert.equal(r.reason, "not-claude");
});

test("★シェルに戻っていて、かつ同じ cwd に名乗っていない claude が居る -> ワーカーも起こさない", () => {
  const panes = [{ pane: "%12", command: "zsh", path: CWD }, claudePane("%99")];
  const r = resolve(S1, CWD, [{ sessionId: S1, pane: "%12", mtimeMs: 100 }], panes);
  assert.equal(r.pane, null);
  assert.equal(r.reason, "unregistered");
  assert.equal(r.source, "registry");
});

test("★★そのペインをより新しい会話が名乗っている -> stale。ワーカーにも落とさない", () => {
  // ペインが使い回された場合。古い登録を信じると **別の会話に本文が入る**。
  const entries = [
    { sessionId: S1, pane: "%12", mtimeMs: 100 },
    { sessionId: S2, pane: "%12", mtimeMs: 200 },
  ];
  const r = resolve(S1, CWD, entries, [claudePane("%12")]);
  assert.equal(r.pane, null);
  assert.equal(r.reason, "stale");
  assert.equal(r.takenBy, S2);
  // 新しい方は通る
  assert.equal(resolve(S2, CWD, entries, [claudePane("%12")]).pane, "%12");
});

test("★登録ペインの現在地が会話の cwd と違う -> cwd-mismatch(登録を信じない)", () => {
  const r = resolve(S1, CWD, [{ sessionId: S1, pane: "%12", mtimeMs: 100 }], [claudePane("%12", "/elsewhere")]);
  assert.equal(r.pane, null);
  assert.equal(r.reason, "cwd-mismatch");
  assert.equal(r.panePath, "/elsewhere");
});

test("会話の cwd が不明な時は突き合わせを省く(登録だけで決める)", () => {
  const r = resolve(S1, "", [{ sessionId: S1, pane: "%12", mtimeMs: 100 }], [claudePane("%12", "/anywhere")]);
  assert.equal(r.pane, "%12");
});

// ---- 登録が無い会話(フォールバック) ----

test("★未登録の会話は、cwd に claude が1つしか無くても注入しない(unregistered)", () => {
  // 「その cwd に claude が1枚だけ」は**同定ではない**。実測で ~/.claude だけに192会話が
  // 同じ cwd を共有している = 今開いている1枚が選んだ会話である保証は無い。
  // 外れると他人の会話に本文と Enter が入って動き出すので、当てにいかず拒否する。
  const r = resolve(S1, CWD, [], [claudePane("%12")]);
  assert.equal(r.pane, null, "推測で注入先を決めない");
  assert.equal(r.reason, "unregistered");
  assert.equal(r.source, "cwd", "由来が cwd 経路だと分かる");
  assert.equal(r.candidates, 1);
});

test("★unregistered はワーカーにも落とさない(UNDECIDABLE 側)", () => {
  // そのペインがこの会話本人である可能性を否定できない。ワーカー(-p --resume)に
  // 落とすと同じ会話を2プロセスが読む(lost-update)ので、拒否で止める。
  const r = resolve(S1, CWD, [], [claudePane("%12")]);
  assert.notEqual(r.reason, "none", "none はワーカー経路 = ここに落としてはいけない");
});

test("★他の会話が名乗り済みのペインは cwd 経路の候補から外す(候補は減る方向にしか動かない)", () => {
  // S2 が %13 を名乗っている。登録の無い S1 を cwd で探す時、%13 は S2 のものと分かっている。
  const entries = [{ sessionId: S2, pane: "%13", mtimeMs: 200 }];
  const panes = [claudePane("%12"), claudePane("%13")];
  const r = resolve(S1, CWD, entries, panes);
  // 絞り込みは効いている(効いていなければ候補2で ambiguous になる)。ただし絞れても
  // cwd 経路は ok を返さない = unregistered で止まる。
  assert.equal(r.reason, "unregistered");
  assert.equal(r.candidates, 1, "名乗り済みを除けば候補は1つに定まる");
  // 名乗り済みを除いた結果ゼロになるなら、注入できる claude が居ない = ワーカー経路でよい。
  // (この行が絞り込みそのものの対照: 絞り込みを外すと unregistered になって落ちる)
  assert.equal(resolve(S1, CWD, [{ sessionId: S2, pane: "%12", mtimeMs: 1 }], [claudePane("%12")]).reason, "none");
});

test("tmux にペインが1つも無ければ none", () => {
  assert.equal(resolve(S1, CWD, [], []).reason, "none");
});

// ---- 未発言の会話を一覧に足す(registryOnlySessions) ----
//
// なぜ要るか: transcript の jsonl は最初のメッセージまで作られない(2026-07-31 edith 実測)。
// 一覧は jsonl の走査なので、開いて席を立った会話は電話から見えない = 最初の一言を送れない。
// ここで守りたいのは逆方向の事故: **操作できないものを一覧に出さない**こと。
// 出したのに送れない行は、Tom から見れば壊れている。だから採否は resolveSessionPane と同じ判定に委ねる。

const only = (listing, entries, panes, extra = {}) =>
  registryOnlySessions({
    listing, entries, panes, isClaude: looksLikeClaudePane,
    now: NOW, ttlMs: 5000, ...extra,
  });

test("jsonl がまだ無い登録は一覧に足される。cwd はペインの現在地を採る", () => {
  const got = only([], [{ sessionId: S1, pane: "%12", mtimeMs: 1000 }], [claudePane("%12")]);
  assert.equal(got.length, 1);
  assert.equal(got[0].id, S1);
  assert.equal(got[0].cwd, CWD, "jsonl が無いので突き合わせる相手が無い -> ペインの居場所");
  assert.equal(got[0].turns, 0);
  assert.equal(got[0].fromRegistryOnly, true, "UI が普通の会話と区別できる印");
  assert.equal(got[0].updatedAt, new Date(1000).toISOString());
});

test("★既に jsonl で一覧に居る会話を二重に出さない", () => {
  const listing = [{ id: S1, updatedAt: "2026-07-31T00:00:00.000Z" }];
  assert.deepEqual(only(listing, [{ sessionId: S1, pane: "%12", mtimeMs: 1000 }], [claudePane("%12")]), []);
});

test("★登録時のペインが消えている -> 出さない(送れない行を並べない)", () => {
  assert.deepEqual(only([], [{ sessionId: S1, pane: "%12", mtimeMs: 1000 }], [claudePane("%99")]), []);
});

test("★ペインは在るが claude でない(シェルに戻った) -> 出さない", () => {
  const panes = [{ pane: "%12", command: "zsh", path: CWD }];
  assert.deepEqual(only([], [{ sessionId: S1, pane: "%12", mtimeMs: 1000 }], panes), []);
});

test("★★同じペインをより新しい会話が名乗っている(stale) -> 古い方は出さない", () => {
  // ペイン使い回し。stale を一覧に出すと、その行を叩いた時に別の会話へ届きうる。
  const entries = [
    { sessionId: S1, pane: "%12", mtimeMs: 100 },
    { sessionId: S2, pane: "%12", mtimeMs: 200 },
  ];
  const got = only([], entries, [claudePane("%12")]);
  assert.deepEqual(got.map((s) => s.id), [S2], "新しい方だけ");
});

test("未発言が複数なら新しい順", () => {
  const entries = [
    { sessionId: S1, pane: "%12", mtimeMs: 100 },
    { sessionId: S2, pane: "%13", mtimeMs: 900 },
  ];
  const got = only([], entries, [claudePane("%12"), claudePane("%13")]);
  assert.deepEqual(got.map((s) => s.id), [S2, S1]);
});

test("登録簿が空なら何も足さない", () => {
  assert.deepEqual(only([], [], [claudePane("%12")]), []);
});

// ---- 登録の生死(2026-08-01 追加。ここが無いと実際に他人の会話へ本文が入る) ----
//
// 実測した事実:
//   1. tmux のペイン id は**サーバ世代ごとに %0 から振り直される**。~/.rc-backend/panes/ の
//      10 件が全部 %0 を名乗っていた(tmux サーバはその時1つも走っていない)。
//   2. 書き手は登録を消さない。会話が終わっても登録ファイルは残り続ける。
//   3. statusline は放置中でも 2 秒ごとに書き直す(90秒で45回 / median 2001ms)。
//   4. 前面判定は pgid == tpgid。Ctrl-Z で止めた claude は tty を握ったままなので、
//      tty 一致だけでは「今そのペインで前面に居る別のプロセス」に送ってしまう。
// 1+2 が揃うと「死んだ登録が、今そこに居る別の会話のペインを指す」状態になる。

const SERVER = "/private/tmp/tmux-501/default,900";
const withId = (sid, pane, pid, mtimeMs = NOW, server = SERVER) =>
  ({ sessionId: sid, pane, model: "", server, pid, mtimeMs });
/** pid -> プロセスの実体。既定は「そのペインの tty で前面に居る」= 生きている状態。 */
const procs = (map) => (pid) => map[pid] || null;
const fg = (tty) => ({ tty, foreground: true });

test("★同一性が揃っていれば心拍が古くても生きている(停止中の機械・スリープ明け)", () => {
  const e = withId(S1, "%0", 777, 0); // mtime は大昔
  const ctx = {
    now: NOW, ttlMs: HEARTBEAT_TTL_MS, server: SERVER,
    procOf: procs({ 777: fg("ttys012") }),
    paneBy: new Map([["%0", claudePane("%0", CWD, "/dev/ttys012")]]),
  };
  assert.equal(entryAlive(e, ctx), true, "本人であることが検証できていれば時刻は問わない");
});

test("★★tmux サーバの世代が違えば同じ %0 でも別物(実測: 登録10件が全部 %0)", () => {
  const e = withId(S1, "%0", 777, NOW, "/private/tmp/tmux-501/default,111"); // 前の世代
  const ctx = {
    now: NOW, ttlMs: HEARTBEAT_TTL_MS, server: SERVER, // 今のサーバは 900
    procOf: procs({ 777: fg("ttys012") }),
    paneBy: new Map([["%0", claudePane("%0", CWD, "/dev/ttys012")]]),
  };
  assert.equal(entryAlive(e, ctx), false);
});

test("★★suspend された claude は tty を握ったままだが前面ではない -> 生きているとみなさない", () => {
  // 実測: 前面 pgid=tpgid=54850 -> Ctrl-Z 後は tpgid だけシェルの 54787 に変わる。
  // tty 一致だけで通すと、そのペインで今前面に居る別プロセスに send-keys が入る。
  const e = withId(S1, "%0", 777);
  const ctx = {
    now: NOW, ttlMs: HEARTBEAT_TTL_MS, server: SERVER,
    procOf: procs({ 777: { tty: "ttys012", foreground: false } }),
    paneBy: new Map([["%0", claudePane("%0", CWD, "/dev/ttys012")]]),
  };
  assert.equal(entryAlive(e, ctx), false);
});

test("★プロセスが消えている / tty がペインと違う -> 生きているとみなさない", () => {
  const base = {
    now: NOW, ttlMs: HEARTBEAT_TTL_MS, server: SERVER,
    paneBy: new Map([["%0", claudePane("%0", CWD, "/dev/ttys012")]]),
  };
  assert.equal(entryAlive(withId(S1, "%0", 777), { ...base, procOf: () => null }), false, "pid が居ない");
  assert.equal(
    entryAlive(withId(S1, "%0", 777), { ...base, procOf: procs({ 777: fg("ttys099") }) }),
    false, "別の tty に居る = 別のペイン",
  );
});

test("★tmux サーバが分からない時は同一性を検証できない -> 生きているとみなさない", () => {
  const e = withId(S1, "%0", 777);
  const ctx = {
    now: NOW, ttlMs: HEARTBEAT_TTL_MS, server: "", // tmux が居ない / display-message が空
    procOf: procs({ 777: fg("ttys012") }),
    paneBy: new Map([["%0", claudePane("%0", CWD, "/dev/ttys012")]]),
  };
  assert.equal(entryAlive(e, ctx), false);
});

test("同一性の無い古い登録は心拍で判定する(TTL 内は生存、超えたら死亡)", () => {
  const old = { sessionId: S1, pane: "%0", model: "", server: "", pid: 0, mtimeMs: NOW - 2000 };
  const ctx = { now: NOW, ttlMs: HEARTBEAT_TTL_MS, server: SERVER, procOf: () => null, paneBy: new Map() };
  assert.equal(entryAlive(old, ctx), true, "実測 2 秒周期 = 1 回分の空振りは生存扱い");
  assert.equal(entryAlive({ ...old, mtimeMs: NOW - HEARTBEAT_TTL_MS - 1 }, ctx), false);
  // 未来の mtime(時計の巻き戻し・NFS のずれ)も信用しない
  assert.equal(entryAlive({ ...old, mtimeMs: NOW + 5000 }, ctx), false);
});

test("★★死んだ登録は他のペインを占有しない(占有し続けると生きた会話がワーカーに落ちる)", () => {
  // 実測した経路: 終わった会話の登録が %0 を掴んだまま -> 今 %0 に居る別の会話は
  // cwd 経路の候補から %0 を外され -> 候補ゼロ = none -> ワーカー(-p --resume)が起動 ->
  // 開いている TUI と同じ会話を2プロセスが触る(lost-update)。
  const dead = { sessionId: S2, pane: "%12", model: "", server: "", pid: 0, mtimeMs: NOW - 60_000 };
  const alive = resolve(S1, CWD, [dead], [claudePane("%12")], { ttlMs: HEARTBEAT_TTL_MS });
  assert.equal(alive.reason, "unregistered", "死んだ登録は候補から外す根拠にならない");
  assert.equal(alive.candidates, 1);
  // 対照: 同じ登録が生きていれば %12 は S2 のものなので候補から外れて none になる
  const withLive = resolve(S1, CWD, [{ ...dead, mtimeMs: NOW }], [claudePane("%12")], { ttlMs: HEARTBEAT_TTL_MS });
  assert.equal(withLive.reason, "none");
});

test("★★死んだ登録は自分の会話の同定にも使わない(別の会話へ注入する経路の根治)", () => {
  // 最悪の形: 死んだ登録が %12 を指していて、そのペインには今**別の会話**が居る。
  // 生死を見ないと reason=ok を返し、電話の本文と Enter がその会話に入る。
  const dead = { sessionId: S1, pane: "%12", model: "", server: "", pid: 0, mtimeMs: NOW - 60_000 };
  const r = resolve(S1, CWD, [dead], [claudePane("%12")], { ttlMs: HEARTBEAT_TTL_MS });
  assert.notEqual(r.reason, "ok", "★これが ok になるのが 2026-08-01 に見つけた事故経路");
  assert.equal(r.reason, "unregistered");
  assert.equal(r.source, "registry", "一度は名乗ったが現実と合っていない、と区別できる");
});

test("★死んだ登録しか無く、近くに claude も居ない会話はワーカー経路に落ちる(机で閉じた会話)", () => {
  // 生死判定を入れたせいで「閉じた会話に電話から送る」という正常系まで塞がないこと。
  const dead = { sessionId: S1, pane: "%12", model: "", server: "", pid: 0, mtimeMs: NOW - 60_000 };
  const r = resolve(S1, CWD, [dead], [], { ttlMs: HEARTBEAT_TTL_MS });
  assert.equal(r.reason, "none");
});

test("★★同着の登録は両方止める(どちらか片方を通すと二重注入になる)", () => {
  // 心拍は 2 秒ごとなので、同じペインを名乗る2件の mtime が一致することは起こりうる。
  // 「厳密に新しい方だけ止める」にすると同着で**両方が ok** になり、どちらの会話にも
  // 本文が入る。可用性(送れない)を差し出して閉じる。
  const entries = [
    { sessionId: S1, pane: "%12", model: "", server: "", pid: 0, mtimeMs: 500 },
    { sessionId: S2, pane: "%12", model: "", server: "", pid: 0, mtimeMs: 500 },
  ];
  assert.equal(resolve(S1, CWD, entries, [claudePane("%12")]).reason, "stale");
  assert.equal(resolve(S2, CWD, entries, [claudePane("%12")]).reason, "stale");
  // 同着のペインは「誰の物か決められない」ので、他の会話の候補からも外さない
  const other = resolve("1b5c9362-aaaa-bbbb-cccc-000000000003", CWD, entries, [claudePane("%12")]);
  assert.equal(other.reason, "unregistered", "占有者を確定できないペインを勝手に除外しない");
});

test("★死んだ登録は未発言一覧にも出さない(叩いても送れない行を並べない)", () => {
  const dead = { sessionId: S1, pane: "%12", model: "", server: "", pid: 0, mtimeMs: NOW - 60_000 };
  assert.deepEqual(only([], [dead], [claudePane("%12")], { ttlMs: HEARTBEAT_TTL_MS }), []);
  // 対照: 心拍が生きていれば出る
  assert.equal(
    only([], [{ ...dead, mtimeMs: NOW }], [claudePane("%12")], { ttlMs: HEARTBEAT_TTL_MS }).length, 1,
  );
});
