#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
CLIENT_DIR="$REPOSITORY_ROOT/packages/ventio_native_client"

cd "$CLIENT_DIR"
flutter config --enable-windows-desktop
flutter create \
  --empty \
  --no-pub \
  --platforms=android,windows \
  --project-name=ventio_native_client \
  --org=com.ventio \
  .
