// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The "who can see it" multi-select in the create-channel sheet: roles and
/// members in one searchable list, each row toggling a view grant that is
/// written once the channel exists.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../providers/admin_providers.dart';
import '../providers/member_presence.dart' show membersProvider;
import '../providers/providers.dart';

/// `role:<id>` or `member:<id>`, the same key the permissions grid uses.
String audienceKey(api.OverwriteTarget kind, String id) => '${kind.wire}:$id';

const _listMaxHeight = 200.0;

class PrivateAudiencePicker extends ConsumerStatefulWidget {
  const PrivateAudiencePicker({
    super.key,
    required this.selected,
    required this.onToggle,
  });

  final Set<String> selected;
  final ValueChanged<String> onToggle;

  @override
  ConsumerState<PrivateAudiencePicker> createState() =>
      _PrivateAudiencePickerState();
}

class _PrivateAudiencePickerState extends ConsumerState<PrivateAudiencePicker> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Widget _row(String key, IconData icon, String label, {String? meta}) =>
      AppListRow(
        key: ValueKey('audience:$key'),
        leading: Icon(icon),
        label: label,
        meta: meta,
        selected: widget.selected.contains(key),
        stateDescription: widget.selected.contains(key)
            ? 'Can see this channel'
            : null,
        trailing: widget.selected.contains(key)
            ? const Icon(AppIcons.check, size: AppSizes.icon16)
            : null,
        onTap: () => widget.onToggle(key),
      );

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final roles = ref.watch(rolesProvider);
    final members = ref.watch(membersProvider);
    final selfId = ref.watch(sessionProvider).tokens?.userId;
    final needle = _search.text.trim().toLowerCase();
    bool shows(String text) =>
        needle.isEmpty || text.toLowerCase().contains(needle);

    if (roles.hasError || members.hasError) {
      return AppErrorState(
        message: 'Could not load roles and members.',
        onRetry: () {
          ref.invalidate(rolesProvider);
          ref.invalidate(membersProvider);
        },
      );
    }
    final rows = <Widget>[
      for (final role in roles.valueOrNull ?? const <api.Role>[])
        if (!role.isEveryone && shows(role.name))
          _row(
            audienceKey(api.OverwriteTarget.role, role.id),
            AppIcons.shield,
            role.name,
          ),
      for (final m in members.valueOrNull ?? const <api.UserProfile>[])
        if (m.id != selfId && shows('${m.displayName} ${m.username}'))
          _row(
            audienceKey(api.OverwriteTarget.member, m.id),
            AppIcons.account,
            m.displayName,
            meta: '@${m.username}',
          ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.selected.isEmpty
              ? 'Pick who can see it. With nobody picked, only you and people '
                    'with Administrator or Manage channels can.'
              : '${widget.selected.length} picked, plus you and people with '
                    'Administrator or Manage channels.',
          style: AppText.caption.copyWith(color: tokens.textSecondary),
        ),
        const SizedBox(height: AppSpacing.s8),
        AppInput(
          controller: _search,
          placeholder: 'Search roles and members',
          icon: const Icon(AppIcons.search),
          semanticLabel: 'Search roles and members',
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: AppSpacing.s4),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: _listMaxHeight),
          child: rows.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(AppSpacing.s12),
                  child: Text(
                    roles.isLoading || members.isLoading
                        ? 'Loading...'
                        : 'No roles or members match.',
                    style: AppText.caption.copyWith(
                      color: tokens.textSecondary,
                    ),
                  ),
                )
              : ListView(shrinkWrap: true, children: rows),
        ),
      ],
    );
  }
}
