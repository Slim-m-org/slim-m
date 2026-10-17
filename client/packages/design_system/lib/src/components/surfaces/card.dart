// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A bordered content surface: the baseline building block for anything that
/// groups related content off the plain background.
///
/// Elevation here is border-first like the rest of the system: a hairline
/// plus a raised fill. The source `Card.jsx` is a purely presentational panel
/// with no click handling of its own, so this port has none either; a clickable card is a different
/// component built from this one, not a variant of it.
library;

import 'package:flutter/material.dart';

import '../../app_metrics.dart';
import '../../app_tokens.dart';
import '../../app_typography.dart';

/// A bordered content container with an optional uppercase micro title header.
class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.title,
    this.padding = const EdgeInsets.all(AppSpacing.s16),
  });

  final Widget child;

  /// An uppercase micro-label header, with its own bottom hairline. Rendered
  /// only when non-null, matching the source's `{title && (...)}`.
  final String? title;

  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;

    final card = Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: tokens.surfaceRaised,
        border: Border.all(color: tokens.borderSubtle),
        borderRadius: BorderRadius.circular(AppRadii.card),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title != null)
            Container(
              padding: const EdgeInsets.symmetric(
                vertical: AppSpacing.s12,
                horizontal: AppSpacing.s16,
              ),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: tokens.borderSubtle)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      title!.toUpperCase(),
                      overflow: TextOverflow.ellipsis,
                      style:
                          AppText.label.copyWith(color: tokens.textSecondary),
                    ),
                  ),
                ],
              ),
            ),
          Padding(padding: padding, child: child),
        ],
      ),
    );

    return Semantics(container: true, child: card);
  }
}
