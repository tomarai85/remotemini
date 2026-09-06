# Codex ship-gate review — live completion instrument + panel measurement doc (2026-09-06, codex-quick, inline prompt)

Prompt: scratchpad codex-B2.prompt.txt (verdict() inline + probe description + the doc's claims). Verdict: FAIL with blocking findings; every one is handled in the same commit (whole-field parsing, duplicate fields rejected, kind=ok required, kind=ng anywhere = not measured, no_alert read from the notifier's state flag, never-active session = not measured, doc wording softened).

```
[codex-quick started pid=87374 09:56:48 timeout=170s — background callers: wait on the pid, do not read the output early]
Reading additional input from stdin...
OpenAI Codex v0.144.3
--------
workdir: /Users/tomtim/Infra/mobile-work
model: gpt-5.6-sol
provider: openai
approval: never
sandbox: read-only
reasoning effort: xhigh
reasoning summaries: none
session id: 01a07738-d4ce-7353-96fa-da7c2fad3b43
--------
user
DO NOT read any files or run any commands — answer purely from this prompt; everything you need is inline. Be concise and direct.
Ship-gate review, under 500 words, no file access (everything is inline). Findings with function name + a concrete failing input; no rewrites. Two artifacts.

(A) verdict() of a live instrument (Node). Contract: exit 0 closed / 1 red / 2 setup aborted / 3 not measured. The shell line it judges looks like: kind=ok activity_seen=1 stopped_seen=1 completion_logged=1 window_min=60 no_alert=1 torn_down=1 torn_retry=0 limited=not-limited. Hunt: field matching, precedence of limited vs kind=ng, window_min edge cases, anything that lets a red line pass.
```js
export function verdict(rc, line) {
  const s = String(line || "");
  if (/\blimited=limited\b/.test(s)) {
    console.log("  --  : 机が利用上限。緑を名乗らない = 測っていない");
    return 3;
  }
  if (/^kind=ng step=/.test(s)) {
    console.log(`  --  : 机に届いていない(${s})—— **測っていない**`);
    return 3;
  }
  let fail = 0;
  const need = [
    ["activity_seen=1", "生成中に digest が none を返した(遷移の前が観測できた)"],
    ["stopped_seen=1", "其の後 input に落ちた(遷移の後)"],
    ["completion_logged=1", "検出器が其の sid の completion 行を書いた"],
    ["no_alert=1", "同じ sid で通知が鳴っていない(記録専用が本番でも保たれている)"],
    ["torn_down=1", "使い捨てを畳めた(机に残していない)"],
  ];
  // ★欄は**丸ごと**一致させる。`includes("completion_logged=1")` は `completion_logged=10` にも当たる
  //   (対照 `live-completion-log-controls.sh` が 2026-09-06 に捕まえた)。姉家族の composer-guard は includes のまま
  //   で、其の対照には此の形の行が無い —— 直すなら向こうも一緒に(此処では触らない)。
  const has = (k) => new RegExp("(^|\\s)" + k.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + "(\\s|$)").test(s);
  for (const [k, why] of need) {
    const ok = has(k);
    console.log(ok ? `  ok  : ${why}` : `  NG  : ${why} —— 観測できない(${k})`);
    if (!ok) fail = 1;
  }
  const m = /\bwindow_min=(\d+)\b/.exec(s);
  if (m && Number(m[1]) > 0) console.log(`  ok  : 記録された窓の長さ ${m[1]} 分(0 より大きい)`);
  else { console.log("  NG  : 記録された窓の長さが 0 か無い(window_min)"); fail = 1; }
  if (fail || rc !== 0) { console.log("→ 完了の記録の確認: 閉じていない"); return 1; }
  console.log("→ 完了の記録の確認: 観測で閉じた");
  return 0;
}
```

(A2) The probe part: it sends one message through the desk API (sleep 200 then say done), polls /digest every 10s until attention none was seen and then input; deadline = start + (200 + 4*150)s; then polls ~/.rc-backend/digest-completion.log via ssh with grep -F on a TAB-delimited field containing the full session uuid, up to 2*150+30 s; then no_alert = (grep -c of the FIRST 8 HEX of the sid in digest-notify.log) == 0; then teardown with one retry. Hunt: the no_alert grep (8-hex prefix collisions, or the notify log never mentioning sids at all -> vacuous 1), the none->input detection when the model finishes before the first poll, and whether a session that never became active yields a misleading red vs 3.

(B) Claims in a measurement doc about the Claude Code /tasks agent panel, from 4 captures (Jervis bare claude 2.1.259 120 cols; friday rc-claude+statusLine 2.1.263 80x24): rows for two same-description subagents are byte-identical ('count slowly (running) · Sonnet 5' twice); the Enter detail view shows agentType › description, elapsed, tokens, tool count, last tool calls, prompt prefix, and no id; footer wraps to two lines at 80 cols; one Escape from the detail view closed the whole overlay; in one probe the list had a 'Shells (2)' section with the initial selection on a shell row that offered 'x to stop'. The doc concludes: no per-row identifier -> keep the ambiguity refusal; verify at two levels (row text, then detail prompt prefix + recent tool calls vs the on-disk agent transcript); refuse shell rows; count Escapes by re-capturing after each. Hunt: any conclusion not supported by those captures, and what a 6+ agent list (5-row cap with scroll hints, not measured) could break.

End with a verdict line: PASS or FAIL, naming blocking findings.
2026-09-06T14:56:49.046502Z ERROR rmcp::transport::worker: worker quit with fatal: Transport channel closed, when Auth(AuthorizationRequired)
2026-09-06T14:56:49.074851Z ERROR rmcp::transport::worker: worker quit with fatal: Transport channel closed, when Auth(AuthorizationRequired)
2026-09-06T14:56:49.744221Z ERROR rmcp::transport::worker: worker quit with fatal: Transport channel closed, when Auth(AuthorizationRequired)
codex
### Artifact A — Live instrument

Blocking findings:

- `verdict()` never returns exit `2`, violating the setup-aborted contract. Input `rc=0, line="kind=ng step=send ..."` returns `3`.
- `verdict()` can pass an explicitly red record because `kind=ng` is recognized only when followed by `step=` at byte zero. Concrete failing input:  
  `rc=0, line="kind=ng activity_seen=1 stopped_seen=1 completion_logged=1 window_min=60 no_alert=1 torn_down=1 limited=not-limited"` → exit `0`.
- `verdict()` does not require `kind=ok` or `limited=not-limited`; a line containing only the five positive flags and `window_min=60` passes.
- `verdict()` accepts contradictory duplicate fields. Input containing `activity_seen=0 activity_seen=1` or `window_min=60 window_min=0` passes if the accepted value appears where the current search finds it.
- `verdict()` does not match `limited` or `window_min` as whole fields. `foo-limited=limited` returns `3`; `window_min=1-junk` is accepted.
- `verdict()` gives `limited` precedence over `kind=ng`: `kind=ng step=send limited=limited` returns `3`, obscuring setup abortion and still never producing `2`.

Probe findings:

- `no_alert` is unsound. For SID `abcdef12-...`, an unrelated matching prefix causes false red; conversely, a real notification line such as `notification sent successfully` containing no SID makes the count zero and falsely reports `no_alert=1`.
- If completion occurs before the first 10-second digest poll, only `input` is observed; the probe times out despite successful completion.
- A session that never becomes active is reported as red (`1`) through missing observation flags, although it was not measured and should be classified separately as `3`.

### Artifact B — `/tasks` measurement claims

The captures support only observations scoped to those versions, terminals, and four runs. They do not establish universal `/tasks` behavior.

- “No per-row identifier” is supported for the captured list text. A blanket ambiguity refusal is not: detail evidence might uniquely disambiguate a row.
- Matching prompt prefixes and recent tool calls to an on-disk transcript is a proposed heuristic, not validated identity proof; prefixes may truncate and tool-call sequences may collide.
- Refusing shell rows is a safety policy supported by one observed shell row, not a general UI invariant.
- One-Escape closure and two-line footer wrapping are single-condition observations, not stable behavior claims.
- With 6+ agents, an unmeasured five-row viewport could hide duplicates, change selection during asynchronous updates, reorder rows while scrolling, or show detail for a different identical row. That can invalidate both row-text verification and subsequent transcript correlation.

FAIL — blocking: red `kind=ng` lines can pass, exit `2` is unreachable, contradictory fields can pass, and `no_alert` can falsely certify that no notification occurred.
tokens used
7,360
### Artifact A — Live instrument

Blocking findings:

- `verdict()` never returns exit `2`, violating the setup-aborted contract. Input `rc=0, line="kind=ng step=send ..."` returns `3`.
- `verdict()` can pass an explicitly red record because `kind=ng` is recognized only when followed by `step=` at byte zero. Concrete failing input:  
  `rc=0, line="kind=ng activity_seen=1 stopped_seen=1 completion_logged=1 window_min=60 no_alert=1 torn_down=1 limited=not-limited"` → exit `0`.
- `verdict()` does not require `kind=ok` or `limited=not-limited`; a line containing only the five positive flags and `window_min=60` passes.
- `verdict()` accepts contradictory duplicate fields. Input containing `activity_seen=0 activity_seen=1` or `window_min=60 window_min=0` passes if the accepted value appears where the current search finds it.
- `verdict()` does not match `limited` or `window_min` as whole fields. `foo-limited=limited` returns `3`; `window_min=1-junk` is accepted.
- `verdict()` gives `limited` precedence over `kind=ng`: `kind=ng step=send limited=limited` returns `3`, obscuring setup abortion and still never producing `2`.

Probe findings:

- `no_alert` is unsound. For SID `abcdef12-...`, an unrelated matching prefix causes false red; conversely, a real notification line such as `notification sent successfully` containing no SID makes the count zero and falsely reports `no_alert=1`.
- If completion occurs before the first 10-second digest poll, only `input` is observed; the probe times out despite successful completion.
- A session that never becomes active is reported as red (`1`) through missing observation flags, although it was not measured and should be classified separately as `3`.

### Artifact B — `/tasks` measurement claims

The captures support only observations scoped to those versions, terminals, and four runs. They do not establish universal `/tasks` behavior.

- “No per-row identifier” is supported for the captured list text. A blanket ambiguity refusal is not: detail evidence might uniquely disambiguate a row.
- Matching prompt prefixes and recent tool calls to an on-disk transcript is a proposed heuristic, not validated identity proof; prefixes may truncate and tool-call sequences may collide.
- Refusing shell rows is a safety policy supported by one observed shell row, not a general UI invariant.
- One-Escape closure and two-line footer wrapping are single-condition observations, not stable behavior claims.
- With 6+ agents, an unmeasured five-row viewport could hide duplicates, change selection during asynchronous updates, reorder rows while scrolling, or show detail for a different identical row. That can invalidate both row-text verification and subsequent transcript correlation.

FAIL — blocking: red `kind=ng` lines can pass, exit `2` is unreachable, contradictory fields can pass, and `no_alert` can falsely certify that no notification occurred.
```
