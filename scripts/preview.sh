#!/bin/bash
set -euo pipefail
project_dir="$(cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$project_dir"
for preview_option in "$@"; do
    case "$preview_option" in light|long|empty|welcome|paused|error) ;;
        *) echo 'Options: light long empty welcome paused error' >&2; exit 2;;
    esac
done
scripts/build.sh release "$project_dir/work/ui-build"
preview_dir="$project_dir/work/preview/Volume Mixer Preview.app"
mkdir -p "$project_dir/work/preview"
ditto 'work/ui-build/Volume Mixer.app' "$preview_dir"
python3 - "$preview_dir/Contents/Info.plist" "$@" <<'PY'
import plistlib, sys
from pathlib import Path
path = Path(sys.argv[1])
with path.open('rb') as stream:
    info = plistlib.load(stream)
info.update(CFBundleIdentifier='local.oliver.VolumeMixer.Preview',
            CFBundleName='Volume Mixer Preview', CFBundleDisplayName='Volume Mixer Preview',
            VolumeMixerPreview=True, VolumeMixerPreviewOptions=sys.argv[2:])
with path.open('wb') as stream:
    plistlib.dump(info, stream)
PY
codesign --force --sign - --identifier local.oliver.VolumeMixer.Preview "$preview_dir"
codesign --verify --strict "$preview_dir"
echo "Preview ready: $preview_dir"
echo 'Quit a previous preview before opening this one. It uses no audio hardware or saved settings.'
