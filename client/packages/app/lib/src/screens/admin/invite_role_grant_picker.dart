// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Choosing the role an invite grants, offered only when the caller could
/// actually create one.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../permissions.dart';
import '../../providers/admin_providers.dart';
import '../../widgets/settings_hairline.dart';

/// The role picker, or nothing at all.
///
/// Absent rather than disabled for a caller without MANAGE_ROLES: the server
/// refuses that combination outright, and a control that can only fail is the
/// thing this codebase keeps taking back out.
///
/// A failed roles fetch renders its own retryable error rather than the same
/// nothing a caller with genuinely no grantable role sees below, so the two
/// cannot be confused for each other.
class InviteRoleGrantPicker extends ConsumerWidget {
  const InviteRoleGrantPicker({
    super.key,
    required this.selected,
    required this.onChanged,
  });

  /// The chosen role id, or null for "grants no role".
  final String? selected;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final permissions = ref.watch(myPermissionsProvider);
    if (!permissions.hasPermission(Perm.manageRoles)) {
      return const SizedBox.shrink();
    }

    final roles = ref.watch(rolesProvider);
    return roles.when(
      loading: () => const SizedBox.shrink(),
      // See this widget's own doc comment for why this differs from below.
      error: (_, _) => Padding(
        padding: const EdgeInsets.all(AppSpacing.s16),
        child: AppErrorState(
          message: 'Could not check which roles you can grant.',
          onRetry: () => ref.invalidate(rolesProvider),
        ),
      ),
      data: (all) {
        // Only what this caller could grant: the server refuses a role
        // carrying a bit they do not hold, so offering it invites a 403.
        final grantable = all
            .where((r) => !r.isEveryone)
            .where((r) => permissions.hasPermission(r.permissions))
            .toList();
        if (grantable.isEmpty) return const SizedBox.shrink();

        final chosen = grantable.where((r) => r.id == selected).firstOrNull;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SettingsHairline(),
            AppListRow(
              label: 'Role granted',
              meta: chosen?.name ?? 'None',
              semanticLabel:
                  'Role granted, currently ${chosen?.name ?? 'none'}',
              trailing: const Icon(
                AppIcons.chevronRight,
                size: AppSizes.icon16,
              ),
              onTap: () => _open(context, grantable),
            ),
          ],
        );
      },
    );
  }

  Future<void> _open(BuildContext context, List<api.Role> grantable) async {
    final picked = await showAppSheet<_Choice>(
      context,
      bare: true,
      builder: (sheetContext) => SafeArea(
        top: false,
        child: AppSheetMenu(
          children: [
            const AppMenuLabel('Role granted on redemption'),
            AppMenuItem(
              label: 'None',
              selected: selected == null,
              onTap: () => Navigator.of(sheetContext).pop(const _Choice(null)),
            ),
            for (final role in grantable)
              AppMenuItem(
                label: role.name,
                selected: role.id == selected,
                onTap: () => Navigator.of(sheetContext).pop(_Choice(role.id)),
              ),
          ],
        ),
      ),
    );
    if (picked != null) onChanged(picked.value);
  }
}

/// A wrapper so "the sheet was dismissed" is distinguishable from "None was
/// chosen", which a bare nullable String cannot express through `pop`.
class _Choice {
  const _Choice(this.value);

  final String? value;
}
