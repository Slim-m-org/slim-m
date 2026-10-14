// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The startup window's backdrop and mark, drawn on one timeline: a dot
/// lattice ripples out from the centre, then four of its points become the
/// brand mark (three dots turn accent, the fourth pops into the rounded
/// square). From the "Startup Window" design, with its timings compressed so
/// the mark is whole inside the standard 900ms splash floor.
library;

import 'dart:math' as math;

import 'package:flutter/animation.dart';
import 'package:flutter/rendering.dart';

/// The splash content is laid out on this fixed canvas, the design's own.
const Size kStartupCanvas = Size(480, 340);

const double _pitch = 28;
const double _unit = _pitch / 12;
const Offset _markOrigin = Offset(205, 95);
const double kStartupMarkSize = 32 * _unit;
const Offset _rippleCentre = Offset(240, 130);
const double _rippleReach = 250;

/// When the wordmark under the mark starts to settle, in seconds.
const double kStartupWordAt = 0.7;

/// Seconds after which nothing in the backdrop or mark moves again.
const double kStartupSettledAt = 1.0;

const double _latticeAt = 0.05;
const double _latticeSpread = 0.35;
const double _dotIn = 0.25;
const double _markAt = 0.4;
const double _dotPop = 0.3;
const double _squareAt = _markAt + 0.2;
const double _squarePop = 0.35;

class _Cell {
  const _Cell(this.at, this.alpha, this.distance);

  final Offset at;
  final double alpha;
  final double distance;
}

final List<_Cell> _cells = () {
  final cells = <_Cell>[];
  for (var i = -9; i <= 9; i++) {
    for (var j = -5; j <= 8; j++) {
      final at = Offset(226 + i * _pitch, 116 + j * _pitch);
      if (at.dx < 10 || at.dx > kStartupCanvas.width - 10) continue;
      if (at.dy < 10 || at.dy > kStartupCanvas.height - 10) continue;
      // The four points the mark assembles from are drawn by the mark itself.
      if ((i == 0 || i == 1) && (j == 0 || j == 1)) continue;
      final distance = (at - _rippleCentre).distance;
      final t = math.min(1.0, distance / _rippleReach);
      final alpha = 0.55 * (1 - t) * (1 - t);
      if (alpha < 0.06) continue;
      cells.add(_Cell(at, alpha, distance));
    }
  }
  return cells;
}();

final double _maxDistance = _cells.map((c) => c.distance).reduce(math.max);

double _progress(double t, double start, double duration, Curve curve) =>
    curve.transform(((t - start) / duration).clamp(0.0, 1.0));

double _lerp(double a, double b, double p) => a + (b - a) * p;

/// Paints the lattice and the assembling mark at [seconds] into the startup
/// timeline; at or past [kStartupSettledAt] it is the finished still.
class StartupLatticePainter extends CustomPainter {
  const StartupLatticePainter({
    required this.seconds,
    required this.dot,
    required this.accent,
  });

  final double seconds;
  final Color dot;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final t = seconds;
    final dim = _lerp(1, 0.5, _progress(t, _markAt, 0.3, Curves.easeOutCubic));
    final paint = Paint();
    for (final cell in _cells) {
      final p = _progress(
        t,
        _latticeAt + cell.distance / _maxDistance * _latticeSpread,
        _dotIn,
        Curves.easeOutCubic,
      );
      if (p <= 0) continue;
      paint.color = dot.withValues(alpha: cell.alpha * dim * p);
      canvas.drawCircle(cell.at, 2.8 * p, paint);
    }
    _paintMark(canvas, t);
  }

  void _paintMark(Canvas canvas, double t) {
    const seedAlpha = 0.5;
    final seed = _progress(t, _latticeAt, _dotIn, Curves.easeOutCubic);
    final paint = Paint();
    const dots = [(9.0, 9.0, 0.0), (21.0, 9.0, 0.06), (9.0, 21.0, 0.12)];
    for (final (x, y, delay) in dots) {
      final p = _progress(t, _markAt + delay, _dotPop, Curves.easeOutBack);
      paint.color = p > 0.02
          ? accent.withValues(alpha: _lerp(seedAlpha, 1, math.min(1, p)))
          : dot.withValues(alpha: seedAlpha * seed);
      final radius = _lerp(2.8, 3.2 * _unit, p);
      canvas.drawCircle(
        _markOrigin + Offset(x * _unit, y * _unit),
        radius,
        paint,
      );
    }
    final pop = _progress(t, _squareAt, _squarePop, Curves.easeOutBack);
    final tint = _progress(t, _squareAt, 0.15, Curves.easeOutCubic);
    paint.color = tint > 0.02
        ? accent.withValues(alpha: _lerp(seedAlpha, 1, tint))
        : dot.withValues(alpha: seedAlpha * seed);
    // Centred where AppBrandMark draws its square, so the still matches the real mark exactly.
    final centre = _markOrigin + const Offset(20.5 * _unit, 20.5 * _unit);
    final side = _lerp(5.6, 11 * _unit, pop);
    final corner = _lerp(2.8, 3.5 * _unit, pop);
    canvas
      ..save()
      ..translate(centre.dx, centre.dy)
      ..rotate(_lerp(math.pi / 2, 0, pop))
      ..drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset.zero, width: side, height: side),
          Radius.circular(corner),
        ),
        paint,
      )
      ..restore();
  }

  @override
  bool shouldRepaint(StartupLatticePainter oldDelegate) =>
      oldDelegate.seconds != seconds ||
      oldDelegate.dot != dot ||
      oldDelegate.accent != accent;
}
