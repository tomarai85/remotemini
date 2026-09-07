# RemoteMini iPhone App — UI Inventory (2026-09-07)

Scope: RootView, AppState, and every file under Sources/Screens (Conversation, KeyEntry, List, Settings, Shared). Read-only survey — no files were changed.

Overall shell: a single `NavigationStack` created once in RootView. Every screen transition in the app is a **push** (`NavigationLink` or a `navigationDestination(item:)`), never a `.sheet` — this is called out repeatedly in the source comments as a deliberate, enforced convention. The only sheet in the whole app is the directory picker used to start a new session. Alerts and confirmation dialogs are used for destructive/blocking interactions (rename, return-to-MacBook, diff line comments).

---

## RootView (app shell / router)

**Purpose**: Decides which screen is root based on `AppState` — a boot-time router, not a screen with its own visible chrome.

**Navigation**: Not reached by navigation; it *is* the root of the `NavigationStack`. It swaps its child view outright (no push) based on `AppState.isLoadingCredentials` / `AppState.credentials` / `AppState.disconnected`.

**Controls / regions, in the order they can appear**:
- A bare `ProgressView`, identifier `root.loading`, shown while `appState.isLoadingCredentials` is true. No label — reading a Keychain does not go over the network, so it is deliberately kept visually identical to (but identifier-distinct from) the List screen's own initial-load spinner.
- If credentials exist: swaps straight to `ListView` (see below), with an `onUnreachable` closure that triggers a one-time "did the desk move?" reseed attempt.
- If credentials are absent: swaps to `DisconnectedView`, passing `appState.disconnected ?? .unexplained` and any `SignOutNotice`.
- In DEBUG builds only, three additional fixture entry points bypass the normal flow entirely (a List fixture, a Conversation fixture, and a KeyEntry-fixture branch) — not part of the shipping UI, used only for scripted UI tests/screenshots.

**Animation**: None declared in RootView itself; the swap between the loading spinner and the resolved screen is an unanimated `Group` content change.

**Gestures**: None (router, no touch surface of its own). It registers `.onOpenURL` as the single entry point for deep links, handing off to a `DeepLink` environment object that `ListView` later consumes.

**Styling**: None of its own; children carry their own materials/backdrops.

---

## AppState (not a screen — the credential/session state machine RootView reads)

Not a view; included here because it fully determines which of the three root screens (loading / List / Disconnected) is shown and why. Four `DisconnectedReason` cases (`seedAbsent`, `seedRejected`, `storeUnreadable`, `keyRejected`, plus an `unexplained` fallback that should be unreachable) each map to a distinct sentence and distinct primary action in `DisconnectedView`. This is the single source of truth for the "why can't I connect" narrative that both DisconnectedView and KeyEntryView render — worth flagging for anyone editing either screen's copy, since the wording lives in the state layer, not the view layer.

---

## KeyEntryView

**Purpose**: Manual Base URL + API Key entry, the last-resort fallback for connecting to a desk.

**Navigation**: Reached by push — either directly as the DEBUG fixture root, or via `DisconnectedView`'s "Enter the key manually" `NavigationLink`.

**Controls, top to bottom** (a single `Form`):
- Optional notice section, shown `if let noticeText`, i.e. only when the screen was reached after a 401 (a prior key was rejected). Identifier `keyEntry.signOutNotice`. Not shown on a first-run entry.
- A "Base URL" `TextField` (URL keyboard type, autocapitalization/autocorrection off), identifier `keyEntry.baseURL`. Disabled while a check is in flight (`viewModel.isChecking`).
- A "API Key" `SecureField`, identifier `keyEntry.apiKey`. Same disabled condition.
- Section footer, mutually exclusive: an in-flight status line (`keyEntry.inFlight`, secondary color) while checking, or an error line (`keyEntry.error`, red) if the last check failed. Never both at once — `submit()` clears the error at the start of every attempt.
- "Connect" button, becomes a spinner while checking; disabled while checking or while either field is empty. Identifier `keyEntry.submit`.
- Build-info footer line (monospaced caption, secondary), identifier `keyEntry.buildInfo` — always shown.

**Animation**: None explicit; the button's Text↔ProgressView swap and the footer's notice↔error swap are plain conditional renders, not animated transitions.

**Gestures**: Standard `Form`/`TextField` interaction only (no swipe/long-press).

**Colors/materials/typography**: `.rcThemedSurface()` modifier for the background (shared theme, not read into this inventory in detail since it lives outside the requested file set). The error text is hardcoded red (`.foregroundStyle(.red)`); notice/build-info/in-flight text use `.secondary`. Build-info uses `.caption2.monospaced()`.

---

## DisconnectedView

**Purpose**: The credential-less "first face" screen — names *why* the app has no credentials before offering the manual-entry fallback, so a build-time misconfiguration doesn't read as a blank form.

**Navigation**: Root-swapped in from RootView when `AppState.credentials == nil`. Its own "Enter the key manually" row pushes to `KeyEntryView`.

