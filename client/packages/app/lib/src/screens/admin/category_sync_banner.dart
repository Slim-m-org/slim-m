// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Above a channel's permissions grid: whether the channel follows its
/// category's permissions (decision 0064), and a way back when it does not.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' show SlimmApiCategoryPermissions;
import 'package:slimm_design_system/design_system.dart';

import '../../providers/admin_providers.dart';
import '../../providers/providers.dart';
import '../../widgets/confirm_dialog.dart';
import '../../widgets/run_guarded.dart';

class CategorySyncBanner extends ConsumerStatefulWidget {
  const CategorySyncBanner({super.key, required this.channelId});

  final String channelId;

  @override
  ConsumerState<CategorySyncBanner> createState() => _CategorySyncBannerState();
}

class _CategorySyncBannerState extends ConsumerState<CategorySyncBanner>
    with GuardedActionState<CategorySyncBanner> {
  bool _syncing = false;

  Future<void> _sync() async {
    final confirmed = await confirmDangerousAction(
      context,
      title: 'Sync with category?',
      message: "This channel's own permissions are replaced by its category's.",
      confirmLabel: 'Sync',
    );
    if (!confirmed || !mounted) return;
    setState(() => _syncing = true);
    final ok = await guard(
      whatFailed: 'sync the permissions',
      action: () =>
          ref.read(apiProvider).syncChannelOverwrites(widget.channelId),
    );
    if (!mounted) return;
    setState(() => _syncing = false);
    if (ok) {
      ref.invalidate(channelOverwritesProvider(widget.channelId));
      ref.invalidate(channelOverwritesSyncedProvider(widget.channelId));
    }
  }

  @override
  Widget build(BuildContext context) {
    final synced = ref
        .watch(channelOverwritesSyncedProvider(widget.channelId))
        .valueOrNull;
    if (synced == null) return const SizedBox.shrink();
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final error = actionError;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.s16,
        0,
        AppSpacing.s16,
        AppSpacing.s8,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                synced ? AppIcons.check : AppIcons.info,
                size: AppSizes.icon16,
                color: tokens.textSecondary,
              ),
              const SizedBox(width: AppSpacing.s8),
              Expanded(
                child: Text(
                  synced
                      ? "Follows its category's permissions."
                      : 'Has its own permissions.',
                  style: AppText.caption.copyWith(color: tokens.textSecondary),
                ),
              ),
              if (!synced)
                AppButton(
                  label: 'Sync with category',
                  variant: AppButtonVariant.secondary,
                  size: AppButtonSize.sm,
                  busy: _syncing,
                  onPressed: _sync,
                ),
            ],
          ),
          if (error != null)
            AppErrorState(message: error, onDismiss: clearActionError),
        ],
      ),
    );
  }
}
