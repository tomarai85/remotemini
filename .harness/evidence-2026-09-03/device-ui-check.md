# The UI tests ran on the real phone for the first time (2026-09-04)

Every UI test in this repo has run on the simulator. That is a real green, but three things were never
measured: whether the controls land where a thumb can reach them on actual hardware, how the real keyboard
interacts with the composer, and whether anything about the physical device changes the app's behaviour.

Tom connected his iPhone and asked whether the app could be driven automatically. It can.

## What ran, and where

`ios/tools/device-ui-check.sh`, targeting `platform=iOS,id=EC0FCBEE-…` (Tom's iPhone 13, iOS 26.5), signed
with the Apple Development identity already in the keychain. Six UI test classes:

| class | result |
|---|---|
| `ToolOutputFoldUITests` | pass |
| `SearchJumpUITests` | pass |
| `SearchHighlightUITests` | pass |
| `ListSearchUITests` | pass |
| `AttachFileButtonUITests` | pass |
| `EmptySessionListHintUITests` | pass |

`Executed 6 tests, with 0 failures (0 unexpected) in 56.872 seconds`, `** TEST SUCCEEDED **`, `xcode rc=0`.

Build 155 was also installed directly over USB (`xcrun devicectl device install app`), so the OTA page was not
needed. That is the faster route whenever the phone is at the desk.

## Two failures with one message, and two different causes

Both attempts before the green one died with the same line:

> `RemoteMiniUITests-Runner encountered an error (Early unexpected exit, operation never finished bootstrapping
> — no restart will be attempted. (Underlying Error: Lost pending connection to the test runner before
> launch.))`

- **First attempt**: the device had gone to `unavailable` mid-run. `xcrun devicectl list devices` showed it;
  `devicectl device info apps` returned `error 1011 device not found`.
- **Second attempt**: the device stayed `connected` the whole time and the run failed identically. The first
  diagnosis was therefore wrong for this case. Launching the runner directly said so plainly:

  > `Unable to launch com.tomarai.RemoteMiniUITests.xctrunner because the device was not, or could not be,
  > unlocked. (FBSOpenApplicationErrorDomain error 7) — BSErrorCodeDescription = Locked`

  XCUITest cannot start its runner while the screen is locked, and the layer that reports the failure does not
  say so.

The general shape: **the same symptom does not imply the same cause, and the reporting layer is rarely the
refusing layer.** Asking the refusing layer directly (`devicectl device process launch`) produced the true
reason in one command, after a four-minute build had produced only the generic one twice.

The runner now checks the device state before building and exits 90 in about two seconds when it is not
`connected`. It cannot pre-check the lock, because lock state is not exposed — the honest handling is the
recorded lesson plus the direct-launch probe when it fails.

## What this does NOT cover

The detached history window — last night's work — is still unmeasured on hardware. Its tests are ViewModel
tests against a fake desk, not UI tests, so this run says nothing about it. Measuring it for real needs a
different shape: a long conversation on the real desk, a search hit more than 500 entries back, and a tap.
That is the next honest step for it, and it is not what this run proved.
