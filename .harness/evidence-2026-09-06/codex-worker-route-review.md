# Codex adversarial review — worker-route launcher resolution (2026-09-06, codex-quick inline)

Verdict: FAIL with 3 blocking findings (relative env path vs spawn cwd; startup-only caching preserves both stale presence and stale absence; absolute path on the unauthenticated /healthz). All folded in: absolutize + ~ expansion + executable check, per-request resolution threaded into the worker plan, no PATH fallback, /healthz left at its 4-key contract (facts go to the startup log). Deferred, recorded in the commit: acknowledge 202 only after the child emits spawn; phone rendering of worker_error.

```
[codex-quick started pid=22708 12:43:42 timeout=170s — background callers: wait on the pid, do not read the output early]
Reading additional input from stdin...
OpenAI Codex v0.144.3
--------
workdir: /Users/tomtim/Infra/mobile-work/rc-backend
model: gpt-5.6-sol
provider: openai
approval: never
sandbox: read-only
reasoning effort: xhigh
reasoning summaries: none
session id: 01a077d1-a44f-7303-8b60-518e9b7c8cf7
--------
user
DO NOT read any files or run any commands — answer purely from this prompt; everything you need is inline. Be concise and direct.
Adversarial review, under 600 words, no file access (all inline). Findings with function name + a concrete failing input; no rewrites. Production context: a Node desk on a Mac mini spawns `claude -p --resume` through a launcher script for phone sends to sessions that have no open tmux pane ("worker route"). The launcher path was hard-wired to `~/fleet-tools/claude-work`, which does not exist on the production machine; Node's `spawn` does not throw synchronously for a missing binary, so the phone received 202 "Sent" and then a `worker_error` poll event nobody renders. The change: resolve the launcher at startup, refuse the send BEFORE spawning when it cannot be resolved, and expose the resolution on the unauthenticated /healthz.

=== src/launcher.mjs (new, pure) ===
export function resolveLauncher({ env = process.env, home, exists = existsSync } = {}) {
  const tried = [];
  const explicit = typeof env.RC_CLAUDE_WORK === "string" && env.RC_CLAUDE_WORK.trim() ? env.RC_CLAUDE_WORK.trim() : null;
  if (explicit) {
    tried.push(explicit);
    if (exists(explicit)) return { path: explicit, source: "env", tried, reason: null };
    return { path: null, source: null, tried, reason: "env-launcher-missing" };   // deliberately does NOT fall through
  }
  if (!home) return { path: null, source: null, tried, reason: "launcher_missing" };
  const candidates = [["fleet-tools", join(home, "fleet-tools", "claude-work")], ["synced", join(home, ".claude", "tools", "claude-work")]];
  for (const [source, p] of candidates) { tried.push(p); if (exists(p)) return { path: p, source, tried, reason: null }; }
  return { path: null, source: null, tried, reason: "launcher_missing" };
}
export function launcherView(r) { return { path: r?.path ?? null, source: r?.source ?? null, reason: r?.reason ?? null, tried: Array.isArray(r?.tried) ? r.tried.length : 0 }; }

=== server.mjs (startup) ===
const LAUNCHER = resolveLauncher({ home: HOME });
const CLAUDE_WORK = LAUNCHER.path;
if (!CLAUDE_WORK) console.error(`[rc-backend] worker 経路の launcher が無い(${LAUNCHER.reason}; tried ${LAUNCHER.tried.join(", ")})— 背景の送信は launcher_missing で断る`);
// the worker manager later does: nodeSpawn(CLAUDE_WORK, ["-p", ...(plan.fork ? ["--fork-session"] : []), "--resume", plan.resumeId, "--input-format", "stream-json", "--output-format", "stream-json", "--verbose"], { stdio: ["pipe","pipe","pipe"], cwd: plan.cwd })

=== server.mjs (send route, worker branch, after the cwd verdict and idempotency hold) ===
      if (!CLAUDE_WORK) {
        if (idemHeld) idem.abandon(sendId);
        return json(res, 409, { accepted: false, route: "worker", reason: "launcher_missing", error: WORKER_REFUSAL.launcher_missing });
      }
      let seq;
      try { seq = manager.send(sessionId, text, { onEvent: ..., cwd: wcwd }); } catch (e) { if (e?.code === "ENOENT") { ...409 cwd_missing... } ... }

=== /healthz (unauthenticated) ===
return json(res, 200, healthzBody({ launcher: launcherView(LAUNCHER), pid: process.pid, uptime: ..., version: DEPLOYED_REV }));
// healthzBody adds: launcher: { path, source, reason, tried } (path is an absolute filesystem path under the user's home)

Questions: (1) Is exposing the launcher's absolute path on the UNAUTHENTICATED /healthz acceptable, or should it be reduced to source+reason only? (2) The resolution is done once at startup — what breaks if the synced launcher appears later (the git sync runs every 5 min) or is deleted while running (the refusal would then be a 202-then-worker_error again)? Would re-resolving per request (cheap existsSync) or on each refusal be safer? (3) Any race between the env-not-fall-through rule and the deploy script that sets env vars? (4) TOCTOU between exists() and spawn — acceptable? (5) The `launcher_missing` message: "The desk can't find its background launcher (claude-work), so this session can't be reached while it has no open pane. Open it on the desk, or fix the desk's launcher path." — actionable enough for a phone user?
End with a verdict line: PASS or FAIL naming blocking findings.
2026-09-06T17:43:43.758404Z ERROR rmcp::transport::worker: worker quit with fatal: Transport channel closed, when Auth(AuthorizationRequired)
2026-09-06T17:43:43.828703Z ERROR rmcp::transport::worker: worker quit with fatal: Transport channel closed, when Auth(AuthorizationRequired)
2026-09-06T17:43:44.247468Z ERROR rmcp::transport::worker: worker quit with fatal: Transport channel closed, when Auth(AuthorizationRequired)
codex
Blocking findings:

- `resolveLauncher` — input: `env.RC_CLAUDE_WORK="./claude-work"`, launcher exists relative to the server’s startup directory, but `plan.cwd="/Users/x/project"`. `exists()` succeeds, while `spawn(..., {cwd: plan.cwd})` resolves the relative command elsewhere and emits `ENOENT` asynchronously. Result: 202 followed by an invisible `worker_error`. Require an absolute resolved path.
- `resolveLauncher` — input: `/Users/x/.claude/tools/claude-work` exists at startup, then is deleted or loses execute permission before a send. Cached `CLAUDE_WORK` remains truthy, so the preflight is bypassed and the original false-202 failure returns. `existsSync` also accepts directories and non-executable files.
- Startup resolution — input: neither candidate exists at boot; synced launcher appears five minutes later. Every worker send remains 409 until process restart. Re-resolve on every worker request; “on refusal” alone does not cover deletion when the cached path remains non-null.

Answers:

1. Reduce unauthenticated `/healthz` to readiness/status plus `source` and `reason`. Absolute paths disclose usernames and host layout without providing useful load-balancer health information. `tried` count is harmless but unnecessary.

2. Startup-only caching is unsafe in both directions: it preserves stale absence and stale presence. Per-request validation is cheap and materially safer. It still cannot eliminate TOCTOU.

3. There is no process-level race if deployment exports the variable before starting Node. There is a deployment/configuration trap: a stale, invalid `RC_CLAUDE_WORK` deliberately disables valid fallback paths. Also, `RC_CLAUDE_WORK="~/..."` is not shell-expanded. Deployment must set an absolute, validated path or fully unset it before launch.

4. The `exists()`/`spawn()` TOCTOU is unavoidable and acceptable only if spawn failure is authoritative. Do not acknowledge 202 until the child emits `spawn`; handle asynchronous `error` events, including `ENOENT`, `EACCES`, and `ENOTDIR`, as refusal-level failures. An existence precheck alone is insufficient.

5. The message is understandable, but with startup caching it is misleading: fixing the path does not restore service without restarting the backend. “Open it on the desk” should specifically mean opening the session in a tmux pane. For phone users, include “retry after the desk service is fixed/restarted.”

FAIL — blocking findings: relative env launcher resolution and stale startup-cached launcher state preserve the false-202 failure mode.
tokens used
13,708
Blocking findings:

- `resolveLauncher` — input: `env.RC_CLAUDE_WORK="./claude-work"`, launcher exists relative to the server’s startup directory, but `plan.cwd="/Users/x/project"`. `exists()` succeeds, while `spawn(..., {cwd: plan.cwd})` resolves the relative command elsewhere and emits `ENOENT` asynchronously. Result: 202 followed by an invisible `worker_error`. Require an absolute resolved path.
- `resolveLauncher` — input: `/Users/x/.claude/tools/claude-work` exists at startup, then is deleted or loses execute permission before a send. Cached `CLAUDE_WORK` remains truthy, so the preflight is bypassed and the original false-202 failure returns. `existsSync` also accepts directories and non-executable files.
- Startup resolution — input: neither candidate exists at boot; synced launcher appears five minutes later. Every worker send remains 409 until process restart. Re-resolve on every worker request; “on refusal” alone does not cover deletion when the cached path remains non-null.

Answers:

1. Reduce unauthenticated `/healthz` to readiness/status plus `source` and `reason`. Absolute paths disclose usernames and host layout without providing useful load-balancer health information. `tried` count is harmless but unnecessary.

2. Startup-only caching is unsafe in both directions: it preserves stale absence and stale presence. Per-request validation is cheap and materially safer. It still cannot eliminate TOCTOU.

3. There is no process-level race if deployment exports the variable before starting Node. There is a deployment/configuration trap: a stale, invalid `RC_CLAUDE_WORK` deliberately disables valid fallback paths. Also, `RC_CLAUDE_WORK="~/..."` is not shell-expanded. Deployment must set an absolute, validated path or fully unset it before launch.

4. The `exists()`/`spawn()` TOCTOU is unavoidable and acceptable only if spawn failure is authoritative. Do not acknowledge 202 until the child emits `spawn`; handle asynchronous `error` events, including `ENOENT`, `EACCES`, and `ENOTDIR`, as refusal-level failures. An existence precheck alone is insufficient.

5. The message is understandable, but with startup caching it is misleading: fixing the path does not restore service without restarting the backend. “Open it on the desk” should specifically mean opening the session in a tmux pane. For phone users, include “retry after the desk service is fixed/restarted.”

FAIL — blocking findings: relative env launcher resolution and stale startup-cached launcher state preserve the false-202 failure mode.
```
