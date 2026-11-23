// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A group DM's people and what any of them can do about it: rename it, add
/// someone, leave, or delete it for everyone. Every member has the same powers.
///
/// Rule 3 of `docs/design/desktop-vs-mobile.md`: information about a thing
/// plus its actions, so a bottom sheet under 600 and a dialog above it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../api_failure.dart';
import '../../../entity_name.dart';
import '../../../providers/providers.dart';
import '../../../routing/routes.dart';
import '../../members/widgets/user_avatar.dart';
import '../providers/group_dm.dart';
import 'channel_rail.dart' show channelIdInPath;
import 'group_dm_people_list.dart';

/// What the row menu asked for, so the sheet opens already on it.
enum GroupDmSheetIntent { members, rename, leave, delete }

Future<void> showGroupDmMembersSheet(
  BuildContext context,
  String channelId, {
  GroupDmSheetIntent intent = GroupDmSheetIntent.members,
}) => showAppSheet<void>(
  context,
  builder: (_) => _GroupDmMembersSheet(channelId: channelId, intent: intent),
);

class _GroupDmMembersSheet extends ConsumerStatefulWidget {
  const _GroupDmMembersSheet({required this.channelId, required this.intent});

  final String channelId;
  final GroupDmSheetIntent intent;

  @override
  ConsumerState<_GroupDmMembersSheet> createState() =>
      _GroupDmMembersSheetState();
}