**Controls, top to bottom** (a `Form`):
- Headline section: one sentence, chosen by `DisconnectedView.headline(for:notice:)` from the `DisconnectedReason` (5 distinct sentences — bundled-without-destination, desk-rejected-key, keychain-unreadable, key-rejected [shares wording with KeyEntryView], and unexplained). Identifier `disconnected.reason`. Always shown.
- Primary-action section, shown **only when `DisconnectedView.primaryAction(for:)` returns non-nil** for the current reason (i.e. only for `.seedRejected` → "Retry with the built-in key", or `.storeUnreadable` → "Read again"). For `.seedAbsent`, `.keyRejected`, and `.unexplained` there is no primary-action button at all — the file's doc explicitly calls this out as a design rule ("don't put a button where pressing it would do nothing"). Identifier `disconnected.primaryAction`.
- "Enter the key manually" row (always shown), with a footer explaining it's a fallback. Identifier `disconnected.manualEntry`.
- Empty section whose *footer* carries the build-info line. Identifier `disconnected.buildInfo`. Always shown.

**Animation**: None declared.

**Gestures**: Standard Form/List interaction only.

**Colors/materials/typography**: `.rcThemedSurface()`; build-info in `.caption2.monospaced()` secondary, same convention as KeyEntryView.

---

## ListView

**Purpose**: The session list — the app's real home screen once authenticated. Shows every active/blocked/needs-input session on the desk, lets the user start, rename, archive, filter, and open sessions.

**Navigation**: Root-swapped in from RootView once credentials resolve. Pushes to `ConversationView` (via `Button` + `navigationDestination(item:)`, not a plain `NavigationLink`, so the destination view model is built lazily). Presents `DirectoryPickerView` as a `.sheet` (the one sheet in the app). `AccountBar` in the toolbar pushes to `SettingsView`.

**Controls / regions, top to bottom / by placement**:
- Toolbar, leading: `+` button ("New session"), opens the `DirectoryPickerView` sheet. Identifier `list.newSession`.
- Toolbar, trailing: `AccountBar` (see Shared section) — account name + entry point to Settings.
- Below the nav bar (searchable drawer, `.automatic` display mode): a search field that filters the **already-fetched** rows locally (no round trip), backed by `SessionFilter`.
- A refreshing indicator overlay (`ProgressView` in a thin-material capsule pinned near the top), shown only when `viewModel.isRefreshing` is true **and** the phase is not `.initialLoading` (that phase has its own spinner). Identifier `list.refreshing`.
- Body content, switched entirely on `viewModel.phase`:
  - `.initialLoading`: a `TimelineView` that escalates from a bare spinner (`list.loading`) to a "slow" fault banner + retry button (`list.loading.slow`) once `WaitEscalation.stage` crosses its elapsed-time threshold (default ~10s). The spinner is explicitly removed, not layered under the escalation text, when it fires.
  - `.empty`: optional update-available bar (see below) + "No sessions" headline (`list.empty`) + a hint line pointing at the toolbar `+` (`list.empty.hint`).
  - `.paneFault`: an orange fault banner (`list.paneFault`) alone if there are no sessions, or the banner stacked above the row list if there are — explicitly never stacked with any other empty-state filler.
  - `.list`: optional update-available bar + the row list.
  - `.retryable`: either a subtle one-line notice + prior (non-grayed) rows, or a "Nothing fetched yet" headline if there's no prior list to fall back on — plus a retry button either way.
  - `.unreachable`: the shared `UnreachableBanner` (context `.list`) + prior rows grayed out (`opacity(0.5)`, `.disabled`) if any, else an empty scroll area — plus a retry button.
- A stale-freshness warning pinned via `.safeAreaInset(edge: .bottom)`, shown only when the last fetch is old enough (`Freshness.freshness(...).stale`). Orange caption text. Identifier `list.freshness`. This is the *only* "instrument" left on this screen — scan-line and freshness detail were moved to Settings.
- Session rows (`SessionRowView`, see below) inside a `List`, each wrapped in a plain `Button` (not `NavigationLink`, so no auto-appended chevron). Row identifier `list.row` (repeated per row, not unique per id).
- Per-row long-press context menu: Rename, Archive, "New session here" (all always present), plus "Return to MacBook…" only `if row.isCheckout`.
- Per-row swipe actions: leading swipe reveals "Return" **only if `row.isCheckout`**; trailing swipe always reveals "Archive".
- Four alert/dialog surfaces, all `Binding(get:set:)`-driven off optional `@State` targets: Rename alert (text field + Save/Clear-name/Cancel), "Can't rename" error alert, Return-to-MacBook confirmation dialog, Return-request result alert.
- Filtered-to-zero state (typed a query that matches nothing): a distinct "No sessions match …" row (`list.search.empty`), explicitly kept visually distinct from `list.empty` (empty desk) so a person doesn't read a stale filter as "everything vanished."

