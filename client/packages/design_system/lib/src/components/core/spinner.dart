// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one loading indicator: an accent arc at a token size that holds a static three-quarter sweep under reduce-motion.
library;

import 'dart:ui' show SemanticsRole;

import 'package:flutter/material.dart';

import '../../app_metrics.dart';
import '../../app_motion.dart';
import '../../app_tokens.dart';

enum AppSpinnerSize {
  xs(AppSizes.icon12, 1.5),
  sm(AppSizes.icon16, 2),
  md(AppSizes.icon20, 2),
  lg(AppSizes.icon24, 2.5);

  const AppSpinnerSize(this.dimension, this.stroke);

  final double dimension;
  final double stroke;
}

class AppSpinner extends StatelessWidget {
  const AppSpinner({
    super.key,
    this.size = AppSpinnerSize.md,
    this.color,
    this.semanticLabel,
  });

  final AppSpinnerSize size;

  /// Defaults to [AppTokens.accentFill], what Material spinners already resolved to; pass the ink of a filled surface.
  final Color? color;

  final String? semanticLabel;

  static const _reducedSweep = 0.75;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final spinner = ExcludeSemantics(
      // The static sweep is a drawing, not a progress value to announce.
      child: SizedBox.square(
        dimension: size.dimension,
        child: CircularProgressIndicator(
          strokeWidth: size.stroke,
          color: color ?? tokens.accentFill,
          value: AppMotion.isReduced(context) ? _reducedSweep : null,
        ),
      ),
    );
    if (semanticLabel == null) return spinner;
    return Semantics(
      label: semanticLabel,
      role: SemanticsRole.loadingSpinner,
      liveRegion: true,
      child: spinner,
    );
  }
}
