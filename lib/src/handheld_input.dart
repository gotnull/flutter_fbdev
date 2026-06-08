import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// A logical handheld button, mapped from raw evdev events by a [HandheldProfile].
enum HandheldButton {
  dpadUp,
  dpadDown,
  dpadLeft,
  dpadRight,
  a,
  b,
  x,
  y,
  l1,
  r1,
  l2,
  r2,
  select,
  start,
  menu,
  volumeUp,
  volumeDown,
  power,
}

/// A press or release of a [HandheldButton].
@immutable
class HandheldButtonEvent {
  const HandheldButtonEvent(this.button, {required this.pressed});
  final HandheldButton button;
  final bool pressed;

  @override
  String toString() => '${button.name} ${pressed ? '↓' : '↑'}';
}

/// Maps a device's raw evdev codes to [HandheldButton]s. The d-pad is assumed to
/// be an `EV_ABS` hat ([hatX]/[hatY]); face/shoulder/menu buttons are `EV_KEY`
/// codes in [keys]. Override for other devices - [rg34xxsp] is the default.
@immutable
class HandheldProfile {
  const HandheldProfile({required this.keys, this.hatX = 16, this.hatY = 17});

  /// evdev `EV_KEY` code → button.
  final Map<int, HandheldButton> keys;

  /// evdev `EV_ABS` axis codes for the d-pad hat (HAT0X / HAT0Y).
  final int hatX;
  final int hatY;

  /// Anbernic RG34XXSP (Allwinner H700), captured on-device. The analog sticks
  /// (ABS 2/3 left, 4/5 right) are not mapped here - read them as raw if needed.
  static const HandheldProfile rg34xxsp = HandheldProfile(
    keys: {
      304: HandheldButton.a,
      305: HandheldButton.b,
      306: HandheldButton.y,
      307: HandheldButton.x,
      308: HandheldButton.l1,
      309: HandheldButton.r1,
      310: HandheldButton.select,
      311: HandheldButton.start,
      312: HandheldButton.menu,
      314: HandheldButton.l2,
      315: HandheldButton.r2,
      354: HandheldButton.menu,
      116: HandheldButton.power,
      115: HandheldButton.volumeUp,
      114: HandheldButton.volumeDown,
    },
  );
}

/// Receives raw evdev input forwarded by the framebuffer embedder over the
/// `flutter_fbdev/input` platform channel, maps it to [HandheldButton]s via a
/// [HandheldProfile], and dispatches press/release events.
///
/// This is **focus-independent** - it works on the framebuffer embedder where no
/// widget ever holds keyboard focus (which is why injected key events don't work
/// and a platform channel is used instead).
class HandheldInput {
  HandheldInput._();
  static final HandheldInput instance = HandheldInput._();

  static const BasicMessageChannel<String?> _channel =
      BasicMessageChannel<String?>('flutter_fbdev/input', StringCodec());

  /// Active device profile. Swap before [start] for a non-RG34XXSP device.
  HandheldProfile profile = HandheldProfile.rg34xxsp;

  /// The most recent mapped button event - listen for gameplay input.
  final ValueNotifier<HandheldButtonEvent?> last =
      ValueNotifier<HandheldButtonEvent?>(null);

  /// A human label for the most recent RAW event, mapped or not, e.g. `A · 304`,
  /// `MENU · 312`, `HAT X +`, `ABS 2 −`. Drives the mapping overlay and is handy
  /// for identifying an unknown device's buttons.
  final ValueNotifier<String?> lastRawLabel = ValueNotifier<String?>(null);

  final List<void Function(HandheldButtonEvent)> _listeners = [];

  /// Subscribe to button events. Remember to [removeListener].
  void addListener(void Function(HandheldButtonEvent) listener) =>
      _listeners.add(listener);
  void removeListener(void Function(HandheldButtonEvent) listener) =>
      _listeners.remove(listener);

  HandheldButton? _hatXActive;
  HandheldButton? _hatYActive;
  bool _started = false;

  /// Begin receiving input. Call once at startup; a no-op anywhere the embedder
  /// isn't sending (so it's safe to call unconditionally).
  void start() {
    if (_started) return;
    _started = true;
    _channel.setMessageHandler((message) async {
      _handle(message);
      return null;
    });
  }

  void _handle(String? message) {
    if (message == null) return;
    final parts = message.split(':'); // type:code:value
    if (parts.length != 3) return;
    final code = int.tryParse(parts[1]);
    final value = int.tryParse(parts[2]);
    if (code == null || value == null) return;

    if (parts[0] == 'abs') {
      _setRawLabel('abs', code, value);
      _handleHat(code, value);
      return;
    }
    // EV_KEY
    if (value != 2) _setRawLabel('key', code, value); // skip auto-repeat
    final button = profile.keys[code];
    if (button == null) return;
    if (value == 1) {
      _emit(button, true);
    } else if (value == 0) {
      _emit(button, false);
    }
  }

  void _handleHat(int code, int value) {
    if (code == profile.hatX) {
      _hatAxis(
        value,
        _hatXActive,
        neg: HandheldButton.dpadLeft,
        pos: HandheldButton.dpadRight,
        set: (b) => _hatXActive = b,
      );
    } else if (code == profile.hatY) {
      _hatAxis(
        value,
        _hatYActive,
        neg: HandheldButton.dpadUp,
        pos: HandheldButton.dpadDown,
        set: (b) => _hatYActive = b,
      );
    }
  }

  void _hatAxis(
    int value,
    HandheldButton? active, {
    required HandheldButton neg,
    required HandheldButton pos,
    required void Function(HandheldButton?) set,
  }) {
    if (value == 0) {
      if (active != null) {
        _emit(active, false);
        set(null);
      }
      return;
    }
    final button = value < 0 ? neg : pos;
    if (active != null && active != button) _emit(active, false);
    _emit(button, true);
    set(button);
  }

  void _emit(HandheldButton button, bool pressed) {
    final event = HandheldButtonEvent(button, pressed: pressed);
    last.value = event;
    for (final listener in List.of(_listeners)) {
      listener(event);
    }
  }

  void _setRawLabel(String kind, int code, int value) {
    if (kind == 'abs') {
      final isHat = code == profile.hatX || code == profile.hatY;
      final axis = code == profile.hatX
          ? 'HAT X'
          : code == profile.hatY
              ? 'HAT Y'
              : 'ABS $code';
      if (value == 0 && isHat) return; // skip hat release in the overlay
      final dir = value < 0
          ? '−'
          : value > 0
              ? '+'
              : '·';
      lastRawLabel.value = '$axis $dir';
      return;
    }
    if (value == 0) return; // key release: don't re-flash
    final button = profile.keys[code];
    lastRawLabel.value =
        button == null ? 'KEY $code' : '${button.name.toUpperCase()} · $code';
  }
}
