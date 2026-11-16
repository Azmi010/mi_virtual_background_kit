#!/usr/bin/env bash
# T15.4: host-only version-bound check for the LiveKit adapter.
# Pins livekit_client to the lower and upper supported versions, then runs
# analyze + unit tests for both workspace packages. Restores the pubspec on exit.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pubspec="$repo_root/livekit/pubspec.yaml"
backup="$(mktemp)"
cp "$pubspec" "$backup"

restore() {
  cp "$backup" "$pubspec"
  rm -f "$backup"
  (cd "$repo_root" && flutter pub get >/dev/null)
}
trap restore EXIT

for version in 2.13.1 2.13.2; do
  echo "=== livekit_client $version ==="
  sed -i '' "s|livekit_client: '>=2.13.1 <2.14.0'|livekit_client: '$version'|" "$pubspec"
  (
    cd "$repo_root"
    flutter pub get
    flutter analyze
    flutter test
  )
  (
    cd "$repo_root/livekit"
    flutter analyze
    flutter test
  )
done
