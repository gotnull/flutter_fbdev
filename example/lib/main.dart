import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_fbdev/flutter_fbdev.dart';

/// flutter_fbdev demo - a cosy, warm showcase (FOLD aesthetic) that proves the
/// whole package on a no-DRM framebuffer handheld:
///  • software rendering to /dev/fb0 (the smooth FPS counter + animations),
///  • gamepad input over the platform channel (the live controller lights up),
///  • the on-screen button-mapping overlay (flashes each press),
///  • d-pad navigation (move the selector, A pops the tile).
///
/// Build it into a flutter-pi bundle, add the embedder, and deploy to Ports -
/// see the package README "Deploy the demo end-to-end".
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  HandheldInput.instance.start();
  runApp(const _DemoApp());
}

// --- warm "cosy wooden floor" palette (FOLD-inspired) ----------------------
const _bg = Color(0xFFE7D9BC);
const _ink = Color(0xFF2C2620);
const _cream = Color(0xFFF6EEDC);
const _amber = Color(0xFFE7A33A);
const _amberDeep = Color(0xFFC9791E);
const _muted = Color(0x552C2620);
const _shadow = Color(0x332C2620);

class _DemoApp extends StatelessWidget {
  const _DemoApp();
  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: _DemoScreen(),
    );
  }
}

class _DemoScreen extends StatefulWidget {
  const _DemoScreen();
  @override
  State<_DemoScreen> createState() => _DemoScreenState();
}

