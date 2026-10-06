#!/bin/bash
set -euo pipefail
project_dir="$(cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$project_dir"
mkdir -p .build/module-cache .build/cache .build/config .build/security
export CLANG_MODULE_CACHE_PATH="$project_dir/.build/module-cache"
# This native test executable runs with Command Line Tools alone (XCTest requires full Xcode).
xcrun swift run --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security MixerChecks
