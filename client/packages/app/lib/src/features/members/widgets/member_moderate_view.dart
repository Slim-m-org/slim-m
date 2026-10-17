// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The card's "Moderate..." sub-view: everything that used to be seven
/// top-level rows lives here instead, one step in from the profile.
///
/// Members without any of these rights never see the row that opens this at
/// all - see `member_profile.dart`'s own `showModeration` - so this view
/// itself never has to re-check "does the caller have any rights here".
///
/// Roles are a checkbox list rather than `member_roles_sheet.dart`'s own
/// sheet: the design folds role editing into Moderate rather than a second
/// surface. `@everyone` is shown, not filtered out as that sheet did, always
/// checked and always locked - every member holds it, and nothing here can
/// change that. A role the caller cannot grant is shown disabled, not
/// hidden, so this never under-reports somebody's privileges; see that
/// file's own library doc for the same reasoning this reuses.
///
/// This calls the same `assignRole`/`unassignRole` routes the Space Settings
/// roles screen uses, not a new one.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../providers/admin_providers.dart';
import '../providers/member_presence.dart' show membersProvider;
import '../../../providers/providers.dart';
import 'member_moderate_roles.dart';
import 'member_profile_sections.dart';
import 'moderation_unavailable_caption.dart';
import 'clear_totp_sheet.dart';
import 'member_rename_sheet.dart';
import 'reset_code_sheet.dart';
import '../../../widgets/run_guarded.dart';
import '../../../action_labels.dart';

class MemberModerateView extends ConsumerStatefulWidget {
  const MemberModerateView({
    super.key,
    required this.profile,
    required this.host,
    required this.canManageRoles,
    required this.outranked,
    required this.canOfferTimeoutChips,
    required this.canRename,
    required this.canIssueReset,
    required this.canRemove,
    required this.canEject,
    required this.onBack,
    required this.onTimeOut,
    required this.onRemove,
    required this.onEject,
    required this.onDone,
    this.compact = false,
  });

  final api.UserProfile profile;

  /// A context that outlives the popover; see `member_profile.dart`'s `host`.
  final BuildContext host;

  final bool canManageRoles;

  /// The member holds permissions the viewer does not; see the gates.
  final bool outranked;
  final bool canOfferTimeoutChips;
  final bool canRename;
  final bool canIssueReset;
  final bool canRemove;
  final bool canEject;

  final VoidCallback onBack;
  final void Function(Duration) onTimeOut;
  final VoidCallback onRemove;
  final VoidCallback onEject;
  final VoidCallback onDone;

  /// A phone sheet: roles collapse to one row and Time out comes first.
  final bool compact;

  @override
  ConsumerState<MemberModerateView> createState() => _MemberModerateViewState();
}

class _MemberModerateViewState extends ConsumerState<MemberModerateView>
    with GuardedActionState<MemberModerateView> {
  Future<void> _toggleRole(api.Role role, bool grant) async {
    final client = ref.read(apiProvider);
    final ok = await guard(
      whatFailed: grant ? 'grant "${role.name}"' : 'take away "${role.name}"',
      action: () => grant
          ? client.assignRole(userId: widget.profile.id, roleId: role.id)
          : client.unassignRole(userId: widget.profile.id, roleId: role.id),
    );
    if (ok && mounted) ref.invalidate(membersProvider);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final roles = ref.watch(rolesProvider).valueOrNull ?? const <api.Role>[];
    final mine = ref.watch(myPermissionsProvider);
    // Re-read live, or a toggle just above keeps reading a stale snapshot.
    final live = ref
        .watch(membersProvider)
        .valueOrNull
        ?.where((m) => m.id == widget.profile.id)
        .firstOrNull;
    final heldIds = live?.roleIds ?? widget.profile.roleIds;

    final header = _header(tokens);
    final rolesSection = widget.canManageRoles
        ? MemberModerateRoles(
            roles: roles,
            heldIds: heldIds,
            myPermissions: mine,
            memberName: widget.profile.displayName,
            compact: widget.compact,
            onChanged: _toggleRole,
          )
        : null;
    final timeOut = widget.canOfferTimeoutChips
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const AppMenuLabel('TIME OUT'),
              TimeoutDurationChips(onChosen: widget.onTimeOut),
            ],
          )
        : null;
    final sections = <Widget?>[
      if (widget.compact) ...[
        timeOut,
        rolesSection,
      ] else ...[
        rolesSection,
        null,
      ],
      if (widget.outranked) _outrankedCaption(),
      if (widget.canRename)
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const AppMenuLabel('NAME'),
            RenameMemberMenuItem(
              host: widget.host,
              profile: live ?? widget.profile,
              onDone: widget.onDone,
            ),
          ],
        ),
      if (!widget.compact) timeOut,
      if (widget.canEject)
        AppMenuItem(
          label: 'Eject from call...',
          leading: AppIcons.leaveCall,
          tone: AppMenuItemTone.danger,
          onTap: widget.onEject,
        ),
      if (widget.canIssueReset)
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const AppMenuLabel('ACCOUNT'),
            ResetCodeMenuItem(
              host: widget.host,
              subjectId: widget.profile.id,
              subjectName: widget.profile.displayName,
              onDone: widget.onDone,
            ),
            ClearTotpMenuItem(
              host: widget.host,
              subjectId: widget.profile.id,
              subjectName: widget.profile.displayName,
              onDone: widget.onDone,
            ),
          ],
        ),
    ].whereType<Widget>().toList();

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        header,
        for (var i = 0; i < sections.length; i++) ...[
          sections[i],
          if (i < sections.length - 1 || (widget.compact && widget.canRemove))
            const AppMenuDivider(),
        ],
        if (actionError != null)
          Padding(
            padding: const EdgeInsets.all(AppSpacing.s8),
            child: AppErrorState(
              message: actionError!,
              onDismiss: clearActionError,
            ),
          ),
        if (widget.canRemove)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.s12,
              AppSpacing.s8,
              AppSpacing.s12,
              AppSpacing.s12,
            ),
            child: AppButton(
              label: ActionLabels.removeFromSpace,
              variant: AppButtonVariant.danger,
              full: true,
              onPressed: widget.onRemove,
            ),
          ),
      ],
    );
  }

  Widget _outrankedCaption() => Padding(
    padding: const EdgeInsets.symmetric(
      horizontal: AppSpacing.s12,
      vertical: AppSpacing.s8,
    ),
    child: ModerationUnavailableCaption(
      'You cannot time out or remove ${widget.profile.displayName}: '
      'they hold permissions you do not.',
    ),
  );

  Widget _header(AppTokens tokens) => Padding(
    padding: const EdgeInsets.fromLTRB(
      AppSpacing.s8,
      AppSpacing.s8,
      AppSpacing.s12,
      AppSpacing.s8,
    ),
    child: Row(
      children: [
        AppIconButton(
          icon: AppIcons.back,
          semanticLabel: 'Back to profile',
          tooltip: 'Back',
          size: AppIconButtonSize.sm,
          onPressed: widget.onBack,
        ),
        const SizedBox(width: AppSpacing.s4),
        Expanded(
          child: Text(
            'Moderate ${widget.profile.displayName}',
            overflow: TextOverflow.ellipsis,
            style: AppText.body.copyWith(
              color: tokens.textPrimary,
              fontWeight: AppWeights.semi,
            ),
          ),
        ),
      ],
    ),
  );
}
