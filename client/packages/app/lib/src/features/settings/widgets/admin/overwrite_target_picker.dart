// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one sheet that adds a role or a member column to a permissions grid.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../../providers/admin_providers.dart';
import '../../../members/providers/member_presence.dart' show membersProvider;
import '../../../members/widgets/bot_avatar_placeholder.dart';
import '../../../members/widgets/user_avatar.dart';
import '../../../palette/widgets/command_palette_items.dart'
    show memberMatchesQuery;

const _listMaxHeightFraction = 0.6;

/// Pops an [api.Role] or an [api.UserProfile].
///
/// [taken] holds the `kind:id` keys already in the grid, which are left out.
/// Both providers are watched here so they stay alive while the sheet is open.
class OverwriteTargetPicker extends ConsumerStatefulWidget {
  const OverwriteTargetPicker({super.key, this.taken = const {}});

  final Set<String> taken;

  @override
  ConsumerState<OverwriteTargetPicker> createState() => _State();
}

class _State extends ConsumerState<OverwriteTargetPicker> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  String get _query => _search.text.trim().toLowerCase();

  List<api.Role> _roles(List<api.Role> all) => [
    for (final r in all)
      if (!r.isEveryone &&
          !widget.taken.contains('role:${r.id}') &&
          r.name.toLowerCase().contains(_query))
        r,
  ];

  List<api.UserProfile> _members(List<api.UserProfile> all) => [
    for (final m in all)
      if (!widget.taken.contains('member:${m.id}') &&
          memberMatchesQuery(m, _query))
        m,
  ];

  void _chooseFirst(List<Object> shown) {
    if (shown.isNotEmpty) Navigator.of(context).pop(shown.first);
  }

  @override
  Widget build(BuildContext context) {
    final roles = ref.watch(rolesProvider);
    final members = ref.watch(membersProvider);
    final touch = MediaQuery.sizeOf(context).width < kCompactWidth;
    final maxHeight =
        MediaQuery.sizeOf(context).height * _listMaxHeightFraction;
    final shownRoles = _roles(roles.valueOrNull ?? const []);
    final shownMembers = _members(members.valueOrNull ?? const []);
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppSheetHeader(
            'Add a role or member',
            trailing: touch
                ? null
                : AppIconButton(
                    key: const Key('target-picker-close'),
                    icon: AppIcons.dismiss,
                    semanticLabel: 'Close',
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s16),
            child: AppInput(
              key: const Key('target-picker-input'),
              controller: _search,
              autofocus: !touch,
              placeholder: 'Search roles and members',
              icon: const Icon(AppIcons.search),
              semanticLabel: 'Search roles and members',
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) =>
                  _chooseFirst([...shownRoles, ...shownMembers]),
            ),
          ),
          const SizedBox(height: AppSpacing.s8),
          AppAsyncView(
            value: AppAsyncState(
              data: roles.valueOrNull == null || members.valueOrNull == null
                  ? null
                  : (roles.valueOrNull!, members.valueOrNull!),
              error: roles.error ?? members.error,
            ),
            errorMessage: 'Could not load roles and members.',
            onRetry: () {
              ref.invalidate(rolesProvider);
              ref.invalidate(membersProvider);
            },
            emptyMessage: 'Nothing to add.',
            isEmpty: (_) => false,
            data: (context, _) => shownRoles.isEmpty && shownMembers.isEmpty
                ? const Padding(
                    key: Key('target-picker-empty'),
                    padding: EdgeInsets.all(AppSpacing.s16),
                    child: Text('Nothing matches.'),
                  )
                : ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: maxHeight),
                    child: ListView(
                      key: const Key('target-picker-list'),
                      shrinkWrap: true,
                      padding: const EdgeInsets.fromLTRB(
                        AppSpacing.s8,
                        0,
                        AppSpacing.s8,
                        AppSpacing.s8,
                      ),
                      children: [
                        if (shownRoles.isNotEmpty) const AppMenuLabel('Roles'),
                        for (final role in shownRoles)
                          AppListRow(
                            key: Key('target-picker-role-${role.id}'),
                            leading: const Icon(
                              AppIcons.shield,
                              size: AppSizes.icon16,
                            ),
                            label: role.name,
                            onTap: () => Navigator.of(context).pop(role),
                          ),
                        if (shownMembers.isNotEmpty)
                          const AppMenuLabel('Members'),
                        for (final m in shownMembers)
                          AppListRow(
                            key: Key('target-picker-member-${m.id}'),
                            leading: UserAvatar(
                              name: m.displayName,
                              userId: m.id,
                              size: AppAvatarSize.s20,
                              shape: m.isBot
                                  ? AppAvatarShape.square
                                  : AppAvatarShape.circle,
                              placeholder: m.isBot
                                  ? botAvatarPlaceholder(context, m.displayName)
                                  : null,
                            ),
                            label: m.displayName,
                            onTap: () => Navigator.of(context).pop(m),
                          ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
