// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The few channels with something waiting, on the home.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../routing/routes.dart';
import '../../channels/widgets/channel_label.dart';
import '../../messages/providers/inbox.dart';
import '../../messages/widgets/inbox_sheet.dart';

/// Rows shown before the rest are left to the inbox.
const homeUnreadLimit = 4;

class HomeUnread extends ConsumerWidget {
  const HomeUnread({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entries = ref.watch(inboxProvider).valueOrNull ?? const [];
    if (entries.isEmpty) return const SizedBox.shrink();
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final rowHeight = AppTouchTargets.of(context)
        ? AppSizes.rowTouch
        : AppSizes.rowPointer;
    final rest = entries.length - homeUnreadLimit;
    return AppCard(
      title: 'Waiting for you',
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.s4),
      child: Column(
        children: [
          for (final entry in entries.take(homeUnreadLimit))
            _UnreadRow(entry: entry, height: rowHeight, tokens: tokens),
          if (rest > 0)
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.s4),
                child: AppButton(
                  label: 'See all ${entries.length}',
                  variant: AppButtonVariant.ghost,
                  onPressed: () => showInboxSheet(context),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _UnreadRow extends StatelessWidget {
  const _UnreadRow({
    required this.entry,
    required this.height,
    required this.tokens,
  });

  final InboxEntry entry;
  final double height;
  final AppTokens tokens;

  @override
  Widget build(BuildContext context) {
    final count = entry.unread > 99 ? '99+' : '${entry.unread}';
    return InkWell(
      onTap: () => context.go(Routes.channel(entry.channel.id)),
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: height),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s16),
          child: Row(
            spacing: AppSpacing.s12,
            children: [
              Icon(
                entry.mentioned ? AppIcons.mentions : AppIcons.hash,
                size: AppSizes.icon16,
                color: tokens.textSecondary,
              ),
              Expanded(
                child: Text(
                  channelDisplayLabel(entry.channel) ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.ui.copyWith(color: tokens.textPrimary),
                ),
              ),
              Text(
                entry.mentioned ? 'Mentioned' : count,
                style: AppText.caption.copyWith(color: tokens.textSecondary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
