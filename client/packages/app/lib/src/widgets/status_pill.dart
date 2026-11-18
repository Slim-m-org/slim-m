// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The compact notice pill, and the severity that colours it and decides how long a banner stays.
///
/// [StatusBanner] puts it in flow with a lifetime; the canvas floats it over the board.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

/// How a notice looks and how long a banner stays. Error has no timer by design.
enum BannerSeverity {
  info(Duration(seconds: 6)),
  success(Duration(seconds: 6)),
  warning(Duration(seconds: 15)),
  error(null);

  const BannerSeverity(this.autoDismiss);

  /// Null means the banner stays until dismissed or removed by its caller.
  final Duration? autoDismiss;
}

/// The widest a notice grows, so a long message wraps instead of spanning the stage.
const double kStatusBannerMaxWidth = 560;

/// One notice: the severity's icon, the message, an optional action and a close button when [onDismiss] is set.
class StatusPill extends StatelessWidget {
  const StatusPill({
    super.key,
    required this.message,
    this.severity = BannerSeverity.info,
    this.icon,
    this.action,
    this.onDismiss,
  });

  final String message;
  final BannerSeverity severity;
  final IconData? icon;

  /// One compact control that sits before the close button.
  final Widget? action;

  /// Shows the close button, which calls this.
  final VoidCallback? onDismiss;

  /// The close button, for a caller's test to find inside its own notice.
  static const dismissKey = Key('status-banner-dismiss');

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final (glyph, tone, border) = switch (severity) {
      BannerSeverity.info => (
        AppIcons.info,
        tokens.textSecondary,
        tokens.borderSubtle,
      ),
      BannerSeverity.success => (
        AppIcons.check,
        tokens.accent,
        tokens.accentFill,
      ),
      BannerSeverity.warning => (
        AppIcons.warning,
        tokens.warnText,
        tokens.warnText,
      ),
      BannerSeverity.error => (
        AppIcons.failed,
        tokens.dangerText,
        tokens.dangerBorder,
      ),
    };
    return Semantics(
      liveRegion: true,
      container: true,
      child: Container(
        constraints: const BoxConstraints(maxWidth: kStatusBannerMaxWidth),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.s12,
          vertical: AppSpacing.s8,
        ),
        decoration: BoxDecoration(
          color: tokens.surfaceRaised,
          border: Border.all(color: border),
          borderRadius: BorderRadius.circular(AppRadii.control),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: AppSpacing.s8,
          children: [
            Icon(icon ?? glyph, size: AppSizes.icon16, color: tone),
            Flexible(
              child: Text(
                message,
                style: AppText.caption.copyWith(color: tokens.textPrimary),
              ),
            ),
            ?action,
            if (onDismiss case final dismiss?)
              AppIconButton(
                key: dismissKey,
                icon: AppIcons.dismiss,
                semanticLabel: 'Dismiss',
                size: AppIconButtonSize.sm,
                onPressed: dismiss,
              ),
          ],
        ),
      ),
    );
  }
}
