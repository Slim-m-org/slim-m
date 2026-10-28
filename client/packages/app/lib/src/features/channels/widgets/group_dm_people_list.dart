// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A searchable list of the Space's people to pick from, for a new group DM
/// and for adding to an existing one.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../providers/providers.dart';
import '../../members/providers/member_presence.dart' show membersProvider;
import '../../members/widgets/user_avatar.dart';

const _listMaxHeight = 240.0;

class GroupDmPeopleList extends ConsumerStatefulWidget {
  const GroupDmPeopleList({
    super.key,
    required this.exclude,
    required this.selected,
    required this.onTap,
    this.full = false,
  });

  /// People never offered, such as those already in the group.
  final Set<String> exclude;
  final Set<String> selected;
  final ValueChanged<String> onTap;

  /// No more can be picked: unpicked rows are shown but cannot be tapped.
  final bool full;

  @override
  ConsumerState<GroupDmPeopleList> createState() => _GroupDmPeopleListState();
}

class _GroupDmPeopleListState extends ConsumerState<GroupDmPeopleList> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Widget _row(api.UserProfile person) {
    final picked = widget.selected.contains(person.id);
    final locked = widget.full && !picked;
    return AppListRow(
      key: ValueKey('group-dm-person:${person.id}'),
      leading: UserAvatar(
        name: person.displayName,
        userId: person.id,
        size: AppAvatarSize.s24,
      ),
      label: person.displayName,
      meta: '@${person.username}',
      selected: picked,
      stateDescription: picked ? 'Picked' : (locked ? 'Group is full' : null),
      trailing: picked
          ? const Icon(AppIcons.check, size: AppSizes.icon16)
          : null,
      onTap: locked ? null : () => widget.onTap(person.id),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final members = ref.watch(membersProvider);
    final selfId = ref.watch(sessionProvider).tokens?.userId;
    if (members.hasError) {
      return AppErrorState(
        message: 'Could not load people.',
        onRetry: () => ref.invalidate(membersProvider),
      );
    }
    final needle = _search.text.trim().toLowerCase();
    final people = [
      for (final m in members.valueOrNull ?? const <api.UserProfile>[])
        if (m.id != selfId &&
            !m.isBot &&
            !m.isWebhook &&
            !widget.exclude.contains(m.id) &&
            (needle.isEmpty ||
                '${m.displayName} ${m.username}'.toLowerCase().contains(
                  needle,
                )))
          m,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppInput(
          controller: _search,
          placeholder: 'Search people',
          icon: const Icon(AppIcons.search),
          semanticLabel: 'Search people',
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: AppSpacing.s4),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: _listMaxHeight),
          child: people.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(AppSpacing.s12),
                  child: Text(
                    members.isLoading ? 'Loading...' : 'No one matches.',
                    style: AppText.caption.copyWith(
                      color: tokens.textSecondary,
                    ),
                  ),
                )
              : ListView(
                  shrinkWrap: true,
                  children: [for (final p in people) _row(p)],
                ),
        ),
      ],
    );
  }
}
