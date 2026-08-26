# Research: what makes a phone client for a coding agent useful (2026-08-26)

Scope: informs the build-order decision between (a) file attachments, (b) diff viewer,
(c) transcript/reading mode, (d) per-device auth + short-lived approvals, for a private
iOS app driving Claude Code sessions on a Mac mini over Tailscale.

---

## Ranked recommendation

### 1st — (a) File attachments (phone → session)

Build this first. There is a **live, unresolved GitHub issue against Anthropic's own
official app** asking for exactly this: [anthropics/claude-code#65868](https://github.com/anthropics/claude-code/issues/65868),
"Support attaching images from iOS Photos in Claude Code mobile app (remote control)."
The issue states the mobile chat input "currently has no attach/image button" and that
iOS/native developers specifically need to send screenshots back to the agent "when the
app misbehaves on device," without leaving the device they're testing on. That's a
mobile-*only* use case — it cannot be done better from a desk, because the bug is
literally on the phone in your hand. Anthropic, Cursor (which supports "include images"
per [cursor.com/blog/agent-web](https://cursor.com/blog/agent-web)), and most of the
mobile wrapper apps surveyed below treat this as a desktop-first feature bolted onto
mobile as an afterthought. It is also the cheapest of the four to build well: attach to
an existing photo picker/camera capture and inject into the same channel that already
carries free-text input.

### 2nd — (d) Per-device auth + short-lived approvals

Build this second, and treat it as a safety feature, not a nice-to-have. The strongest
evidence in this research is a documented real incident: an engineering manager approved
an AI-generated PR from a phone that contained a `DROP COLUMN` "buried below the fold in
a six-inch diff view," described in
[wgrow.com, "Codex on the Phone: Useful, Dangerous, Mostly Triage"](https://wgrow.com/field-notes/codex-on-the-phone-useful-dangerous-mostly-triage/):
"The failure was a human trying to validate a structural database change on a form
factor built for reading WhatsApp messages." The same source and
[the CodeAgent Mobile comparison at codeongrass.com](https://codeongrass.com/blog/best-app-to-control-coding-agents-from-mobile/)
independently converge on the same diagnosis: mobile is good for low-risk orchestration
(dispatch, nudge, restart CI) and bad for validating destructive changes, because
"the same gesture that clears a Slack ping also approves a PR" — notification fatigue
plus a thumb-swipe UI is a structurally dangerous combination for irreversible actions.
On the HN Boxes.dev launch thread ([hn item 48399358](https://hn.algolia.com/api/v1/items/48399358)),
commenter **bruckie** asked for exactly this shape of feature — an agent
"constrained enough that I can safely run agents in YOLO mode" with "an escape hatch
that allows doing other things with human supervision" — and the founder **nab**
confirmed they don't have it yet ("considering having some sort of key storage construct
that allows you to require human confirmation for access to certain...keys"). Separately,
Anthropic's own Remote Control has known reliability failures in this exact area per
codeongrass: "OAuth token expiry killing all sessions simultaneously with no graceful
refresh," and Simon Willison independently documented persistent 500 errors and confusing
un-terminated-session states in [his Remote Control review](https://simonwillison.net/2026/Feb/25/claude-code-remote-control/).
This product already has "answering multiple-choice prompts" and "interrupt" — the gap is
specifically *tiered* approval (auto-approve reads, require an explicit, hard-to-fat-finger
step for destructive ops) plus a session/device model that doesn't silently die.

### 3rd — (c) Transcript/reading mode

Build this third. This is what the field evidence says mobile is actually *for*.
On the Omnara HN launch thread ([hn item 46991591](https://hn.algolia.com/api/v1/items/46991591)),
real users describe exactly this pattern: **kmansm27** — "Omnara is used while on the
toilet a lot"; **groovetandon** — "I feel like I lose a lot of work during lunch runs and
on the commute home"; **josefrichter** — "Very useful for supervising Claude and
occasionally steering it." wgrow.com's three legitimate mobile use cases (dispatching,
nudging, CI follow-up) are all read-then-light-touch actions, not deep review. A reading
mode is lower risk than a diff viewer (no destructive-approval surface) and directly
serves the confirmed "catch up on what happened while away" use case this product
already partially supports via the SSE conversation stream — this item is about making
that stream comfortable to *read back through*, not just watch live.

### 4th — (b) Diff viewer

Build this last, and reconsider the shape before building it. Every independent source
that discusses mobile diff review agrees it's the wrong place for real verification, not
merely inconvenient. From [semaloop, "The review moved to the device"](https://semaloop.com/blog/the-review-moved-to-the-device)
via search-result excerpt and corroborated by wgrow.com: pagination into ~10-line chunks
loses the ability to trace state across a change or compare before/after simultaneously;
"the issue is not pixel density — it is the absence of the mental environment that deep
review actually requires: a quiet desk, a second screen, a full terminal." wgrow.com's
explicit rule: "Use the phone to signal intent... Wait until you have a monitor to
confirm they did not rewrite your schema." Competitors that ship a diff viewer (Cursor
mobile, GitHub Mobile Copilot agent, CodeAgent Mobile) treat it as approve/merge surface,
which is the exact pattern implicated in the DROP COLUMN incident. If built, it should
be scoped as a read-only, low-risk-only surface (gated by the tiering from item (d)) — not
a general "review and merge" tool — which is also why it should come after, not before,
per-device auth. It's also the least differentiated of the four: every competitor already
has *some* diff view, so building one doesn't close a gap this product uniquely has.

---

## Features nobody in this space does well (concrete, not generic)

- **Structural-risk-aware approval, not binary approve/deny.** Every tool surveyed
  (Claude Code Remote Control, Cursor, Codex mobile, CodeAgent Mobile) gates on a
  per-tool-call yes/no. None classify the *content* of the action (e.g., pattern-match
  for `DROP`, `DELETE FROM`, `rm -rf`, `git push --force`, migration files) and force a
  harder confirmation only for those. This is the direct fix for the documented DROP
  COLUMN incident and is cheap for a single-user app (regex/keyword classification over
  the tool-call payload before it hits the push channel).
- **A digest, not a firehose.** Every tool streams raw tool-call/text events to mobile.
  None of the sources describe a "here's what changed while you were away" summary view
  (session start → now: N tool calls, M files touched, test result, one-line summary).
  Given the confirmed "check in from the toilet/commute" usage pattern, a digest view
  would directly serve real usage better than raw streaming does.
- **Session continuity back to desktop.** On the Omnara thread, **ncphillips** flagged
  exactly this gap in Claude Code: "I can't sit back down at my computer and
  cd/ssh/tmux into that same environment" after starting/monitoring from mobile. Since
  this product's backend already drives a live tmux pane on the Mac mini, it can trivially
  offer what Anthropic's own official tool doesn't: the mobile session and a desktop
  terminal attach to the *same* tmux pane, so switching devices mid-task loses nothing.
  This is a differentiator specific to this architecture, not available to tools that
  proxy through cloud VMs.
- **Tiered "cannot do X without human merge" account-level constraints**, as a cheaper
  substitute for building exhaustive UI gating. On the Boxes.dev HN thread, **wmedrano**
  described a manual workaround: "I gave it an account on a custom Git forge. It cannot
  commit without my direct permission." No surveyed tool productizes this as a first-class
  setting (e.g., "agent may open PRs, may never merge/push to protected branches,
  regardless of what the UI approves"). For a single-user private app this is a config
  flag plus a git remote wrapper, not a UI project.
- **Voice input**, repeatedly the top requested-but-missing feature. On
  [explainx.ai's guide](https://explainx.ai/blog/claude-code-mobile-remote-control-phone-guide-2026)
  a developer says of native Remote Control: "Voice mode would be great!" — and two
  separate HN Show-HNs exist purely to bolt voice onto other agent CLIs (AgentWire,
  [hn item 46974968](https://news.ycombinator.com/item?id=46974968); Amux voice variant).
  iOS's on-device Speech framework makes this a cheap addition for a private app — no
  server-side STT infra needed.

## Concrete UI patterns worth stealing (named, with source)

- **Live per-terminal attention coloring** — PATAPIM (via
  [codeongrass.com](https://codeongrass.com/blog/best-app-to-control-coding-agents-from-mobile/)):
  color-codes which of a grid of terminal sessions "need attention" via pattern-matching
  on terminal output (braille spinners, cost summaries, prompt characters) rather than a
  generic "running/idle" dot. More informative than a status dot alone.
- **Agent-aware approval forwarding** — Grass (same source): "The CLI is agent-aware, not
  terminal-aware: it understands Claude Code's permission model and forwards approval
  requests natively" as push notifications/modals, instead of just mirroring raw terminal
  text and making the user parse a y/n prompt out of a wall of output.
- **PWA dashboard you can "peek into" without SSH** — Amux
  ([hn item 47363707](https://news.ycombinator.com/item?id=47363707)): "I can monitor all
  my agents from my phone (it's a PWA), send them messages, check the kanban board, and
  peek at any terminal — all without SSH-ing into my machine." The kanban-of-agents view
  (also in [Cursor's agent-web](https://cursor.com/blog/agent-web): "Kanban view of Cursor
  Agents performing coding and research tasks") is a useful multi-session-at-a-glance
  layout worth stealing if/when this product needs to show more than one session's status
  at once.
- **Interactive diff mechanics, if/when a diff viewer is built** — from
  [coder/cmux PR #315](https://github.com/coder/cmux/pull/315): keyboard j/k navigation
  that respects editability, click-line-to-select / shift-click-for-range with the
  selection auto-quoted into a follow-up message with line numbers attached, a file tree
  that extracts the common path prefix so deep repo paths don't eat the whole screen width,
  and a diff-base selector (HEAD / staged / custom ref / include-dirty). This is a
  concrete, screen-width-conscious spec if item (b) gets built later.
- **Structural gate before production, separate from the mobile approval** — wgrow.com's
  recommendation: mobile approval satisfies "signal intent" only; an additional
  desktop-gated step (branch protection + credentials mobile flows don't have) is required
  before anything ships. Worth mirroring as a policy even without new UI: make the
  Mac-mini-side git/deploy tooling refuse a push that was approved from a mobile-flagged
  session unless a second, desktop-originated confirmation follows.

## What I found evidence for vs. my inference

**Evidence-backed (cited above):**
- Real unresolved demand for phone→session image attachment specific to on-device
  debugging (GitHub issue #65868).
- A real incident where mobile-approved a destructive schema change slipped through
  (wgrow.com).
- Independent convergence (wgrow.com, semaloop-via-search-excerpt, codeongrass) that
  mobile diff review is structurally weaker than desktop review, not just less
  convenient.
- Confirmed real usage pattern of checking in briefly from mobile during dead time
  (toilet, commute, lunch) rather than doing deep work (Omnara HN comments).
- A specific, named session-continuity complaint against Claude Code's official tool
  (ncphillips on HN).
- Reliability/session-death problems in Anthropic's own shipped Remote Control
  (Willison's review, codeongrass comparison).
- Voice input as a repeated, explicit user request across three independent sources.

**My inference, not directly evidenced by a source:**
- That structural-risk keyword classification (regex over tool-call payloads) is cheap
  to build — this is a reasonable engineering judgment, not something any source
  described as already built or explicitly recommended in that exact form.
- That tying the mobile and desktop UI to the *same* tmux pane (rather than separate
  synced state) is the right implementation for session continuity — the HN complaint
  establishes the gap, not the fix.
- The exact rank order given ties together separately-sourced claims (demand for (a),
  risk evidence for (d), usage-pattern evidence for (c), and the "wrong place for review"
  critique for (b)) into a single priority call; no source ranks these four options
  against each other directly, because no source frames the same four-option decision
  this product faces.
- That a digest/summary view would outperform raw streaming for the toilet/commute/lunch
  use case — inferred from the usage pattern, not something any surveyed tool has
  actually shipped and been evaluated on.

## Sources consulted

- https://github.com/anthropics/claude-code/issues/65868
- https://wgrow.com/field-notes/codex-on-the-phone-useful-dangerous-mostly-triage/
- https://codeongrass.com/blog/best-app-to-control-coding-agents-from-mobile/
- https://hn.algolia.com/api/v1/items/46991591 (Launch HN: Omnara)
- https://hn.algolia.com/api/v1/items/48399358 (Show HN: Boxes.dev)
- https://hn.algolia.com/api/v1/items/47363707 (Show HN: Amux)
- https://simonwillison.net/2026/Feb/25/claude-code-remote-control/
- https://github.com/anthropics/claude-code/issues/29006
- https://explainx.ai/blog/claude-code-mobile-remote-control-phone-guide-2026
- https://cursor.com/blog/agent-web
- https://github.com/coder/cmux/pull/315
- https://semaloop.com/blog/the-review-moved-to-the-device (via search excerpt; direct
  fetch returned HTTP 403)
- General search coverage (not individually fetched, corroborating only): Anthropic
  Remote Control launch coverage (VentureBeat, Help Net Security, TechRadar), GitHub
  Copilot coding agent on GitHub Mobile changelog posts, OpenAI "Work with Codex from
  anywhere," Devin AI reviews (G2, Gartner, Qubika — confirms Devin has no mobile app as
  of this research), HN searches on tmux/voice agent wrappers (AgentWire, Tmux-IDE,
  Pocketbot).
