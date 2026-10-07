#!/bin/bash
set -euo pipefail
project_dir="$(cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$project_dir"
mkdir -p .build/module-cache .build/cache .build/config .build/security
export CLANG_MODULE_CACHE_PATH="$project_dir/.build/module-cache"
# This native test executable runs with Command Line Tools alone (XCTest requires full Xcode).
xcrun swift run --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security MixerChecks

# Compile the production slider and termination helper directly into an isolated
# AppKit check executable; no UI windows, app preferences or audio are opened.
xcrun swiftc -module-cache-path .build/module-cache \
    Sources/VolumeMixer/VolumeSlider.swift Sources/VolumeMixer/ApplicationTermination.swift \
    Tests/AppKitChecks/main.swift -o .build/AppKitChecks
.build/AppKitChecks
