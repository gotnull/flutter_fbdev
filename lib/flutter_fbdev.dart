/// Run Flutter on no-DRM framebuffer handhelds (Anbernic RG34XXSP and friends),
/// with gamepad/evdev input and an on-screen button-mapping overlay.
///
/// See the README for the full picture: this package ships a software-rendered
/// `/dev/fb0` Flutter embedder (`native/`), build + deploy tooling (`tool/`), and
/// the Dart input layer exported here.
library;

export 'src/fbdev_audio.dart';
export 'src/fbdev_platform.dart';
export 'src/handheld_input.dart';
export 'src/handheld_input_overlay.dart';
export 'src/version.dart';
