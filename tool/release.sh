#!/usr/bin/env bash
# release.sh X.Y.Z - cut a flutter_fbdev release.
#
# Bumps the version in pubspec.yaml and the mirrored lib/src/version.dart, runs
# the full verification, commits, tags vX.Y.Z, and pushes. Pushing the tag fires
# .github/workflows/publish.yml, which publishes to pub.dev via automated
# publishing (a one-time setup on the pub.dev admin page).
#
# The FIRST publish of the package must be done manually instead:
#   flutter pub publish        # interactive pub.dev login required
# then enable Automated publishing on pub.dev and use this script thereafter.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

V="${1:?usage: tool/release.sh X.Y.Z}"
echo "$V" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$' || {
  echo "bad version '$V' (want X.Y.Z)" >&2
  exit 2
}
[ -z "$(git status --porcelain)" ] || {
  echo "working tree not clean - commit or stash first" >&2
  exit 1
}

echo "› bumping to $V"
perl -i -pe "s/^version:.*/version: $V/" pubspec.yaml
perl -i -pe "s/const String flutterFbdevVersion = '.*';/const String flutterFbdevVersion = '$V';/" lib/src/version.dart

echo "› verifying"
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test
# (No local `pub publish --dry-run` here: it would flag the just-bumped, not-yet-
# committed files as a warning and abort. The publish workflow validates on CI.)

echo "› committing + tagging v$V"
git add pubspec.yaml lib/src/version.dart CHANGELOG.md
git commit -m "Release $V"
git tag "v$V"
git push origin HEAD "v$V"
echo "✓ pushed v$V - watch the Publish workflow under GitHub Actions"
