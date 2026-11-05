// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Puts [AdminAlertBanner] above the signed-in shell while an operator alert is open.
///
/// Mounts nothing when there is nothing to show, the same rule as the other banner hosts.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../routing/routes.dart';
import '../../../widgets/banner_host_layout.dart';
import '../providers/admin_alerts.dart';

class AdminAlertBannerHost extends ConsumerWidget {
  const AdminAlertBannerHost({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final alerts = ref.watch(bannerAdminAlertsProvider);
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return BannerHostLayout(
      banner: alerts.isEmpty
          ? null
          : Material(
              color: tokens.surfaceBase,
              child: SafeArea(
                bottom: false,
                child: AdminAlertBanner(alerts: alerts),
              ),
            ),
      child: child,
    );
  }
}

/// The newest open alert in a sentence, a count of the rest, and the two answers.
class AdminAlertBanner extends ConsumerWidget {
  const AdminAlertBanner({super.key, required this.alerts});

  final List<api.AdminAlert> alerts;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final more = alerts.length - 1;
    final message = Text.rich(
      TextSpan(
        children: [
          const TextSpan(
            text: 'Server alert: ',
            style: TextStyle(fontWeight: AppWeights.semi),
          ),
          TextSpan(
            text: more > 0
                ? '${alerts.first.detail} (+$more more)'
                : alerts.first.detail,
            style: TextStyle(color: tokens.textPrimary),
          ),
        ],
      ),
    );
    final actions = Wrap(
      spacing: AppSpacing.s8,
      children: [
        AppButton(
          key: const Key('admin-alert-view'),
          label: 'View',
          variant: AppButtonVariant.secondary,
          size: AppButtonSize.sm,
          onPressed: () => context.push(Routes.adminStorage),
        ),
        AppButton(
          key: const Key('admin-alert-dismiss'),
          label: 'Dismiss',
          variant: AppButtonVariant.secondary,
          size: AppButtonSize.sm,
          onPressed: () => dismissAdminAlerts(ref, alerts),
        ),
      ],
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final inline = constraints.maxWidth >= _inlineWidth;
        return AppCallout(
          key: const Key('admin-alert-banner'),
          centred: inline,
          child: inline
              ? Row(
                  children: [
                    Expanded(child: message),
                    const SizedBox(width: AppSpacing.s12),
                    actions,
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    message,
                    const SizedBox(height: AppSpacing.s8),
                    actions,
                  ],
                ),
        );
      },
    );
  }
}

/// Below this the alert and its two answers stop fitting on one line.
const double _inlineWidth = 640;
