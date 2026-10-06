// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The selected role's own surface: a header naming it, and its
/// Permissions/Members/Display tabs. See `roles_screen.dart` for the pane
/// this sits in.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../providers/admin_providers.dart';
import '../../widgets/role_color.dart';
import 'role_display_tab.dart';
import 'role_members_tab.dart';
import 'role_permissions_tab.dart';

enum _RoleDetailTab { permissions, members, display }

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

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    // Reads the live copy so edits from another client (roleChangeWatcherProvider) show here too.
    final roles = ref.watch(rolesProvider).valueOrNull;
    final role =
        roles?.where((r) => r.id == widget.role.id).firstOrNull ?? widget.role;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.s16,
            AppSpacing.s16,
            AppSpacing.s16,
            AppSpacing.s12,
          ),
          child: Row(
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  color: roleColor(role.id),
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
            ],
          ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: tokens.borderSubtle)),
          ),
          child: Padding(
            // s16 and s20 less the focus ring's 4 per side, so the labels sit where they did.
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s12),
            // Scrolls rather than wraps: three tab labels plus a live count may not fit a phone's width.
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _tabLabel(context, 'Permissions', _RoleDetailTab.permissions),
                  const SizedBox(width: AppSpacing.s12),
                  _tabLabel(
                    context,
                    'Members · ${role.memberCount}',
                    _RoleDetailTab.members,
                  ),
                  const SizedBox(width: AppSpacing.s12),
                  _tabLabel(context, 'Display', _RoleDetailTab.display),
                ],
              ),
            ),
          ),
        ),
        Expanded(
          child: AppFadeIn(
            key: ValueKey(_tab),
            duration: AppMotion.fast,
            offset: 0,
            child: switch (_tab) {
              _RoleDetailTab.permissions => RolePermissionsTab(role: role),
              _RoleDetailTab.members => RoleMembersTab(role: role),
              _RoleDetailTab.display => RoleDisplayTab(role: role),
            },
          ),
        ),
      ],
    );
  }

  Widget _tabLabel(BuildContext context, String label, _RoleDetailTab tab) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final selected = _tab == tab;
    return FocusableTapTarget(
      onTap: () => setState(() => _tab = tab),
      semanticLabel: label,
      selected: selected,
      builder: (context, focused, hovered) => DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: selected ? tokens.accent : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Padding(
          // The focus ring's own gap and stroke take the other four.
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.s8),
          child: Text(
            label,
            style: AppText.ui.copyWith(
              color: selected ? tokens.textPrimary : tokens.textSecondary,
              fontWeight: selected ? AppWeights.medium : AppWeights.regular,
            ),
          ),
        ),
      ),
    );
  }
}
