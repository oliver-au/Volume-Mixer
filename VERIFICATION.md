# Volume Mixer verification

The current source is **1.3 (10)**, a local Apple Silicon build for macOS 27.
Version 1.3 changes release metadata only; the validation below records the 1.2.4 build.
The security hardening in 1.2.1 and a subsequent defect review were checked on
7 October 2026. The installed app was not replaced or launched during this review.

## Automated checks

Run `scripts/test.sh` with Apple's Command Line Tools and the macOS 27 SDK.
The suite covers 63 core scenarios and four isolated native AppKit scenarios:

- Gain, attenuation, mute/unmute ramps, channel mapping and input exclusion.
- Bounded audio queues, variable callback sizes, ring wraps and concurrent ordering.
- App/helper and Wine identity, separate bottles and PID reuse.
- Malformed object-list sizes, channel overflow, and truncated or oversized Wine metadata.
- Saved levels and routes, isolated preference cleanup and symlink-safe file cleanup.
- Independent sessions, explicit output routing, disconnected devices, sleep/wake,
  pause/shutdown and latched failure recovery using simulated hardware.
- Default-output changes preserve unaffected explicit routes and do not retry
  failures on unrelated devices; system-following routes still move correctly.
- Hidden idle-app attenuation, rapid slider updates, batched preference writes,
  dragging across 100%, delayed bypass and flushing on pause/shutdown/reset.
- Bounded transient-discovery recovery, per-route health checks, retained output
  choices and connecting states for newly discovered apps.
- Repeated 500 ms capture backlogs, crossfades spanning render calls and ring wraps,
  interrupted crossfades, gain/mute preservation and mono/stereo mapping.
- Full-queue overflow recovery, repeated consumer resets, fresh-audio fade-in,
  gain/mute preservation, and concurrent stereo integrity through overflows.
- Keyboard-repeat save debouncing, native arrow/Shift-arrow actions and bounds,
  delayed termination events, immediate completion and bounded run-loop waits.
- Output symbols from terminal/transport metadata and lifetime-safe idle retention.
- Apple-engine offline conversion, mono/anti-alias behavior, independent gain/mute
  and a ten-minute simulated clock-drift run when Audio Units are available.

The 1.2.4 run passed **all 63 core and four native AppKit scenarios**, with no
skips or failed assertions. The same 63 core scenarios passed under
AddressSanitizer with no memory reports. A separate C capture/render stress probe
passed under ThreadSanitizer with zero race reports, zero invalid stereo frames,
and successful playback after repeated queue overflows. Clang static analysis
reported zero diagnostics. The native checks instantiate the production slider
and quit-wait helper without displaying windows or terminating any running app.

The full-queue regressions failed with 90 assertions against the old processor
before the fix. The original keyboard path was separately reproduced as 20
keypresses causing 20 preference writes; the new native test checks that key
repeats emit volume actions without drag-end callbacks, and the engine regression
checks that the repeat burst saves only once.

The earlier final 1.2.3 run had **60 passes, no skips and no failed assertions**. It ran as
the ordinary user with access to Apple's Audio Unit registry, without administrator
rights. The initial restricted run passed 56 scenarios and skipped four because
it could not resolve Audio Units; that run also verified the unavailable-component
failure path. The four offline Apple-engine checks then passed, including stereo
conversion in both directions, mono/anti-alias checks and ten simulated minutes
of playback with clock drift. These are synthetic tests, not listening checks.

The same 60 scenarios passed under AddressSanitizer with no skips or reported
memory errors. Clang static analysis of the updated C processor reported zero
findings. The release app and isolated preview build passed strict ad-hoc
signature verification.

Tests use in-memory preferences and disposable files under `work/`; they do not
capture or play hardware audio or change macOS settings. Build and test logs are
local artifacts and are not committed.

## Security review

The source review covered audio buffer handling and lifecycle, process metadata,
permissions, stored data, uninstall cleanup, build scripts and repository content.
This is a source review and local test pass, not an independent penetration test.

Fixed in 1.2.1:

- Reject misaligned, oversized and inconsistent Core Audio object-list lengths
  before allocation/use; verify scalar property lengths and reject channel-count
  arithmetic overflow. Unsupported metadata follows the existing failure path.
- Bound process-name decoding to its fixed field, explicitly terminate executable
  paths, and reject oversized Wine identities instead of silently truncating them.
  Clear the temporary kernel argument/environment buffer with `memset_s` before
  freeing it; only the allowlisted game and bottle fields are retained.
- Build and package in fresh temporary staging directories, copy an explicit list
  of resources, and replace the complete generated bundle. Leftover files cannot
  be inherited from earlier app bundles or installer staging folders.

Validation on 7 October 2026:

- Clang static analysis reported no findings after hardening.
- A local deterministic mutation harness exercised 100,000 synthetic Wine metadata
  inputs under AddressSanitizer and UndefinedBehaviorSanitizer without a finding.
  The installed Command Line Tools lacked libFuzzer; no tool was installed.
