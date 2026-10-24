#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
CLIENT_DIR="$REPOSITORY_ROOT/packages/ventio_native_client"

for platform in android windows; do
  if [[ -e "$CLIENT_DIR/$platform" ]]; then
    echo "Refusing to regenerate existing platform folder: $CLIENT_DIR/$platform" >&2
    echo "Preserve or back it up before generating fresh runners." >&2
    exit 1
  fi
done

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