**Update-available bar** (`updateBar`, shown above `.empty`/`.list` rows when `viewModel.updateNotice` is set): message + a "後で" (Later/snooze) button, identifier `list.updateAvailable.snooze`, remembered per-build-version so it reappears on the next build.

**Animation**: Row entry uses a staggered spring (`response: 0.42, dampingFraction: 0.86`), delayed by `min(position, 8) * 0.035`s per row — i.e. only the first 8 rows get a visible stagger, capped so a 41-row list doesn't take 1.4s to finish animating in. Governed by `RCListStyle.animatesEntry`; when that style flag is off, opacity/offset are hard-pinned to their settled values rather than animated at all (the source comment is explicit that "no animation" must not be faked with a zero-duration animation).

**Gestures**: Pull-to-refresh (`.refreshable`). Leading and trailing swipe actions on rows (see above). Long-press context menu on rows. Tap to open a row.

**Colors/materials/typography**: `RCBackdrop()` background; rows use `RCCard` (emphasized/orange-bordered specifically `if row.display.route.kind == .choice`); row press feedback via `RCPressable` (a custom button style that scales/dims but preserves title color, chosen specifically to fix a "row press doesn't look pressed" regression). Status chips use `RCChip`. Fault banners hardcode `Color.orange` (headline) / `.opacity(0.15)` background. Diff badge uses hardcoded `Color.green` / `RCTheme.danger`. Machine badge (`From MacBook` / `Return queued`) uses `RCTheme.violet`.

---

## SessionRowView (row content, defined in ListView.swift)

Not a separate screen, but complex enough to break out:
- Leading status mark: a `desktopcomputer` SF Symbol + green dot overlay when the session is a live tmux/desktop session, else a plain colored dot.
- Title (1 line) + relative-time trailing text on the first line.
- Subtitle (server-provided, rendered verbatim, 1–2 lines depending on `RCListStyle`).
- A second row of chips: machine badge (`From MacBook`/`Return queued`, only `if row.isCheckout`) → status word chip (`Needs your input` / `On desktop` / `Unavailable`, `nil` = no chip at all for `.worker`/`.unknown`) → diff badge (`+N -M`, only `if d.files > 0`, never shown for a zero-diff or unmeasured session) → raw diagnostic text (only for `.blocked`/`.unknown` route kinds — healthy rows never show the raw string).

---

## DirectoryPickerView

**Purpose**: Browse the desk's allow-listed root directories to start a brand-new session in a chosen folder (distinct from "New session here" on an existing row, which reuses that row's known cwd).

**Navigation**: Presented as a `.sheet` from ListView's `+` toolbar button. Its own `NavigationStack` inside the sheet; "Close" (cancellation toolbar item) dismisses; drilling into a folder does not push a new screen — it swaps the same List's sections in place.

**Controls, top to bottom**:
- Toolbar: "Close" (leading, `roots.close`) always; "Start here" (trailing, confirmation action, `roots.start`) shown **only once a root is selected** (`if let selectedRoot`), becomes a spinner while starting, disabled while starting.
- Root-not-selected state: either "No directories are allowed on the desk yet" (`roots.empty`, with a footer instructing how to add roots) if `noRoots`, or a load-error line (`roots.error`), or the list of allowed roots (`roots.root.<index>`) as tappable rows — mutually exclusive, in that priority order.
- Root-selected state: a "Here" section showing the current path (monospaced, `roots.here`) and an "Up one level" / "All roots" row (`roots.up`, label text depends on whether relativePath is empty); an "Folders" section listing immediate subdirectories (`roots.entry.<path>`), an empty-state row ("No folders inside. Start here, or go up.") if none, and a truncation marker (`roots.truncated`) if the desk capped the listing.
- Optional notice section at the bottom (`roots.notice`) for transient messages (e.g. "root gone" after a 404, or unauthorized/unreachable text).

**Animation**: None declared — section swaps are plain conditional renders.

**Gestures**: Standard List/Form tap interaction only.

**Colors/materials/typography**: Plain `List`/`Section`/system styling — no custom `RCTheme`/`RCCard` usage in this file, the one screen in the inventory that does not reach for the shared design tokens.

---

## SettingsView

**Purpose**: A second-level screen (deliberately split out of ListView per an explicit 2026-08-13 design decision to stop cramming every feature into one screen) — account switching, connection info, archived-session access, and debug "instruments" (scan line, freshness) that used to live permanently on List.

**Navigation**: Reached by push, only from `AccountBar`'s `NavigationLink` (i.e. only from List's toolbar).

**Controls, by section**:
- **Account section** (always shown): switches on `accountViewModel.phase`.
  - `.idle`/`.loading`: spinner + "Loading" (`settings.account.loading`).
  - `.failed`: orange reason text (`settings.account.failed`) + "Reload" button (`settings.account.retry`).
  - `.loaded`: an unreadable-list warning block (`settings.account.unreadable` + raw diagnostic text `settings.account.raw`, itself possibly truncated with an explicit "(Output truncated…)" note `settings.account.rawTruncated`) shown only `if !state.ok`; a "Current" row always shown (`settings.account.current`); one row per candidate account (`accountRow`, see below); anomaly message rows (`settings.account.anomaly`) if any; and a "Next account" fallback button (`settings.account.next`, spinner while advancing) that is **always available**, described in-source as "the one thing that still works even when the named list is unreadable."
  - Footer: last-failure text (`settings.account.lastFailure`) if any, shown even when the phase itself is `.loaded` (a failure can be historical, not blocking).
