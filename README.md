# Volume Mixer

A native macOS menu bar mixer with independent app volume, mute, per-app output
selection, saved settings, and a clean uninstall action. Personal Apple Silicon
build for macOS 27. Current build: **1.2.0 (5)**.

Version 1.2.0 adds an arrowless native glass menu panel, compact rows, a cobalt
fader app icon and a matching monochrome menu-bar symbol. It uses the buffered playback engine introduced in 1.1.2. Basic Bluetooth
playback has been reported working; reconnects, headset profile changes and
sustained playback remain separate acceptance checks. See `VERIFICATION.md`.

## Install and use

Build the installer with `scripts/package.sh`, then open
`dist/Volume Mixer.dmg`, drag **Volume Mixer** into the Applications folder
provided, and launch the installed app. Click its menu bar fader icon, choose
**Enable app control** (or **Resume control** on an existing installation), and adjust a playing app. Allow **System Audio Recording**
when macOS prompts. This permission enables audio processing; no audio is saved
or uploaded. The app does not capture microphone input.

- Sliders run from 0–100%; new apps start at 100%.
- Mute retains the slider's saved value. Moving a muted slider above zero unmutes it.
- **Play through** chooses the output independently for each app. **System output**
  uses the Mac's current output while adjusting volume; choosing a named device remembers that device
  across reconnects and app restarts. This does not change macOS's default output.
- **Pause control** and **Quit** restore the app's original volume and output. They are not
  “mute all” controls.
- If a selected device disconnects, the app's original playback returns and the
  row shows an error. Reconnect the device to resume the saved route, or select
  **System output**. Unsupported formats also restore original playback.
- Apps playing audio appear automatically; recently active rows remain for 60 seconds.
- Unknown CrossOver/Wine processes have temporary rows. Stable executable/bottle
  identities retain volumes and output choices without relying on recycled PIDs.
- This build is locally ad-hoc signed, not notarized for public distribution.

## Uninstall

Use **Settings → Uninstall Volume Mixer…**. The app restores normal playback,
unregisters its optional login item, removes its own preferences and allowlisted
cache/support directories, moves itself to Trash, and exits. Cleanup failures
are reported. Empty Trash yourself when ready.

The downloaded DMG and this source folder are deliberately preserved. macOS may
retain system-managed privacy/history entries. No driver, system extension,
privileged helper, daemon, analytics, or network service is installed.

## Build and test

Requires Apple's Command Line Tools with the macOS 27 SDK. No external packages.

```sh
scripts/test.sh
scripts/build.sh debug
scripts/package.sh
```

The icon source is `Resources/Artwork/AppIcon.png`; the build resizes it into all
standard and Retina ICNS representations. No external icon service is required.

Quit the running mixer before replacing a build. `scripts/test.sh` uses a native
test executable, so full Xcode/XCTest is not required. The checks cover sample
processing, channel layouts, gain ramps, process identity, settings, and scoped
cleanup. Real device compatibility still requires the live tests in
`VERIFICATION.md`.

Packaging builds a UDF image in user space and compresses it without mounting
the image or asking for administrator access. The app and installer are published
together under `dist/`. Automated preference tests use memory, not your macOS
preferences, and cleanup tests use disposable project-local files.

Read-only diagnostics are available from the built executable with `--diagnose`
(output device and audio app identities) and `--self-check` (packaged preferences).
`--quit-running` requests a normal quit from the existing instance.

## Audio architecture

SwiftUI/AppKit presents state from a serial Core Audio control queue. Untouched
100% apps without an explicit route use their original playback path, including
apps bound to a different device. Adjusted apps use a private inclusive stereo
process tap (`mutedWhenTapped`). Explicit routes remain active at 100%.

Matching-rate streams use a private aggregate with the chosen output, tap drift
compensation, and a C callback applying an 8 ms gain ramp. Physical microphone
streams are disabled. Mismatched rates, such as 48 kHz game audio and 44.1 kHz Sony
playback, use a tap-only capture aggregate, a fixed-capacity single-producer /
single-consumer C buffer, and a separate AVAudioEngine. Its output Audio Unit is
bound to the selected device; its mixer converts sample rates. No physical device
rate or default-output property is written. The engine's input node is never used.

The C queue accepts independently sized capture/playback buffers and applies
atomic gains with mono/stereo mapping. A small, bounded Varispeed correction
(maximum ±0.2%) on the control queue compensates slow clock drift. Startup buffering
is at least 2048 input frames and increases for larger render requests; Bluetooth
and framework latency are additional. This path's total latency is not yet measured.
No allocations, locks, logging or file access occur in the application's audio
callbacks.

Layout faults, stopped output, repeated starvation and overflow stop the graph
and restore the original playback path. Errors stay latched until a user retry or
a real route/process/device change, avoiding repeated ten-second interruptions.
Output/profile changes, sleep/wake and audio-service restarts rebuild graphs.
Destinations persist by UID, and app preferences never rely only on recycled PIDs.

## Offline audio check

With control paused, **gear → Check audio engine…** runs synthetic 48 → 44.1 kHz
stereo and 48 → 24 kHz mono audio through the same buffered Apple graph. It checks
pitch, amplitude, channels and mute without capturing or playing hardware audio,
recording files, or changing settings. This gives the installed app a way to test
framework components unavailable in the command environment. A pass establishes
only offline conversion; real Bluetooth playback, reconnects and sustained
listening still require verification.

App discovery groups helpers by owning application. CrossOver identities use
executable/bottle metadata only when available, otherwise process lifetime keys.
The app has no remote-control API and never inspects browser tab contents.

## Interface preview

`--preview-panel` runs the real interface with fake audio sessions and in-memory
preferences. It never enumerates hardware or captures/plays audio. Login, privacy
settings, uninstall and the audio probe are disabled in this mode. Optional flags
are `--preview-light`, `--preview-long`, `--preview-empty`, `--preview-welcome`,
`--preview-paused`, and `--preview-error`. Use a separately identified preview
bundle when the installed app is running; see `scripts/preview.sh`.

The normal app follows macOS appearance and accessibility preferences. Its
340-point panel anchors four points below the status item, stays within the active
display, and measures content before choosing a scroll height. Escape and outside
clicks dismiss it. Clicking a volume slider gives it keyboard focus: arrows adjust
by one percent, Shift–arrow by ten percent, without changing system settings.

## Repository contents

Only source, tests, build scripts, documentation and the original icon artwork
are versioned. Builds regenerate the ICNS and menu-icon PNGs. `dist/`, `work/`,
build caches, local logs, screenshots, backups and signing credentials are ignored.
No installer binary or developer-machine configuration is required in Git.
