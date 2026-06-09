import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_fbdev/flutter_fbdev.dart';

/// flutter_fbdev demo - a cosy, warm showcase that proves the
/// whole package on a no-DRM framebuffer handheld:
///  • software rendering to /dev/fb0 (the smooth FPS counter + starfield),
///  • gamepad input over the platform channel (the live controller lights up),
///  • analog sticks (the two dots track each stick),
///  • the on-screen button-mapping overlay (flashes each press).
///
/// Build it into a flutter-pi bundle, add the embedder, and deploy to Ports -
/// see the package README "The demo, end-to-end".
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  HandheldInput.instance.start();
  runApp(const _DemoApp());
}

// --- palette ---------------------------------------------------------------
// Warm controls glowing over a deep night sky so the starfield can blaze.
const _sky = Color(0xFF0B0910); // near-black sky
const _ink = Color(0xFF2C2620);
const _cream = Color(0xFFF6EEDC);
const _amber = Color(0xFFE7A33A);
const _amberDeep = Color(0xFFC9791E);
const _muted = Color(0x552C2620); // dim label on a light surface (pad faces)
const _faint = Color(0x99F6EEDC); // dim label on the dark sky
const _shadow = Color(0x66000000);

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
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 2),
  )..repeat();

  // FPS (proves the software rasteriser is keeping up).
  Ticker? _ticker;
  int _frames = 0;
  double _fps = 0;
  Duration _lastTick = Duration.zero;

  // Background chiptune, looped quietly (a bundled ogg).
  AudioPlayer? _music;

  // Lets every input nudge the starfield (gamepad on device, keyboard on
  // desktop). A press surges the warp; a held stick / arrow keys steer it.
  final _StarfieldController _star = _StarfieldController();
  final FocusNode _focus = FocusNode();
  double _kbX = 0, _kbY = 0;

  Future<void> _startMusic() async {
    // On the handheld the framebuffer embedder decodes + plays it via ALSA;
    // elsewhere (desktop preview) use a normal audio plugin.
    if (isFbdevHandheld) {
      await FbdevAudio.setVolume(0.5);
      await FbdevAudio.play('assets/audio/blank_page.ogg');
      return;
    }
    try {
      final player = AudioPlayer();
      await player.setReleaseMode(ReleaseMode.loop);
      await player.setVolume(0.5);
      await player.play(AssetSource('audio/blank_page.ogg'));
      _music = player;
    } catch (_) {
      // No audio backend available - run silently.
    }
  }

  @override
  void initState() {
    super.initState();
    HandheldInput.instance.addListener(_onButton);
    HandheldInput.instance.sticks.addListener(_onSticks);
    _startMusic();
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
    HandheldInput.instance.sticks.removeListener(_onSticks);
    _focus.dispose();
    _music?.dispose();
    _ticker?.dispose();
    _pulse.dispose();
    super.dispose();
  }

  void _onButton(HandheldButtonEvent e) {
    if (e.pressed) _star.kick(); // every button press surges the starfield
    setState(() {
      if (e.pressed) {
        _down.add(e.button);
      } else {
        _down.remove(e.button);
      }
    });
  }

  // Both sticks steer the field (summed, the engine clamps).
  void _onSticks() {
    final s = HandheldInput.instance.sticks.value;
    _star.steer(s.leftX + s.rightX, s.leftY + s.rightY);
  }

  // Desktop fallback so the macOS/Linux preview reacts too: any key surges,
  // arrows / WASD steer.
  void _onKey(KeyEvent e) {
    if (e is KeyDownEvent) _star.kick();
    double? ax, ay;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.arrowLeft || k == LogicalKeyboardKey.keyA) {
      ax = -1;
    } else if (k == LogicalKeyboardKey.arrowRight ||
        k == LogicalKeyboardKey.keyD) {
      ax = 1;
    } else if (k == LogicalKeyboardKey.arrowUp ||
        k == LogicalKeyboardKey.keyW) {
      ay = -1;
    } else if (k == LogicalKeyboardKey.arrowDown ||
        k == LogicalKeyboardKey.keyS) {
      ay = 1;
    }
    if (ax != null) _kbX = e is KeyUpEvent ? 0 : ax;
    if (ay != null) _kbY = e is KeyUpEvent ? 0 : ay;
    if (ax != null || ay != null) _star.steer(_kbX, _kbY);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _sky,
      body: KeyboardListener(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: Stack(
          children: [
            Positioned.fill(child: _Starfield(controller: _star)),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _header(),
                    const SizedBox(height: 12),
                    Expanded(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Expanded(
                            child: Center(
                              child: _StickPad(
                                label: 'L-STICK',
                                select: (s) => Offset(s.leftX, s.leftY),
                              ),
                            ),
                          ),
                          _Gamepad(down: _down),
                          Expanded(
                            child: Center(
                              child: _StickPad(
                                label: 'R-STICK',
                                select: (s) => Offset(s.rightX, s.rightY),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
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
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  const Text(
                    'flutter_fbdev',
                    style: TextStyle(
                      color: _cream,
                      fontSize: 26,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -0.5,
                      height: 1.0,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'v$flutterFbdevVersion',
                    style: const TextStyle(
                        color: _amber,
                        fontSize: 13,
                        fontWeight: FontWeight.w900),
                  ),
                ],
              ),
              const SizedBox(height: 5),
              const Text(
                'by gotnull · github.com/gotnull',
                style: TextStyle(
                    color: _faint, fontSize: 11, fontWeight: FontWeight.w700),
              ),
            ],
          ),
          const Spacer(),
          const Text(
            'on /dev/fb0',
            style: TextStyle(
                color: _faint, fontSize: 13, fontWeight: FontWeight.w700),
          ),
        ],
      );

  Widget _footer() => Row(
        children: [
          const Text(
            'sweep the sticks · Vol ▲▼ quits',
            style: TextStyle(
                color: _faint, fontSize: 13, fontWeight: FontWeight.w700),
          ),
          const Spacer(),
          const Text(
            '♪ blank page · 4mat',
            style: TextStyle(
                color: _faint, fontSize: 12, fontWeight: FontWeight.w700),
          ),
          const SizedBox(width: 14),
          Text(
            '${_fps.toStringAsFixed(0)} fps',
            style: const TextStyle(
                color: _cream, fontSize: 14, fontWeight: FontWeight.w900),
          ),
        ],
      );
}

/// A live analog-stick readout: a dot tracks the normalized stick position
/// within its gate, proving the `flutter_fbdev/input` ABS axes reach Dart.
class _StickPad extends StatelessWidget {
  const _StickPad({required this.label, required this.select});
  final String label;
  final Offset Function(HandheldSticks) select;

  static const double _size = 104;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ValueListenableBuilder<HandheldSticks>(
          valueListenable: HandheldInput.instance.sticks,
          builder: (context, sticks, _) {
            final pos = select(sticks);
            const r = (_size - 28) / 2; // dot travel radius
            return Container(
              width: _size,
              height: _size,
              decoration: BoxDecoration(
                color: _cream,
                shape: BoxShape.circle,
                boxShadow: const [
                  BoxShadow(
                      color: _shadow, offset: Offset(0, 4), spreadRadius: -2),
                ],
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: const BoxDecoration(
                        color: _muted, shape: BoxShape.circle),
                  ),
                  Transform.translate(
                    offset: Offset(pos.dx * r, pos.dy * r),
                    child: Container(
                      width: 22,
                      height: 22,
                      decoration: const BoxDecoration(
                          color: _amber, shape: BoxShape.circle),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
        const SizedBox(height: 8),
        Text(
          label,
          style: const TextStyle(
              color: _faint,
              fontSize: 11,
              fontWeight: FontWeight.w900,
              letterSpacing: 1),
        ),
      ],
    );
  }
}

/// A live controller diagram - every button lights amber while held, proving the
/// full evdev→button mapping (d-pad hat, face keys, shoulders, Select/Start).
class _Gamepad extends StatelessWidget {
  const _Gamepad({required this.down});
  final Set<HandheldButton> down;

  static const double _width = 300;

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
                  child: pad(HandheldButton.x, 'X')),
              Align(
                  alignment: Alignment.bottomCenter,
                  child: pad(HandheldButton.b, 'B')),
              Align(
                  alignment: Alignment.centerLeft,
                  child: pad(HandheldButton.y, 'Y')),
              Align(
                  alignment: Alignment.centerRight,
                  child: pad(HandheldButton.a, 'A')),
            ],
          ),
        );

    return SizedBox(
      width: _width,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  pad(HandheldButton.l1, 'L1', size: 36),
                  const SizedBox(width: 8),
                  pad(HandheldButton.l2, 'L2', size: 32),
                ],
              ),
              pad(HandheldButton.menu, 'M', size: 38),
              Row(
                children: [
                  pad(HandheldButton.r2, 'R2', size: 32),
                  const SizedBox(width: 8),
                  pad(HandheldButton.r1, 'R1', size: 36),
                ],
              ),
            ],
          ),
          const SizedBox(height: 22),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [dpad(), faces()],
          ),
          const SizedBox(height: 22),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              pad(HandheldButton.select, 'SEL', size: 34),
              const SizedBox(width: 20),
              pad(HandheldButton.start, 'STA', size: 34),
            ],
          ),
        ],
      ),
    );
  }
}

