## 0.1.0

Initial release.

- Software-rendered `/dev/fb0` Flutter embedder (`native/flutter_fbdev_embedder.c`)
  for no-DRM Allwinner/Mali-fbdev handhelds where flutter-pi can't run.
- `HandheldInput` - focus-independent gamepad input over the
  `flutter_fbdev/input` platform channel, mapped from raw evdev to
  `HandheldButton`s via a `HandheldProfile` (RG34XXSP profile bundled).
- Analog sticks via `HandheldInput.sticks` - both stick axes, self-calibrating
  to a normalized `-1.0 .. 1.0` (RG34XXSP axes bundled).
- Audio: `FbdevAudio.play/stop/setVolume` plays a bundled Ogg Vorbis file looped
  through the embedder (decoded with stb_vorbis, output via ALSA loaded at
  runtime). Gives sound on no-DRM handhelds where the usual Flutter audio plugins
  don't run; a silent no-op elsewhere.
- `HandheldInputOverlay` - on-screen flash/bounce of the pressed button for
  mapping any device by eye.
- `isFbdevHandheld` / `fbdevTryStep` platform helpers.
- Tooling: `native/build_embedder.sh` (zig or Docker cross-compile),
  `tool/deploy_samba.sh` (timeout-capped, verified Samba deploy).
- Example app.
