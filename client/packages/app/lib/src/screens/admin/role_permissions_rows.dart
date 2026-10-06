// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Permissions tab's presentational rows: a group header, the
/// Administrator row, one fixed-bitmask permission row, and one module
/// permission row. Split out of `role_permissions_tab.dart`, which owns the
/// pending-changes state these render, when that file reached the 500-line
/// hard limit.
library;

import 'package:flutter/material.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../permissions.dart';

class GroupHeader extends StatelessWidget {
  const GroupHeader({super.key, required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.s12, bottom: 6),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: tokens.borderSubtle)),
        ),
        child: Padding(
          padding: const EdgeInsets.only(top: AppSpacing.s12),
          child: Text(
            title.toUpperCase(),
            style: AppText.label.copyWith(color: tokens.textSecondary),
          ),
        ),
      ),
    );
  }
}

class AdministratorRow extends StatelessWidget {
  const AdministratorRow({
    super.key,
    required this.value,
    required this.dimmed,
    required this.onChanged,
  });

  final bool value;
  final bool dimmed;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.s4),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s12,
        vertical: AppSpacing.s12,
      ),
      decoration: BoxDecoration(
        border: Border.all(color: tokens.borderSubtle),
        borderRadius: BorderRadius.circular(AppRadii.card),
        color: tokens.surfaceBase,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Administrator',
                  style: AppText.ui.copyWith(
                    color: dimmed ? tokens.textSecondary : tokens.textPrimary,
                    fontWeight: AppWeights.medium,
                  ),
                ),
                Text(
                  'Every permission below, in every channel, ignoring overrides.',
                  style: AppText.caption.copyWith(color: tokens.textSecondary),
                ),
              ],
            ),
          ),
          AppToggle(
            value: value,
            onChanged: onChanged,
            semanticLabel: 'Administrator',
          ),
        ],
      ),
    );
  }
}

class PermissionListRow extends StatelessWidget {
  const PermissionListRow({
    super.key,
    required this.spec,
    required this.value,
    required this.allowed,
    required this.onChanged,
  });

  final PermSpec spec;
  final bool value;
  final bool allowed;
  final ValueChanged<bool> onChanged;

  /// Below this, the label/description column and the "you don't hold this"
  /// hint cannot both fit beside the toggle on one line without truncating
  /// either into illegibility - the hint wraps to its own line instead. Not
  /// a breakpoint token: this is one row's own content fitting its own
  /// width, the same class of decision `PermissionRow`'s doc reserves for a
  /// control rather than a layout tier.
  static const double _stackHintBelowWidth = 380;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    // Wrap, not Row: a fixed-width badge beside a label that can't shrink below its own text overflows a Row at a narrow enough width; wrapping it to its own line never does.
    final label = Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: AppSpacing.s8,
      children: [
        Text(
          spec.label,
          style: AppText.ui.copyWith(
            color: allowed ? tokens.textPrimary : tokens.textSecondary,
          ),
        ),
        if (spec.elevated)
          const AppBadge(variant: AppBadgeVariant.warn, label: 'elevated'),
      ],
    );
    final description = Text(
      spec.description,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: AppText.caption.copyWith(color: tokens.textSecondary),
    );
    final hint = allowed
        ? null
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                AppIcons.restrictedChannel,
                size: AppSizes.icon16,
                color: tokens.textDisabled,
              ),
              const SizedBox(width: AppSpacing.s4),
              Text(
                "you don't hold this",
                style: AppText.caption.copyWith(color: tokens.textSecondary),
              ),
            ],
          );
    final toggle = AppToggle(
      value: value,
      semanticLabel: spec.label,
      onChanged: allowed ? onChanged : null,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.s4),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth >= _stackHintBelowWidth) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [label, description],
                  ),
                ),
                if (hint != null) ...[
                  hint,
                  const SizedBox(width: AppSpacing.s12),
                ],
                toggle,
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              label,
              description,
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.s4),
                child: Row(
                  children: [
                    if (hint != null) Expanded(child: hint) else const Spacer(),
                    toggle,
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class ModulePermissionListRow extends StatelessWidget {
  const ModulePermissionListRow({
    super.key,
    required this.permission,
    required this.value,
    required this.onChanged,
  });

  final api.ModulePermission permission;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.s4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  permission.name,
                  style: AppText.ui.copyWith(color: tokens.textPrimary),
                ),
                Text(
                  permission.description.isEmpty
                      ? permission.moduleName
                      : permission.description,
                  style: AppText.caption.copyWith(color: tokens.textSecondary),
                ),
              ],
            ),
          ),
          AppToggle(
            value: value,
            onChanged: onChanged,
            semanticLabel: '${permission.name} (${permission.moduleName})',
          ),
        ],
      ),
    );
  }
}
