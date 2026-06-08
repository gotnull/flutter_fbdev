# flutter_fbdev

[![CI](https://github.com/gotnull/flutter_fbdev/actions/workflows/ci.yml/badge.svg)](https://github.com/gotnull/flutter_fbdev/actions/workflows/ci.yml)
[![pub package](https://img.shields.io/pub/v/flutter_fbdev.svg)](https://pub.dev/packages/flutter_fbdev)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**Run Flutter on no-DRM framebuffer handhelds, and map their gamepad.**

A growing class of cheap ARM Linux handhelds (Anbernic RG34XXSP, RG35XX, and other
Allwinner H700 / Mali-fbdev devices) have **no DRM/KMS** - no `/dev/dri`, no
`libdrm`/`libgbm`. The standard embedded Flutter runtime,
[flutter-pi](https://github.com/ardera/flutter-pi), is DRM/KMS-only and **cannot
run** on them. `flutter_fbdev` fills that gap:

- a tiny **software-rendered `/dev/fb0` embedder** (≈300 lines of C) that renders
  any Flutter app straight to the framebuffer - the surface these devices already
  use for everything;
- **gamepad input over a platform channel** (focus-independent - injected key
  events don't get delivered on a framebuffer embedder), mapped from raw evdev to
  logical buttons in Dart;
- an **on-screen button-mapping overlay** to identify any device's controls by eye;
- **build + deploy tooling** (cross-compile with `zig`, deploy over Samba).

> Born from porting the puzzle game [FOLD](https://github.com/gotnull/fold) to an
> Anbernic RG34XXSP. It renders, it's the right colours, the d-pad and A/B work.

## Why a framebuffer embedder?

| | flutter-pi | flutter_fbdev |
|---|---|---|
| Output | DRM/KMS + GBM + GLES | `/dev/fb0` (software / Skia CPU) |
| Needs `/dev/dri`, libdrm/gbm | **yes** | **no** |
| Runs on Mali-fbdev H700 handhelds | ✗ | ✓ |
| GPU-accelerated | ✓ | ✗ (CPU rasteriser) |

Software rendering is the trade-off - fine for 2D/UI-heavy apps at modest
resolution (e.g. 720×480), not for heavy 3D. If your device *does* expose DRM/KMS,
use flutter-pi instead.

## What's in the box

```
lib/                 Dart: HandheldInput, HandheldInputOverlay, isFbdevHandheld
native/
  flutter_fbdev_embedder.c   the framebuffer embedder
  flutter_embedder.h         the Flutter embedder API header
  build_embedder.sh          cross-compile (zig, or Docker fallback)
tool/
  deploy_samba.sh            copy the bundle to the device over Samba
example/             a minimal handheld app
```

## Quick start

### 1. Add the Dart package

```yaml
dependencies:
  flutter_fbdev: ^0.1.0
```

### 2. Wire up input

```dart
import 'package:flutter_fbdev/flutter_fbdev.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  HandheldInput.instance.start();            // receive gamepad input
  HandheldInput.instance.addListener((e) {   // logical button events
    if (!e.pressed) return;
    switch (e.button) {
      case HandheldButton.dpadLeft:  /* … */
      case HandheldButton.a:         /* … */
      default: break;
    }
  });
  runApp(const MyApp());
}
```

Drop the mapping overlay on top of any screen (inert on touch devices):

```dart
Stack(children: [ const MyGame(), const HandheldInputOverlay() ])
```

`isFbdevHandheld` switches on handheld code paths (button input, landscape,
silent audio, skipping touch menus). `fbdevTryStep(...)` wraps risky bootstrap
calls so a plugin that's missing on the embedder can't abort startup.

### 3. Build the flutter-pi bundle (AOT, arm64)

```bash
dart pub global activate flutterpi_tool
flutterpi_tool build --arch arm64 --cpu pi3 --release   # pi3 = Cortex-A53, fits H700
# → build/flutter-pi/pi3-64/   (app.so, icudtl.dat, libflutter_engine.so, assets)
```

### 4. Build the embedder into the bundle

```bash
brew install zig   # one-time (or rely on the Docker fallback)
.../flutter_fbdev/native/build_embedder.sh build/flutter-pi/pi3-64
# → build/flutter-pi/pi3-64/flutter_fbdev  (aarch64 ELF, self-contained)
```

### 5. Deploy + run on the device

```bash
FBDEV_IP=192.168.0.42 .../flutter_fbdev/tool/deploy_samba.sh build/flutter-pi/pi3-64 roms/ports/myapp
```

Launch it with a one-line script (e.g. a Knulli/Batocera **Port**):

```sh
#!/bin/sh
DIR="$(dirname "$0")/myapp"
cd "$DIR" && chmod +x ./flutter_fbdev && ./flutter_fbdev "$DIR" > "$DIR/run.log" 2>&1
```

The embedder picks the framebuffer + input devices itself, renders, and forwards
`/dev/input` events to your Dart app. **Volume / Power quits** (a hard exit baked
into the embedder so you're never trapped).

## The demo, end-to-end

[`example/`](example) is a cosy showcase (FOLD aesthetic) that proves every part:
software rendering (live FPS + animation), gamepad input (a controller diagram
that lights up live), the mapping overlay (flashes each press), and d-pad
navigation. Here's the exact flow - the same five steps for any app:

```bash
cd example

# 1) build the Flutter AOT bundle for arm64 (Cortex-A53 → --cpu pi3)
flutterpi_tool build --arch arm64 --cpu pi3 --release
#    → build/flutter-pi/pi3-64/  (app.so, icudtl.dat, libflutter_engine.so, assets)

# 2) cross-compile the framebuffer embedder INTO the bundle (one self-contained dir)
../native/build_embedder.sh build/flutter-pi/pi3-64
#    → build/flutter-pi/pi3-64/flutter_fbdev  (aarch64 ELF)

# 3) deploy the bundle to the device's Ports area over Samba
FBDEV_IP=192.168.0.42 ../tool/deploy_samba.sh build/flutter-pi/pi3-64 roms/ports/fbdevdemo

# 4) put the launcher next to it (example/FbdevDemo.sh) in roms/ports/, e.g.:
#    cp FbdevDemo.sh  <samba-share>/roms/ports/FbdevDemo.sh
```

5) On the device, refresh the games list (or restart EmulationStation) and pick
**Ports → FbdevDemo**. Press buttons - the controller diagram lights up, the
overlay flashes each press, the FPS counter shows the software rasteriser keeping
up. **Volume / Power quits.** Logs land in `roms/ports/fbdevdemo/run.log` - read
them over Samba (no SSH needed).

> Tip: the 20 MB `libflutter_engine.so` is the slow part of a first deploy; later
> code-only changes just re-copy the ~3-4 MB `app.so`.

## Mapping a new device

`HandheldProfile.rg34xxsp` is bundled. For another device, run with the
[`HandheldInputOverlay`] visible, press each button, read its label, and build a
`HandheldProfile`:

```dart
HandheldInput.instance.profile = const HandheldProfile(keys: {
  304: HandheldButton.a, 305: HandheldButton.b, /* … */
}, hatX: 16, hatY: 17);
```

The d-pad is typically an `EV_ABS` hat (`HAT0X`/`HAT0Y`); face/shoulder buttons
are `EV_KEY` codes. The overlay also shows raw `KEY n` / `ABS n` for anything
unmapped.

## Status & caveats

- **Software rendering only** (no GPU). Great for UI/2D; profile heavy scenes.
- The display path assumes a 32-bpp framebuffer (the converter honours the fb's
  bitfield offsets). RGB565 panels would need a small tweak.
- Deploy tooling targets macOS hosts + Samba-enabled firmware (Knulli/Batocera
  family); adapt `tool/` for your setup.
- No touch - design for buttons (or use the input layer to drive focus).

## License

MIT - see [LICENSE](LICENSE).
