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
