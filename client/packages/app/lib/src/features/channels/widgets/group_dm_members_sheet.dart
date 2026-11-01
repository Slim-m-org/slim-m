// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A group DM's people and what any of them can do about it: rename it, add
/// someone, or leave.
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
import 'group_dm_people_list.dart';

Future<void> showGroupDmMembersSheet(BuildContext context, String channelId) =>
    showAppSheet<void>(
      context,
      builder: (_) => GroupDmMembersSheet(channelId: channelId),
    );

class GroupDmMembersSheet extends ConsumerStatefulWidget {
  const GroupDmMembersSheet({super.key, required this.channelId});

  final String channelId;

  @override
  ConsumerState<GroupDmMembersSheet> createState() =>
      _GroupDmMembersSheetState();
}

class _GroupDmMembersSheetState extends ConsumerState<GroupDmMembersSheet> {
  final _name = TextEditingController();
  String? _seededFor;
  bool _busy = false;
  bool _confirmingLeave = false;
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

  Future<void> _leave() async {
    final router = GoRouter.of(context);
    final navigator = Navigator.of(context);
    var left = false;
    await _run('leave the group', () async {
      await leaveGroupDm(_container, widget.channelId);
      left = true;
    });
    if (!left) return;
    navigator.pop();
    router.go(Routes.channels);
  }

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
        AppSpacing.s16,
        0,
        AppSpacing.s16,
        AppSpacing.s16,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              shownName,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AppText.heading.copyWith(
                color: tokens.textPrimary,
                fontWeight: AppWeights.semi,
              ),
            ),
            const SizedBox(height: AppSpacing.s12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: AppInput(
                    counterMax: entityNameMaxChars,
                    controller: _name,
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
                    () =>
                        renameGroupDm(_container, widget.channelId, _name.text),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.s12),
            Text(
              '${info.members.length} of $groupDmMaxPeople people',
              style: AppText.label.copyWith(color: tokens.textSecondary),
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
              Text(
                'This group is full.',
                style: AppText.caption.copyWith(color: tokens.textSecondary),
              )
            else ...[
              Text(
                'Add someone',
                style: AppText.label.copyWith(color: tokens.textSecondary),
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
              AppErrorState(message: _error!),
            ],
            const SizedBox(height: AppSpacing.s12),
            if (_confirmingLeave) ...[
              Text(
                'You lose this conversation and its calls. The others keep it, '
                'and someone in it has to add you back to rejoin.',
                style: AppText.caption.copyWith(color: tokens.textSecondary),
              ),
              const SizedBox(height: AppSpacing.s8),
              Row(
                children: [
                  Expanded(
                    child: AppButton(
                      label: 'Cancel',
                      full: true,
                      disabled: _busy,
                      onPressed: () => setState(() => _confirmingLeave = false),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.s8),
                  Expanded(
                    child: AppButton(
                      label: 'Leave $shownName',
                      variant: AppButtonVariant.danger,
                      full: true,
                      disabled: _busy,
                      onPressed: _leave,
                    ),
                  ),
                ],
              ),
            ] else
              AppButton(
                label: 'Leave group',
                variant: AppButtonVariant.danger,
                full: true,
                onPressed: () => setState(() => _confirmingLeave = true),
              ),
          ],
        ),
      ),
    );
  }
}
