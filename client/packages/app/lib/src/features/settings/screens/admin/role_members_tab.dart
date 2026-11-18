// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The selected role's Members tab: the members who could be given the role,
/// most recently active first and narrowed by a search, then every holder in
/// two groups (bots, people) - both grouped the same way regardless of holder
/// kind, since a bot is a full principal like any other (decision 0028), not
/// a second class of member.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../members/providers/member_presence.dart' show membersProvider;
import '../../../../providers/admin_providers.dart' show roleLadderProvider;
import '../../../../providers/providers.dart';
import '../../../../widgets/run_guarded.dart';
import '../../providers/role_candidates.dart';
import '../../widgets/settings_empty.dart';
import '../../widgets/settings_section_header.dart';
import 'role_holder_avatar.dart';

/// A group past this size collapses to this many rows plus a "+N more"
/// summary, matching the design's own worked example.
const _collapseAt = 5;

/// How many people the add list shows at once, all of them up to this many;
/// each "Show more" reveals this many again.
const _candidatePage = 20;

class RoleMembersTab extends ConsumerStatefulWidget {
  const RoleMembersTab({super.key, required this.role, this.locked = false});

  final api.Role role;

  /// The role is not below the viewer's highest, so its holders are listed without add or remove.
  final bool locked;

  @override
  ConsumerState<RoleMembersTab> createState() => _RoleMembersTabState();
}

class _RoleMembersTabState extends ConsumerState<RoleMembersTab>
    with GuardedActionState<RoleMembersTab> {
  final TextEditingController _search = TextEditingController();
  bool _expandBots = false;
  bool _expandPeople = false;
  int _candidatesShown = _candidatePage;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
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
        final role = widget.role;
        final ladder = ref.watch(roleLadderProvider);
        final locked = widget.locked || role.isManagedByBot || role.isBotsRole;
        final activityState = locked ? null : ref.watch(memberActivityProvider);
        // Null when it failed: a server without the route must not call everyone silent.
        final activity = activityState?.valueOrNull;
        // Rows wait for their order, so a click never lands on a row that is about to move.
        final ordering =
            activityState != null &&
            !activityState.hasValue &&
            !activityState.hasError;
        final searching = _search.text.trim().isNotEmpty;
        final candidates = locked || ordering
            ? const <api.UserProfile>[]
            : roleCandidates(
                members: list,
                role: role,
                ladder: ladder,
                activity: activity ?? const {},
                query: _search.text,
              );
        final shownCandidates = candidates.take(_candidatesShown).toList();
        final moreCandidates = candidates.length - shownCandidates.length;
        final remove = locked ? null : _remove;
        bool removable(api.UserProfile m) =>
            ladder.lockOf(role, member: m, held: true) == null;

        return Column(
          children: [
            if (!locked)
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
                  onChanged: (_) =>
                      setState(() => _candidatesShown = _candidatePage),
                  onSubmitted: (_) {
                    if (!searching || candidates.isEmpty) return;
                    unawaited(_add(candidates.first));
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
                  if (ordering)
                    const SettingsSectionCard(
                      title: 'Add to this role',
                      children: [
                        Padding(
                          padding: EdgeInsets.all(AppSpacing.s16),
                          child: Center(
                            child: AppSpinner(size: AppSpinnerSize.lg),
                          ),
                        ),
                      ],
                    )
                  else if (candidates.isNotEmpty)
                    SettingsSectionCard(
                      title: 'Add to this role',
                      children: [
                        for (final (index, candidate)
                            in shownCandidates.indexed)
                          AppListRow(
                            key: ValueKey(candidate.id),
                            leading: roleHolderAvatar(context, candidate),
                            label: candidate.displayName,
                            meta: activity == null
                                ? '@${candidate.username}'
                                : postedLabel(activity[candidate.id]),
                            trailing: _AddAction(
                              name: candidate.displayName,
                              enterAdds: searching && index == 0,
                              onAdd: () => unawaited(_add(candidate)),
                            ),
                            // Unasked rows add only from their button, so a stray tap grants nothing.
                            onTap: searching
                                ? () => unawaited(_add(candidate))
                                : null,
                          ),
                        if (moreCandidates > 0)
                          _ShowMoreRow(
                            count: moreCandidates < _candidatePage
                                ? moreCandidates
                                : _candidatePage,
                            onTap: () => setState(
                              () => _candidatesShown += _candidatePage,
                            ),
                          ),
                      ],
                    )
                  else if (searching)
                    const SettingsSectionCard(
                      title: 'Add to this role',
                      children: [
                        SettingsEmptyState(
                          icon: AppIcons.search,
                          title: 'No one matches',
                          detail: 'Try another name.',
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
                      onRemove: remove,
                      removable: removable,
                    ),
                  _HolderGroup(
                    title: 'People',
                    holders: people,
                    expanded: _expandPeople,
                    onExpand: () => setState(() => _expandPeople = true),
                    onRemove: remove,
                    removable: removable,
                    emptyTitle: 'No people hold this role',
                    emptyDetail: ordering || candidates.isEmpty || searching
                        ? null
                        : 'Add someone from the list above.',
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

/// The add list's last row, revealing the next [count] people.
class _ShowMoreRow extends StatelessWidget {
  const _ShowMoreRow({required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => FocusableTapTarget(
    onTap: onTap,
    semanticLabel: 'Show $count more',
    builder: (context, focused, hovered) => SettingsSubRow(
      label: 'Show $count more',
      trailing: const Icon(AppIcons.chevronDown, size: AppSizes.icon16),
    ),
  );
}

/// An Add button on every candidate; Enter in the search adds only the first,
/// so only that row says so, and only where there is a keyboard to press it on.
class _AddAction extends StatelessWidget {
  const _AddAction({
    required this.name,
    required this.enterAdds,
    required this.onAdd,
  });

  final String name;
  final bool enterAdds;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: AppSpacing.s8,
      children: [
        if (enterAdds && !AppTouchTargets.of(context))
          Text(
            'Enter',
            style: AppText.caption.copyWith(color: tokens.textSecondary),
          ),
        AppButton(
          label: 'Add',
          size: AppButtonSize.sm,
          semanticLabel: 'Add $name',
          onPressed: onAdd,
        ),
      ],
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
    required this.removable,
    this.emptyTitle,
    this.emptyDetail,
  });

  final String title;
  final List<api.UserProfile> holders;
  final bool expanded;
  final VoidCallback onExpand;

  /// Null lists the holders without a Remove button.
  final ValueChanged<api.UserProfile>? onRemove;

  /// Whether the viewer may take the role from this holder, which the owner's own roles never are.
  final bool Function(api.UserProfile) removable;
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
              leading: roleHolderAvatar(context, holder),
              label: holder.displayName,
              meta: '@${holder.username}',
              trailing: switch (onRemove) {
                final remove? when removable(holder) => AppButton(
                  label: 'Remove',
                  semanticLabel: 'Remove ${holder.displayName}',
                  variant: AppButtonVariant.ghost,
                  size: AppButtonSize.sm,
                  onPressed: () => remove(holder),
                ),
                _ => null,
              },
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
