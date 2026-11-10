// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The destination list a forward and a share both pick from: every channel,
/// DM and group the caller may post to, drawn the way the rail draws them.
///
/// Only the list lives here. What picking a row does (send a forward, open a
/// composer with the shared files staged) belongs to each caller.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../widgets/sheet_item_list.dart';
import '../../channels/widgets/channel_kind_icon.dart';
import '../../channels/widgets/group_avatar_stack.dart';
import '../../members/widgets/user_avatar.dart';
import '../providers/forward_targets.dart';

/// The search field over [DestinationList]; its text goes straight back to the caller.
class DestinationSearchField extends StatelessWidget {
  const DestinationSearchField({
    super.key,
    required this.onChanged,
    required this.semanticLabel,
    this.controller,
  });

  final ValueChanged<String> onChanged;
  final String semanticLabel;
  final TextEditingController? controller;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return AppInput(
      controller: controller,
      placeholder: 'Search channels and DMs',
      icon: Icon(
        AppIcons.search,
        size: AppSizes.icon16,
        color: tokens.textSecondary,
      ),
      onChanged: onChanged,
      semanticLabel: semanticLabel,
    );
  }
}

/// The matching [ForwardTarget]s for [query], filtered by [search]; tapping a
/// row calls [onPick]. While [busyChannelId] is set every other row is
/// disabled and that row shows a spinner.
class DestinationList extends ConsumerWidget {
  const DestinationList({
    super.key,
    required this.query,
    required this.search,
    required this.onPick,
    required this.errorMessage,
    required this.emptyMessage,
    this.busyChannelId,
  });

  final ForwardTargetsQuery query;
  final String search;
  final ValueChanged<ForwardTarget> onPick;
  final String errorMessage;
  final String emptyMessage;
  final String? busyChannelId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final targets = ref.watch(forwardTargetsProvider(query));
    return AppAsyncView(
      value: AppAsyncState(data: targets.valueOrNull, error: targets.error),
      errorMessage: errorMessage,
      onRetry: () => ref.invalidate(forwardTargetsProvider(query)),
      emptyMessage: emptyMessage,
      isEmpty: (list) => list.isEmpty,
      data: (context, list) => _results(context, tokens, list),
    );
  }

  Widget _results(
    BuildContext context,
    AppTokens tokens,
    List<ForwardTarget> list,
  ) {
    final needle = search.trim().toLowerCase();
    final filtered = needle.isEmpty
        ? list
        : [
            for (final target in list)
              if (target.matches(needle)) target,
          ];
    if (filtered.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.s16),
          child: Text(
            'No matches.',
            style: TextStyle(color: tokens.textSecondary),
          ),
        ),
      );
    }
    return SheetItemList(
      itemCount: filtered.length,
      itemBuilder: (context, i) => _row(filtered[i], tokens),
    );
  }

  Widget _row(ForwardTarget target, AppTokens tokens) {
    final busyHere = busyChannelId == target.channelId;
    return AppListRow(
      leading: _leading(target, tokens),
      label: target.label,
      trailing: busyHere ? const AppSpinner(size: AppSpinnerSize.sm) : null,
      onTap: busyChannelId != null ? null : () => onPick(target),
    );
  }

  Widget _leading(ForwardTarget target, AppTokens tokens) {
    final groupMemberIds = target.groupMemberIds;
    if (groupMemberIds != null) {
      return GroupAvatarStack(
        memberIds: groupMemberIds,
        size: AppAvatarSize.s24,
      );
    }
    // A DM is a person; one generic glyph made them all look alike.
    final userId = target.userId;
    if (target.isDm && userId != null) {
      return UserAvatar.known(
        userId: userId,
        avatarUpdatedAt: target.avatarUpdatedAt,
        name: target.label,
        size: AppAvatarSize.s24,
      );
    }
    if (target.isDm) return const Icon(AppIcons.account);
    return ChannelKindIcon(
      isVoice: target.isVoice,
      restricted: target.restricted,
      color: tokens.textSecondary,
      size: AppSizes.icon20,
    );
  }
}