class _GroupDmMembersSheetState extends ConsumerState<_GroupDmMembersSheet> {
  final _name = TextEditingController();
  String? _seededFor;
  bool _busy = false;
  late GroupDmSheetIntent _confirming = widget.intent;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _run(String whatFailed, Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      ref.invalidate(groupDmProvider(widget.channelId));
    } on api.ApiException catch (e, stack) {
      api.reportFailure(api.LogTag.ui, whatFailed, e, stack);
      if (mounted) {
        setState(
          () => _error = e is api.ForbiddenException
              ? describeGroupDmFailure(whatFailed, e)
              : describeApiFailure(whatFailed, e),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _leave() => _depart(
    'leave the group',
    () => leaveGroupDm(_container, widget.channelId),
  );

  Future<void> _delete() => _depart(
    'delete the group',
    () => deleteGroupDm(_container, widget.channelId),
  );

  /// Closes the sheet and, if this group is the open view, the view with it.
  Future<void> _depart(
    String whatFailed,
    Future<void> Function() action,
  ) async {
    final router = GoRouter.of(context);
    final navigator = Navigator.of(context);
    var done = false;
    await _run(whatFailed, () async {
      await action();
      done = true;
    });
    if (!done) return;
    navigator.pop();
    final viewing = channelIdInPath(
      router.routerDelegate.currentConfiguration.uri.path,
    );
    if (viewing == null || viewing == widget.channelId) {
      router.go(Routes.channels);
    }
  }

  void _cancelConfirm() =>
      setState(() => _confirming = GroupDmSheetIntent.members);

  ProviderContainer get _container =>
      ProviderScope.containerOf(context, listen: false);

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final group = ref.watch(groupDmProvider(widget.channelId));
    final selfId = ref.watch(sessionProvider).tokens?.userId;
    final dm = group.valueOrNull;
    final info = dm?.group;
    if (group.hasError) {
      return AppErrorState(
        message: 'Could not load this group.',
        onRetry: () => ref.invalidate(groupDmProvider(widget.channelId)),
      );
    }
    if (dm == null || info == null) {
      return Padding(
        padding: const EdgeInsets.all(AppSpacing.s16),
        child: Text(
          group.isLoading ? 'Loading...' : 'You are not in this group.',
          style: AppText.caption.copyWith(color: tokens.textSecondary),
        ),
      );
    }
    if (_seededFor != widget.channelId) {
      _seededFor = widget.channelId;
      _name.text = info.name ?? '';
    }
    final others = [
      for (final m in info.members)
        if (m.id != selfId) m.displayName,
    ];
    final defaultName = defaultGroupName(others);
    final shownName = info.name ?? defaultName;
    final memberIds = {for (final m in info.members) m.id};
    final full = info.members.length >= groupDmMaxPeople;
    final nameChanged = _name.text.trim() != (info.name ?? '');
    final nameOk = _name.text.trim().isEmpty || entityNameValid(_name.text);

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.s8,
        0,
        AppSpacing.s8,
        AppSpacing.s16,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppSheetHeader(
              shownName,
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.s8,
                AppSpacing.s12,
                AppSpacing.s8,
                AppSpacing.s12,
              ),
            ),
            _inset(
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: AppInput(
                      counterMax: entityNameMaxChars,
                      controller: _name,
                      autofocus: widget.intent == GroupDmSheetIntent.rename,
                      placeholder: defaultName,
                      semanticLabel: 'Group name',
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.s8),
                  AppButton(
                    label: 'Save',
                    disabled: _busy || !nameChanged || !nameOk,
                    onPressed: () => _run(
                      'rename the group',
                      () => renameGroupDm(
                        _container,
                        widget.channelId,
                        _name.text,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.s12),
            _inset(
              Text(
                '${info.members.length} of $groupDmMaxPeople people',
                style: AppText.label.copyWith(color: tokens.textSecondary),
              ),
            ),
            const SizedBox(height: AppSpacing.s4),
            for (final m in info.members)
              AppListRow(
                key: ValueKey('group-dm-member:${m.id}'),
                leading: UserAvatar(
                  name: m.displayName,
                  userId: m.id,
                  size: AppAvatarSize.s24,
                ),
                label: m.id == selfId
                    ? '${m.displayName} (you)'
                    : m.displayName,
                meta: '@${m.username}',
              ),
            const SizedBox(height: AppSpacing.s12),
            if (full)
              _inset(
                Text(
                  'This group is full.',
                  style: AppText.caption.copyWith(color: tokens.textSecondary),
                ),
              )
            else ...[
              _inset(
                Text(
                  'Add someone',
                  style: AppText.label.copyWith(color: tokens.textSecondary),
                ),
              ),
              const SizedBox(height: AppSpacing.s4),
              GroupDmPeopleList(
                exclude: memberIds,
                selected: const {},
                full: _busy,
                onTap: (id) => _run(
                  'add them to the group',
                  () => addToGroupDm(_container, widget.channelId, id),
                ),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: AppSpacing.s8),
              _inset(AppErrorState(message: _error!)),
            ],
            const SizedBox(height: AppSpacing.s12),
            _inset(
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_confirming == GroupDmSheetIntent.leave)
                    _Confirm(
                      message:
                          'You lose this conversation and its calls. The others keep it, '
                          'and someone in it has to add you back to rejoin.',
                      action: 'Leave group',
                      busy: _busy,
                      onCancel: _cancelConfirm,
                      onConfirm: _leave,
                    )
                  else if (_confirming == GroupDmSheetIntent.delete)
                    _Confirm(
                      message:
                          'This deletes $shownName and all its messages for everyone '
                          'in it. It cannot be undone.',
                      action: 'Delete group',
                      busy: _busy,
                      onCancel: _cancelConfirm,
                      onConfirm: _delete,
                    )
                  else ...[
                    AppButton(
                      label: 'Leave group',
                      variant: AppButtonVariant.danger,
                      full: true,
                      onPressed: () => setState(
                        () => _confirming = GroupDmSheetIntent.leave,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.s8),
                    AppButton(
                      label: 'Delete group',
                      variant: AppButtonVariant.danger,
                      full: true,
                      onPressed: () => setState(
                        () => _confirming = GroupDmSheetIntent.delete,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Rows carry their own 8dp inset, so everything else steps in to meet their content edge.
  Widget _inset(Widget child) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s8),
    child: child,
  );
}

/// A destructive act's plain warning with Cancel beside the button that does it.
class _Confirm extends StatelessWidget {
  const _Confirm({
    required this.message,
    required this.action,
    required this.busy,
    required this.onCancel,
    required this.onConfirm,
  });

  final String message;
  final String action;
  final bool busy;
  final VoidCallback onCancel;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          message,
          style: AppText.caption.copyWith(color: tokens.textSecondary),
        ),
        const SizedBox(height: AppSpacing.s8),
        Row(
          children: [
            Expanded(
              child: AppButton(
                label: 'Cancel',
                full: true,
                disabled: busy,
                onPressed: onCancel,
              ),
            ),
            const SizedBox(width: AppSpacing.s8),
            Expanded(
              child: AppButton(
                label: action,
                variant: AppButtonVariant.danger,
                full: true,
                disabled: busy,
                onPressed: onConfirm,
              ),
            ),
          ],
        ),
      ],
    );
  }
}
