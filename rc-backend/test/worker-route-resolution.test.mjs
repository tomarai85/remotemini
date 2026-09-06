// worker 経路の launcher 解決(2026-09-06)。`server.mjs` は import しない(listen する)。
//
// 測るのは順序と「無い時に何を返すか」: env > fleet-tools > synced、env が指す物が無ければ次へ落ちない、
// 何も無ければ path=null + launcher_missing(spawn の前に断る材料)。
import { test } from "node:test";
import assert from "node:assert/strict";
import { resolveLauncher, launcherView, executableSync } from "../src/launcher.mjs";

const existsIn = (...paths) => (p) => paths.includes(p);
const HOME = "/Users/x";
const FLEET = "/Users/x/fleet-tools/claude-work";
const SYNCED = "/Users/x/.claude/tools/claude-work";

test("env の RC_CLAUDE_WORK が在れば其れ(source=env)", () => {
  const r = resolveLauncher({ env: { RC_CLAUDE_WORK: "/opt/x/claude-work" }, home: HOME, exists: existsIn("/opt/x/claude-work", FLEET, SYNCED) });
  assert.equal(r.path, "/opt/x/claude-work");
  assert.equal(r.source, "env");
  assert.equal(r.reason, null);
});

test("★env が指す物が無ければ**次へ落ちない**(設定の誤りを直った顔にしない)", () => {
  const r = resolveLauncher({ env: { RC_CLAUDE_WORK: "/opt/x/claude-work" }, home: HOME, exists: existsIn(FLEET, SYNCED) });
  assert.equal(r.path, null);
  assert.equal(r.reason, "env-launcher-missing");
  assert.deepEqual(r.tried, ["/opt/x/claude-work"]);
});

test("艦隊の置き場が在れば其れ(synced より先)", () => {
  const r = resolveLauncher({ env: {}, home: HOME, exists: existsIn(FLEET, SYNCED) });
  assert.equal(r.path, FLEET);
  assert.equal(r.source, "fleet-tools");
});

test("★friday の形: fleet-tools が無く synced だけ在る → synced(2026-09-06 に本番で無かった経路)", () => {
  const r = resolveLauncher({ env: {}, home: HOME, exists: existsIn(SYNCED) });
  assert.equal(r.path, SYNCED);
  assert.equal(r.source, "synced");
  assert.deepEqual(r.tried, [FLEET, SYNCED]);
});

test("何も無ければ path=null / launcher_missing(spawn の前に断る材料)", () => {
  const r = resolveLauncher({ env: {}, home: HOME, exists: () => false });
  assert.equal(r.path, null);
  assert.equal(r.source, null);
  assert.equal(r.reason, "launcher_missing");
  assert.equal(r.tried.length, 2);
});

test("HOME が無ければ候補を組まずに launcher_missing(投げない)", () => {
  const r = resolveLauncher({ env: {}, home: null, exists: () => true });
  assert.equal(r.path, null);
  assert.equal(r.reason, "launcher_missing");
});

test("空白だけの env は未設定として扱う", () => {
  const r = resolveLauncher({ env: { RC_CLAUDE_WORK: "   " }, home: HOME, exists: existsIn(SYNCED) });
  assert.equal(r.source, "synced");
});

test("launcherView は source/reason だけ(path を認証の外に運ばない — Codex 2026-09-06)", () => {
  const v = launcherView(resolveLauncher({ env: {}, home: HOME, exists: existsIn(SYNCED) }));
  assert.deepEqual(v, { source: "synced", reason: null });
  assert.deepEqual(launcherView(null), { source: null, reason: null });
});

// ── Codex 2026-09-06 の所見 ────────────────────────────────────────────────
test("★相対 path の env は起動時の cwd で絶対にする(spawn は plan.cwd で走るので、相対のままだと別の file を見る)", () => {
  const r = resolveLauncher({ env: { RC_CLAUDE_WORK: "./bin/claude-work" }, home: HOME, cwd: "/srv/desk", exists: existsIn("/srv/desk/bin/claude-work") });
  assert.equal(r.path, "/srv/desk/bin/claude-work");
  assert.equal(r.source, "env");
});

test("`~/…` の env は home で展開する(shell を通らない launchd の env は展開されない)", () => {
  const r = resolveLauncher({ env: { RC_CLAUDE_WORK: "~/bin/claude-work" }, home: HOME, exists: existsIn("/Users/x/bin/claude-work") });
  assert.equal(r.path, "/Users/x/bin/claude-work");
});

test("既定の『在るか』は実行できるか(x の無い file は無いのと同じ)", () => {
  assert.equal(executableSync("/no/such/file"), false);
  assert.equal(executableSync("/etc/hosts"), false);      // 在るが実行できない
  assert.equal(executableSync("/bin/sh"), true);
});

test("★決め直しは要求ごと(同じ引数でも、fs が変われば答えが変わる)", () => {
  let present = false;
  const exists = (p) => present && p === SYNCED;
  assert.equal(resolveLauncher({ env: {}, home: HOME, exists }).path, null);
  present = true;
  assert.equal(resolveLauncher({ env: {}, home: HOME, exists }).path, SYNCED);
  present = false;
  assert.equal(resolveLauncher({ env: {}, home: HOME, exists }).path, null);
});