// ===========================================================================
// Starfield - a small star engine with seven motion modes (forward warp,
// parallax, vortex, twinkle, rain, lightspeed, blackhole), an xorshift32 PRNG,
// and a per-star tint/brightness/size model. It draws to a Flutter canvas and
// runs at the canvas's own dimensions so the projections fill any surface it
// is given. Inputs nudge it: a press speeds and reseeds the field, a held
// stick steers the drift.
// ===========================================================================

// Star tint palette in RGB565: warm + cool whites plus a few accents so the
// field reads varied, not monochrome.
const List<int> _kStarTints565 = [
  0xFFFF, // pure white
  0xFFFE, // bright white (slight green bias)
  0xC79F, // pale blue
  0xFFE0, // warm yellow
  0xFE36, // soft pink
  0x7DFF, // light cyan
  0xFCE0, // peach
  0xAFFF, // electric blue
];
const int _kStarCount = 150; // total stars
const int _kStarTintCount = 8; // tint palette size

// RGB565 tints decoded to 0..255 channels once, then modulated per star by
// brightness at draw time (the renderer's "modulate by brightness" step).
final List<int> _tintR =
    _kStarTints565.map((v) => (((v >> 11) & 0x1F) * 255 / 31).round()).toList();
final List<int> _tintG =
    _kStarTints565.map((v) => (((v >> 5) & 0x3F) * 255 / 63).round()).toList();
