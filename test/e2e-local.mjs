// ローカル E2E — 偽 claude-work を注入してサーバの8機能を通す。
// 実 claude・実セッションに一切触れない。実行: node test/e2e-local.mjs
//
// 409 の陽性対照について: RC_TEST_HELD_CWD に「実際に対話 claude が今掴んでいる cwd」を
// 渡すと、その cwd の fixture への書き込みが 409 になることまで検証する(渡さなければ skip)。
import { spawn } from "node:child_process";
import { mkdtempSync, writeFileSync, mkdirSync, readFileSync, chmodSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const SB = mkdtempSync(join(tmpdir(), "rc-e2e-"));
const PROJ = join(SB, "projects", "-Users-Shared-dev-roundtrip");
mkdirSync(PROJ, { recursive: true });
const SID1 = "11111111-1111-1111-1111-111111111111";
const SID3 = "33333333-3333-3333-3333-333333333333";
const HELD_CWD = process.env.RC_TEST_HELD_CWD || null;

writeFileSync(join(PROJ, `${SID1}.jsonl`), [
  JSON.stringify({ entrypoint: "cli", cwd: "/Users/Shared/dev/roundtrip", type: "user", message: { role: "user", content: "最初の質問" } }),
  JSON.stringify({ type: "assistant", message: { role: "assistant", content: [{ type: "text", text: "最初の答え" }, { type: "tool_use", name: "Bash", input: {} }] } }),
  JSON.stringify({ type: "ai-title", aiTitle: "検証用の会話" }),
  JSON.stringify({ type: "last-prompt", lastPrompt: "最初の質問" }),
].join("\n"));
writeFileSync(join(PROJ, "22222222-2222-2222-2222-222222222222.jsonl"),
  JSON.stringify({ entrypoint: "sdk-cli", cwd: "/x", type: "user", message: { content: "noise" } }));
if (HELD_CWD) {
  writeFileSync(join(PROJ, `${SID3}.jsonl`), [
    JSON.stringify({ entrypoint: "cli", cwd: HELD_CWD, type: "user", message: { role: "user", content: "保持中" } }),
    JSON.stringify({ type: "ai-title", aiTitle: "TUI保持テスト" }),
  ].join("\n"));
}

const fakeWork = join(SB, "fake-claude-work");
writeFileSync(fakeWork, `#!/usr/bin/env python3
import sys, json
for line in sys.stdin:
    line=line.strip()
    if not line: continue
    try: msg=json.loads(line)
    except Exception: continue
    txt=msg.get("message",{}).get("content",[{}])[0].get("text","")
    print(json.dumps({"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"echo:"+txt}]}}),flush=True)
    print(json.dumps({"type":"result","result":"echo:"+txt}),flush=True)
`);
chmodSync(fakeWork, 0o755);
const fakeAcct = join(SB, "fake-fleet-account");
writeFileSync(fakeAcct, "#!/bin/sh\necho account=testacct\n");
chmodSync(fakeAcct, 0o755);

const PORT = 8790 + Math.floor(Math.random() * 100);
const sv = spawn(process.execPath, [join(ROOT, "src", "server.mjs")], {
  env: {
    ...process.env,
    RC_PROJECTS_DIR: join(SB, "projects"),
    RC_CLAUDE_WORK: fakeWork,
    RC_FLEET_ACCOUNT: fakeAcct,
    RC_KEY_DIR: join(SB, "keys"),
    RC_PORT: String(PORT),
  },
  stdio: ["ignore", "pipe", "pipe"],
});
let svlog = "";
sv.stdout.on("data", (c) => (svlog += c));
sv.stderr.on("data", (c) => (svlog += c));

const B = `http://127.0.0.1:${PORT}`;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

let pass = 0, fail = 0;
function check(name, cond, detail = "") {
  if (cond) { pass++; console.log(`PASS  ${name}`); }
  else { fail++; console.log(`FAIL  ${name}  ${detail}`); }
}

try {
  // サーバ起動待ち
  let up = false;
  for (let i = 0; i < 50 && !up; i++) { await sleep(100); up = svlog.includes("listening"); }
  if (!up) throw new Error(`server did not start:\n${svlog}`);
  const KEY = readFileSync(join(SB, "keys", "api.key"), "utf8").trim();
  const H = { authorization: `Bearer ${KEY}` };

  // 1. 認証
  check("401 without key", (await fetch(`${B}/api/sessions`)).status === 401);
  check("401 with wrong key", (await fetch(`${B}/api/sessions`, { headers: { authorization: "Bearer nope" } })).status === 401);

  // 2. 一覧
  const list = await (await fetch(`${B}/api/sessions`, { headers: H })).json();
  const ids = list.sessions.map((s) => s.id);
  check("listing includes cli session", ids.includes(SID1));
  check("listing excludes sdk-cli noise", !ids.includes("22222222-2222-2222-2222-222222222222"));
  check("title resolved from ai-title", list.sessions.find((s) => s.id === SID1).title === "検証用の会話");

  // 3. history
  const hist = await (await fetch(`${B}/api/sessions/${SID1}/history`, { headers: H })).json();
  check("history has user+assistant+tool", JSON.stringify(hist.history) ===
    JSON.stringify([
      { role: "user", text: "最初の質問" },
      { role: "assistant", text: "最初の答え" },
      { role: "tool", text: "⚙ Bash" },
    ]), JSON.stringify(hist.history));

  // 4. account
  const acct = await (await fetch(`${B}/api/account`, { headers: H })).json();
  check("account passthrough", acct.account === "account=testacct");

  // 5. SSE 購読(fetch ストリーム)
  const sseCtl = new AbortController();
  const sseChunks = [];
  const ssePromise = fetch(`${B}/api/sessions/${SID1}/stream`, { headers: H, signal: sseCtl.signal })
    .then(async (r) => {
      const reader = r.body.getReader();
      const dec = new TextDecoder();
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        sseChunks.push(dec.decode(value));
      }
    })
    .catch(() => {});
  await sleep(200);

  // 6. メッセージ送信 → 偽ワーカーが echo
  const post = await fetch(`${B}/api/sessions/${SID1}/messages`, {
    method: "POST", headers: { ...H, "content-type": "application/json" },
    body: JSON.stringify({ text: "テスト送信" }),
  });
  check("message accepted 202", post.status === 202);
  await sleep(800);
  const sseText = sseChunks.join("");
  check("SSE carries assistant echo", sseText.includes("echo:テスト送信"));
  check("SSE carries result", sseText.includes('"type":"result"'));

  // 7. status → ready
  const st = await (await fetch(`${B}/api/sessions/${SID1}/status`, { headers: H })).json();
  check("worker ready after result", st.worker === "running" && st.state === "ready", JSON.stringify(st));

  // 8. interrupt
  const intr = await (await fetch(`${B}/api/sessions/${SID1}/interrupt`, { method: "POST", headers: H })).json();
  check("interrupt returns true", intr.interrupted === true);
  const st2 = await (await fetch(`${B}/api/sessions/${SID1}/status`, { headers: H })).json();
  check("worker gone after interrupt", st2.worker === "none", JSON.stringify(st2));

  // 9. 異常系: bad body / unknown session
  const bad = await fetch(`${B}/api/sessions/${SID1}/messages`, {
    method: "POST", headers: { ...H, "content-type": "application/json" }, body: "{not json",
  });
  check("bad body -> 400", bad.status === 400);
  check("unknown session -> 404",
    (await fetch(`${B}/api/sessions/99999999-9999-9999-9999-999999999999/history`, { headers: H })).status === 404);

  // 10. 409 陽性対照(環境が実 TUI cwd を提供した時のみ)
  if (HELD_CWD) {
    const held = await fetch(`${B}/api/sessions/${SID3}/messages`, {
      method: "POST", headers: { ...H, "content-type": "application/json" },
      body: JSON.stringify({ text: "書けないはず" }),
    });
    check("TUI-held session -> 409 (positive control)", held.status === 409, `status=${held.status}`);
  } else {
    console.log("SKIP  409 positive control (RC_TEST_HELD_CWD not provided)");
  }

  sseCtl.abort();
  await ssePromise;
} finally {
  sv.kill("SIGTERM");
}
console.log(`\nE2E: pass=${pass} fail=${fail}`);
process.exit(fail === 0 ? 0 : 1);
