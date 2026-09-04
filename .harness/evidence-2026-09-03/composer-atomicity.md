# A phone send could execute a command nobody wrote (2026-09-04)

Found by the adversarial Codex read that was launched to answer "what should this project do next now that
the parity table is exhausted". It answered something better than a feature: the worst thing here is not a
missing capability, it is that **nothing owned the tmux composer** while several paths appended to it.

## The defect

`TmuxInjector.#sendExclusive` checked one thing before typing: `classifyScreen(before).state === "SENDABLE"`.
It never checked whether the composer was **empty**. It counted a probe in the existing composer text, typed
the phone's text, waited for the probe count to rise, and pressed Enter.

So with a draft left in the Mac's composer:

1. The Mac's composer holds `deploy production` (typed by hand, never sent).
2. The phone sends `run tests`.
3. Claude Code receives `deploy productionrun tests`.
4. The phone can report success — the post-send check reads "the probe appeared, then the composer emptied",
   which is true. **It verifies the addition, not the total.**

The attachment flow reaches the same place without anyone making a mistake: attaching puts an absolute path
into the composer, the wording says to press send when ready, and typing `summarize this` then sending
produces `/Users/…/abc.pdfsummarize this`.

Separately, both attach handlers in `server.mjs` called `typeLiteral` **outside** the pane mutex, while sends
run inside it — so a photo upload and a send could type into the same composer concurrently. That is not a
race that might exist; it is where the synchronisation boundary was drawn.

## Verified before fixing

Three claims, each checked in the source rather than taken from the review: `typeLiteral` calls
`this.tmux.run` with no mutex; `#sendExclusive`'s only precondition is the `SENDABLE` state; both attach call
sites invoke `typeLiteral` directly.

Then a test was written that **reproduced the defect and passed** — pinning "it appends and presses Enter,
and zero keystrokes clear the composer" as the current behaviour. Writing the reproduction first is what makes
the later red the proof of the fix; fixing first would have left nobody having seen the defect in machine
terms.

## The fix

The obvious two options were each wrong on their own. Refusing whenever the composer is non-empty kills
attachments, which are non-empty by construction. Clearing the composer before typing silently destroys a
human's draft. The pair is only separable with one extra piece of information: **who put that text there.**

- `typeLiteral` records what it typed per pane in a private `#placed` map, with `placedIn` / `forgetPlaced`.
- `#sendExclusive` refuses with `composer-busy`, **typing nothing at all**, when the composer is non-empty and
  its normalised content is not exactly equal to what the desk placed. Exact rather than prefix match, because
  "the desk's path plus what the human then typed" is the merge case all over again.
- The memory is dropped the moment Enter is pressed: after that the composer's contents are no longer the
  desk's, and a stale entry would let the next send treat a human's new text as the desk's own.
- No memory (a desk restart) means refuse. The safe side of that failure is refusing a legitimate attachment,
  not sending a merged command.
- `typeLiteralExclusive` wraps the literal typing in the pane mutex, and both attach handlers await it.

## Observed

| what | result |
|---|---|
| `inject.test.mjs` (four new contract cases) | 91 / 91 |
| `inject-serial.test.mjs` (serialisation control) | 16 / 16 |
| full desk suite | 1267 / 1267 |
| e2e | 379 / 379 |

The four contract cases: a human draft refuses with zero keystrokes; a desk-placed attachment sends; an
attachment with human text appended refuses; no memory refuses.

## One control had to change, and why that is not moving the goalposts

`inject-serial.test.mjs`'s negative control proves the mutex earns its keep by removing it and showing the
result is not a clean `A→A→B→B`. That claim still holds and still passes. What broke was a second assertion
recording **what the mess looks like** — previously "both bodies land in the composer before the first Enter".
With the fix, the second send is refused before typing, so only one body lands. The claim was kept and the
recorded failure mode updated. The distinction that makes this legitimate: the load-bearing assertion
(`clean === false`) was untouched, and the edited line is a description of consequences, which is supposed to
change when the consequences improve.

## Round two: the fix was reviewed, and five of its seven findings were real