final List<int> _tintB =
    _kStarTints565.map((v) => ((v & 0x1F) * 255 / 31).round()).toList();

// Parallax tuning: five layers, slow -> fast px/frame.
const List<double> _kParallaxSpeed = [0.5, 1.1, 1.8, 2.7, 4.0];
const List<int> _kParallaxBright = [80, 130, 180, 220, 255];
const int _kParallaxLayers = 5;

class _StarData {
  double a = 0, b = 0, c = 0; // mode-specific animation state
  double sx = 0, sy = 0; // projected screen position
  double brightness = 0; // 0..255
  int tint = 0;
  int size = 0; // 0 = dot, 1 = small disc, 2 = bigger disc
}

/// The star engine: owns the PRNG, the star buffer, and the active mode. One
/// [tick] advances a single 60 fps frame, exactly as the C `update*` helpers do.
class _StarEngine {
  _StarEngine(int seed) : _prng = (seed & 0xFFFFFFFF) == 0 ? 0x12345678 : seed;

  int _prng;
  int _mode = 0; // start on Forward3D (the classic warp)
  int _frame = 0;
  double _w = 1, _h = 1;
  bool _seeded = false;
  final List<_StarData> stars = List.generate(_kStarCount, (_) => _StarData());

  // ~12 s between mode changes at 60 fps.
  static const int _modeHoldFrames = 720;
  static const int _modeCount = 7;

  // Input reaction. [energy] (0..1.5) spikes on any press and decays each tick,
  // boosting the field's speed, size and brightness (a warp surge). [steerX/Y]
  // ease toward a held stick / arrow-key direction and parallax-shift the field.
  double energy = 0;
  double steerX = 0, steerY = 0;
  double _steerTargetX = 0, _steerTargetY = 0;

  void kick() => energy = math.min(1.5, energy + 0.8);
  void steerTo(double x, double y) {
    _steerTargetX = x.clamp(-1.0, 1.0);
    _steerTargetY = y.clamp(-1.0, 1.0);
  }

  // xorshift32 PRNG.
  int _nextU32() {
    int x = _prng;
    x ^= (x << 13) & 0xFFFFFFFF;
    x ^= x >> 17;
    x ^= (x << 5) & 0xFFFFFFFF;
    _prng = x & 0xFFFFFFFF;
    return _prng;
  }

