// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Puts [NewDeviceSignInBanner] above the signed-in shell while another
/// device has just signed into this account.
///
/// Mounts no banner, and so no `SafeArea`, when there is nothing to show: a
/// `SafeArea` wrapped around nothing still reserves a status-bar band on every
/// phone. The child's own parent chain never changes, see [BannerHostLayout].
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_design_system/design_system.dart';

import '../format.dart';
import '../providers/display_preferences.dart';
import '../providers/new_device_alert.dart';
import '../routing/routes.dart';
import 'banner_host_layout.dart';
import 'message_row_identity.dart' show formatMessageDay;

class NewDeviceBannerHost extends ConsumerWidget {
  const NewDeviceBannerHost({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final alert = ref.watch(newDeviceAlertProvider);
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return BannerHostLayout(
      banner: alert == null
          ? null
          : Material(
              // Solid, so the callout's translucent warn fill never lands on the bare window.
              color: tokens.surfaceBase,
              child: SafeArea(
                bottom: false,
                child: NewDeviceSignInBanner(alert: alert),
              ),
            ),
      child: child,
    );
  }
}

/// "Signed in from Laptop (Desktop) at ..." with the two answers to it.
class NewDeviceSignInBanner extends ConsumerWidget {
  const NewDeviceSignInBanner({super.key, required this.alert});

  final NewDeviceSignIn alert;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final when = signInWhen(
      alert.signedInAt,
      use24Hour: watchUse24Hour(ref, context),
    );
    final controller = ref.read(newDeviceAlertProvider.notifier);
    return AppCallout(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'New sign-in: ${newDeviceLabel(alert)} signed in to your account '
            '$when.',
          ),
          Wrap(
            spacing: AppSpacing.s8,
            children: [
              AppButton(
                label: "This wasn't me",
                variant: AppButtonVariant.danger,
                size: AppButtonSize.sm,
                onPressed: () {
                  controller.dismiss();
                  context.push(Routes.personalSettingsPane(accountDevicesPane));
                },
              ),
              AppButton(
                label: 'This was me',
                variant: AppButtonVariant.ghost,
                size: AppButtonSize.sm,
                onPressed: controller.dismiss,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// "today at 9:25 PM", "yesterday at ...", or "on September 30 at ...": the
/// day wording the transcript's dividers use, with the user's clock choice.
String signInWhen(int epochMs, {required bool use24Hour, DateTime? now}) {
  final day = formatMessageDay(epochMs, now: now);
  final dayPhrase = switch (day) {
    'Today' => 'today',
    'Yesterday' => 'yesterday',
    _ => 'on $day',
  };
  final clock = formatClock(
    DateTime.fromMillisecondsSinceEpoch(epochMs),
    use24Hour: use24Hour,
  );
  return '$dayPhrase at $clock';
}

/// The device's name, with the platform it reported when that adds something.
String newDeviceLabel(NewDeviceSignIn alert) {
  final kind = switch (alert.clientKind) {
    'ios' => 'iOS',
    'android' => 'Android',
    'desktop' => 'desktop',
    'web' => 'web',
    _ => null,
  };
  return kind == null ? alert.deviceName : '${alert.deviceName} ($kind)';
}
