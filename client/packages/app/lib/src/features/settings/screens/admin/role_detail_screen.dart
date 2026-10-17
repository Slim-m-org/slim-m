// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One role, routed: what a phone-width [RolesPane] pushes instead of
/// embedding [RoleDetail] under its own second app bar. See
/// `dock_module_screen.dart` for the identical shape one level up the Dock's
/// own drill-down.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../../providers/admin_providers.dart';
import '../../../../routing/routes.dart';
import '../settings_screen_scaffold.dart';
import 'role_detail.dart';

class RoleDetailScreen extends ConsumerWidget {
  const RoleDetailScreen({super.key, required this.roleId});

  final String roleId;

  api.Role? _find(List<api.Role>? roles) =>
      roles?.where((r) => r.id == roleId).firstOrNull;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final roles = ref.watch(rolesProvider);

    return SettingsScreenScaffold(
      title: _find(roles.valueOrNull)?.name ?? 'Role',
      backTooltip: 'Back to roles',
      backFallback: Routes.adminRoles,
      scrollable: false,
      child: AppAsyncView<List<api.Role>>(
        value: AppAsyncState(data: roles.valueOrNull, error: roles.error),
        center: false,
        errorMessage: 'Could not load this role.',
        onRetry: () => ref.invalidate(rolesProvider),
        data: (context, list) {
          final role = _find(list);
          if (role == null) {
            // Deleted from elsewhere while this screen was open; nothing left to show.
            WidgetsBinding.instance.addPostFrameCallback(
              (_) => closeToRoles(context),
            );
            return const SizedBox.shrink();
          }
          return RoleDetail(role: role);
        },
      ),
    );
  }
}

/// Leaves a role's screen for the list it was opened from, falling back to
/// the roles route when there is nothing to pop (a cold deep link).
void closeToRoles(BuildContext context) {
  final navigator = Navigator.of(context);
  if (navigator.canPop()) {
    navigator.pop();
  } else {
    GoRouter.of(context).go(Routes.adminRoles);
  }
}
