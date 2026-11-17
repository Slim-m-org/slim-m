// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// "Who can see this" under a Private switch: everyone, or administrators
/// plus each role and member an Allow View row lets in (decision 0124).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../providers/admin_providers.dart';
import '../../../providers/providers.dart' show meProvider;
import '../../../widgets/run_guarded.dart';
import '../../members/providers/member_presence.dart' show membersProvider;
import '../../members/widgets/bot_avatar_placeholder.dart';
import '../../members/widgets/user_avatar.dart';
import '../../settings/widgets/admin/channel_permissions_columns.dart';
import '../../settings/widgets/admin/channel_permissions_grid_rows.dart';
import '../../settings/widgets/admin/channel_permissions_picker.dart';
import '../../settings/widgets/settings_entity_row.dart';
import '../providers/view_access.dart';

class WhoCanSee extends ConsumerStatefulWidget {
  const WhoCanSee({super.key, required this.target, this.private});

  final ViewTarget target;

  /// The switch's value while its write is in flight, ahead of the rows.
  final bool? private;

  @override
  ConsumerState<WhoCanSee> createState() => _WhoCanSeeState();
}

class _WhoCanSeeState extends ConsumerState<WhoCanSee>
    with GuardedActionState<WhoCanSee> {
  bool _busy = false;

  OverwriteReach _reach(List<api.Role> roles, List<api.UserProfile> members) =>
      OverwriteReach(
        ladder: ref.read(roleLadderProvider),
        selfId: ref.read(meProvider).valueOrNull?.id,
        roles: roles,
        members: members,
      );

  Future<void> _setViewer(
    List<api.ChannelOverwrite> existing,
    GridColumn column, {
    required bool allowed,
  }) async {
    setState(() => _busy = true);
    final target = widget.target;
    await guard(
      whatFailed: allowed ? 'add ${column.label}' : 'remove ${column.label}',
      action: () async {
        await ref.read(viewAccessWriterProvider).write(target, [
          viewGrantEdit(
            existing,
            kind: column.kind,
            id: column.id,
            allowed: allowed,
          ),
        ]);
        target.affected.forEach(ref.invalidate);
      },
    );
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _add(
    List<api.ChannelOverwrite> existing,
    ViewAccess access,
    OverwriteReach reach,
  ) async {
    final column = await pickGridColumn(
      context,
      taken: {
        for (final v in access.viewers) '${v.kind.wire}:${v.id}',
        ...reach.outrankedKeys,
      },
    );
    if (column == null || !mounted) return;
    await _setViewer(existing, column, allowed: true);
  }

  @override
  Widget build(BuildContext context) {
    final overwrites = ref.watch(widget.target.overwrites).valueOrNull;
    final roles = ref.watch(rolesProvider).valueOrNull;
    final members = ref.watch(membersProvider).valueOrNull;
    ref
      ..watch(roleLadderProvider)
      ..watch(meProvider);
    final everyone = roles?.where((r) => r.isEveryone).firstOrNull;
    if (overwrites == null || members == null || everyone == null) {
      return const SizedBox.shrink();
    }
    final access = ViewAccess.of(overwrites, everyoneRoleId: everyone.id);
    final reach = _reach(roles!, members);
    final private = widget.private ?? access.private;
    final error = actionError;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _Heading(),
        if (!private)
          const _Row(label: 'Everyone', icon: AppIcons.members)
        else ...[
          const _Row(
            label: 'Administrators',
            detail: 'Always',
            icon: AppIcons.shield,
          ),
          for (final viewer in access.viewers)
            if (resolveGridColumn(
                  '${viewer.kind.wire}:${viewer.id}',
                  roles,
                  members,
                )
                case final column?)
              _Row(
                label: column.label,
                column: column,
                onRemove: reach.reaches(column.key) && !_busy
                    ? () => unawaited(
                        _setViewer(overwrites, column, allowed: false),
                      )
                    : null,
              ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.s16,
              AppSpacing.s4,
              AppSpacing.s16,
              AppSpacing.s12,
            ),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: AppButton(
                label: 'Add role or member',
                icon: AppIcons.add,
                variant: AppButtonVariant.secondary,
                size: AppButtonSize.sm,
                busy: _busy,
                onPressed: () => unawaited(_add(overwrites, access, reach)),
              ),
            ),
          ),
        ],
        if (error != null)
          AppErrorState(message: error, onDismiss: clearActionError),
      ],
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading();

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.s16,
        AppSpacing.s12,
        AppSpacing.s16,
        AppSpacing.s4,
      ),
      child: Semantics(
        header: true,
        child: Text(
          'Who can see this',
          style: AppText.caption.copyWith(color: tokens.textSecondary),
        ),
      ),
    );
  }
}

/// One principal: a role's shield, a member's avatar, or a fixed group.
class _Row extends StatelessWidget {
  const _Row({
    required this.label,
    this.detail,
    this.icon,
    this.column,
    this.onRemove,
  });

  final String label;
  final String? detail;
  final IconData? icon;
  final GridColumn? column;
  final VoidCallback? onRemove;

  Widget _leading(BuildContext context, AppTokens tokens) {
    final column = this.column;
    if (column != null && column.kind == api.OverwriteTarget.member) {
      return UserAvatar(
        name: column.label,
        userId: column.id,
        size: AppAvatarSize.s20,
        shape: column.isBot ? AppAvatarShape.square : AppAvatarShape.circle,
        placeholder: column.isBot
            ? botAvatarPlaceholder(context, column.label)
            : null,
      );
    }
    // As wide as an avatar, so every name starts at one x.
    return SizedBox.square(
      dimension: 20,
      child: Icon(
        icon ?? AppIcons.shield,
        size: AppSizes.icon16,
        color: tokens.textSecondary,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final detail = this.detail;
    return SettingsEntityRow(
      dense: true,
      headline: label,
      leading: _leading(context, tokens),
      details: [
        if (detail != null)
          Text(
            detail,
            style: AppText.caption.copyWith(color: tokens.textSecondary),
          ),
      ],
      actions: [
        if (column != null)
          onRemove == null
              ? null
              : AppIconButton(
                  icon: AppIcons.dismiss,
                  iconSize: AppSizes.icon16,
                  size: AppIconButtonSize.sm,
                  semanticLabel: 'Remove $label',
                  tooltip: 'Remove',
                  onPressed: onRemove,
                ),
      ],
    );
  }
}
