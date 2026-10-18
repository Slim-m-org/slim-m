// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The inbox: every channel with an unread mention or unread messages, newest
/// first with mentions on top, each one tap from the message, plus a "Mark all
/// read" for the lot.
///
/// A sheet like the saved-messages one: a bottom sheet under 600 and a centred
/// dialog above it, decided by `showAppSheet`.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../routing/routes.dart';
import '../../../widgets/run_guarded.dart';
import '../../../widgets/sheet_item_list.dart';
import '../../channels/widgets/channel_label.dart';
import '../../channels/widgets/channel_rail.dart' show selectedChannelId;
import '../../members/providers/user_profiles.dart';
import '../../members/widgets/user_avatar.dart';
import '../../settings/providers/display_density.dart';
import '../providers/inbox.dart';
import 'author_label.dart';
import 'mark_read_action.dart';
import 'message_jump.dart';
import 'reply_target_summary.dart' show previewLine;

/// Marks the sizing box around the sheet's body, so a test can measure it.
const inboxBodyBoxKey = Key('inbox_body_box');

Future<void> showInboxSheet(BuildContext context) {
  final router = GoRouter.of(context);
  final currentChannelId = selectedChannelId(context);
  return showAppSheet<void>(
    context,
    maxWidth: 560,
    scrolls: true,
    builder: (context) =>
        _InboxSheet(router: router, currentChannelId: currentChannelId),
  );
}

class _InboxSheet extends ConsumerStatefulWidget {
  const _InboxSheet({required this.router, required this.currentChannelId});

  final GoRouter router;
  final String? currentChannelId;

  @override
  ConsumerState<_InboxSheet> createState() => _InboxSheetState();
}

class _InboxSheetState extends ConsumerState<_InboxSheet>
    with GuardedActionState<_InboxSheet> {
  bool _busy = false;

  Future<void> _markAllRead() async {
    setState(() => _busy = true);
    await guard(
      whatFailed: 'mark everything read',
      action: () async {
        final ids = await ref.refresh(inboxUnreadIdsProvider.future);
        if (!mounted) return;
        await markChannelsRead(
          ProviderScope.containerOf(context, listen: false),
          ids,
        );
      },
    );
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final inbox = ref.watch(inboxProvider);
    final entries = inbox.valueOrNull ?? const <InboxEntry>[];
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.s16,
              0,
              AppSpacing.s16,
              AppSpacing.s8,
            ),
            child: Row(
              children: [
                const Expanded(child: Text('Inbox', style: AppText.heading)),
                AppButton(
                  label: 'Mark all read',
                  variant: AppButtonVariant.ghost,
                  icon: AppIcons.check,
                  onPressed: entries.isEmpty || _busy ? null : _markAllRead,
                ),
              ],
            ),
          ),
          if (actionError case final error?)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.s16,
                0,
                AppSpacing.s16,
                AppSpacing.s8,
              ),
              child: AppErrorState(message: error, onDismiss: clearActionError),
            ),
          ConstrainedBox(
            key: inboxBodyBoxKey,
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.5,
            ),
            child: AppAsyncView(
              value: AppAsyncState(data: inbox.valueOrNull, error: inbox.error),
              errorMessage: 'Could not load your inbox.',
              onRetry: () => ref.invalidate(inboxProvider),
              emptyMessage: 'You are all caught up.',
              isEmpty: (list) => list.isEmpty,
              data: (context, list) {
                resolveAuthorProfiles(
                  ref,
                  list.map((e) => e.message?.authorId),
                );
                return SheetItemList(
                  itemCount: list.length,
                  itemBuilder: (context, i) => InboxRow(
                    entry: list[i],
                    router: widget.router,
                    currentChannelId: widget.currentChannelId,
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// One channel's row. A mention leads with who wrote it; an unread run leads
/// with the channel and how many are waiting.
class InboxRow extends ConsumerWidget {
  const InboxRow({
    super.key,
    required this.entry,
    required this.router,
    required this.currentChannelId,
  });

  final InboxEntry entry;
  final GoRouter router;
  final String? currentChannelId;

  void _open(BuildContext context, WidgetRef ref) {
    final read = ref.read;
    final message = entry.message;
    Navigator.of(context).pop();
    if (entry.mentioned && message != null) {
      jumpToMessage(
        router,
        read,
        currentChannelId: currentChannelId,
        channelId: entry.channel.id,
        messageId: message.id,
      );
      return;
    }
    router.go(Routes.channel(entry.channel.id));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final density = ref.watch(messageDensityControllerProvider);
    final message = entry.message;
    final where = channelDisplayLabel(entry.channel) ?? '';
    final resolution = ref.watch(
      batchProfilesControllerProvider.select(
        (m) => authorResolution(m, message?.authorId ?? ''),
      ),
    );
    final author = authorLabelResolved(
      authorId: message?.authorId,
      cachedDisplayName: message?.authorDisplayName,
      resolution: resolution,
    );
    final snippet = message == null
        ? null
        : previewLine(message.content, const []);
    return ListTile(
      dense: density == AppDensity.compact,
      visualDensity: density.tileVisualDensity,
      onTap: () => _open(context, ref),
      leading: entry.mentioned && message != null
          ? UserAvatar(
              userId: message.authorId,
              name: author,
              size: density.listAvatarSize,
            )
          : SizedBox(
              width: density.listAvatarSize,
              height: density.listAvatarSize,
              child: Icon(
                entry.mentioned ? AppIcons.mentions : AppIcons.hash,
                size: AppSizes.icon20,
                color: tokens.textSecondary,
              ),
            ),
      title: entry.mentioned && message != null
          ? AuthorNameLine(
              name: author,
              profile: resolution.profile,
              secondary: '·  $where',
            )
          : Text(where, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        snippet ?? (entry.mentioned ? 'You were mentioned' : ''),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: tokens.textSecondary),
      ),
      trailing: entry.mentioned || entry.unread <= 0
          ? null
          : Text(
              entry.unread > 99 ? '99+' : '${entry.unread}',
              style: AppText.caption.copyWith(color: tokens.textSecondary),
            ),
    );
  }
}
