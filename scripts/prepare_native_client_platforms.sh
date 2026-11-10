#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
CLIENT_DIR="$REPOSITORY_ROOT/packages/ventio_native_client"

if [[ -d "$CLIENT_DIR/android" && -d "$CLIENT_DIR/windows" ]]; then
  for file in android/app/src/main/AndroidManifest.xml android/app/build.gradle.kts windows/CMakeLists.txt windows/runner/main.cpp; do
    [[ -f "$CLIENT_DIR/$file" ]] || { echo "Existing native runner is incomplete: $file" >&2; exit 1; }
  done
  grep -q 'android.permission.INTERNET' "$CLIENT_DIR/android/app/src/main/AndroidManifest.xml" || {
    echo 'Existing Android runner lacks the required INTERNET permission.' >&2
    exit 1
  }
  echo 'Using the reviewed Android and Windows platform runners already present in the checkout.'
  exit 0
fi
if [[ -e "$CLIENT_DIR/android" || -e "$CLIENT_DIR/windows" ]]; then
  echo 'Native runner checkout is incomplete; refusing to overwrite the existing platform folder.' >&2
  exit 1
fi

cd "$CLIENT_DIR"
flutter config --enable-windows-desktop
flutter create \
  --empty \
  --no-pub \
  --platforms=android,windows \
  --project-name=ventio_native_client \
  --org=com.ventio \
  .

python3 - <<'PY'
import re
from pathlib import Path

manifest = Path('android/app/src/main/AndroidManifest.xml')
text = manifest.read_text(encoding='utf-8')
permission = '    <uses-permission android:name="android.permission.INTERNET" />'
if permission not in text:
    text = text.replace(
        '<application',
        permission + '\n    <application',
        1,
    )
label, count = re.subn(
    r'(<application\b[^>]*\bandroid:label=")[^"]*(")',
    r'\1Ventio Framework\2',
    text,
    count=1,
)
if count != 1:
    raise SystemExit('Generated Android manifest has no application label to set.')
manifest.write_text(label, encoding='utf-8')
PY
