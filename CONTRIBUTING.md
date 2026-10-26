# Contributing

Thanks for considering a contribution.

## Getting started

1. Fork the repo and create a branch from `main`.
2. Run `flutter pub get`.
3. Make your change.
4. Verify before opening a PR:
   - `flutter analyze`
   - `dart format --set-exit-if-changed .`
   - `flutter test`

## Pull requests

- Keep PRs focused: one change per PR.
- Fill in the PR template.
- Link the related issue.
- CI must pass before review.

## Issues

- Use the bug report or feature request template.
- For bugs, include device, OS, `flutter_webrtc` version, and logs.

## Code style

- Follow the existing structure: public API in `lib/`, implementation in `lib/src/`.
- No comments unless the *why* is not obvious from the code.
- All processing stays on-device: no network calls, no telemetry.

## License

By contributing, you agree that your contributions are licensed under the MIT License.
