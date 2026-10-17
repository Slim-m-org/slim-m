// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The mark's own idea, drawn large: a field of dots on a lattice, and one
/// rounded square that has left it.
///
/// [AppBrandMark] is three dots and a square on a 32 grid. This paints the
/// lattice those dots belong to across a whole panel, faint and neutral, with
/// the accent square resting a half-step off its slot and the slot it left
/// standing empty. It is the brand's one figure at the scale of a page rather
/// than an icon, which is what an onboarding rail can carry that a settings
/// screen cannot. Nothing here is copy, so nothing here can overstate what a
/// server does - the reason the rail below the wordmark was kept blank.
///
/// Neutral-first, as the design language asks: the dots take a hairline
/// token and fade with distance from the square, and the square is the single
/// place brand ink appears. On entrance the square slides from its slot to
/// where it rests, one [AppMotion.slow] ease-out, so the story the mark tells
/// happens once in front of you; under reduce-motion it is simply already
/// there. Geometry is a function of size alone, so a render is repeatable.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app_motion.dart';
import '../../app_tokens.dart';

/// Distance between lattice slots, and the unit every other measure scales by.
const double _pitch = 28;

/// Which slot the square left, counted from the panel's top-left corner.
const int _homeColumn = 4;
const int _homeRow = 12;

/// Below this the field is not drawn at all, so the edges of the panel and
/// the wordmark's corner stay quiet rather than carrying a faint grid.
const double _floorAlpha = 0.06;

class AppBrandLattice extends StatefulWidget {
  const AppBrandLattice({super.key});

  @override
  State<AppBrandLattice> createState() => AppBrandLatticeState();
}

/// Public so a test can ask whether the entrance has settled, which under
/// reduce-motion must be true on the very first frame.
class AppBrandLatticeState extends State<AppBrandLattice>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: AppMotion.slow,
  );

  bool get settled => _controller.isCompleted;

  /// Where the square is between its slot (0) and rest (1), for tests.
  @visibleForTesting
  double get progress => _controller.value;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_controller.isAnimating || _controller.isCompleted) return;
    if (AppMotion.isReduced(context)) {
      _controller.value = 1;
    } else {
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return ExcludeSemantics(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) => CustomPaint(
          painter: _LatticePainter(
            dot: tokens.borderStrong,
            ink: tokens.accent,
            progress: AppMotion.entrance.transform(_controller.value),
          ),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

class _LatticePainter extends CustomPainter {
  const _LatticePainter({
    required this.dot,
    required this.ink,
    required this.progress,
  });

  final Color dot;
  final Color ink;

  /// 0 with the square still in its slot, 1 at rest a half-step away.
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    final columns = (size.width / _pitch).ceil() + 1;
    final rows = (size.height / _pitch).ceil() + 1;
    final home = const Offset(_homeColumn * _pitch, _homeRow * _pitch);
    final rest = home + const Offset(_pitch / 2, _pitch / 2);
    final square = Offset.lerp(home, rest, progress)!;

    // Quadratic falloff from the square: the eye lands there, the wordmark's corner stays clear.
    final reach = math.min(size.width * 1.4, size.height * 0.5);
    final paint = Paint();
    for (var c = 0; c < columns; c++) {
      for (var r = 0; r < rows; r++) {
        if (c == _homeColumn && r == _homeRow) continue;
        final at = Offset(c * _pitch, r * _pitch);
        final t = ((at - rest).distance / reach).clamp(0.0, 1.0);
        final alpha = 0.55 * (1 - t) * (1 - t);
        if (alpha < _floorAlpha) continue;
        paint.color = dot.withValues(alpha: alpha);
        canvas.drawCircle(at, _pitch * 0.1, paint);
      }
    }

    final side = _pitch * 0.62;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: square, width: side, height: side),
        const Radius.circular(_pitch * 0.2),
      ),
      Paint()..color = ink,
    );
  }

  @override
  bool shouldRepaint(_LatticePainter old) =>
      old.dot != dot || old.ink != ink || old.progress != progress;
}
