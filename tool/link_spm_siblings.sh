#!/usr/bin/env bash
# Create sibling symlinks under ios/ that Package.swift path deps expect.
#
# ios/mi_virtual_background_kit/Package.swift declares:
#   .package(name: "flutter_webrtc", path: "../flutter_webrtc")
#   .package(name: "FlutterFramework", path: "../FlutterFramework")
# which resolve to ios/flutter_webrtc and ios/FlutterFramework.
#
# Those paths only exist when SwiftPM reads the plugin manifest through the
# ephemeral .packages symlinks (where all plugins are siblings). Some Xcode
# versions on CI (26.6 runner) canonicalize the symlink to the real
# <repo>/ios/mi_virtual_background_kit first, so "../..." resolves against
# ios/ and fails:
#   "the package at '.../ios/flutter_webrtc' cannot be accessed".
# Recreating the same names under ios/ makes both resolutions work.
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

link_sibling "flutter_webrtc"
link_sibling "FlutterFramework"
