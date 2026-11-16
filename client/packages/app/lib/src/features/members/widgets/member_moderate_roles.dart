// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Moderate view's roles section: a toggle per role on a pointer layout,
/// and on a phone one "Roles" row that shows what the member holds as chips
/// and opens the same toggles in place. The card's Roles section opens the
/// same toggles and makes the same write, from [setMemberRole].
///
/// A phone sheet cannot afford a 44dp row per role - a Space with a dozen
/// roles pushed Time out and Remove off the screen. Expanding in place keeps
/// the toggles inside the sheet's one scroll view rather than stacking a
/// second sheet on it (`docs/design/desktop-vs-mobile.md`, rule 3).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../role_ladder.dart';
import '../../../widgets/run_guarded.dart';
import '../providers/member_actions.dart';
import '../providers/member_presence.dart' show membersProvider;

/// Grants [role] to [memberId] or takes it away through [guard], which shows
/// a refusal inline, then refetches the roster so every surface follows.
Future<void> setMemberRole(
  WidgetRef ref,
  Guard guard, {
  required String memberId,
  required api.Role role,
  required bool grant,
}) async {
  final client = ref.read(memberActionsProvider);
  final ok = await guard(
    whatFailed: grant ? 'grant "${role.name}"' : 'take away "${role.name}"',
    action: () => grant
        ? client.assignRole(userId: memberId, roleId: role.id)
        : client.unassignRole(userId: memberId, roleId: role.id),
  );
  if (ok && ref.context.mounted) ref.invalidate(membersProvider);
}

class MemberModerateRoles extends StatefulWidget {
  const MemberModerateRoles({
    super.key,
    required this.roles,
    required this.member,
    required this.ladder,
    required this.compact,
    required this.onChanged,
  });

  final List<api.Role> roles;
  final api.UserProfile member;
  final RoleLadder ladder;
  final bool compact;
  final void Function(api.Role role, bool grant) onChanged;

  @override
  State<MemberModerateRoles> createState() => _MemberModerateRolesState();
}

class _MemberModerateRolesState extends State<MemberModerateRoles> {
  bool _open = false;

  Widget _toggles() => MemberRoleToggles(
    roles: widget.roles,
    member: widget.member,
    ladder: widget.ladder,
    showIcon: !widget.compact,
    onChanged: widget.onChanged,
  );

  @override
  Widget build(BuildContext context) {
    if (!widget.compact) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [const AppMenuLabel('Roles'), _toggles()],
      );
    }
    final held = [
      for (final role in widget.roles)
        if (!role.isEveryone && widget.member.roleIds.contains(role.id)) role,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _RolesSummaryRow(
          held: held,
          open: _open,
          onTap: () => setState(() => _open = !_open),
        ),
        if (_open) _toggles(),
      ],
    );
  }
}

/// A toggle per role in [roles], each locked where [RoleLadder.lockOf] says the server would refuse.
class MemberRoleToggles extends StatelessWidget {
  const MemberRoleToggles({
    super.key,
    required this.roles,
    required this.member,
    required this.ladder,
    required this.onChanged,
    this.showIcon = false,
  });

  final List<api.Role> roles;
  final api.UserProfile member;
  final RoleLadder ladder;
  final bool showIcon;
  final void Function(api.Role role, bool grant) onChanged;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [for (final role in roles) _row(role)],
  );

  Widget _row(api.Role role) {
    final held = role.isEveryone || member.roleIds.contains(role.id);
    return _RoleRow(
      role: role,
      held: held,
      lock: ladder.lockOf(role, member: member, held: held),
      memberName: member.displayName,
      showIcon: showIcon,
      onChanged: (v) => onChanged(role, v),
    );
  }
}

/// Why a locked toggle is locked, in a few words; `@everyone` says so in its meta instead.
String? _lockReason(RoleLock? lock) => switch (lock) {
  null || RoleLock.always => null,
  RoleLock.followsBot => 'Follows its bot',
  RoleLock.missingPermissions => 'Needs permissions you lack',
  RoleLock.notBelowYou => 'Not below your highest role',
  RoleLock.memberAboveYou => 'They rank above you',
};

class _RolesSummaryRow extends StatelessWidget {
  const _RolesSummaryRow({
    required this.held,
    required this.open,
    required this.onTap,
  });

  final List<api.Role> held;
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Semantics(
      button: true,
      expanded: open,
      label: 'Roles',
      value: held
          .map((r) => r.isManagedByBot ? '${r.name} (bot)' : r.name)
          .join(', '),
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: AppSizes.rowTouch),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.s12,
              vertical: AppSpacing.s8,
            ),
            child: Row(
              children: [
                Icon(AppIcons.shield, color: tokens.textSecondary),
                const SizedBox(width: AppSpacing.s12),
                Text(
                  'Roles',
                  style: AppText.body.copyWith(color: tokens.textPrimary),
                ),
                const SizedBox(width: AppSpacing.s12),
                Expanded(
                  child: Wrap(
                    alignment: WrapAlignment.end,
                    spacing: AppSpacing.s4,
                    runSpacing: AppSpacing.s4,
                    children: [
                      for (final role in held)
                        AppBadge(
                          variant: AppBadgeVariant.tag,
                          label: role.isManagedByBot
                              ? '${role.name} (bot)'
                              : role.name,
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: AppSpacing.s8),
                Icon(
                  open ? AppIcons.chevronUp : AppIcons.chevronDown,
                  size: AppSizes.icon16,
                  color: tokens.textSecondary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One role's toggle row. `@everyone` arrives already locked and held, so it
/// renders the same as any role the caller cannot toggle - the design's own
/// "shown but locked".
class _RoleRow extends StatelessWidget {
  const _RoleRow({
    required this.role,
    required this.held,
    required this.lock,
    required this.memberName,
    required this.showIcon,
    required this.onChanged,
  });

  final api.Role role;
  final bool held;
  final RoleLock? lock;
  final String memberName;
  final bool showIcon;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return AppListRow(
      leading: showIcon
          ? Icon(AppIcons.shield, color: tokens.textSecondary)
          : null,
      label: role.name,
      meta: role.isEveryone ? 'Always granted' : null,
      subtitle: _lockReason(lock),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (role.isManagedByBot) ...[
            const AppBadge(variant: AppBadgeVariant.tag, label: 'Bot'),
            const SizedBox(width: AppSpacing.s8),
          ],
          AppToggle(
            value: held,
            onChanged: lock == null ? (v) => onChanged(v) : null,
            locked: role.isEveryone,
            semanticLabel: '${role.name} for $memberName',
          ),
        ],
      ),
    );
  }
}
