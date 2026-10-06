#!/bin/bash
set -euo pipefail
project_dir="$(cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$project_dir"
configuration="${1:-release}"
case "$configuration" in debug|release) ;; *) echo 'Usage: scripts/build.sh [debug|release]' >&2; exit 2;; esac
mkdir -p .build/module-cache .build/cache .build/config .build/security dist
export CLANG_MODULE_CACHE_PATH="$project_dir/.build/module-cache"
mkdir -p work
xcrun swift scripts/make-icon.swift work/AppIcon.iconset
cp work/AppIcon.icns Resources/AppIcon.icns
build_args=(--disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security)
# Release artifacts do not need a dSYM. Avoid invoking the SDK's debug-symbol
# service, allowing an ordinary local build without any elevated access.
if [ "$configuration" = release ]; then build_args+=(-debug-info-format none); fi
xcrun swift build "${build_args[@]}" -c "$configuration" --product VolumeMixer
binary_dir="$(xcrun swift build "${build_args[@]}" -c "$configuration" --show-bin-path)"
output_dir="${2:-$project_dir/dist}"
mkdir -p "$output_dir"
stage_dir="$(mktemp -d "$project_dir/work/build.XXXXXX")"
trap 'rm -rf -- "$stage_dir"' EXIT
app_dir="$stage_dir/Volume Mixer.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary_dir/VolumeMixer" "$app_dir/Contents/MacOS/VolumeMixer"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$app_dir/Contents/Resources/AppIcon.icns"; fi
cp Resources/MenuBarIcon.png Resources/MenuBarIcon@2x.png Resources/MenuBarIcon@3x.png "$app_dir/Contents/Resources/"
codesign --force --sign - --identifier local.oliver.VolumeMixer "$app_dir"
codesign --verify --strict --verbose=2 "$app_dir"
# Publish a fresh bundle so old resource files cannot leak into a new build.
rm -rf -- "$output_dir/Volume Mixer.app"
mv -- "$app_dir" "$output_dir/Volume Mixer.app"
echo "$output_dir/Volume Mixer.app"
