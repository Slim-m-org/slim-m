// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The selected role's own surface: a header naming it, and its
/// Permissions/Members/Display tabs, read-only for a role not below the
/// viewer's highest. See `roles_screen.dart` for the pane this sits in.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../../permissions.dart';
import '../../../../providers/admin_providers.dart';
import '../../../../routing/routes.dart';
import '../../../role_preview/providers/role_preview_controller.dart';
import '../../../members/providers/member_presence.dart' show membersProvider;
import '../../../members/widgets/role_color.dart';
import '../../widgets/settings_draft_guard.dart';
import '../../widgets/settings_sub_pages.dart';
import '../../widgets/settings_tab_strip.dart';
import 'role_display_tab.dart';
import 'role_members_tab.dart';
import 'role_permissions_tab.dart';

enum _RoleDetailTab { permissions, members, display }

/// Says why a role's controls are absent, once, under its name.
const lockedRoleCaption = 'Only roles below your highest role can be changed.';

/// Opens the shell as this role sees it (decision 0124).
const viewAsRoleKey = Key('role-detail-view-as');

/// Shown on a hand-made role that no person holds.
const botOnlyRoleHint =
    'Only bots hold this role. Give the bots these permissions directly instead.';

class RoleDetail extends ConsumerStatefulWidget {
  const RoleDetail({super.key, required this.role});

  final api.Role role;

  @override
  ConsumerState<RoleDetail> createState() => _RoleDetailState();
}

class _RoleDetailState extends ConsumerState<RoleDetail> {
  var _tab = _RoleDetailTab.permissions;

  /// Held by the open tab's Save bar draft, so leaving it never drops an edit unasked.
  late final _draft = DraftLeaveGuard(() => confirmDiscardChanges(context));

  /// The settings pane this sits in; null on its own phone route, where a [PopScope] asks instead.
  late final SettingsSubPageStack? _pane = SettingsSubPages.maybeOf(context);

  @override
  void initState() {
    super.initState();
    _pane?.setPaneGuard(_draft);
  }

  @override
  void dispose() {
    _pane?.releasePaneGuard(_draft);
    _draft.dispose();
    super.dispose();
  }

  Future<void> _selectTab(_RoleDetailTab tab) async {
    if (tab == _tab || !await _draft.allowLeave() || !mounted) return;
    _draft.dirty = false;
    setState(() => _tab = tab);
  }

  Future<void> _popUnlessKept(bool didPop) async {
    if (didPop || !await _draft.allowLeave() || !mounted) return;
    _draft.dirty = false;
    Navigator.of(context).pop();
  }

  @override
  void didUpdateWidget(RoleDetail oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Selecting a different role starts back on Permissions, like switching settings panes.
    if (oldWidget.role.id != widget.role.id) {
      _draft.dirty = false;
      setState(() => _tab = _RoleDetailTab.permissions);
    }
  }

  void _viewAs(api.Role role) {
    unawaited(ref.read(rolePreviewProvider.notifier).enter(role));
    context.go(Routes.channels);
  }

  bool _heldOnlyByBots(api.Role role) {
    if (role.isEveryone || role.isBotsRole || role.isManagedByBot) return false;
    final members = ref.watch(membersProvider).valueOrNull ?? const [];
    final holders = members.where((m) => m.roleIds.contains(role.id));
    return holders.isNotEmpty && holders.every((m) => m.isBot);
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

    final body = Column(
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
        if (_heldOnlyByBots(role))
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.s24,
              0,
              AppSpacing.s24,
              AppSpacing.s12,
            ),
            child: AppCallout(
              tone: AppCalloutTone.info,
              child: Row(
                children: [
                  const Expanded(child: Text(botOnlyRoleHint)),
                  AppButton(
                    label: 'Open bots',
                    variant: AppButtonVariant.ghost,
                    onPressed: () => context.push(Routes.adminBots),
                  ),
                ],
              ),
            ),
          ),
        SettingsTabStrip<_RoleDetailTab>(
          selected: _tab,
          onSelected: (tab) => unawaited(_selectTab(tab)),
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
                draft: _draft,
              ),
              _RoleDetailTab.members => RoleMembersTab(
                role: role,
                locked: locked,
              ),
              _RoleDetailTab.display => RoleDisplayTab(
                role: role,
                locked: locked,
                draft: _draft,
              ),
            },
          ),
        ),
      ],
    );
    if (_pane != null) return body;
    return ListenableBuilder(
      listenable: _draft,
      builder: (context, child) => PopScope(
        canPop: !_draft.blocking,
        onPopInvokedWithResult: (didPop, _) =>
            unawaited(_popUnlessKept(didPop)),
        child: child!,
      ),
      child: body,
    );
  }
}
