#!/usr/bin/env bash
# T15.6: verify the adapter as a dependency in a clean Flutter app.
#
# Usage:
#   tool/livekit_depcheck.sh path
#   tool/livekit_depcheck.sh git <commit-sha>
#
# `path` checks local development resolution. `git` is the acceptance check:
# it resolves the adapter from the GitHub repo (subfolder livekit/) and
# verifies that no path points back to this working copy.
set -euo pipefail

mode="${1:-}"
ref="${2:-HEAD}"
if [[ "$mode" != "path" && "$mode" != "git" ]]; then
  echo "usage: $0 path | git <commit-sha>" >&2
  exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo_url="https://github.com/Azmi010/mi_virtual_background_kit.git"
tmp_root="/private/var/folders/w2/yh4js5w12tg7f27108cq9z1r0000gn/T/opencode"
mkdir -p "$tmp_root"
work="$(mktemp -d "$tmp_root/livekit-depcheck.XXXXXX")"
app="$work/app"

flutter create --template=app --platforms=android,ios \
  --project-name livekit_depcheck "$app" >/dev/null

if [[ "$mode" == "git" ]]; then
  adapter_dep="    git:
      url: $repo_url
      path: livekit
      ref: $ref"
  core_override="    git:
      url: $repo_url
      ref: $ref"
else
  adapter_dep="    path: $repo_root/livekit"
  core_override="    path: $repo_root"
fi

cat >"$app/pubspec.yaml" <<EOF
name: livekit_depcheck
description: Clean consumer for the LiveKit adapter.
publish_to: none
environment:
  sdk: ^3.6.0

dependencies:
  flutter:
    sdk: flutter
  livekit_client: '>=2.13.1 <2.14.0'
  mi_virtual_background_kit_livekit:
$adapter_dep

dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^6.0.0

# The adapter declares core as hosted ^0.2.0; 0.2.0 is not published yet.
dependency_overrides:
  mi_virtual_background_kit:
$core_override
EOF

rm -f "$app/test/widget_test.dart"

cat >"$app/lib/main.dart" <<'EOF'
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:mi_virtual_background_kit_livekit/mi_virtual_background_kit_livekit.dart';

void main() => runApp(const DepcheckApp());

class DepcheckApp extends StatelessWidget {
  const DepcheckApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        home: Scaffold(
          body: Center(
            child: Text(
              'adapter ready: ${LiveKitVirtualBackground().runtimeType}',
            ),
          ),
        ),
      );
}
EOF

cd "$app"
flutter pub get
flutter analyze
flutter build apk --debug

if [[ "$mode" == "git" ]]; then
  if grep -F "$repo_root" .dart_tool/package_config.json >/dev/null; then
    echo "FAIL: package_config.json still points to the local working copy" >&2
    exit 1
  fi
  echo "OK: no reference to $repo_root in package_config.json"
fi

echo "clean app: $app"
echo "run on device: cd $app && flutter run -d DEVICE_ID"
