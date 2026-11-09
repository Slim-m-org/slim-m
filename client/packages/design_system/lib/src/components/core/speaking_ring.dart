// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The speaking ring: the one looping animation in the chrome, and what it
/// becomes for a viewer who has asked for less motion.
///
/// Decision 0004 settles both halves. The ring pulses while someone is
/// talking; under reduce-motion it holds still and gains a bar glyph, so
/// speaking is carried by two cues rather than by the one that just stopped
/// moving. A stilled ring alone would be indistinguishable from the ring any
/// other caller can draw through `AppAvatar.ringColor`.
library;

import 'package:flutter/material.dart';

import '../../app_metrics.dart';
import '../../app_motion.dart';
import '../../app_tokens.dart';

/// Wraps [child] in a ring that pulses while it is mounted.
///
/// Mount it only while someone is actually speaking: it has no `speaking`
/// flag, because a widget that animates whether or not it is doing anything
/// is a timer that never stops.
class AppSpeakingRing extends StatefulWidget {
  const AppSpeakingRing({
    super.key,
    required this.color,
    required this.size,
    required this.child,
    this.round = true,
    this.radius = AppRadii.control,
    this.glyphBackgroundColor,
  });

  final Color color;

  /// The side of the square [child] occupies, which the reduce-motion glyph is
  /// scaled from.
  final double size;

  final Widget child;

  /// Circle or rounded rectangle, matching whatever [child] is clipped to.
  final bool round;
  final double radius;

  /// What the glyph's backdrop is drawn in, so it reads against the surface
  /// behind rather than against the avatar it overlaps. Defaults to
  /// [AppTokens.surfaceBase].
  final Color? glyphBackgroundColor;

  @override
  State<AppSpeakingRing> createState() => _AppSpeakingRingState();
}

/// How faint the ring gets at the bottom of its pulse.
const double _pulseFloor = 0.4;

const double _ringWidth = 2;

class _AppSpeakingRingState extends State<AppSpeakingRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: AppMotion.speakingPulse,
    value: 1,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (AppMotion.isReduced(context)) {
      _pulse.stop();
      _pulse.value = 1;
    } else if (!_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduced = AppMotion.isReduced(context);
    final tokens = Theme.of(context).extension<AppTokens>()!;

    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // Its own layer, or each frame of the pulse repaints everything around the ring.
          RepaintBoundary(
            child: AnimatedBuilder(
              animation: _pulse,
              // A foreground overlay, not a border, so a pulse moves no layout.
              builder: (context, child) => Container(
                foregroundDecoration: BoxDecoration(
                  shape: widget.round ? BoxShape.circle : BoxShape.rectangle,
                  borderRadius: widget.round
                      ? null
                      : BorderRadius.circular(widget.radius),
                  border: Border.all(
                    color: widget.color.withValues(
                      alpha: _pulseFloor + _pulse.value * (1 - _pulseFloor),
                    ),
                    width: _ringWidth,
                  ),
                ),
                child: child,
              ),
              child: widget.child,
            ),
          ),
          if (reduced)
            Positioned(
              left: -2,
              bottom: -2,
              child: AppSpeakingGlyph(
                size: _glyphSize(widget.size),
                color: widget.color,
                backgroundColor:
                    widget.glyphBackgroundColor ?? tokens.surfaceBase,
              ),
            ),
        ],
      ),
    );
  }
}

/// The glyph's side for an avatar of [avatarSize], floored the same way the
/// presence dot floors its own so it stays legible on the smallest avatar.
double _glyphSize(double avatarSize) {
  final scaled = (avatarSize * 0.3).round();
  return scaled < 9 ? 9.0 : scaled.toDouble();
}

/// Three level bars on a disc: the non-moving half of the speaking cue.
///
/// Drawn rather than set as a Lucide glyph, which the icon set would otherwise
/// require: this renders at roughly 10dp, where a 1.5px-stroked outline icon
/// closes up into a smudge.
class AppSpeakingGlyph extends StatelessWidget {
  const AppSpeakingGlyph({
    super.key,
    required this.color,
    required this.backgroundColor,
    this.size = 10,
  });

  final Color color;
  final Color backgroundColor;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(color: backgroundColor, shape: BoxShape.circle),
      child: CustomPaint(
        size: Size.square(size),
        painter: AppSpeakingBarsPainter(color: color),
      ),
    );
  }
}

/// Draws the three bars. Public for the same reason `AppStatusDotPainter` is:
/// a test asserts the mark directly rather than inferring it from pixels.
class AppSpeakingBarsPainter extends CustomPainter {
  const AppSpeakingBarsPainter({required this.color});

  final Color color;

  /// Bar heights as a fraction of the box, tallest in the middle so the mark
  /// reads as a level meter rather than as three ticks.
  static const List<double> _heights = [0.5, 1.0, 0.7];

  @override
  void paint(Canvas canvas, Size size) {
    final barWidth = size.width * 0.18;
    final gap = size.width * 0.14;
    final total = _heights.length * barWidth + (_heights.length - 1) * gap;
    final paint = Paint()..color = color;

    var x = (size.width - total) / 2;
    for (final fraction in _heights) {
      final height = size.height * fraction;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, (size.height - height) / 2, barWidth, height),
          Radius.circular(barWidth / 2),
        ),
        paint,
      );
      x += barWidth + gap;
    }
  }

  @override
  bool shouldRepaint(covariant AppSpeakingBarsPainter oldDelegate) =>
      oldDelegate.color != color;
}
