// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A short message that floats over the screen and says one thing.
///
/// Mostly for events that are fine to miss: "Copied", "Saved", an invite put on
/// the clipboard; those leave on a timer. A failure belongs at the point of the
/// action as an `AppErrorState`, never on a timer that carries it away. The one
/// exception is a failure whose surface has already closed (a context menu, a
/// member card) before the request answers: it gets the [AppToastSeverity.error]
/// tone and stays until dismissed, which keeps it a state rather than an event
/// (decision 0018, 2026-11-20 update).
///
/// Outlined, never filled, following `AppErrorState`: the severity shows as a
/// hairline and a leading glyph over the ordinary raised surface, so a toast is
/// legible without being the brightest thing on the screen.
library;

import 'package:flutter/material.dart';

import '../../app_icons.dart';
import '../../app_metrics.dart';
import '../../app_tokens.dart';
import '../../app_typography.dart';

/// The widest a toast grows, so a long message wraps rather than spanning the
/// window.
const double kToastMaxWidth = 380;

/// The tone a toast carries. [error] is only for a failure whose surface has
/// closed, and never times out; see this file's doc comment.
enum AppToastSeverity { success, info, warning, error }

/// One transient confirmation. [onDismiss], when given, draws a close affordance
/// and is also what a tap on the toast calls, so a reader never has to wait out
/// the timer.
class AppToast extends StatelessWidget {
  const AppToast({
    super.key,
    required this.message,
    this.severity = AppToastSeverity.info,
    this.onDismiss,
  });

  final String message;
  final AppToastSeverity severity;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final (icon, tone) = _iconAndTone(tokens);

    final card = Container(
      constraints: const BoxConstraints(maxWidth: kToastMaxWidth),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s12,
        vertical: AppSpacing.s12,
      ),
      decoration: BoxDecoration(
        color: tokens.surfaceRaised,
        borderRadius: BorderRadius.circular(AppRadii.card),
        border: Border.all(color: tone),
        boxShadow: AppShadows.canvasTile,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: AppSizes.icon16, color: tone),
          const SizedBox(width: AppSpacing.s8),
          Flexible(
            child: Text(
              message,
              style: AppText.body.copyWith(color: tokens.textPrimary),
            ),
          ),
          if (onDismiss != null) ...[
            const SizedBox(width: AppSpacing.s8),
            Icon(
              AppIcons.dismiss,
              size: AppSizes.icon16,
              color: tokens.textSecondary,
            ),
          ],
        ],
      ),
    );

    // Overlays have no Material above; without one the text gets a yellow underline.
    final material = Material(type: MaterialType.transparency, child: card);

    // The labelled node owns the dismiss action, so a screen reader can reach it.
    return Semantics(
      liveRegion: true,
      container: true,
      onTap: onDismiss,
      onTapHint: onDismiss == null ? null : 'Dismiss',
      child: onDismiss == null
          ? material
          : GestureDetector(
              onTap: onDismiss,
              behavior: HitTestBehavior.opaque,
              excludeFromSemantics: true,
              child: material,
            ),
    );
  }

  (IconData, Color) _iconAndTone(AppTokens tokens) => switch (severity) {
        AppToastSeverity.success => (AppIcons.check, tokens.accent),
        AppToastSeverity.info => (AppIcons.info, tokens.borderStrong),
        AppToastSeverity.warning => (AppIcons.warning, tokens.warnText),
        AppToastSeverity.error => (AppIcons.failed, tokens.dangerText),
      };
}
