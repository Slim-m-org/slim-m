// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Permissions tab's one row shape: a named, described permission with a
/// toggle, used for Administrator, every fixed-bitmask permission and every
/// module permission alike.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../widgets/settings_detail_row.dart';

/// A permission the caller does not hold is dimmed, locked and says why,
/// rather than left to answer a refusal on save.
class PermissionToggleRow extends StatelessWidget {
  const PermissionToggleRow({
    super.key,
    required this.title,
    required this.description,
    required this.value,
    required this.onChanged,
    required this.semanticLabel,
    this.elevated = false,
    this.held = true,
  });

  final String title;
  final String description;
  final bool value;
  final ValueChanged<bool> onChanged;
  final String semanticLabel;

  /// Flags a permission that can do damage in the wrong hands.
  final bool elevated;

  /// Whether the caller holds the permission themselves.
  final bool held;

  static const notHeldHint = "you don't hold this";

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return SettingsDetailRow(
      title: title,
      detail: description,
      dimmed: !held,
      badge: elevated
          ? const AppBadge(variant: AppBadgeVariant.warn, label: 'elevated')
          : null,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: AppSpacing.s8,
        children: [
          if (!held)
            Tooltip(
              message: notHeldHint,
              triggerMode: TooltipTriggerMode.tap,
              child: Icon(
                AppIcons.restrictedChannel,
                size: AppSizes.icon16,
                color: tokens.textSecondary,
                semanticLabel: notHeldHint,
              ),
            ),
          AppToggle(
            value: value,
            semanticLabel: semanticLabel,
            onChanged: held ? onChanged : null,
          ),
        ],
      ),
    );
  }
}