  double _nextFloat() => _nextU32() / 0xFFFFFFFF;
  int _nextTint() => _nextU32() % _kStarTintCount;

  void resize(double w, double h) {
    if (w == _w && h == _h && _seeded) return;
    _w = w;
    _h = h;
    _seeded = true;
    _initForMode();
  }

  void tick() {
    if (!_seeded) return;
    energy *= 0.93;
    if (energy < 0.001) energy = 0;
    steerX += (_steerTargetX - steerX) * 0.15;
    steerY += (_steerTargetY - steerY) * 0.15;
    _frame++;
    if (_frame % _modeHoldFrames == 0) _rerollMode();
    _updateForMode();
  }

  void _rerollMode() {
    final cur = _mode;
    var next = cur;
    while (next == cur) {
      next = _nextU32() % _modeCount;
    }
    _mode = next;
    _initForMode();
  }

  // seedCommonAppearance: tint + size, biased small (only ~20% are big).
  void _seedCommon(_StarData s) {
    s.tint = _nextTint();
    final roll = _nextU32() & 0xFF;
    s.size = roll < 200 ? 0 : (roll < 240 ? 1 : 2);
  }

  void _initForMode() {
    switch (_mode) {
      case 0:
        _initForward3D();
      case 1:
        _initParallax();
      case 2:
        _initVortex();
      case 3:
        _initTwinkle();
      case 4:
        _initRain();
      case 5:
        _initLightspeed();
      default:
        _initBlackhole();
    }
  }

  void _updateForMode() {
    switch (_mode) {
      case 0:
        _updateForward3D();
      case 1:
        _updateParallax();
      case 2:
        _updateVortex();
      case 3:
        _updateTwinkle();
      case 4:
        _updateRain();
      case 5:
        _updateLightspeed();
      default:
        _updateBlackhole();
    }
  }

  // --- Forward3D: classic perspective starfield, streaming toward viewer ----
  void _initForward3D() {
    for (final s in stars) {
      _seedCommon(s);
      s.a = _nextFloat() * 2 - 1;
      s.b = _nextFloat() * 2 - 1;
      s.c = _nextFloat();
    }
  }

  void _updateForward3D() {
    final halfW = _w / 2, halfH = _h / 2;
    for (final s in stars) {
      s.c -= 0.02;
      if (s.c <= 0) {
        s.a = _nextFloat() * 2 - 1;
        s.b = _nextFloat() * 2 - 1;
        s.c = 1;
        s.tint = _nextTint();
      }
      final invZ = 1 / s.c;
      final sx = halfW + s.a * halfW * invZ;
      final sy = halfH + s.b * halfH * invZ;
      if (sx < 0 || sx >= _w || sy < 0 || sy >= _h) {
        s.brightness = 0;
        continue;
      }
      s.sx = sx;
      s.sy = sy;
      s.brightness = (255 * (1 - s.c)).clamp(0, 255).toDouble();
    }
  }

  // --- Parallax: five-layer horizontal scroll -------------------------------
  void _initParallax() {
    for (var i = 0; i < stars.length; i++) {
      final s = stars[i];
      _seedCommon(s);
      s.a = _nextFloat() * _w;
      s.b = _nextFloat() * _h;
      final layer = i % _kParallaxLayers;
      s.c = layer / (_kParallaxLayers - 1);
    }
  }

  void _updateParallax() {
    for (final s in stars) {
      var layer = (s.c * (_kParallaxLayers - 1) + 0.5).floor();
      layer = layer.clamp(0, _kParallaxLayers - 1);
      s.a -= _kParallaxSpeed[layer];
      if (s.a < 0) {
        s.a += _w;
        s.b = _nextFloat() * _h;
        s.tint = _nextTint();
      }
      s.sx = s.a;
      s.sy = s.b;
      s.brightness = _kParallaxBright[layer].toDouble();
    }
  }

  // --- Vortex: stars spiral outward from centre -----------------------------
  void _initVortex() {
    for (final s in stars) {
      _seedCommon(s);
      s.a = _nextFloat() * 2 * math.pi;
      s.b = _nextFloat() * 0.3;
      s.c = _nextFloat() * 0.06 + 0.02;
    }
  }

