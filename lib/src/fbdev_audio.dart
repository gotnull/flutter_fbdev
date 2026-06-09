import 'package:flutter/services.dart';

/// Plays a bundled audio file through the framebuffer embedder.
///
/// The embedder decodes the file (Ogg Vorbis) and plays it looped via ALSA. This
/// is the audio path on the no-DRM handheld, where the usual Flutter audio
/// plugins (which need GStreamer/GPU stacks) aren't wired up. It is a no-op
/// anywhere the embedder isn't present (desktop, mobile) - use a normal audio
/// plugin there, gated on [isFbdevHandheld].
///
/// The path is resolved relative to the app bundle directory, which for a
/// `flutterpi_tool` bundle is the same string you declare as a Flutter asset
/// (e.g. `assets/audio/track.ogg`).
class FbdevAudio {
  FbdevAudio._();

  static const BasicMessageChannel<String?> _channel =
      BasicMessageChannel<String?>('flutter_fbdev/audio', StringCodec());

  /// Start (or restart) looped playback of [bundleRelativePath]. Safe to call
  /// unconditionally; it does nothing without the embedder.
  static Future<void> play(String bundleRelativePath) async {
    await _channel.send('play:$bundleRelativePath');
  }

  /// Stop playback.
  static Future<void> stop() async {
    await _channel.send('stop');
  }

  /// Set playback volume, `0.0`..`1.0`.
  static Future<void> setVolume(double volume) async {
    final pct = (volume.clamp(0.0, 1.0) * 100).round();
    await _channel.send('volume:$pct');
  }
}
