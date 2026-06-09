import 'package:flutter/material.dart';

import 'handheld_input.dart';

/// On-screen overlay that flashes + bounces the most recently pressed handheld
/// button (mapped name, or the raw `KEY n` / `HAT X +` for unmapped inputs).
///
/// Drop it on top of any screen - it's inert until input arrives, so it shows
/// nothing on touch devices. Invaluable for mapping a new device's buttons by
/// eye: press each one and read its label.
class HandheldInputOverlay extends StatefulWidget {
  const HandheldInputOverlay({
    super.key,
    this.alignment = Alignment.topCenter,
    this.background = const Color(0xFF1B1B1F),
    this.foreground = const Color(0xFFF4ECD8),
  });

  /// Where the flash appears.
  final Alignment alignment;
  final Color background;
  final Color foreground;

  @override
  State<HandheldInputOverlay> createState() => _HandheldInputOverlayState();
}

class _HandheldInputOverlayState extends State<HandheldInputOverlay>
    with SingleTickerProviderStateMixin {
  static const Duration _flash = Duration(milliseconds: 750);
  static const double _fadeStart = 0.6; // fraction of the flash before fading

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: _flash,
  );
  String _label = '';

  @override
  void initState() {
    super.initState();
    HandheldInput.instance.lastRawLabel.addListener(_onInput);
  }

  @override
  void dispose() {
    HandheldInput.instance.lastRawLabel.removeListener(_onInput);
    _controller.dispose();
    super.dispose();
  }

  void _onInput() {
    final label = HandheldInput.instance.lastRawLabel.value;
    if (label == null) return;
    setState(() => _label = label);
    _controller.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: SafeArea(
        child: Align(
          alignment: widget.alignment,
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, _) {
              final t = _controller.value;
              if (t == 0 || t >= 1) return const SizedBox.shrink();
              final pop = Curves.elasticOut.transform(t);
              final fade = t < _fadeStart
                  ? 1.0
                  : 1.0 - (t - _fadeStart) / (1 - _fadeStart);
              return Padding(
                padding: const EdgeInsets.all(20),
                child: Opacity(
                  opacity: fade.clamp(0.0, 1.0),
                  child:
                      Transform.scale(scale: 0.7 + 0.3 * pop, child: _chip()),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _chip() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 11),
        decoration: BoxDecoration(
          color: widget.background,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          _label,
          style: TextStyle(
            color: widget.foreground,
            fontSize: 24,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.5,
          ),
        ),
      );
}
