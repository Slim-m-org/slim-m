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
import '../../widgets/settings_empty.dart';
import '../../widgets/settings_section_header.dart';
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

        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.s24,
                AppSpacing.s16,
                AppSpacing.s24,
                0,
              ),
              child: AppInput(
                controller: _search,
                placeholder: 'Search members to add',
                icon: const Icon(AppIcons.search),
                semanticLabel: 'Search members to add',
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) {
                  if (candidates.isNotEmpty) unawaited(_add(candidates.first));
                },
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.s24,
                  0,
                  AppSpacing.s24,
                  40,
                ),
                children: [
                  if (candidates.isNotEmpty)
                    SettingsSectionCard(
                      title: 'Add to this role',
                      children: [
                        for (final candidate in candidates)
                          AppListRow(
                            leading: _avatar(context, candidate),
                            label: candidate.displayName,
                            meta: '@${candidate.username}',
                            trailing: const Text('⏎ add'),
                            onTap: () => unawaited(_add(candidate)),
                          ),
                      ],
                    ),
                  if (actionError case final error?) ...[
                    const SizedBox(height: AppSpacing.s12),
                    AppErrorState(message: error, onDismiss: clearActionError),
                  ],
                  if (bots.isNotEmpty)
                    _HolderGroup(
                      title: 'Bots',
                      holders: bots,
                      expanded: _expandBots,
                      onExpand: () => setState(() => _expandBots = true),
                      onRemove: _remove,
                    ),
                  _HolderGroup(
                    title: 'People',
                    holders: people,
                    expanded: _expandPeople,
                    onExpand: () => setState(() => _expandPeople = true),
                    onRemove: _remove,
                    emptyTitle: 'No people hold this role',
                    emptyDetail: 'Search above to add someone.',
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

Widget _avatar(BuildContext context, api.UserProfile member) =>
    UserAvatar.known(
      name: member.displayName,
      userId: member.id,
      avatarUpdatedAt: member.avatarUpdatedAt,
      size: AppAvatarSize.s28,
      shape: member.isBot ? AppAvatarShape.square : AppAvatarShape.circle,
      placeholder: member.isBot
          ? botAvatarPlaceholder(context, member.displayName)
          : null,
    );

class _HolderGroup extends StatelessWidget {
  const _HolderGroup({
    required this.title,
    required this.holders,
    required this.expanded,
    required this.onExpand,
    required this.onRemove,
    this.emptyTitle,
    this.emptyDetail,
  });

  final String title;
  final List<api.UserProfile> holders;
  final bool expanded;
  final VoidCallback onExpand;
  final ValueChanged<api.UserProfile> onRemove;
  final String? emptyTitle;
  final String? emptyDetail;

  @override
  Widget build(BuildContext context) {
    final shown = expanded || holders.length <= _collapseAt
        ? holders
        : holders.take(_collapseAt).toList();
    final hidden = holders.skip(shown.length).toList();
    final summary =
        '+ ${hidden.length} more · ${hidden.map((h) => h.displayName).join(', ')}';

    return SettingsSectionCard(
      title: '$title · ${holders.length}',
      children: [
        if (holders.isEmpty && emptyTitle != null)
          SettingsEmptyState(
            icon: AppIcons.account,
            title: emptyTitle!,
            detail: emptyDetail,
          )
        else
          for (final holder in shown)
            AppListRow(
              key: ValueKey(holder.id),
              leading: _avatar(context, holder),
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
          FocusableTapTarget(
            onTap: onExpand,
            semanticLabel: summary,
            builder: (context, focused, hovered) => SettingsSubRow(
              label: summary,
              trailing: const Icon(AppIcons.chevronDown, size: AppSizes.icon16),
            ),
          ),
      ],
    );
  }
}