The fix above was sent back to the same adversarial reviewer before landing. It returned seven findings and a
verdict of fix-first. Five were reproduced in the source and fixed; two were rejected with reasons, and both
rejections are pinned by tests so a later reader can tell a decision from an oversight.

**F1 — the guard ran before typing, and a human can type after that.** The pre-check reads a capture; the desk
then types, waits for the echo, and presses Enter. Everything a person types on the Mac during that window
sails past the check, because the echo test only asks whether the phone's own probe appeared — it verifies the
addition, again. Fixed by re-reading the composer at the moment of the echo and requiring the whole box to be a
**suffix** of what the desk authorised. Suffix rather than equality because a long composer scrolls its head
off screen (measured 2026-08-01 at about 1,500 Japanese characters); text prepended or appended by a human
breaks the suffix relation either way. This does not make the window zero. Sending Enter is a separate tmux
call, so a keystroke landing in that gap is unobservable by anyone. What the fix does is shrink the window from
seconds (capture through poll) to one tmux round trip, and that is the honest claim.

**F4 — the memory of what the desk placed could drift from the pane.** If a person pressed Enter on the Mac,
the composer emptied but the memory kept the old path; the next attachment produced memory `A+B` against a
composer holding only `B`, and from then on *every* attachment was refused. Attaching now runs inside the pane
lock, reconciles first (an empty composer clears the memory), and refuses to append onto text it did not place.
That last clause fixed a second defect nobody had named: attaching used to write an absolute path into a
human's unsent draft. The same guard also stops an attachment from being typed into a choice screen, where the
digits of a path can read as menu keys — sending checked for that screen, attaching never had.

**F5 — the attach handlers ignored their own refusal.** Both awaited the injector and then set `injected: true`
unconditionally, so a refusal or a full lock queue was reported to the phone as a successful attachment with
zero keystrokes sent. They now report what actually happened.

**F6 — the new refusal had no words.** `composer-busy` was missing from the refusal table, so the phone showed
the fallback: "No composer field found." The composer is right there; the sentence was simply false. Both new
reasons now have text, and `test/send-refusal-vocabulary.test.mjs` counts the reasons the send path can return
against the table's keys so the next person to add a refusal is stopped rather than trusted.

**F7 — nothing measured the new attach-vs-send boundary.** Writing that control turned up something better than
a missing test: **the lock's job here has changed.** With the ownership guard in place, removing the lock no
longer corrupts anything — the attachment is refused instead. So the pair now measures that difference: with
the lock both the message and the attachment land; without it the attachment dies with `composer-busy`.

### Two findings rejected, with reasons

**F2 (normalisation hides whitespace edits).** The proposed fix — preserve real whitespace, normalise only
soft wrapping — is not implementable from a screen capture: wrapping and a hard newline are the same pixels,
which this file already recorded before the review. Preserving interior spaces instead would make any long
message that wraps *at a space* fail its own ownership check, so the cost lands on ordinary long messages while
the exposure it closes is an attachment path with a space in it. Whitespace-only edits cannot introduce a word,
and the text goes to Claude Code as a prompt rather than to a shell, so the worst case is a malformed path.

**F3 (the queue placeholder is treated as an empty composer).** Fail-closing here would refuse every send made
while Claude is generating — the app's main path — because that is exactly when the TUI shows the placeholder.
The only other discriminator available is the activity signal, measured at 61-82% coverage and documented as
not a decision input, so gating on it would drop roughly a fifth of legitimate sends. The residual needs a
person to type a 32-character TUI string verbatim and leave it unsent.

## Observed, after round two

| what | result |
|---|---|
| `inject.test.mjs` | 99 / 99 |
| `inject-serial.test.mjs` | 18 / 18 |
| full desk suite | 1280 / 1280 |
| e2e | 381 / 381 |

Each fix was checked by mutation rather than by its own green: the F1 suffix check, the F4 reconcile, the F4
draft refusal and the F4 choice-screen refusal were each disabled in turn, and each produced exactly one red,
with the tree restored from a copy afterwards. The F5 fix was mutated back to `injected = true` and the new
end-to-end case caught it. The F7 control fails if the attach lock is removed. The vocabulary census was failed
three ways: a missing message, a message for a reason that cannot be returned, and a message that does not say
nothing was sent.
