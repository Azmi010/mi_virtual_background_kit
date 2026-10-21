#!/usr/bin/env bash
# Point example/build at a directory outside the plugin repository.
#
# Flutter's Swift Package Manager integration copies the whole plugin package
# root into example/build/ios/SourcePackages/ with rsync. Because the example
# app lives inside the package root, that copy is recursive: example/build ends
# up inside the copy source and grows without bound.
#
# Upstream fixed this by excluding the example directory from the copy
# (flutter/flutter#188647, shipped in Flutter 3.48). Until then, making
# example/build a symlink to a directory outside the repository keeps the copy
# finite, because rsync copies symlinks as symlinks.
#
# Usage: tool/link_example_build.sh [target-dir]
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
target="${1:-${XDG_CACHE_HOME:-$HOME/.cache}/mivbg-build/example}"

link="$repo_root/example/build"

if [[ -L "$link" ]]; then
  current="$(readlink "$link")"
  if [[ "$current" == "$target" ]]; then
    echo "example/build already linked to $target"
    exit 0
  fi
  rm "$link"
elif [[ -e "$link" ]]; then
  echo "Removing existing $link (build artifacts)"
  rm -rf "$link"
fi

mkdir -p "$target"
ln -s "$target" "$link"
echo "example/build -> $target"
