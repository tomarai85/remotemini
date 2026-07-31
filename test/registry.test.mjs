// ペイン登録簿 — 「宛先を間違えない」ことだけを検査する。
//
// 出典: DESIGN.md §2.10(登録簿が必要な理由 = 2026-07-31 実測で cwd 一致もプロセス名も
//       会話を特定できないことが確定)。書き手は ~/.claude/statusline.sh の rc-backend ブロック。
//
// ここで守りたい事故は1つだけ: **別の会話に本文が入ること**。
// だから「決められない」を返すケースを、決められるケースより厚く検査する。
import { test } from "node:test";
import assert from "node:assert/strict";
import { parseEntry, readRegistry, resolveSessionPane } from "../src/registry.mjs";
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

const resolve = (sessionId, cwd, entries, panes) =>
  resolveSessionPane({ sessionId, cwd, entries, panes, isClaude: looksLikeClaudePane, resolveByCwd: byCwd });

const claudePane = (pane, path = CWD) => ({ pane, command: "2.1.220", path });

// ---- 1件のパース ----

test("statusline が書く実物の形をそのまま読める", () => {
  const e = parseEntry(rec(S1, "%12"), 1000);
  assert.deepEqual(e, { sessionId: S1, pane: "%12", model: "Opus 5", mtimeMs: 1000 });
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

test("登録時のペインが消えている -> tmux に居ない(ワーカー経路で安全)", () => {
  const r = resolve(S1, CWD, [{ sessionId: S1, pane: "%12", mtimeMs: 100 }], [claudePane("%99")]);
  assert.equal(r.pane, null);
  assert.equal(r.reason, "none");
});

test("★ペインは在るが claude が終了してシェルに戻っている -> 送らない(任意コマンド実行の防止)", () => {
  const panes = [{ pane: "%12", command: "zsh", path: CWD }];
  const r = resolve(S1, CWD, [{ sessionId: S1, pane: "%12", mtimeMs: 100 }], panes);
  assert.equal(r.pane, null);
  assert.equal(r.reason, "not-claude");
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

test("登録が無ければ cwd 経路。source で由来が分かる", () => {
  const r = resolve(S1, CWD, [], [claudePane("%12")]);
  assert.equal(r.pane, "%12");
  assert.equal(r.source, "cwd");
});

test("★他の会話が名乗り済みのペインは cwd 経路の候補から外す(候補は減る方向にしか動かない)", () => {
  // S2 が %13 を名乗っている。登録の無い S1 を cwd で探す時、%13 は S2 のものと分かっている。
  const entries = [{ sessionId: S2, pane: "%13", mtimeMs: 200 }];
  const panes = [claudePane("%12"), claudePane("%13")];
  const r = resolve(S1, CWD, entries, panes);
  assert.equal(r.pane, "%12", "名乗り済みを除けば候補は1つに定まる");
  // 名乗り済みを除いた結果ゼロになるなら、ワーカー経路(注入はしない)
  assert.equal(resolve(S1, CWD, [{ sessionId: S2, pane: "%12", mtimeMs: 1 }], [claudePane("%12")]).reason, "none");
});

test("tmux にペインが1つも無ければ none", () => {
  assert.equal(resolve(S1, CWD, [], []).reason, "none");
});
