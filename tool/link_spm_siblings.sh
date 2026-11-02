#!/usr/bin/env bash
# Create sibling symlinks under ios/ that Package.swift path deps expect.
#
# ios/mi_virtual_background_kit/Package.swift declares:
#   .package(path: "../flutter_webrtc-<version>")
#   .package(path: "../FlutterFramework")
# which resolve to ios/flutter_webrtc-<version> and ios/FlutterFramework.
# Locally these are gitignored symlinks into the example's ephemeral SPM
# packages; CI must recreate them after `flutter pub get` or xcodebuild fails:
#   "the package at '.../ios/flutter_webrtc-...' cannot be accessed".
#
# Usage: tool/link_spm_siblings.sh   (run after flutter pub get in example/)
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
packages="$repo_root/example/ios/Flutter/ephemeral/Packages/.packages"

if [[ ! -d "$packages" ]]; then
  echo "error: $packages not found — run 'flutter pub get' in example/ first" >&2
  exit 1
fi

link_sibling() {
  local name="$1"
  local target="$packages/$name"
  local link="$repo_root/ios/$name"

  if [[ ! -e "$target" ]]; then
    echo "error: SPM package not found: $target" >&2
    exit 1
  fi

  rm -f "$link"
  ln -s "../example/ios/Flutter/ephemeral/Packages/.packages/$name" "$link"
  echo "ios/$name -> example/.../.packages/$name"
}

link_sibling "FlutterFramework"

# flutter_webrtc folder name includes the resolved version (e.g. 1.6.2+hotfix.4).
found=0
for d in "$packages"/flutter_webrtc-*; do
  [[ -e "$d" ]] || continue
  link_sibling "$(basename "$d")"
  found=1
done
if [[ "$found" -ne 1 ]]; then
  echo "error: no flutter_webrtc-* package under $packages" >&2
  exit 1
fi