- **Archive section**: shown only `if archiveDeps != nil` — a single NavigationLink row "Archived sessions" (`settings.archived`) → pushes `ArchivedListView`.
- **Connection section** (always shown): "Desk" row showing host:port only (never the key) (`settings.endpoint`); "Build" row (`settings.buildInfo`); an optional "Reconnect to this build's desk" button (`settings.reseed`, only if `onReseed` was supplied) with an explanatory footnote.
- **Instruments section**: shown only `if let list = listViewModel` (i.e. only when opened from List, not from a fixture/other entry point) — "Scan" line (verbatim server text, `settings.scanLine`) if available, and "Freshness" row (`settings.freshness`, orange if stale) if a fetch has happened. Footer: "For debugging on a bad day. Safe to ignore normally."

**Account row detail** (`accountRow`): name (dimmed if not selectable) + optional "blocked" reason caption; optional usage block — a status line (`settings.account.status`, red if `relogin_required`, secondary otherwise) shown **before** the staleness check so a "can't answer" reason is never hidden by a staleness note; then either a "Usage unavailable" caution line (`settings.account.usageStale`, if the measurement is >900s old) or the actual "Session/Week % left" line (`settings.account.usage`, red if either window is ≥98% used). Trailing: a spinner while switching to that row, or a checkmark if it's the active account.

**Animation**: None declared anywhere in this file.

**Gestures**: Standard List/Form tap only. No swipe actions here.

