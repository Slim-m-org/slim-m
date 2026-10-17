// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The rail (and, for the tree style, the elbows) that ties a run of
/// continuation rows to the avatar above them.
///
/// Every coordinate comes from the row's real layout, so the rail stays on the
/// avatar column's centre at each density and the elbow stops short of the
/// text at each scale.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../settings/providers/display_density.dart';

/// Where a continuation row's marker sits, derived from its own layout.
class ContinuationGeometry {
  const ContinuationGeometry({
    required this.railLeft,
    required this.midline,
    required this.elbowWidth,
  });

  /// The rail's centre sits on the avatar column's centre.
  factory ContinuationGeometry.of(
    BuildContext context, {
    required double gutter,
    required AppDensity density,
  }) {
    final avatar = density.avatarSize;
    final bodyLine =
        MediaQuery.textScalerOf(context).scale(AppText.body.fontSize!) *
        AppText.body.height!;
    final textLeft = avatar + AppSpacing.s12;
    return ContinuationGeometry(
      railLeft: gutter + avatar / 2 - ContinuationRail.thickness / 2,
      midline: density.groupedRowGap + bodyLine / 2,
      elbowWidth:
          textLeft - ContinuationRail.textGap - avatar / 2 + _halfThickness,
    );
  }

  static const _halfThickness = ContinuationRail.thickness / 2;

  final double railLeft;

  /// Distance from the row's top to its first line's vertical centre.
  final double midline;

  /// Rail left edge to the elbow's tip.
  final double elbowWidth;
}

class ContinuationRail extends StatelessWidget {
  const ContinuationRail({
    super.key,
    required this.marker,
    required this.geometry,
    required this.lastInGroup,
  });

  static const double thickness = 2;
  static const double elbowRadius = 8;

  /// Space left between the elbow's tip and the text.
  static const double textGap = 9;

  static const Key railKey = Key('continuation_rail');

  final ContinuationMarker marker;
  final ContinuationGeometry geometry;

  /// True on the last continuation row, where the rail ends instead of
  /// joining the next row.
  final bool lastInGroup;

  @override
  Widget build(BuildContext context) {
    final tree = marker == ContinuationMarker.tree;
    final color = Theme.of(context).extension<AppTokens>()!.borderSubtle;
    final height = lastInGroup
        ? geometry.midline + (tree ? thickness / 2 : 0)
        : null;
    return Positioned(
      left: geometry.railLeft,
      top: 0,
      bottom: lastInGroup ? null : 0,
      width: tree ? geometry.elbowWidth : thickness,
      height: height,
      child: IgnorePointer(
        child: CustomPaint(
          key: railKey,
          painter: _RailPainter(
            color: color,
            tree: tree,
            lastInGroup: lastInGroup,
            midline: geometry.midline,
          ),
        ),
      ),
    );
  }
}

class _RailPainter extends CustomPainter {
  const _RailPainter({
    required this.color,
    required this.tree,
    required this.lastInGroup,
    required this.midline,
  });

  final Color color;
  final bool tree;
  final bool lastInGroup;
  final double midline;

  @override
  void paint(Canvas canvas, Size size) {
    const t = ContinuationRail.thickness;
    final paint = Paint()..color = color;
    if (!tree) {
      const cap = Radius.circular(t / 2);
      canvas.drawRRect(
        RRect.fromLTRBAndCorners(
          0,
          0,
          t,
          size.height,
          bottomLeft: lastInGroup ? cap : Radius.zero,
          bottomRight: lastInGroup ? cap : Radius.zero,
        ),
        paint,
      );
      return;
    }
    const r = ContinuationRail.elbowRadius;
    const x = t / 2;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = t;
    final path = Path();
    if (!lastInGroup) {
      path
        ..moveTo(x, 0)
        ..lineTo(x, size.height);
    }
    path
      ..moveTo(x, 0)
      ..lineTo(x, midline - r)
      ..arcToPoint(
        Offset(x + r, midline),
        radius: const Radius.circular(r),
        clockwise: false,
      )
      ..lineTo(size.width, midline);
    canvas.drawPath(path, stroke);
  }

  @override
  bool shouldRepaint(_RailPainter old) =>
      old.color != color ||
      old.tree != tree ||
      old.lastInGroup != lastInGroup ||
      old.midline != midline;
}
