# Volume Mixer verification

The packaged release is **1.2.0 (5)**, a local Apple Silicon build for macOS 27.
This repository also includes a source cleanup performed after that package was
built. The cleanup removes unused bridge callback counters, session signature
fields, unused row peak telemetry and an unused shutdown option. Gain processing,
resampling, routing and error-recovery behavior are unchanged by the cleanup.

## Automated checks

Run `scripts/test.sh` with Apple's Command Line Tools and the macOS 27 SDK.
The suite covers 42 scenarios:

- Gain, attenuation, mute/unmute ramps, channel mapping and input exclusion.
- Bounded audio queues, variable callback sizes, ring wraps and concurrent ordering.
- App/helper and Wine identity, separate bottles and PID reuse.
- Saved levels and routes, isolated preference cleanup and symlink-safe file cleanup.
- Independent sessions, explicit output routing, disconnected devices, sleep/wake,
  pause/shutdown and latched failure recovery using simulated hardware.
- Apple-engine offline conversion, mono/anti-alias behavior, independent gain/mute
  and a ten-minute simulated clock-drift run when Audio Units are available.

The last packaged-release run had **38 passes, 4 skips and no failed assertions**.
The repository cleanup was rechecked on 7 October 2026 with the same result;
its release build and strict ad-hoc signature verification also passed.
The four skips were the Apple-engine scenarios: the command environment could not
resolve the required Audio Units. These skips are not successful playback tests.
The unavailable-component failure path did pass. The earlier audio-engine suite
also ran under AddressSanitizer without reported memory errors in executed tests.

Tests use in-memory preferences and disposable files under `work/`; they do not
capture or play hardware audio or change macOS settings. Build and test logs are
local artifacts and are not committed.

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