**Colors/materials/typography**: `.rcThemedSurface()`. Extensive use of `.orange`/`RCTheme.danger`/`RCTheme.caution` for graded severity (unreadable list = orange, exhausted usage/relogin-required = danger red, stale usage = caution). Monospaced fonts used for the endpoint, build line, and account names/usage numbers (`monospacedDigit` specifically for usage percentages, so they don't jitter as digits change).

---

## ArchivedListView

**Purpose**: Read-only-ish list of archived (removed-from-List) sessions, with a single "Restore" action per row — deliberately has no way to open a session directly from here (must restore, then go find it in List).

**Navigation**: Reached by push, only from SettingsView's "Archived sessions" row.

**Controls, top to bottom**:
- `.loading`: spinner + "Loading" text (no identifier on the spinner row itself).
- `.failed`: "Couldn't load" (orange) + "Reload" button.
- Loaded + empty: "No archived sessions" (`archived.empty`).
- Loaded + rows: title + subtitle (1 line, secondary) per row, with a trailing "Restore" button (`archived.restore.<id>`, bordered style).
- An alert (title "Archive") surfaces transient notices (unreachable / unauthorized) after a restore attempt.

**Animation**: None declared.

**Gestures**: Standard List tap only; no swipe actions (unlike the main List, archived rows have no swipe-to-restore — restore is a visible button only).

**Colors/materials/typography**: `.rcThemedSurface()`; otherwise plain system List styling, no `RCCard`/`RCChip` usage.

---

## ConversationView

**Purpose**: The core chat/transcript screen — read the conversation, send messages/attachments, respond to approval prompts, search the transcript, view what's running, and jump into the diff viewer. By far the largest and most stateful screen in the app (2,218 lines).

**Navigation**: Pushed from a List row (`Button` + `navigationDestination(item:)`), or from a search-results row via a jump. Toolbar exposes two further pushes: to `DiffView` (plusminus icon) and to `SubagentsView` (stacked-squares icon). No `.sheet` usage anywhere in this file (photo/file pickers use their native presentation, not a custom sheet).

**Controls / regions, top to bottom**:

*Nav bar / toolbar*:
- `.searchable` search field, always drawn (`displayMode: .always`, not `.automatic`) specifically so the nav-bar height never changes with scroll — this is called out as necessary to avoid perturbing the auto-scroll "landing" logic.
- Toolbar trailing: Diff icon (`conversation.diff.open`) with an unread-comment-count badge overlay shown only `if viewModel.diffComments.count > 0` (`conversation.diff.commentCount`); Subagents icon (`conversation.subagents.open`), no badge.

*Body, switched on `viewModel.phase`*:
- `.initialLoading`: spinner (`conversation.loading`).
- `.unreachable` / `.malformedBody`: shared `failureView` (headline + Retry button).
- `.notFound`: distinct view with **no retry button** (retrying a 404 just 404s again) — only "Back to sessions" (`conversation.notFound.backToList`).
- `.contractViolation`: distinct view with **neither retry nor back-to-list** — a fixed diagnostic sentence only, on the reasoning that this indicates an app/server contract bug, not a user-facing recoverable state.
- `.loaded`: the main transcript UI (see below).

*`.loaded` layout, top to bottom*:
1. `statusBanners`: gap notice (`conversation.gapNotice`, secondary) → worker-route error (`conversation.workerError`, red) → degradation banner (see below), each independently shown/hidden.
2. Either an empty-state block ("No messages yet" + hint, `conversation.empty`) or the scrollable transcript (`LazyVStack` of `EntryBubble` rows with a bottom-anchor sentinel used for the auto-scroll-to-bottom logic).
3. Below the transcript (hidden entirely while search is presented): either `detachedFooter` (viewing older/detached history) or `loadEarlierFooter`, then the `composer`.
4. A search-results overlay (`searchResultsPanel`) drawn **on top of** the transcript (not swapped in) whenever search is presented — explicitly not a replace-in-place, to avoid re-triggering the transcript's `.onAppear` auto-scroll logic.

**Composer stack, top to bottom** (all conditionally shown, described in-source as "only one standing-status slot may be visible at once" for the top items):
- `standingStatusSlot`: either the shared `UnreachableBanner` or a send-queue strip (`conversation.queueStrip` — queued-count text + age text + a "Clear" button), never both.
- Desk-working indicator (dot + "Working · <tool>" / "Working" / "Waiting on you" / "Idle"), shown only `if let working = viewModel.deskIsWorking` — deliberately absent (not "Idle") when the state can't be observed. Identifier `conversation.deskState`.
- Session-runtime line (model/tool info, `cpu` icon), shown only if available. Identifier `conversation.sessionRuntime`.
- Permission-mode chip (`lock` icon), shown only if available, deliberately **not** colored as a warning even for `bypass` mode (source comment: that alarm belongs to the choice-card hard-stop, not this chip). Identifier `conversation.permissionMode`.
- Away-digest line (what happened while you were away), shown only if non-empty, colored caution only `if d.shouldUrge`. Identifier `conversation.awayDigest`.
- Independent one-line banners, each its own row so a surviving sentence stays attributable to one operation: queue-clear result (`conversation.queueBanner`), send result (`conversation.sendBanner`), interrupt result (`conversation.interruptBanner`), interrupt-disabled reason (`conversation.interruptDisabledReason`), interrupt-in-flight notice (`conversation.interruptInFlightNotice`), send-in-flight notice (`conversation.sendInFlightNotice`), composer-disabled reason (`conversation.composerDisabledReason`).
- `choiceCard` (approval/menu prompt from the desk) — see below.
- Choice-in-flight notice (`conversation.choiceInFlightNotice`), deliberately kept **outside** the choice card so it survives the card being replaced by a non-choice poll result mid-flight.
- Attach-result notice (`conversation.attachNotice`).
- Usage-limit notice (`conversation.limitedNotice`), shown only if the desk reports a limit — sending is never blocked by it, only announced.
- Slash-command chips (`/compact`, `/context`, `/model`) in a horizontal scroller, shown only `if viewModel.composerEnabled`. Pressing one inserts text only; never auto-sends.
- `/model`/`/effort` argument chips (a second row, e.g. model names or `low/medium/high`), shown only when the draft text names one of those commands and candidates exist.
- `@`-path-completion chips, shown only when the draft ends in `@<partial-path>` and candidates exist, with a non-interactive "…" chip if the desk truncated the candidate list.
- The input row itself: Interrupt button (stop-circle icon, spinner while interrupting, dimmed to 45% opacity when the desk is known idle but never actually disabled-looking) → Photo-attach button (`PhotosPicker`, hourglass icon while busy) → File-attach button (`fileImporter`, doc-badge icon) → the message `TextField` (with a keyboard accessory toolbar of `@`/`/`/backtick insert buttons plus a "Hide keyboard" button) → Send button (arrow-up-circle, spinner while sending/verifying, colored only when actually sendable).

**`choiceCard`** (approval/menu prompt): risk banner (icon + notice + bullet-point "why" signals) shown only if the server sent a non-empty risk notice — explicitly renders a low-key "not checked" line even for an "unmatched" risk classification rather than staying silent, on the reasoning that silence itself reads as "safe." Then head lines (verbatim from the server), then any options the server declined to give a button for (printed as plain numbered text, not buttons — a deliberate signal that the server withheld that key). If pressable: an "armed" confirmation notice for dangerous choices (tap-twice pattern), then one row per button with a per-button spinner that only shows for the exact key in flight, then a stale-choice warning if applicable. If not pressable: the server's reason text in orange. A choice-specific banner row at the bottom.

**`degradationBanner`** (poll-loop health, 3 states): `.normal` → nothing; `.degraded` → a quiet one-line "Updates are lagging" + last-confirmed time, no buttons; `.stalled` → red "No response confirmed" + last-confirmed time, plus Retry (`conversation.stalled.retry`) and Re-read (`conversation.stalled.reread`) buttons.

**Search results panel** (`searchResultsPanel`, overlay): a "Results" header with a "Done" close button (`conversation.search.close`); status lines that vary by `viewModel.searchState` (idle hint, running spinner, match-count + "showing newest N" + "search stopped before start of conversation" caveats, two distinct empty states, and a failed state with its own Retry); then result rows (tappable `EntryBubble`s that jump to that point in the transcript if the server supplied an anchor, otherwise inert) plus a jump-failure notice and a static "tap to jump" / "can't jump" hint line.

**`EntryBubble`** (one transcript row, 3 role-based renderings): `.tool` rows render as a compact pill (who + truncated text + an expand chevron shown only `if entry.output != nil`), tappable to reveal/collapse trimmed tool output beneath it (animated, `.snappy(duration: 0.22)`), with a "trimmed by the desk" note if the output itself was cut. `.user` rows render as a right-aligned bubble. `.assistant`/`.unknown` rows render as bubble-less full-width text (explicitly matched to "the official Claude app" look — no bordered bubble for assistant replies).

**Animation / transitions** (explicit, several — this screen has by far the most motion of any screen in the app):
- New transcript rows insert via `.transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))`, animated only when `viewModel.live.count` changes (not on the initial bulk load, to avoid 90 rows sliding in at once).
- Tool-output expand/collapse: `.snappy(duration: 0.22)` + `.transition(.opacity.combined(with: .move(edge: .top)))`.
- The initial-landing auto-scroll-to-bottom logic is a hand-rolled convergence loop (not a single animated scroll) that re-measures and re-corrects up to 12 times, with its own stall/give-up logic and a debug-only "landing distance" accessibility readout used purely for instrumented UI tests.
- Send/attach/choice buttons use `ProgressView` spinners in place of their icon while their respective operation is in flight (a state swap, not a transition modifier).

**Gestures**: Long-press on a tool row's chip toggles output expand (`onTapGesture`, not an actual `Button`, specifically to avoid SwiftUI collapsing the row's child `Text` elements into a button label and breaking existing accessibility anchors). Search-result rows use `onTapGesture` for the same reason. No swipe actions on this screen. Keyboard accessory toolbar is the one keyboard-specific affordance in the inventory.

