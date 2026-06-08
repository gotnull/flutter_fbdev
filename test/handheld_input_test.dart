import 'package:flutter/services.dart';
import 'package:flutter_fbdev/flutter_fbdev.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tests the evdev -> HandheldButton mapping by feeding raw messages through the
/// `flutter_fbdev/input` channel exactly as the native embedder would, with no
/// device involved.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const codec = StringCodec();

  Future<void> send(String raw) {
    return TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      'flutter_fbdev/input',
      codec.encodeMessage(raw),
      (_) {},
    );
  }

  List<String> capture() {
    final events = <String>[];
    HandheldInput.instance.start();
    HandheldInput.instance
        .addListener((e) => events.add('${e.button.name}:${e.pressed}'));
    return events;
  }

  test('face button press/release maps to A (RG34XXSP code 304)', () async {
    final events = capture();
    await send('key:304:1');
    await send('key:304:0');
    expect(events, ['a:true', 'a:false']);
  });

  test('d-pad hat maps to dpad buttons with a synthesized release', () async {
    final events = capture();
    await send('abs:16:-1'); // HAT0X negative = left
    await send('abs:16:0'); // centre = release
    await send('abs:17:1'); // HAT0Y positive = down
    expect(events, ['dpadLeft:true', 'dpadLeft:false', 'dpadDown:true']);
  });

  test('unmapped code is ignored but shows a raw label', () async {
    final events = capture();
    await send('key:999:1');
    expect(events, isEmpty);
    expect(HandheldInput.instance.lastRawLabel.value, 'KEY 999');
  });
}
