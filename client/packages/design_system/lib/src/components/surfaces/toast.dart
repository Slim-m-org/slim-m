// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A transient confirmation that floats in, says one thing, and leaves.
///
/// Deliberately not for failures. This app's error grammar holds that a failure
/// is a state, not an event: it belongs at the point of the action and stays
/// until something changes it (`AppErrorState`), never on a timer that carries
/// it away. A toast is the opposite shape on purpose - it is for the things
/// that genuinely are events and are fine to miss: "Copied", "Saved", an
/// invite put on the clipboard. So the severities here stop at success, info
/// and a non-failure warning; there is no error variant, and routing a caught
/// API error through one would both contradict the grammar and trip
/// `scripts/check-error-surface.py`.
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

/// The tone a toast carries. No error member: failures use `AppErrorState`; see
/// this file's doc comment.
enum AppToastSeverity { success, info, warning }

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
    final semantic = Semantics(
      liveRegion: true,
      container: true,
      child: Material(type: MaterialType.transparency, child: card),
    );

    if (onDismiss == null) return semantic;
    return GestureDetector(
      onTap: onDismiss,
      behavior: HitTestBehavior.opaque,
      child: semantic,
    );
  }

  (IconData, Color) _iconAndTone(AppTokens tokens) => switch (severity) {
        AppToastSeverity.success => (AppIcons.check, tokens.accent),
        AppToastSeverity.info => (AppIcons.info, tokens.borderStrong),
        AppToastSeverity.warning => (AppIcons.warning, tokens.warnText),
      };
}