- A stale-file regression placed synthetic markers in old staging folders, the
  previous generated app and an unexpected icon resource. The new bundle contained
  only the seven expected files, and the uncompressed installer contained the
  expected executable/readme and none of the stale markers. Temporary staging
  directories were removed after packaging.
- The app passed strict signature verification, and the DMG passed image and
  SHA-256 verification. Mounting the new image was unavailable in the command
  environment, so this review did not repeat an installed first-launch check.
- Repository content was scanned for private keys, access tokens, credential
  assignments/URLs, sensitive filenames and machine paths. No credentials were
  found. Retina icon filenames were reviewed as email-pattern false positives.

No network transport/upload code, third-party package dependencies, privileged
helper or automatic system-setting changes were found in the app. Login-item and
privacy-settings actions require explicit UI interaction. Uninstall cleanup uses
the app's own preference domain and explicit file allowlist; its disposable-file
test verifies that a symlink target and unrelated app data survive cleanup.
No live audio, permission, login-item or macOS settings changes were made during
this review. The existing ad-hoc signing/public-distribution limitation remains.

## Follow-up defect review

Reviewed discovery and stable identity, control lifecycle, audio buffers and
conversion, persistence, UI state, uninstall boundaries and release packaging.

### Review fixes in 1.2.4

- Arrow-key actions use the existing 350 ms save debounce. Mouse drags retain
  their end-of-drag flush; pause, sleep and shutdown still flush pending changes.
- Capture owns the write cursor and playback owns the read cursor. On overflow,
  capture sets an atomic reset request and drops incoming packets until playback
  has discarded the stale queue and acknowledged the reset. Playback re-primes
  from fresh samples and fades in over 5 ms. The request/acknowledgement ordering
  prevents either callback from overwriting in-flight samples, and capture reads
  the read cursor only after observing the acknowledgement. No allocation, locks,
  waiting, logging or file operations were added to the callbacks.
- Oversized buffers remain errors. The existing three-second stalled-output
  watchdog and tests remain in place; recovery cannot keep an unresponsive output
  controlling an app indefinitely. Actual Bluetooth stall/reconnect listening
  checks remain outstanding.
- The developer quit helper pumps the main run loop and uses a monotonic timeout,
  allowing NSRunningApplication termination state to update during its 12-second
  wait. Tests use timer-driven fake completion; the installed mixer was not quit.
- The redundant minimum of already-equal frame counts is now a direct assignment.

The 1.2.4 app and installer were built and signature-checked. The versioned image
was mounted read-only; its app and a disposable copied app passed strict signature
verification. The mounted executable, version metadata and installation text
matched the release inputs. Both DMG filenames passed SHA-256 checks. The image
was ejected and its disposable review directory removed. A scan of 47 tracked
and new project files found no credential-pattern matches. No app was installed
or launched, and no macOS settings or administrator privileges were used.

### Behaviour fixes in 1.2.3

The supplied review correctly identified gaps in the earlier 46-scenario suite.
Five regression scenarios were first run against 1.2.2 and produced eleven failed
assertions: hidden-app teardown, repeated slider discovery/persistence, unity-gain
session churn, transient discovery teardown and missing new-app connecting state.
Those scenarios now pass. Additional regressions cover recovery boundaries.

- Row visibility no longer determines session lifetime. Existing playback processes
  remain controllable while idle; retaining an idle process with no exposed streams
  requires its original object, PID and nonzero start time. Input-only and recycled
  processes are not retained. Playback activity/device listeners supplement polling
  and are removed on process removal, audio-service restart and shutdown.
- Gain changes on an existing graph use cached state, with no hardware scan or JSON
  encoding per slider event. Preferences flush on drag completion, pause, sleep and
  shutdown; other volume events use a 350 ms debounce. Reset/uninstall cannot be
  undone by a pending write. Unity gain retains the graph while dragging and for a
  one-second grace period before the next poll bypasses it.
- Only known transient discovery status codes receive a grace period, bounded by
  fewer than three failures and less than two seconds. Existing graphs must still
  have valid process lifetimes, a live matching output and healthy callbacks.
  Failed routes stop and latch their errors; unknown/fatal errors stop all control.
  The last successful inventory stays visible, but no new graph uses stale data.
- Large buffered backlogs skip forward on the consumer thread with a preallocated
  five-millisecond crossfade. Normal packet variation and slow drift keep the
  continuous path. Tests cover 48, 44.1 and 24 kHz, mono/stereo, repeated stalls,
  ring wraps, partial/interrupted crossfades and muted output. The concurrent
  lossless-ordering test stays below the deliberate backlog threshold; separate
  recovery tests verify discarded-frame telemetry and bounded queue depth.
- A new app appears as Connecting before graph creation. Error rows expose an
  accessible Retry button, and output icons use stream terminal/device transport
  metadata instead of guessing from names. Unknown Bluetooth device types use a
  generic waveform, rather than assuming every Bluetooth device is a headset.

