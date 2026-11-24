// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One role, routed: what a phone-width [RolesPane] pushes instead of
/// embedding [RoleDetail] under its own second app bar. See
/// `dock_module_screen.dart` for the identical shape one level up the Dock's
/// own drill-down.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../../providers/admin_providers.dart';
import '../../../../routing/routes.dart';
import '../settings_screen_scaffold.dart';
import 'role_detail.dart';

class RoleDetailScreen extends ConsumerStatefulWidget {
  const RoleDetailScreen({super.key, required this.roleId});

  final String roleId;

  @override
  ConsumerState<RoleDetailScreen> createState() => _RoleDetailScreenState();
}

class _RoleDetailScreenState extends ConsumerState<RoleDetailScreen> {
  bool _leaving = false;

  api.Role? _find(List<api.Role>? roles) =>
      roles?.where((r) => r.id == widget.roleId).firstOrNull;

  void _leaveOnce() {
    if (_leaving) return;
    _leaving = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) closeToRoles(context);
    });
  }

  @override
  Widget build(BuildContext context) {
    final roles = ref.watch(rolesProvider);

    return SettingsScreenScaffold(
      title: _find(roles.valueOrNull)?.name ?? 'Role',
      backTooltip: 'Back to roles',
      backFallback: Routes.adminRoles,
      // Asks the role's PopScope first, so unsaved edits are never dropped unasked.
      onBack: () => unawaited(_back(context)),
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
            _leaveOnce();
            return const SizedBox.shrink();
          }
          return RoleDetail(role: role);
        },
      ),
    );
  }
}

Future<void> _back(BuildContext context) async {
  if (await Navigator.of(context).maybePop() || !context.mounted) return;
  context.go(Routes.adminRoles);
}
