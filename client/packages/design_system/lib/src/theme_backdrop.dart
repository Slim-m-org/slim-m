// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The decorative layer a theme can paint over the app, drawn procedurally so
/// no image asset ships with it.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'app_tokens.dart';

/// Which backdrop a theme carries; [AppTokens.backdrop] is null for none.
enum AppBackdrop { halloweenWebs }

/// Paints the current theme's [AppTokens.backdrop] above its child, and
/// nothing when the theme has none.
///
/// A foreground overlay because the shell paints opaque surfaces over anything
/// behind it. It is static, inert to pointers and hidden from semantics.
class ThemeBackdrop extends StatelessWidget {
  const ThemeBackdrop({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final backdrop = Theme.of(context).extension<AppTokens>()?.backdrop;
    if (backdrop == null) return child;
    return Stack(
      fit: StackFit.passthrough,
      children: [
        child,
        Positioned.fill(
          child: IgnorePointer(
            child: ExcludeSemantics(
              child: RepaintBoundary(
                child: CustomPaint(
                  key: const Key('theme_backdrop'),
                  painter: switch (backdrop) {
                    AppBackdrop.halloweenWebs => const HalloweenWebsPainter(),
                  },
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Cobwebs in the top-right and bottom-left corners and a few specks, at a
/// very low alpha so text over them stays legible.
class HalloweenWebsPainter extends CustomPainter {
  const HalloweenWebsPainter();

  static const _ink = Color(0xFFF4EADB);
  static const _threadAlpha = 0.09;
  static const _speckAlpha = 0.07;
  static const _threads = 7;
  static const _rings = 5;

  @override
  void paint(Canvas canvas, Size size) {
    final reach = math.min(240.0, size.shortestSide * 0.6);
    if (reach <= 0) return;
    _web(canvas, Offset(size.width, 0), reach, math.pi / 2, math.pi);
    _web(canvas, Offset(0, size.height), reach * 0.8, -math.pi / 2, 0);
    _specks(canvas, size);
  }

  void _web(
      Canvas canvas, Offset anchor, double reach, double from, double to) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = _ink.withValues(alpha: _threadAlpha);
    final step = (to - from) / (_threads - 1);
    final spokes = [
      for (var i = 0; i < _threads; i++)
        anchor + Offset.fromDirection(from + step * i, reach),
    ];
    for (final tip in spokes) {
      canvas.drawLine(anchor, tip, paint);
    }
    for (var ring = 1; ring <= _rings; ring++) {
      final k = ring / _rings;
      final path = Path();
      for (var i = 0; i < _threads; i++) {
        final point = anchor + (spokes[i] - anchor) * k;
        if (i == 0) {
          path.moveTo(point.dx, point.dy);
          continue;
        }
        final prev = anchor + (spokes[i - 1] - anchor) * k;
        final mid = Offset.lerp(prev, point, 0.5)!;
        // Each strand sags toward the anchor, the way silk hangs between spokes.
        final sag = anchor + (mid - anchor) * 0.82;
        path.quadraticBezierTo(sag.dx, sag.dy, point.dx, point.dy);
      }
      canvas.drawPath(path, paint);
    }
  }

  void _specks(Canvas canvas, Size size) {
    final paint = Paint()..color = _ink.withValues(alpha: _speckAlpha);
    const spots = [
      Offset(0.12, 0.18),
      Offset(0.31, 0.07),
      Offset(0.58, 0.13),
      Offset(0.83, 0.34),
      Offset(0.94, 0.62),
      Offset(0.72, 0.9),
      Offset(0.44, 0.82),
      Offset(0.21, 0.57),
    ];
    for (var i = 0; i < spots.length; i++) {
      final at = Offset(spots[i].dx * size.width, spots[i].dy * size.height);
      canvas.drawCircle(at, i.isEven ? 1.5 : 1, paint);
    }
  }

  @override
  bool shouldRepaint(HalloweenWebsPainter oldDelegate) => false;
}
