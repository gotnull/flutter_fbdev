# Contributing

Thanks for your interest in flutter_fbdev. Issues and pull requests are welcome.

## Getting started

1. Fork and clone the repo.
2. Create a branch: `git checkout -b my-change`.
3. Make your change and keep the checks below green.
4. Open a pull request describing what changed and why.

## Before you submit

Run the same checks CI runs:

```bash
flutter pub get
dart format .
flutter analyze
flutter test
```

PRs must be formatted (`dart format`), analyze clean, and pass the tests.

## Scope notes

- The Dart input layer (`lib/`) has unit tests; please add tests for new mapping
  or parsing logic. Feed events through the `flutter_fbdev/input` channel the way
  the tests already do, so no device is required.
- The native embedder (`native/`) is plain C against the Flutter embedder ABI.
  Keep it small and device-agnostic; device-specific mapping belongs in Dart
  (`HandheldProfile`).
- New device profiles are very welcome. Capture the codes with the
  `HandheldInputOverlay`, then add a `HandheldProfile` constant.

## Style

Match the surrounding code and let `dart format` decide layout.

## Releasing (maintainers)

Releases publish on a version **tag**, never on a plain push (CI only
lints/tests pushes). The very first publish of the package is manual:

```bash
flutter pub publish   # interactive pub.dev login; creates the package
```

Then enable **Automated publishing** on the pub.dev package admin page (GitHub
Actions, repo `gotnull/flutter_fbdev`, tag pattern `v{{version}}`). Every release
after that is just:

```bash
tool/release.sh X.Y.Z   # bumps pubspec + version.dart, verifies, tags vX.Y.Z, pushes
```

Pushing the tag triggers `.github/workflows/publish.yml`, which publishes via
pub.dev's OIDC automated publishing (no stored tokens). `flutterFbdevVersion`
mirrors the pubspec version, and a test guards against drift.
