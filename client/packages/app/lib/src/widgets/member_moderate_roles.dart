// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Moderate view's roles section: a toggle per role on a pointer layout,
/// and on a phone one "Roles" row that shows what the member holds as chips
/// and opens the same toggles in place.
///
/// A phone sheet cannot afford a 44dp row per role - a Space with a dozen
/// roles pushed Time out and Remove off the screen. Expanding in place keeps
/// the toggles inside the sheet's one scroll view rather than stacking a
/// second sheet on it (`docs/design/desktop-vs-mobile.md`, rule 3).
library;

import 'package:flutter/material.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../permissions.dart';

class MemberModerateRoles extends StatefulWidget {
  const MemberModerateRoles({
    super.key,
    required this.roles,
    required this.heldIds,
    required this.myPermissions,
    required this.memberName,
    required this.compact,
    required this.onChanged,
  });

  final List<api.Role> roles;
  final List<String> heldIds;
  final int myPermissions;
  final String memberName;
  final bool compact;
  final void Function(api.Role role, bool grant) onChanged;

  @override
  State<MemberModerateRoles> createState() => _MemberModerateRolesState();
}

class _MemberModerateRolesState extends State<MemberModerateRoles> {
  bool _open = false;

  Widget _toggles() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      for (final role in widget.roles)
        _RoleRow(
          role: role,
          held: role.isEveryone || widget.heldIds.contains(role.id),
          grantable:
              !role.isEveryone &&
              widget.myPermissions.hasPermission(role.permissions),
          memberName: widget.memberName,
          showIcon: !widget.compact,
          onChanged: (v) => widget.onChanged(role, v),
        ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    if (!widget.compact) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [const AppMenuLabel('ROLES'), _toggles()],
      );
    }
    final held = [
      for (final role in widget.roles)
        if (!role.isEveryone && widget.heldIds.contains(role.id)) role,
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

/// One role's toggle row. `@everyone` arrives already locked (`grantable`
/// false and `held` true), so it renders the same as any role the caller
/// cannot toggle - the design's own "shown but locked".
class _RoleRow extends StatelessWidget {
  const _RoleRow({
    required this.role,
    required this.held,
    required this.grantable,
    required this.memberName,
    required this.showIcon,
    required this.onChanged,
  });

  final api.Role role;
  final bool held;
  final bool grantable;
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
      subtitle: role.isEveryone || grantable
          ? null
          : 'Needs permissions you lack',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (role.isManagedByBot) ...[
            const AppBadge(variant: AppBadgeVariant.tag, label: 'Bot'),
            const SizedBox(width: AppSpacing.s8),
          ],
          AppToggle(
            value: held,
            onChanged: (!role.isEveryone && grantable)
                ? (v) => onChanged(v)
                : null,
            locked: role.isEveryone,
            semanticLabel: '${role.name} for $memberName',
          ),
        ],
      ),
    );
  }
}
