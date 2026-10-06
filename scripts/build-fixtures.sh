#!/bin/bash
set -euo pipefail
project_dir="$(cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$project_dir"
export CLANG_MODULE_CACHE_PATH="$project_dir/.build/module-cache"
build_args=(--disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security)
xcrun swift build "${build_args[@]}" --product AudioFixture
binary_dir="$(xcrun swift build "${build_args[@]}" --show-bin-path)"
for fixture in A B; do
  app_dir="$project_dir/work/fixtures/Mixer Test $fixture.app"
  mkdir -p "$app_dir/Contents/MacOS"
  cp "$binary_dir/AudioFixture" "$app_dir/Contents/MacOS/AudioFixture"
  cat > "$app_dir/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.oliver.VolumeMixer.Fixture.$fixture</string>
<key>CFBundleName</key><string>Mixer Test $fixture</string>
<key>CFBundleExecutable</key><string>AudioFixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
  codesign --force --sign - "$app_dir"
done
