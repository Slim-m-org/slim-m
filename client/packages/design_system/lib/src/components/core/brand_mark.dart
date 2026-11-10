// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The slim-m mark: three dots on a lattice and one rounded square that has
/// left it.
///
/// Painted rather than loaded from the SVGs in `design_system/brand/`, which
/// are the source of record for the icon pipeline but are not bundled as
/// Flutter assets. The package's `assets:` block and flutter_svg exist for the
/// third-party logos in `BrandLogo`; four shapes of our own are exact as a
/// `CustomPainter` and need neither a bundled file nor an asset-load frame.
///
/// The geometry is copied from `brand/icon-master.svg` and must stay in step
/// with it: dots of r=3.2 centred at (9,9), (21,9) and (9,21) on a 32 grid,
/// and an 11x11 square with a 3.5 radius at (15,15). Below about 16 logical
/// pixels the dots collapse into noise, which is what `brand/glyph.svg`
/// exists for, so [AppBrandMark] drops them at [_latticeFloor] and draws the
/// square alone - scaled up, so the two versions carry the same ink weight.
library;

import 'package:flutter/material.dart';

import '../../app_tokens.dart';

/// Below this the lattice is dropped and the square carries the mark alone.
const double _latticeFloor = 16;

class AppBrandMark extends StatelessWidget {
  const AppBrandMark({super.key, this.size = 28, this.color});

  final double size;

  /// Defaults to the accent, which is the one place brand ink is allowed to
  /// come from; pass a colour for a mono treatment.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>();
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: _MarkPainter(
          color: color ?? tokens?.accent ?? AppTokens.dark.accentFill,
          lattice: size >= _latticeFloor,
        ),
      ),
    );
  }
}

class _MarkPainter extends CustomPainter {
  const _MarkPainter({required this.color, required this.lattice});

  final Color color;
  final bool lattice;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final unit = size.width / 32;

    if (lattice) {
      for (final (cx, cy) in const [(9.0, 9.0), (21.0, 9.0), (9.0, 21.0)]) {
        canvas.drawCircle(Offset(cx * unit, cy * unit), 3.2 * unit, paint);
      }
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(15 * unit, 15 * unit, 11 * unit, 11 * unit),
          Radius.circular(3.5 * unit),
        ),
        paint,
      );
      return;
    }

    // brand/glyph.svg's square: sized for equal ink, not an equal box.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(8.472 * unit, 8.472 * unit, 15.056 * unit, 15.056 * unit),
        Radius.circular(4.791 * unit),
      ),
      paint,
    );
  }

  @override
  bool shouldRepaint(_MarkPainter old) =>
      old.color != color || old.lattice != lattice;
}