The isolated 1.2.3 interface preview was inspected visually and through its
accessibility tree. Retry remains available on an error row; adjusting/muting
Safari to 61% preserved the other app's 37% setting. Unmute restored 61%, and
pause/resume correctly disabled/re-enabled controls and restored the error action.
The preview used fake sessions and memory preferences and was then quit. The
installed mixer, real playback, login items and macOS settings were untouched.

The 1.2.3 installer was built successfully, mounted read-only with `diskutil`,
and ejected after verification. Both the mounted app and a disposable copied app
passed strict signature verification. Executable, Info.plist and install text
matched their build inputs, and both installer filenames passed SHA-256 checks.
Temporary installer-review/staging directories were removed. A new scan of all
45 tracked files found no credential patterns or sensitive filenames.

### Previous routing fixes in 1.2.2

A simulated system-output switch reproduced two failures in the previous engine:
it interrupted an unchanged explicit route, and it retried a failed route whose
source/destination had not changed. The two new regression scenarios failed with
five assertions before the fix and passed after it. The engine now relies on each
app's source/destination signature instead of tearing down every graph when the
default changes. Sleep and audio-service restarts still release all sessions.
Existing profile-change, source-change, reconnect, pause and shutdown checks pass.

The rebuilt 1.2.2 app, mounted read-only installer app and project-local copy of
that app all passed strict signature verification. The mounted executable,
Info.plist and install instructions matched the build inputs. Both DMG filenames
have matching bytes and passed SHA-256 verification; the image itself passed its
checksum check. The bundle contains only its seven expected files. The review
image was ejected and temporary staging/review directories were removed.
The installed app was not changed. A fresh scan of all 45 tracked files found no
credential-pattern or sensitive-filename matches.

### Packaging warning follow-up

The macOS 27 deprecation notice was addressed by replacing `hdiutil convert` with
`diskutil image create from --format UDZO`, using the syntax in the installed
`diskutil(8)` manual. Shell syntax and whitespace checks passed. The replacement
command and complete packaging script then passed with ordinary-user access to
DiskManagement; there was no conversion deprecation notice. The restricted
command environment alone could not access that service. No administrator rights
or changes to macOS settings were needed.

The separate missing-search-directory linker warnings were reproduced with
Command Line Tools. Disabling XCTest/Swift Testing and supplying an xcconfig did
not remove the generated search paths; neither workaround was retained. The
installed Xcode requires licence acceptance before use and was left untouched.
The project continues to use the selected toolchain and show its diagnostics.

## Installed-release evidence

- The installed offline audio check was reported to pass 48 → 44.1 kHz stereo
  and 48 → 24 kHz mono conversion, pitch, gain and mute using synthetic audio.
- Basic playback through Bluetooth headphones was subsequently reported working
  in 1.1.2. Earlier reports confirmed playback through built-in and display speakers.
- Pause was reported to restore original playback after an earlier route failure.
- The 1.2.0 interface preview was checked in light/dark appearance, including
  scrolling, empty/onboarding/error states, independent output menus, pause,
  mute preservation and keyboard slider adjustment. See `design-qa.md`.
- The 1.2.0 UDF disk image passed image verification. Its mounted app and a copied
  bundle passed strict code-signature verification. Finder displayed the new icon.
- A later read-only check confirmed an installed 1.2.0 (5) bundle with icon bytes
  matching the packaged release. The system Apps view may retain a cached old icon.

The app is ad-hoc signed, not Developer ID signed or notarized. Packaging uses a
native Finder bookmark for Applications and a UDF image to preserve signatures.
Installers are local build outputs; this repository does not contain a release DMG.

## Remaining hardware acceptance

| Scenario | Evidence available | Still needed |
| --- | --- | --- |
| Concurrent game/browser control | Independent DSP and simulated-session tests | Real simultaneous listening |
| Settings after relaunch | Stable-identity persistence tests | Installed app/game relaunch |
| Bluetooth routing | Installed offline check and basic listening report | Routing combinations and sustained playback |
| Disconnects and headset profiles | Simulated graph lifecycle checks | Physical reconnects and microphone-mode transitions |
| Sleep/wake and output switching | Simulated teardown and rebuild checks | Physical transitions without duplicate/missing audio |
| Permission denial/revocation | Injected failure checks | User-controlled permission transitions |
| Quit/force quit | Simulated teardown checks | Real private-resource removal |
| Clean uninstall/reinstall | Scoped file and preference cleanup tests | Full installed removal, login cleanup and fresh reinstall |
| Accessibility and positioning | Native labels, keyboard controls and one display checked | Full VoiceOver, multiple displays and auto-hidden menu bars |

Do not infer complete hardware compatibility from compilation or offline checks.
`--live-audio-check` and `scripts/build-fixtures.sh` are optional developer aids;
they are not run automatically and cannot replace CrossOver/Bluetooth listening.
