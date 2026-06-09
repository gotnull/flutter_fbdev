import 'dart:async';

import 'package:flutter/foundation.dart';

/// True when running on a no-DRM framebuffer handheld via the `flutter_fbdev`
/// embedder (the engine reports the Linux target). Gate handheld code paths on
/// this: button input, landscape layout, silent audio, skipping touch menus, etc.
bool get isFbdevHandheld =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.linux;

/// Runs [step], swallowing any error so a platform service that's unavailable on
/// the minimal embedder (shared_preferences, audio, haptics, Game Center, …)
/// can't abort startup. Wrap each risky bootstrap call. Returns true on success.
///
/// ```dart
/// await fbdevTryStep(() => settings.load());
/// await fbdevTryStep(() => progress.load());
/// ```
Future<bool> fbdevTryStep(FutureOr<void> Function() step) async {
  try {
    await step();
    return true;
  } catch (_) {
    return false;
  }
}