class _DemoScreenState extends State<_DemoScreen>
    with TickerProviderStateMixin {
  final Set<HandheldButton> _down = {};
  int _selected = 0;
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 2),
  )..repeat();

  // FPS (proves the software rasteriser is keeping up).
  Ticker? _ticker;
  int _frames = 0;
  double _fps = 0;
  Duration _lastTick = Duration.zero;

  static const _tiles = ['RENDER', 'INPUT', 'D-PAD', 'MAPPED'];

  @override
  void initState() {
    super.initState();
    HandheldInput.instance.addListener(_onButton);
    _ticker = createTicker((elapsed) {
      _frames++;
      if (elapsed - _lastTick >= const Duration(seconds: 1)) {
        setState(() {
          _fps = _frames / ((elapsed - _lastTick).inMilliseconds / 1000);
          _frames = 0;
          _lastTick = elapsed;
        });
      }
    })
      ..start();
  }

  @override
  void dispose() {
    HandheldInput.instance.removeListener(_onButton);
    _ticker?.dispose();
    _pulse.dispose();
    super.dispose();
  }

  void _onButton(HandheldButtonEvent e) {
    setState(() {
      if (e.pressed) {
        _down.add(e.button);
      } else {
        _down.remove(e.button);
      }
      if (!e.pressed) return;
      switch (e.button) {
        case HandheldButton.dpadLeft:
          _selected = (_selected - 1) % _tiles.length;
          if (_selected < 0) _selected += _tiles.length;
        case HandheldButton.dpadRight:
          _selected = (_selected + 1) % _tiles.length;
        case HandheldButton.a:
          _bump = _selected; // pop the selected tile
          _pop.forward(from: 0);
        default:
          break;
      }
    });
  }

  // tile pop animation
  int _bump = -1;
  late final AnimationController _pop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: Stack(
        children: [
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _header(),
                  const SizedBox(height: 14),
                  Expanded(child: _tileRow()),
                  const SizedBox(height: 10),
                  _Gamepad(down: _down),
                  const SizedBox(height: 8),
                  _footer(),
                ],
              ),
            ),
          ),
          const HandheldInputOverlay(
            background: _ink,
            foreground: _cream,
          ),
        ],
      ),
    );
  }

  Widget _header() => Row(
        children: [
          AnimatedBuilder(
            animation: _pulse,
            builder: (context, _) {
              final t = (0.5 + 0.5 * (1 - (2 * _pulse.value - 1).abs()));
              return Container(
                width: 16,
                height: 16,
                decoration: BoxDecoration(
                  color: Color.lerp(_amber, _amberDeep, t),
                  shape: BoxShape.circle,
                ),
              );
            },
          ),
          const SizedBox(width: 10),
          const Text(
            'flutter_fbdev',
            style: TextStyle(
              color: _ink,
              fontSize: 26,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.5,
            ),
          ),
          const Spacer(),
          const Text(
            'on /dev/fb0',
            style: TextStyle(
                color: _muted, fontSize: 13, fontWeight: FontWeight.w700),
          ),
        ],
      );

  Widget _tileRow() => Row(
        children: [
          for (var i = 0; i < _tiles.length; i++)
            Expanded(
              child: AnimatedBuilder(
                animation: _pop,
                builder: (context, _) {
                  final selected = i == _selected;
                  final pop = (i == _bump)
                      ? Curves.elasticOut.transform(_pop.value)
                      : 0.0;
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 5),
                    child: Transform.scale(
                      scale: 1 + 0.10 * pop,
                      child: Container(
                        decoration: BoxDecoration(
                          color: selected ? _amber : _cream,
                          borderRadius: BorderRadius.circular(16),
                          boxShadow: const [
                            BoxShadow(
                                color: _shadow,
                                offset: Offset(0, 4),
                                spreadRadius: -2),
                          ],
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          _tiles[i],
                          style: TextStyle(
                            color: selected ? _ink : _muted,
                            fontWeight: FontWeight.w900,
                            fontSize: 15,
                            letterSpacing: 1,
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
        ],
      );

  Widget _footer() => ValueListenableBuilder<HandheldButtonEvent?>(
        valueListenable: HandheldInput.instance.last,
        builder: (context, e, _) => Row(
          children: [
            Text(
              'D-pad ◀ ▶ select · Ⓐ pop',
              style: const TextStyle(
                  color: _muted, fontSize: 13, fontWeight: FontWeight.w700),
            ),
            const Spacer(),
            Text(
              '${_fps.toStringAsFixed(0)} fps',
              style: const TextStyle(
                  color: _ink, fontSize: 14, fontWeight: FontWeight.w900),
            ),
          ],
        ),
      );
}

/// A live controller diagram - every button lights amber while held, proving the
/// full evdev→button mapping (d-pad hat, face keys, shoulders, Select/Start).
class _Gamepad extends StatelessWidget {
  const _Gamepad({required this.down});
  final Set<HandheldButton> down;

  @override
  Widget build(BuildContext context) {
    Widget pad(HandheldButton b, String label, {double size = 40}) {
      final on = down.contains(b);
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: on ? _amber : _cream,
          borderRadius: BorderRadius.circular(size / 4),
          boxShadow: const [
            BoxShadow(color: _shadow, offset: Offset(0, 3), spreadRadius: -2),
          ],
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            color: on ? _ink : _muted,
            fontWeight: FontWeight.w900,
            fontSize: 14,
          ),
        ),
      );
    }

    Widget dpad() => SizedBox(
          width: 132,
          height: 132,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Align(
                  alignment: Alignment.topCenter,
                  child: pad(HandheldButton.dpadUp, '▲')),
              Align(
                  alignment: Alignment.bottomCenter,
                  child: pad(HandheldButton.dpadDown, '▼')),
              Align(
                  alignment: Alignment.centerLeft,
                  child: pad(HandheldButton.dpadLeft, '◀')),
              Align(
                  alignment: Alignment.centerRight,
                  child: pad(HandheldButton.dpadRight, '▶')),
            ],
          ),
        );

    Widget faces() => SizedBox(
          width: 132,
          height: 132,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Align(
                  alignment: Alignment.topCenter,
                  child: pad(HandheldButton.y, 'Y')),
              Align(
                  alignment: Alignment.bottomCenter,
                  child: pad(HandheldButton.a, 'A')),
              Align(
                  alignment: Alignment.centerLeft,
                  child: pad(HandheldButton.x, 'X')),
              Align(
                  alignment: Alignment.centerRight,
                  child: pad(HandheldButton.b, 'B')),
            ],
          ),
        );

    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            pad(HandheldButton.l1, 'L', size: 36),
            Row(
              children: [
                pad(HandheldButton.select, 'SEL', size: 34),
                const SizedBox(width: 8),
                pad(HandheldButton.start, 'STA', size: 34),
              ],
            ),
            pad(HandheldButton.r1, 'R', size: 36),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [dpad(), faces()],
        ),
      ],
    );
  }
}
