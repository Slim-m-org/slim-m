// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A gallery section's title line, with its count and buttons centred on
/// it, and the dashed tile a section shows when it holds nothing.
library;

import 'dart:ui' show PathMetric;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

class ThemeGallerySectionHeader extends StatelessWidget {
  const ThemeGallerySectionHeader({
    super.key,
    required this.title,
    this.count,
    this.actions = const [],
    this.first = false,
  });

  final String title;

  /// Beside the title in caption: '2 of 50', 'Shared by members'.
  final String? count;
  final List<Widget> actions;

  /// The first section sits closer to the filter above it.
  final bool first;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Padding(
      padding: EdgeInsets.only(
        top: first ? AppSpacing.s16 : AppSpacing.s24,
        bottom: 10,
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: AppSizes.controlMd),
        child: Row(
          spacing: AppSpacing.s8,
          children: [
            Semantics(
              header: true,
              child: Text(
                title,
                style: AppText.ui.copyWith(
                  color: tokens.textPrimary,
                  fontWeight: AppWeights.semi,
                ),
              ),
            ),
            Expanded(
              child: Text(
                count ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.caption.copyWith(color: tokens.textSecondary),
              ),
            ),
            ...actions,
          ],
        ),
      ),
    );
  }
}

/// A section with nothing in it: what it holds and how to add one, in a
/// dashed tile inset like a card.
class ThemeGalleryEmptyTile extends StatelessWidget {
  const ThemeGalleryEmptyTile({
    super.key,
    required this.title,
    required this.next,
  });

  final String title;

  /// The step that fills the section.
  final String next;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return CustomPaint(
      foregroundPainter: _DashedEdge(tokens.borderStrong),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.s16,
          vertical: AppSpacing.s20,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: AppText.ui.copyWith(color: tokens.textPrimary)),
            const SizedBox(height: 2),
            Text(
              next,
              style: AppText.caption.copyWith(color: tokens.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}

/// A one-pixel dashed rounded edge; Flutter has no dashed [Border].
class _DashedEdge extends CustomPainter {
  const _DashedEdge(this.colour);

  final Color colour;

  static const _dash = 4.0;
  static const _gap = 3.0;

  @override
  void paint(Canvas canvas, Size size) {
    final edge = RRect.fromRectAndRadius(
      (Offset.zero & size).deflate(0.5),
      const Radius.circular(AppRadii.card),
    );
    final paint = Paint()
      ..color = colour
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final PathMetric metric in (Path()..addRRect(edge)).computeMetrics()) {
      for (var d = 0.0; d < metric.length; d += _dash + _gap) {
        canvas.drawPath(metric.extractPath(d, d + _dash), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DashedEdge old) => old.colour != colour;
}