  void _updateVortex() {
    final halfW = _w / 2, halfH = _h / 2;
    for (final s in stars) {
      s.b += 0.012 * (0.3 + s.b);
      s.a += s.c;
      if (s.b > 1.4) {
        s.a = _nextFloat() * 2 * math.pi;
        s.b = _nextFloat() * 0.15;
        s.c = _nextFloat() * 0.06 + 0.02;
        s.tint = _nextTint();
      }
      final sx = halfW + math.cos(s.a) * s.b * halfW;
      final sy = halfH + math.sin(s.a) * s.b * halfH;
      if (sx < 0 || sx >= _w || sy < 0 || sy >= _h) {
        s.brightness = 0;
        continue;
      }
      final bf = (s.b / 1.4).clamp(0.0, 1.0);
      s.sx = sx;
      s.sy = sy;
      s.brightness = 255 * (0.4 + 0.6 * bf);
    }
  }

  // --- Twinkle: random field of pulsing sparkles ----------------------------
  void _initTwinkle() {
    for (final s in stars) {
      _seedCommon(s);
      s.a = _nextFloat() * _w;
      s.b = _nextFloat() * _h;
      s.c = _nextFloat();
    }
  }

  void _updateTwinkle() {
    for (var i = 0; i < stars.length; i++) {
      final s = stars[i];
      s.c += 0.012 + (i & 7) * 0.0008;
      if (s.c >= 1) {
        s.c -= 1;
        s.a = _nextFloat() * _w;
        s.b = _nextFloat() * _h;
        s.tint = _nextTint();
      }
      s.sx = s.a;
      s.sy = s.b;
      s.brightness = (255 * math.sin(s.c * math.pi)).clamp(0, 255).toDouble();
    }
  }

  // --- Rain: diagonal streaks falling NE->SW --------------------------------
  void _initRain() {
    for (final s in stars) {
      _seedCommon(s);
      s.a = _nextFloat() * _w;
      s.b = _nextFloat() * _h;
      s.c = 1.5 + _nextFloat() * 3;
    }
  }

  void _updateRain() {
    for (final s in stars) {
      s.a -= s.c;
      s.b += s.c * 0.45;
      if (s.a < 0 || s.b >= _h) {
        if ((_nextU32() & 1) == 0) {
          s.a = _w;
          s.b = _nextFloat() * _h;
        } else {
          s.a = _nextFloat() * _w;
          s.b = 0;
        }
        s.c = 1.5 + _nextFloat() * 3;
        s.tint = _nextTint();
      }
      s.sx = s.a;
      s.sy = s.b;
      final b = 120 + ((s.c - 1.5) / 3 * 135);
      s.brightness = b > 255 ? 255 : b;
    }
  }

  // --- Lightspeed: radial hyperspace warp -----------------------------------
  void _initLightspeed() {
    for (final s in stars) {
      _seedCommon(s);
      if (s.size < 1) s.size = 1;
      s.a = _nextFloat() * 2 * math.pi;
      s.b = _nextFloat() * 0.05;
      s.c = 0.6 + _nextFloat() * 0.8;
    }
  }

  void _updateLightspeed() {
    final halfW = _w / 2, halfH = _h / 2;
    for (final s in stars) {
      s.b += s.c * 0.025 * (0.4 + s.b * 4);
      if (s.b > 1.5) {
        s.a = _nextFloat() * 2 * math.pi;
        s.b = _nextFloat() * 0.05;
        s.c = 0.6 + _nextFloat() * 0.8;
        s.tint = _nextTint();
      }
      final sx = halfW + math.cos(s.a) * s.b * halfW * 1.2;
      final sy = halfH + math.sin(s.a) * s.b * halfH * 1.6;
      if (sx < 0 || sx >= _w || sy < 0 || sy >= _h) {
        s.brightness = 0;
        continue;
      }
      final bf = (s.b / 1.5).clamp(0.0, 1.0);
      s.sx = sx;
      s.sy = sy;
      s.brightness = 40 + 215 * bf;
    }
  }

  // --- Blackhole: singularity pulling stars inward, accelerating ------------
  void _initBlackhole() {
    for (final s in stars) {
      _seedCommon(s);
      s.a = _nextFloat() * 2 * math.pi;
      s.b = 0.08 + _nextFloat() * (1.1 - 0.08);
      s.c = 0.7 + _nextFloat() * 0.6;
    }
  }

