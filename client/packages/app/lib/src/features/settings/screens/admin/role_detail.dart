// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The selected role's own surface: a header naming it, and its
/// Permissions/Members/Display tabs, read-only for a role not below the
/// viewer's highest. See `roles_screen.dart` for the pane this sits in.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:go_router/go_router.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../../permissions.dart';
import '../../../../providers/admin_providers.dart';
import '../../../../routing/routes.dart';
import '../../../role_preview/providers/role_preview_controller.dart';
import '../../../members/widgets/role_color.dart';
import '../../widgets/settings_tab_strip.dart';
import 'role_display_tab.dart';
import 'role_members_tab.dart';
import 'role_permissions_tab.dart';

enum _RoleDetailTab { permissions, members, display }

/// Says why a role's controls are absent, once, under its name.
const lockedRoleCaption = 'Only roles below your highest role can be changed.';

/// Opens the shell as this role sees it (decision 0124).
const viewAsRoleKey = Key('role-detail-view-as');

class RoleDetail extends ConsumerStatefulWidget {
  const RoleDetail({super.key, required this.role});

  final api.Role role;

  @override
  ConsumerState<RoleDetail> createState() => _RoleDetailState();
}

class _RoleDetailState extends ConsumerState<RoleDetail> {
  var _tab = _RoleDetailTab.permissions;

  @override
  void didUpdateWidget(RoleDetail oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Selecting a different role starts back on Permissions, like switching settings panes.
    if (oldWidget.role.id != widget.role.id) {
      setState(() => _tab = _RoleDetailTab.permissions);
    }
  }

  void _viewAs(api.Role role) {
    unawaited(ref.read(rolePreviewProvider.notifier).enter(role));
    context.go(Routes.channels);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    // Reads the live copy so edits from another client (roleChangeWatcherProvider) show here too.
    final roles = ref.watch(rolesProvider).valueOrNull;
    final role =
        roles?.where((r) => r.id == widget.role.id).firstOrNull ?? widget.role;
    final ladder = ref.watch(roleLadderProvider);
    final locked = !ladder.reachesRole(role);
    final canPreview =
        ladder.permissions.hasPermission(Perm.manageRoles) &&
        (role.isEveryone || !locked);
    // Beside the name where there is room, under it on a phone so a long name keeps its width.
    final previewInline = MediaQuery.sizeOf(context).width >= kCompactWidth;
    final preview = AppButton(
      key: viewAsRoleKey,
      label: 'View server as this role',
      icon: AppIcons.preview,
      size: AppButtonSize.sm,
      onPressed: () => _viewAs(role),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.s24,
            AppSpacing.s20,
            AppSpacing.s24,
            AppSpacing.s12,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: AppSpacing.s4,
            children: [
              Row(
                children: [
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: roleDotColor(role.color, tokens),
                      shape: BoxShape.circle,
                    ),
                    child: const SizedBox(width: 14, height: 14),
                  ),
                  const SizedBox(width: AppSpacing.s12),
                  Expanded(
                    child: Text(
                      role.name,
                      style: AppText.heading.copyWith(
                        color: tokens.textPrimary,
                        fontWeight: AppWeights.semi,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (canPreview && previewInline) ...[
                    const SizedBox(width: AppSpacing.s12),
                    preview,
                  ],
                ],
              ),
              if (locked)
                Text(
                  lockedRoleCaption,
                  style: AppText.caption.copyWith(color: tokens.textSecondary),
                ),
              if (canPreview && !previewInline)
                Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.s8),
                  child: preview,
                ),
            ],
          ),
        ),
        SettingsTabStrip<_RoleDetailTab>(
          selected: _tab,
          onSelected: (tab) => setState(() => _tab = tab),
          tabs: [
            (_RoleDetailTab.permissions, 'Permissions'),
            (_RoleDetailTab.members, 'Members · ${role.memberCount}'),
            (_RoleDetailTab.display, 'Display'),
          ],
        ),
        Expanded(
          child: AppFadeIn(
            key: ValueKey(_tab),
            duration: AppMotion.fast,
            offset: 0,
            child: switch (_tab) {
              _RoleDetailTab.permissions => RolePermissionsTab(
                role: role,
                locked: locked,
              ),
              _RoleDetailTab.members => RoleMembersTab(
                role: role,
                locked: locked,
              ),
              _RoleDetailTab.display => RoleDisplayTab(
                role: role,
                locked: locked,
              ),
            },
          ),
        ),
      ],
    );
  }
}
