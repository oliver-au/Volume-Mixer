#!/bin/bash
set -euo pipefail
project_dir="$(cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$project_dir"
mkdir -p work dist
package_dir="$(mktemp -d "$project_dir/work/package.XXXXXX")"
trap 'rm -rf -- "$package_dir"' EXIT
scripts/build.sh release "$package_dir"
stage_dir="$package_dir/dmg-stage"
mkdir -p "$stage_dir"
ditto "$package_dir/Volume Mixer.app" "$stage_dir/Volume Mixer.app"
installation_folder="$HOME/Applications"
# A personal update should target the user's existing copy, avoiding two versions
# in the two Applications folders. Fresh installs still use the user folder.
if [ -d '/Applications/Volume Mixer.app' ] && [ ! -d "$HOME/Applications/Volume Mixer.app" ]; then
    installation_folder='/Applications'
fi
if [ ! -d "$installation_folder" ]; then installation_folder='/Applications'; fi
CLANG_MODULE_CACHE_PATH="$project_dir/.build/module-cache" xcrun swift scripts/make-applications-alias.swift "$installation_folder" "$stage_dir/Applications"
cp Resources/Install.txt "$stage_dir/Read me.txt"
candidate="$package_dir/Volume Mixer.candidate.dmg"
hybrid="$package_dir/Volume Mixer.udf.iso"
# Build UDF in user space: the HFS+ hybrid writer adds empty FinderInfo attributes
# to signed bundle files, causing strict signature verification to fail on mount.
# This does not attach a disk or require an administrator/device-service request.
installer_version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
hdiutil makehybrid -udf -udf-volume-name "Volume Mixer $installer_version" -o "$hybrid" "$stage_dir"
diskutil image create from --format UDZO "$hybrid" "$candidate"
hdiutil verify "$candidate"
# Publish only a complete, verified image. An earlier image may still be mounted.
mv -f -- "$candidate" 'dist/Volume Mixer.dmg'
rm -rf -- 'dist/Volume Mixer.app'
mv -- "$package_dir/Volume Mixer.app" 'dist/Volume Mixer.app'
codesign --verify --strict 'dist/Volume Mixer.app'
shasum -a 256 'dist/Volume Mixer.dmg' > 'dist/Volume Mixer.dmg.sha256'
ditto 'dist/Volume Mixer.dmg' "dist/Volume Mixer $installer_version.dmg"
shasum -a 256 "dist/Volume Mixer $installer_version.dmg" > "dist/Volume Mixer $installer_version.dmg.sha256"
printf '\nCreated:\n  %s\n  %s\n' "$project_dir/dist/Volume Mixer.app" "$project_dir/dist/Volume Mixer.dmg"
