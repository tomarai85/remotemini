# Splitting the push into the two official types (parity row #32) — design, 2026-09-04

Row #32: the official client's `/config` has **two independently switchable** push types — *Push when Claude
decides* and *Push when actions required*. Ours has one undifferentiated path (`rc-backend/tools/digest-notify.sh`),
and the row records the gap as "種別が1つしかない。「判断待ち」と「完了」を分けられない".

The row's framing is slightly off, and the correction is the whole design. We do not have one type that
conflates two things. We have **one of the two types, built well**, and the other **cannot be produced by the
layer that decides today**.

## What we actually have

`digest.mjs` decides in two steps.

`attentionFromScreen(state)` maps a screen classification to an attention word: `CHOICE` → `choice`,
`SENDABLE` → `input`, anything unread → `unknown` (deliberately not `none`). `attentionOf` then demotes
`input` to `none` when activity is observed, because a composer being present is not evidence of waiting.

`actionRequired(attentionState, d)` maps that word to a level: `permission`/`choice` → `now` (nothing moves
until a human presses), `input` → `soon` (stopped but nothing breaks), `none` → `none` only when the digest is
complete, otherwise `unknown`.

`digest-notify.sh` then fires only for `choice`/`input`: `now` after two consecutive identical fingerprints,
`soon` only after the same fingerprint has stood for 20 real minutes, never for `unknown`, and never twice for
the same fingerprint (`sessionId + attention + lastAt`).

That entire pipeline is the **actions-required** type, with two urgencies inside it. It is well-tuned and its
tuning was itself a Codex ruling (2026-08-26).

## What is missing, and why the classifier cannot produce it

"Push when Claude decides" fires when a long task finishes and Claude judges you would want to know. Our
classifier has no state that means that, and cannot have one, because **a finished task and an idle session
render the same screen**: composer present, no activity. Both land on `SENDABLE` → `input` → `soon`.

So today a completed long task does notify — as "stopped, needs a message", **twenty minutes late**, wearing
the label of a different thing. That is worse than not notifying, on this repo's own standard: a signal that
mislabels its cause teaches the reader to distrust the signal.

The distinguishing evidence is a **transition**, not a state: activity was observed on a previous tick and is
not observed now, with a digest window that contains real work. `attentionFromScreen` is memoryless by
construction (it reads one screen), so this cannot live there. It can only live where memory already exists —
`digest-notify.sh`, which already keeps per-session fingerprints on disk across ticks.

## The design

**One new eligibility rule in the notify script, not a new classifier state.**

- Track, per session, the previous tick's `attention` alongside the fingerprint already stored.
- A *completion* candidate is: previous tick `none` (activity observed), current tick `input`, and the digest
  reports non-trivial work in its window (`counts.assistant > 0` or `writeTargetsTotal > 0`) with
  `complete === true`. An incomplete digest never qualifies — the existing rule that we do not say "fine" from
  a partial read applies unchanged.
- It fires **once, immediately** (no 20-minute wait: the whole value is promptness), and marks the fingerprint
  spent so the existing `soon` rule cannot fire again for the same standstill.
- The message says finished, not waiting: `"<window> — finished, nothing pending."`

**Two switches, one per type, and the new one is default-off.**

- `RC_DIGEST_ACTIONS=1` (default on) — the existing `now`/`soon` path.
- `RC_DIGEST_COMPLETION=0` (**default-off, opt-in**) — the new completion path.

Default-off is not timidity. The same Codex ruling that shaped this script rejected an adjacent
"it recovered" notification for exactly this reason: the person who sent the last message already knows they
sent it, so a notification about their own turn completing is noise. A completion push is only valuable when
the task ran long enough that the person stopped watching, and no measurement in this repo yet says where that
threshold is. Shipping it on by default would be guessing that threshold, on a channel whose value is
destroyed by being wrong. Opt-in lets it be measured before it is imposed.

**Presence still wins.** The existing rule that nothing fires while Tom is at the desk (heartbeat younger than
`PRESENCE_MAX_S`) applies to both types unchanged. A completion push is the type most likely to fire while he
is sitting right there.

## What to measure before turning it on

1. How often the completion candidate fires per day, from log-only mode (evaluate the rule, log, do not send).
2. The distribution of window lengths at fire time — that is the empirical answer to "how long is long
   enough", which the threshold guess above deliberately avoids inventing.
3. How many of them fire while presence is fresh (those would have been noise).

Only after those three numbers exist should the default flip, and the flip should carry the numbers as its
justification.

## What this does not do

It does not add a phone-side toggle UI. Row #32's official surface is a `/config` screen with two switches;
ours would start as two desk-side environment switches, because the desk is where the decision is made and
because a phone toggle for a push type that has never fired is a control with nothing behind it. The phone
surface is the follow-up once the measurement above says the type is worth having.