**Colors/materials/typography**: Extremely theme-heavy relative to other screens — the file's comments record multiple rounds of "flat vs glass" color-system unification (moving away from raw `Color(.systemGray6)`/`.systemGray5` "neutral gray" toward `RCTheme` tokens like `.surface`/`.surfaceElevated`/`.composerFieldFill`/`.composerBarFill`) specifically to stop different pieces of this one screen drifting onto different gray families. Uses `.thinMaterial` for the queue-clear-result background and the stop-notice-style banners; `RCCard(emphasized: true)` for the choice card; `RCChip` for slash/path/model chips. Danger/caution colors come from `RCTheme.danger`/`RCTheme.caution` rather than raw `.red`/`.orange` in most (not all — a few `.red`/`.orange` literals remain, e.g. `degradationBanner`'s `.red` and several banner-tone mappings' `.orange`).

---

## DiffView

**Purpose**: Read a git diff for the current session's working tree, and leave per-line comments that queue for the desk.

**Navigation**: Pushed only from ConversationView's toolbar plusminus icon.

**Controls, top to bottom**:
- `.loading`: spinner (`diff.loading`).
- `.failed`: message + Retry button (`diff.retry`), wrapped in `diff.failed`.
- `.loaded`, sub-cases keyed by the server's `reason` field:
  - A reason present (not-a-repo / no-cwd / cwd-missing / git-failed / unsafe-repo / busy / unknown-default): a `ContentUnavailableView` (`diff.reason`) with reason-specific title+detail text, **plus a "Try again" button only when `reason == "busy"`** — the source is explicit that other reasons wouldn't change on retry, so no button is drawn for them.
  - No reason, no files: "No changes" `ContentUnavailableView` (`diff.empty`).
  - Files present: a scrollable list of file cards.
