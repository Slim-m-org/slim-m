// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Above a permissions grid: whether a channel follows its category's
/// permissions (decision 0064), or a sub-category its parent's (0120), and a
/// way back when it does not.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../../providers/admin_providers.dart';
import '../../../../widgets/confirm_dialog.dart';
import '../../../../widgets/run_guarded.dart';
import '../../providers/settings_actions.dart';

class CategorySyncBanner extends ConsumerStatefulWidget {
  const CategorySyncBanner({super.key, required String this.channelId})
    : categoryId = null;

  /// A sub-category's own line; shows nothing for a top-level category.
  const CategorySyncBanner.forSubCategory({
    super.key,
    required String this.categoryId,
  }) : channelId = null;

  final String? channelId;
  final String? categoryId;

  @override
  ConsumerState<CategorySyncBanner> createState() => _CategorySyncBannerState();
}

/// What differs between a channel following its category and a sub-category its parent.
typedef _SyncCopy = ({
  String follows,
  String button,
  String title,
  String message,
});

const _SyncCopy _channelCopy = (
  follows: "Follows its category's permissions.",
  button: 'Sync with category',
  title: 'Sync with category?',
  message: "This channel's own permissions are replaced by its category's.",
);

const _SyncCopy _subCategoryCopy = (
  follows: "Follows its parent category's permissions.",
  button: 'Sync with parent category',
  title: 'Sync with parent category?',
  message:
      "This category's own permissions are replaced by its parent's, and so "
      'are those of the channels that follow it.',
);

class _CategorySyncBannerState extends ConsumerState<CategorySyncBanner>
    with GuardedActionState<CategorySyncBanner> {
  bool _syncing = false;

  _SyncCopy get _copy =>
      widget.categoryId == null ? _channelCopy : _subCategoryCopy;

  Future<void> _sync() async {
    final copy = _copy;
    final confirmed = await confirmDangerousAction(
      context,
      title: copy.title,
      message: copy.message,
      confirmLabel: 'Sync',
    );
    if (!confirmed || !mounted) return;
    setState(() => _syncing = true);
    final actions = ref.read(settingsActionsProvider);
    final channelId = widget.channelId;
    final categoryId = widget.categoryId;
    final ok = await guard(
      whatFailed: 'sync the permissions',
      action: () async {
        if (channelId != null) await actions.syncChannelOverwrites(channelId);
        if (categoryId != null) {
          await actions.syncCategoryOverwrites(categoryId);
        }
      },
    );
    if (!mounted) return;
    setState(() => _syncing = false);
    if (ok) _refresh();
  }

  void _refresh() {
    if (widget.channelId case final channelId?) {
      ref.invalidate(channelOverwritesProvider(channelId));
      ref.invalidate(channelOverwritesSyncedProvider(channelId));
    }
    if (widget.categoryId case final categoryId?) {
      ref.invalidate(categoryOverwritesProvider(categoryId));
      ref.invalidate(categoryOverwritesSyncedProvider(categoryId));
    }
  }

  bool? _synced() {
    if (widget.channelId case final channelId?) {
      return ref.watch(channelOverwritesSyncedProvider(channelId)).valueOrNull;
    }
    if (widget.categoryId case final categoryId?) {
      return ref
          .watch(categoryOverwritesSyncedProvider(categoryId))
          .valueOrNull;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final synced = _synced();
    if (synced == null) return const SizedBox.shrink();
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final copy = _copy;
    final error = actionError;
    final message = Text(
      synced ? copy.follows : 'Has its own permissions.',
      style: AppText.caption.copyWith(color: tokens.textSecondary),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.s12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppCallout(
            tone: AppCalloutTone.info,
            icon: synced ? AppIcons.check : AppIcons.info,
            centred: true,
            child: Row(
              children: [
                Expanded(child: message),
                if (!synced) ...[
                  const SizedBox(width: AppSpacing.s8),
                  AppButton(
                    label: copy.button,
                    variant: AppButtonVariant.secondary,
                    size: AppButtonSize.sm,
                    busy: _syncing,
                    onPressed: _sync,
                  ),
                ],
              ],
            ),
          ),
          if (error != null)
            AppErrorState(message: error, onDismiss: clearActionError),
        ],
      ),
    );
  }
}
