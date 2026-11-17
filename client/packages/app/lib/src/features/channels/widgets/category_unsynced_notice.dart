// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Under a category's Private switch: the sub-categories and channels a save
/// here does not reach because they keep their own permissions (decision
/// 0120), with a way to sync them all or open each one.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../providers/admin_providers.dart';
import '../../../widgets/confirm_dialog.dart';
import '../../../widgets/run_guarded.dart';
import '../../settings/providers/settings_actions.dart';
import '../../settings/widgets/admin/channel_permissions_grid.dart';
import '../../settings/widgets/settings_entity_row.dart';
import '../../settings/widgets/settings_info_line.dart';
import 'category_permissions_sheet.dart';

/// "3 sub-categories and 2 channels have their own permissions and are not changed."
String unsyncedMessage(int subCategories, int channels) {
  String count(int n, String one, String many) => '$n ${n == 1 ? one : many}';
  final parts = [
    if (subCategories > 0)
      count(subCategories, 'sub-category', 'sub-categories'),
    if (channels > 0) count(channels, 'channel', 'channels'),
  ];
  final single = subCategories + channels == 1;
  return '${parts.join(' and ')} '
      '${single ? 'has its' : 'have their'} own permissions and '
      '${single ? 'is' : 'are'} not changed.';
}

class CategoryUnsyncedNotice extends ConsumerStatefulWidget {
  const CategoryUnsyncedNotice({
    super.key,
    required this.categoryId,
    required this.categoryName,
    this.subCategories = const [],
    this.channels = const [],
  });

  final String categoryId;
  final String categoryName;
  final List<ChannelCategoryRow> subCategories;

  /// Every channel filed under this category or one of its sub-categories.
  final List<Channel> channels;

  @override
  ConsumerState<CategoryUnsyncedNotice> createState() =>
      _CategoryUnsyncedNoticeState();
}

class _CategoryUnsyncedNoticeState extends ConsumerState<CategoryUnsyncedNotice>
    with GuardedActionState<CategoryUnsyncedNotice> {
  bool _shown = false;
  bool _syncing = false;

  /// What a save here does not reach: unsynced sub-categories, then every
  /// unsynced channel beneath, since "Sync all" re-syncs the sub-categories too.
  ({List<ChannelCategoryRow> subs, List<Channel> channels}) _unsynced() {
    bool unsynced(AsyncValue<bool?> synced) => synced.valueOrNull == false;
    return (
      subs: [
        for (final sub in widget.subCategories)
          if (unsynced(ref.watch(categoryOverwritesSyncedProvider(sub.id))))
            sub,
      ],
      channels: [
        for (final channel in widget.channels)
          if (unsynced(ref.watch(channelOverwritesSyncedProvider(channel.id))))
            channel,
      ],
    );
  }

  Future<void> _syncAll(
    List<ChannelCategoryRow> subs,
    List<Channel> channels,
  ) async {
    final confirmed = await confirmDangerousAction(
      context,
      title: 'Sync them all?',
      message: "Their own permissions are replaced by this category's.",
      confirmLabel: 'Sync',
    );
    if (!confirmed || !mounted) return;
    setState(() => _syncing = true);
    final actions = ref.read(settingsActionsProvider);
    await guard(
      whatFailed: 'sync the permissions',
      action: () async {
        // Sub-categories first, so a channel then syncs to its sub-category's new rows.
        for (final sub in subs) {
          await actions.syncCategoryOverwrites(sub.id);
        }
        for (final channel in channels) {
          await actions.syncChannelOverwrites(channel.id);
        }
      },
    );
    if (!mounted) return;
    setState(() => _syncing = false);
    for (final sub in widget.subCategories) {
      ref
        ..invalidate(categoryOverwritesSyncedProvider(sub.id))
        ..invalidate(categoryOverwritesProvider(sub.id));
    }
    for (final channel in widget.channels) {
      ref
        ..invalidate(channelOverwritesSyncedProvider(channel.id))
        ..invalidate(channelOverwritesProvider(channel.id));
    }
  }

  void _openSub(ChannelCategoryRow sub) => unawaited(
    showCategoryPermissionsSheet(
      context,
      categoryId: sub.id,
      categoryName: '${widget.categoryName} / ${sub.name}',
      isSubCategory: true,
      channels: [
        for (final c in widget.channels)
          if (c.categoryId == sub.id) c,
      ],
    ),
  );

  void _openChannel(Channel channel) => unawaited(
    showAppSheet<void>(
      context,
      maxWidth: 960,
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(AppSpacing.s16),
            child: Text(
              '#${channel.name} · Permissions',
              style: AppText.heading,
            ),
          ),
          ChannelPermissionsGrid(channel: channel),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final (:subs, :channels) = _unsynced();
    if (subs.isEmpty && channels.isEmpty) return const SizedBox.shrink();
    final error = actionError;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsInfoLine(
          unsyncedMessage(subs.length, channels.length),
          warn: true,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.s40,
            0,
            AppSpacing.s16,
            AppSpacing.s12,
          ),
          child: Wrap(
            spacing: AppSpacing.s8,
            runSpacing: AppSpacing.s8,
            children: [
              AppButton(
                label: 'Sync all',
                variant: AppButtonVariant.secondary,
                size: AppButtonSize.sm,
                busy: _syncing,
                onPressed: () => unawaited(_syncAll(subs, channels)),
              ),
              AppButton(
                label: _shown ? 'Hide' : 'Show them',
                variant: AppButtonVariant.ghost,
                size: AppButtonSize.sm,
                onPressed: () => setState(() => _shown = !_shown),
              ),
            ],
          ),
        ),
        if (_shown) ...[
          for (final sub in subs)
            _Item(
              name: sub.name,
              kind: 'Sub-category',
              icon: AppIcons.category,
              onOpen: () => _openSub(sub),
            ),
          for (final channel in channels)
            _Item(
              name: '#${channel.name}',
              kind: 'Channel',
              icon: AppIcons.hash,
              onOpen: () => _openChannel(channel),
            ),
        ],
        if (error != null)
          AppErrorState(message: error, onDismiss: clearActionError),
      ],
    );
  }
}

class _Item extends StatelessWidget {
  const _Item({
    required this.name,
    required this.kind,
    required this.icon,
    required this.onOpen,
  });

  final String name;
  final String kind;
  final IconData icon;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return SettingsEntityRow(
      dense: true,
      headline: name,
      leading: SizedBox.square(
        dimension: 20,
        child: Icon(icon, size: AppSizes.icon16, color: tokens.textSecondary),
      ),
      details: [
        Text(
          kind,
          style: AppText.caption.copyWith(color: tokens.textSecondary),
        ),
      ],
      onTap: onOpen,
      onTapSemanticLabel: 'Open $name permissions',
      actions: [
        AppIconButton(
          icon: AppIcons.chevronRight,
          iconSize: AppSizes.icon16,
          size: AppIconButtonSize.sm,
          semanticLabel: 'Open $name permissions',
          onPressed: onOpen,
        ),
      ],
    );
  }
}