  void _updateBlackhole() {
    final halfW = _w / 2, halfH = _h / 2;
    for (final s in stars) {
      final r = s.b < 0.04 ? 0.04 : s.b;
      s.a += s.c * 0.04 / math.sqrt(r);
      s.b -= 0.0035;
      if (s.b < 0.08) {
        s.a = _nextFloat() * 2 * math.pi;
        s.b = 1.1;
        s.c = 0.7 + _nextFloat() * 0.6;
        s.tint = _nextTint();
      }
      final sx = halfW + math.cos(s.a) * s.b * halfW;
      final sy = halfH + math.sin(s.a) * s.b * halfH;
      if (sx < 0 || sx >= _w || sy < 0 || sy >= _h) {
        s.brightness = 0;
        continue;
      }
      final bf = (s.b - 0.08) / (1.1 - 0.08);
      s.sx = sx;
      s.sy = sy;
      s.brightness = (40 + 215 * bf).clamp(0, 255).toDouble();
    }
  }
}

/// A thin handle the screen uses to push input into the starfield without
/// owning its engine: [kick] on any press, [steer] from a held stick / keys.
class _StarfieldController {
  _StarEngine? _engine;
  void _attach(_StarEngine e) => _engine = e;
  void kick() => _engine?.kick();
  void steer(double x, double y) => _engine?.steerTo(x, y);
}

/// Hosts the [_StarEngine], drives it at a fixed 60 fps step from a ticker, and
/// repaints the canvas each frame. Owns its own ticker so it never rebuilds the
/// widget tree above it.
class _Starfield extends StatefulWidget {
  const _Starfield({required this.controller});
  final _StarfieldController controller;
  @override
  State<_Starfield> createState() => _StarfieldState();
}

class _StarfieldState extends State<_Starfield>
    with SingleTickerProviderStateMixin {
  final _StarEngine _engine = _StarEngine(0x5EED1E);
  final ValueNotifier<int> _repaint = ValueNotifier<int>(0);
  late final Ticker _ticker;
  Duration _last = Duration.zero;
  double _acc = 0;

  static const double _step = 1 / 60;

  @override
  void initState() {
    super.initState();
    widget.controller._attach(_engine);
    _ticker = createTicker((elapsed) {
      final dt = (elapsed - _last).inMicroseconds / 1e6;
      _last = elapsed;
      _acc += dt;
      var steps = 0;
      while (_acc >= _step && steps < 4) {
        // A press surges energy; run extra sub-steps so the field visibly
        // accelerates, then settles as the energy decays.
        final surge = 1 + (_engine.energy * 4).round();
        for (var k = 0; k < surge; k++) {
          _engine.tick();
        }
        _acc -= _step;
        steps++;
      }
      _repaint.value++;
    })
      ..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _repaint.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: LayoutBuilder(
        builder: (context, constraints) {
          _engine.resize(constraints.maxWidth, constraints.maxHeight);
          return CustomPaint(
            painter: _StarPainter(_engine, _repaint),
            size: Size.infinite,
          );
        },
      ),
    );
  }
}

class _StarPainter extends CustomPainter {
  _StarPainter(this.engine, Listenable repaint) : super(repaint: repaint);
  final _StarEngine engine;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint();
    final em = engine.energy;
    final brightMul = 1 + em * 0.7; // bloom on a press
    final radiusMul = 1 + em * 0.6;
    final shiftX = engine.steerX * 26; // held-stick parallax shift
    final shiftY = engine.steerY * 26;
    for (final s in engine.stars) {
      if (s.brightness <= 0) continue;
      final bf = (s.brightness / 255.0) * brightMul;
      final t = s.tint;
      paint.color = Color.fromARGB(
        255,
        (_tintR[t] * bf).clamp(0, 255).round(),
        (_tintG[t] * bf).clamp(0, 255).round(),
        (_tintB[t] * bf).clamp(0, 255).round(),
      );
      // Nearer (bigger) stars shift more than far ones for a parallax feel.
      final depth = s.size == 0 ? 0.4 : (s.size == 1 ? 0.7 : 1.0);
      final radius =
          (s.size == 0 ? 0.9 : (s.size == 1 ? 1.7 : 2.7)) * radiusMul;
      canvas.drawCircle(
        Offset(s.sx + shiftX * depth, s.sy + shiftY * depth),
        radius,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_StarPainter oldDelegate) =>
      false; // repaints via listenable
}