- File card: path (monospaced, truncated from the head) + "staged" chip (only `if file.staged`) + `+added`/`-removed` counts (green/danger, only if not binary) + either "Binary file" text or per-hunk diff content + a "This file was cut off" caption if the file itself was truncated.
- Hunk view: raw header line (server's literal text, unprocessed) + per-line rendering with a colored background/foreground by add/del/context kind, a left accent-colored marker bar shown only on lines carrying an existing comment, and a long-press-to-comment gesture on lines whose line number could be resolved.
- A bottom `safeAreaInset` truncation notice ("Truncated — showing partial output", `diff.truncated`) shown only `if response.truncated`.
- A `.alert` for adding/editing/removing a line comment (TextField + Save + a "Remove" button shown only when editing an existing comment + Cancel).

**Animation**: None declared — this screen has no explicit `.animation`/`.transition`/`withAnimation` calls at all, unlike Conversation and List.

**Gestures**: Long-press (`.onLongPressGesture`) on a diff line opens the comment alert — the *only* place in the whole app this specific gesture is used (Conversation's tool-row expand uses a plain tap). Lines with no resolvable line number have `onTap` set to `nil` and cannot be commented on.

**Colors/materials/typography**: `RCBackdrop()` background; `RCCard()` for file cards; `RCChip(tint: RCTheme.accent)` for the "staged" chip; add/del lines use raw `.green`/`RCTheme.danger` at `0.12` opacity backgrounds; monospaced fonts throughout (path, hunk header, line text) — the only screen where nearly everything text-related is monospaced, appropriate to its code-reading purpose.

---

## SubagentsView

**Purpose**: See what background subagents/tools the current session has running, and stop one from the phone (the desk performs the actual stop; the phone only names an id).

**Navigation**: Pushed only from ConversationView's toolbar stacked-squares icon.

**Controls, top to bottom**:
- `.loading`: spinner (`subagents.loading`).
- `.failed`: message + Retry (`subagents.retry`), wrapped in `subagents.failed`.
- `.loaded`:
  - A server-authored note line (`subagents.note`) — always rendered verbatim, never reconstructed client-side, because the server's empty-list note can mean three different things (genuinely none running / can't read the directory / doesn't know if they finished) and only the server can tell them apart.
  - A stop-result notice (`subagents.stopNotice`, thin-material background) shown only after a stop attempt.
  - One card per subagent row (`SubagentRowCard`).
- Tapping empty space in the list disarms any "confirm stop" state (`onTapGesture` on the scroll content).

**`SubagentRowCard`**: description/type/id title (whichever is available, in that priority) + a secondary-line trio of state word (server-authored, `subagents.row.state`) / agent type / model, all optional. A "Stop" button is drawn **only for rows the view model says are stoppable** (i.e. only running rows) — a two-tap confirm pattern (label reads "Stop" then "Confirm stop" after the first tap, tinted red once armed), with a per-row spinner while stopping and the whole button disabled while any stop is in flight elsewhere on screen.

**Animation**: None declared in this file.

**Gestures**: Tap-to-arm / tap-again-to-confirm on the Stop button (a two-step confirmation, not a system alert) is the distinguishing interaction pattern here — deliberately chosen, per the source comment, because this is an irreversible remote action that must not be sendable by a single accidental tap.

**Colors/materials/typography**: `RCBackdrop()` background; rows use `.thinMaterial` (not `RCCard`, unlike every other card-like element in the app); Stop button tinted `.red` only once armed, `.secondary` otherwise.

---

## Shared components (used across screens)

- **AccountBar**: toolbar-embedded account-name label + entry point to `SettingsView`, used only in ListView's toolbar. States: `.idle`/`.loading` → spinner (deliberately never blank, since blank would read as "no account"); `.loaded` → shortened name (truncated at `@`, full value still used for actual switching) + a warning triangle if the account list itself is unreadable; `.failed` → the failure text itself, width-capped to 120pt so it can't crowd out the `+` button in the toolbar (a regression the source explicitly documents having caused the label to disappear entirely under SwiftUI's ideal-width layout). Refreshes on `scenePhase` foreground-resume via the shared `ForegroundResume` gate (not on a timer).
- **UnreachableBanner**: shared red banner used identically by List and Conversation (`context: .list` vs `.conversation` only changes the trailing hint sentence). Deliberately states only the observation ("N fetches failed") and never asserts a cause (Wi-Fi vs. desk down vs. tailnet issue are indistinguishable to the phone). No dismiss button — it clears only when a request actually succeeds.
- **TapTarget**: not a view but a `View` extension (`.tapTarget()`) enforcing a 44×44pt minimum hit target, applied inside button labels (not around them) plus an explicit `.contentShape(Rectangle())` so the enlarged frame is actually tappable, not just visually padded. Used pervasively across Conversation, DiffView, SubagentsView, ListView, and KeyEntryView's "Connect"-adjacent controls (search-adjacent retry/try-again buttons, interrupt/send buttons, choice buttons, load-earlier/back-to-live/older/newer buttons, keyboard tools).
- **RCTheme / RCBackdrop / RCCard / RCChip / RCPressable / RCListStyle** (referenced constantly but defined outside the requested file set, under `Sources/Core/`): the shared design-token layer. Nearly every screen except DirectoryPickerView and ArchivedListView reaches for at least `RCBackdrop()` for its background and `RCTheme.accent`/`RCTheme.danger`/`RCTheme.caution` for semantic coloring.

---

## Cross-screen observations

**(a) Controls that appear on multiple screens with inconsistent placement or form.**
- "Retry" exists in at least six different visual forms across the app: a plain `Button` with `.tapTarget()` (List's `list.retry`, Conversation's `conversation.retry`/`conversation.search.retry`, SubagentsView's `subagents.retry`), a `.borderedProminent` button (DiffView's `diff.retry`, only for the `busy` reason), and a two-button pair with different verbs for the same concept (Conversation's degraded state offers "Retry" *and* "Re-read" as two distinct actions for what a user would likely think of as one "try again" impulse). There is no single shared "Retry" component; each screen reimplements it, and the styling (plain vs. bordered-prominent) is not consistent by function (e.g. "this failed, try again" vs. "this is busy, try again shortly") but by which screen happened to add it.
- Build-info line (`BuildInfo.line`, monospaced caption) appears independently on KeyEntryView, DisconnectedView, and SettingsView, each with its own identifier (`keyEntry.buildInfo`, `disconnected.buildInfo`, `settings.buildInfo`) and its own hand-placed footer, rather than a single shared "build footer" component — the source comments confirm this is deliberate (a dedicated UI test, `BuildIdentityUITests`, checks all three name the same build) but it is still three copies of the same view fragment.
- "Unreachable"/degraded-connectivity messaging exists in at least three independently-worded forms: the shared `UnreachableBanner` (List/Conversation), Conversation's separate `degradationBanner` 3-stage system (normal/degraded/stalled, a *different* state machine from `UnreachableBanner`'s failure-streak count), and Settings' per-account "usage unavailable"/"relogin required" lines. A user could plausibly see two different "can't reach/read" messages on two different screens for what is, from their perspective, one underlying connectivity problem.
- Slash-command / path-completion / model-argument chips in Conversation's composer are three visually near-identical horizontal chip-scrollers stacked on top of each other when all three could apply, each independently gated and each with its own `ScrollView(.horizontal)` — they are not unified into one row despite sharing the same `RCChip` styling and "insert into draft, never auto-send" behavior.

**(b) Always-visible elements that could be progressive-disclosed.**
- Conversation's permission-mode chip and session-runtime chip are both always-on (whenever data is available) rather than tap-to-reveal, even though the source explicitly frames them as low-priority/read-only "state of the world" info competing for the same vertical space as urgent operational banners (send/interrupt/choice results). A collapsed "desk status" disclosure row could hold working-state + runtime + permission-mode + away-digest together instead of stacking four independent conditionally-shown rows.
- Settings' "Instruments" section (scan line + freshness) is explicitly labeled in its own footer as "for debugging on a bad day, safe to ignore normally" — an admission that this is diagnostic information permanently occupying screen space in a full `Section`, rather than living behind a disclosure toggle or a long-press/debug-menu affordance.
- DirectoryPickerView's root list and List's `+` button both exist to start a new session, and the row-level "New session here" context-menu action is a third path to a related outcome (same desk, different scoping) — three separate discovery routes to overlapping functionality, none of which cross-reference each other in the UI itself (only in code comments).

**(c) Notices/banners that stack.**
- Conversation's composer is the clearest case: `standingStatusSlot` (1 of 2) → desk-working line → session-runtime line → permission-mode chip → away-digest → queue banner → send banner → interrupt banner → interrupt-disabled-reason → interrupt-in-flight-notice → send-in-flight-notice → composer-disabled-reason → choice card → choice-in-flight-notice → attach-notice → limited-notice, all independently conditioned. The source comments show real prior incidents from this ("帯3段", "3 banners stacked," 2026-08-16) that were partially mitigated by making the *top* slot (unreachable vs. queue) mutually exclusive, but the remaining dozen-plus rows below it are still independent and can, in the worst case (send in flight + interrupt in flight + a stale choice + an attach result + a limit notice all true at once), stack five or more single-line notices before the actual text field is reached.
- List's `.list`/`.empty` phases can show an update-available bar *and* the bottom-pinned stale-freshness warning simultaneously — two independent "something about this screen's data is not current" messages, one server-version-related and one fetch-age-related, that a user has no obvious way to tell apart at a glance beyond reading both.
- Settings' account rows can independently show a status line (relogin-required/unavailable) and a "usage unavailable — desk cannot measure" line for the same account, per the source's own note that the status check is placed before the staleness check specifically so both can appear together without either hiding the other.

**(d) State changes with no animation, shown abruptly.**
- DiffView has zero `.animation`/`.transition`/`withAnimation` calls anywhere in the file — file cards, hunks, and the loading→loaded→failed phase switch all cut instantly, including the comment marker bar appearing/disappearing on a line the instant a comment is saved or removed.
- SubagentsView likewise has no explicit animation — the Stop button's label change ("Stop" → "Confirm stop"), its tint change (secondary → red), and the spinner swap-in all happen as an unanimated state change, despite this being the one two-tap-confirm irreversible action in the app where a visible "arming" transition might reduce misreads.
- ListView's phase-to-phase transitions (`.initialLoading` → `.list`/`.empty`/`.paneFault`/etc.) are entirely unanimated `switch` swaps — the whole screen's content can replace itself in one frame, in contrast to the row-entry stagger animation that governs content *within* the `.list` phase once reached.
- Conversation's numerous composer banners (queue/send/interrupt/choice/attach/limit notices) all appear and disappear as plain conditional renders with no transition modifier, in contrast to the deliberate, heavily-commented transition work applied to transcript-row insertion and tool-output expand/collapse just above them in the same file — motion craft is concentrated in the transcript area and absent from the status-banner stack immediately below it.
