import 'dart:io';

import 'package:flutter_fbdev/flutter_fbdev.dart';
import 'package:flutter_test/flutter_test.dart';

/// Guards that [flutterFbdevVersion] stays in sync with `pubspec.yaml`, so the
/// version shown in an app (and in screenshots) is always the real one.
void main() {
  test('flutterFbdevVersion matches pubspec.yaml', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final match = RegExp(
      r'^version:\s*(\S+)',
      multiLine: true,
    ).firstMatch(pubspec);
    expect(match, isNotNull, reason: 'no version: in pubspec.yaml');
    expect(flutterFbdevVersion, match!.group(1));
  });
}
