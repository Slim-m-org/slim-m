// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The status strip at the top of the Notifications pane: whether this device
/// can be reached at all, in a warning tone when something needs fixing.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../providers/push_status.dart';

/// Which tone and glyph each push state reads in.
({bool warn, bool bell}) notificationBannerStyle(
  PushStatus status, {
  required bool localOnly,
}) {
  if (localOnly) return (warn: false, bell: true);
  return switch (status) {
    PushStatus.registered => (warn: false, bell: true),
    PushStatus.notSignedIn ||
    PushStatus.noTokenYet => (warn: false, bell: false),
    PushStatus.unsupportedPlatform ||
    PushStatus.registrationFailed ||
    PushStatus.serverError ||
    PushStatus.registeredNotificationsBlocked => (warn: true, bell: false),
  };
}

class NotificationStatusBanner extends StatelessWidget {
  const NotificationStatusBanner({
    super.key,
    required this.label,
    required this.warn,
    required this.bell,
  });

  final String label;
  final bool warn;
  final bool bell;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final ink = warn ? tokens.warnText : tokens.textSecondary;
    return Semantics(
      container: true,
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: warn ? tokens.warnSoft : tokens.surfaceRaised,
          border: Border.all(
            color: warn
                ? tokens.warnText.withValues(alpha: 0.5)
                : tokens.borderSubtle,
          ),
          borderRadius: BorderRadius.circular(AppRadii.card),
        ),
        child: Row(
          spacing: AppSpacing.s12,
          children: [
            Icon(
              bell ? AppIcons.notificationsOn : AppIcons.notificationsOff,
              size: AppSizes.icon20,
              color: ink,
            ),
            Expanded(
              child: Text(
                label,
                style: AppText.ui.copyWith(
                  color: tokens.textPrimary,
                  fontWeight: warn ? AppWeights.medium : AppWeights.regular,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
