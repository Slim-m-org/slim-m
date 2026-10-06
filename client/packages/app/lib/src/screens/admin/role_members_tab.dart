// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The selected role's Members tab: search to add, then every holder in two
/// groups (bots, people) - both grouped the same way regardless of holder
/// kind, since a bot is a full principal like any other (decision 0028), not
/// a second class of member.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../providers/member_presence.dart' show membersProvider;
import '../../providers/providers.dart';
import '../../widgets/bot_avatar_placeholder.dart';
import '../../widgets/run_guarded.dart';
import '../../widgets/user_avatar.dart';

/// A group past this size collapses to this many rows plus a "+N more"
/// summary, matching the design's own worked example.
const _collapseAt = 5;

class RoleMembersTab extends ConsumerStatefulWidget {
  const RoleMembersTab({super.key, required this.role});

  final api.Role role;

  @override
  ConsumerState<RoleMembersTab> createState() => _RoleMembersTabState();
}

class _RoleMembersTabState extends ConsumerState<RoleMembersTab>
    with GuardedActionState<RoleMembersTab> {
  final TextEditingController _search = TextEditingController();
  bool _expandBots = false;
  bool _expandPeople = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<api.UserProfile> _candidates(List<api.UserProfile> members) {
    final needle = _search.text.trim().toLowerCase();
    if (needle.isEmpty) return const [];
    return members
        .where((m) => !m.roleIds.contains(widget.role.id))
        .where(
          (m) =>
              m.displayName.toLowerCase().contains(needle) ||
              m.username.toLowerCase().contains(needle),
        )
        .take(5)
        .toList();
  }

  Future<void> _add(api.UserProfile member) async {
    final ok = await guard(
      whatFailed: 'add ${member.displayName}',
      action: () => ref
          .read(apiProvider)
          .assignRole(userId: member.id, roleId: widget.role.id),
    );
    if (!mounted) return;
    if (ok) {
      _search.clear();
      setState(() {});
      ref.invalidate(membersProvider);
    }
  }

  Future<void> _remove(api.UserProfile member) async {
    final ok = await guard(
      whatFailed: 'remove ${member.displayName}',
      action: () => ref
          .read(apiProvider)
          .unassignRole(userId: member.id, roleId: widget.role.id),
    );
    if (ok && mounted) ref.invalidate(membersProvider);
  }

  @override
  Widget build(BuildContext context) {
    final members = ref.watch(membersProvider);

    return AppAsyncView<List<api.UserProfile>>(
      value: AppAsyncState(data: members.valueOrNull, error: members.error),
      center: false,
      errorMessage: 'Could not load members.',
      onRetry: () => ref.invalidate(membersProvider),
      data: (context, list) {
        final holders = list
            .where((m) => m.roleIds.contains(widget.role.id))
            .toList();
        final bots = holders.where((m) => m.isBot).toList();
        final people = holders.where((m) => !m.isBot).toList();
        final candidates = _candidates(list);

        return ListView(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.s16,
            AppSpacing.s12,
            AppSpacing.s16,
            AppSpacing.s16,
          ),
          children: [
            AppInput(
              controller: _search,
              placeholder: 'Search members to add',
              icon: const Icon(AppIcons.search),
              semanticLabel: 'Search members to add',
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) {
                if (candidates.isNotEmpty) unawaited(_add(candidates.first));
              },
            ),
            for (final candidate in candidates)
              AppListRow(
                leading: UserAvatar.known(
                  name: candidate.displayName,
                  userId: candidate.id,
                  avatarUpdatedAt: candidate.avatarUpdatedAt,
                  size: AppAvatarSize.s28,
                  shape: candidate.isBot
                      ? AppAvatarShape.square
                      : AppAvatarShape.circle,
                  placeholder: candidate.isBot
                      ? botAvatarPlaceholder(context, candidate.displayName)
                      : null,
                ),
                label: candidate.displayName,
                meta: '@${candidate.username}',
                trailing: const Text('⏎ add'),
                onTap: () => unawaited(_add(candidate)),
              ),
            if (actionError case final error?) ...[
              const SizedBox(height: AppSpacing.s8),
              AppErrorState(message: error, onDismiss: clearActionError),
            ],
            const SizedBox(height: AppSpacing.s16),
            _HolderGroup(
              title: 'Bots',
              holders: bots,
              expanded: _expandBots,
              onExpand: () => setState(() => _expandBots = true),
              onRemove: _remove,
            ),
            const SizedBox(height: AppSpacing.s12),
            _HolderGroup(
              title: 'People',
              holders: people,
              expanded: _expandPeople,
              onExpand: () => setState(() => _expandPeople = true),
              onRemove: _remove,
              emptyMessage:
                  'No people hold this role. Search above to add someone.',
            ),
          ],
        );
      },
    );
  }
}

class _HolderGroup extends StatelessWidget {
  const _HolderGroup({
    required this.title,
    required this.holders,
    required this.expanded,
    required this.onExpand,
    required this.onRemove,
    this.emptyMessage,
  });

  final String title;
  final List<api.UserProfile> holders;
  final bool expanded;
  final VoidCallback onExpand;
  final ValueChanged<api.UserProfile> onRemove;
  final String? emptyMessage;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final shown = expanded || holders.length <= _collapseAt
        ? holders
        : holders.take(_collapseAt).toList();
    final hidden = holders.skip(shown.length).toList();
    final summary =
        '+ ${hidden.length} more · ${hidden.map((h) => h.displayName).join(', ')}';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${title.toUpperCase()} · ${holders.length}',
          style: AppText.micro.copyWith(color: tokens.textSecondary),
        ),
        const SizedBox(height: AppSpacing.s4),
        if (holders.isEmpty && emptyMessage != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.s4),
            child: Text(
              emptyMessage!,
              style: AppText.caption.copyWith(color: tokens.textSecondary),
            ),
          )
        else
          for (final holder in shown)
            AppListRow(
              key: ValueKey(holder.id),
              leading: UserAvatar.known(
                name: holder.displayName,
                userId: holder.id,
                avatarUpdatedAt: holder.avatarUpdatedAt,
                size: AppAvatarSize.s28,
                shape: holder.isBot
                    ? AppAvatarShape.square
                    : AppAvatarShape.circle,
                placeholder: holder.isBot
                    ? botAvatarPlaceholder(context, holder.displayName)
                    : null,
              ),
              label: holder.displayName,
              meta: '@${holder.username}',
              trailing: AppButton(
                label: 'Remove',
                semanticLabel: 'Remove ${holder.displayName}',
                variant: AppButtonVariant.ghost,
                size: AppButtonSize.sm,
                onPressed: () => onRemove(holder),
              ),
            ),
        if (hidden.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.s4),
            child: FocusableTapTarget(
              onTap: onExpand,
              semanticLabel: summary,
              builder: (context, focused, hovered) => Text(
                summary,
                style: AppText.caption.copyWith(color: tokens.textSecondary),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
      ],
    );
  }
}
