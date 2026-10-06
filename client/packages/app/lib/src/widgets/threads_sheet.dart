// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The sheet the channel header's thread pill opens: every thread hanging
/// off a message in this channel, newest activity first, each showing its
/// parent's own snippet and author, its reply count, and whether the
/// caller has unread replies in it - the listing docs/IMPLIED-GAPS.md named
/// as missing entirely, and this is its one client surface.
///
/// Mirrors `pinned_messages_sheet.dart`'s own shape (a plain `ListTile` per
/// row, the same loading/error/empty states) rather than inventing a
/// second one for a very similar list.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../providers/threads.dart';
import '../routing/breakpoints.dart';
import '../providers/user_profiles.dart';
import '../routing/routes.dart';
import 'author_label.dart';
import 'sheet_item_list.dart';
import 'user_avatar.dart';

/// Marks the sizing box around the sheet's body, so a test can measure it
/// directly rather than inferring the fix from a screenshot - the same
/// technique `pinnedMessagesBodyBoxKey` uses.
const threadsBodyBoxKey = Key('threads_body_box');

/// The router is captured here, not inside the sheet: the sheet's own
/// context is a dialog pushed straight onto the Navigator, outside a
/// route's own builder subtree where `GoRouter.of` would otherwise have to
/// resolve - the same reason `showPinnedMessagesSheet` captures it up front.
Future<void> showThreadsSheet(BuildContext context, String channelId) {
  final router = GoRouter.of(context);
  return showAppSheet<void>(
    context,
    maxWidth: 560,
    scrolls: true,
    builder: (context) => _ThreadsSheet(channelId: channelId, router: router),
  );
}

class _ThreadsSheet extends ConsumerWidget {
  const _ThreadsSheet({required this.channelId, required this.router});

  final String channelId;
  final GoRouter router;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final threads = ref.watch(threadsListProvider(channelId));
    final hasList = threads.valueOrNull?.isNotEmpty ?? false;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.s16,
            0,
            AppSpacing.s16,
            AppSpacing.s12,
          ),
          child: Row(
            children: [
              Icon(
                AppIcons.thread,
                size: AppSizes.icon16,
                color: tokens.textSecondary,
              ),
              const SizedBox(width: AppSpacing.s8),
              Text(
                'Threads',
                style: AppText.body.copyWith(
                  color: tokens.textPrimary,
                  fontWeight: AppWeights.semi,
                ),
              ),
            ],
          ),
        ),
        ConstrainedBox(
          key: threadsBodyBoxKey,
          // A ceiling for a real list, via `_Body`'s own shrinkWrap ListView; an empty or loading state keeps a modest fixed box instead.
          constraints: hasList
              ? BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height * 0.6,
                )
              : const BoxConstraints.tightFor(height: 160),
          child: _Body(channelId: channelId, threads: threads, router: router),
        ),
      ],
    );
  }
}

class _Body extends ConsumerWidget {
  const _Body({
    required this.channelId,
    required this.threads,
    required this.router,
  });

  final String channelId;
  final AsyncValue<List<api.ThreadListItem>> threads;
  final GoRouter router;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final forbidden = threads.error is api.ForbiddenException;
    return AppAsyncView<List<api.ThreadListItem>>(
      value: AppAsyncState(data: threads.valueOrNull, error: threads.error),
      errorMessage: forbidden
          ? 'You do not have permission to see threads here.'
          : 'Could not load threads.',
      onRetry: forbidden
          ? null
          : () => ref.invalidate(threadsListProvider(channelId)),
      emptyMessage: 'No threads yet.',
      isEmpty: (list) => list.isEmpty,
      data: (context, list) {
        resolveAuthorProfiles(ref, list.map((t) => t.parentAuthorId));
        return SheetItemList(
          itemCount: list.length,
          itemBuilder: (context, i) =>
              ThreadRow(thread: list[i], router: router),
        );
      },
    );
  }
}

/// One thread row: selects only its own parent author's slice of
/// [batchProfilesControllerProvider], so an unrelated author resolving does
/// not rebuild every row in the list - see `message_row_identity.dart`.
class ThreadRow extends ConsumerWidget {
  const ThreadRow({super.key, required this.thread, required this.router});

  final api.ThreadListItem thread;
  final GoRouter router;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final resolution = ref.watch(
      batchProfilesControllerProvider.select(
        (m) => authorResolution(m, thread.parentAuthorId ?? ''),
      ),
    );
    final name = authorLabelResolved(
      authorId: thread.parentAuthorId,
      cachedDisplayName: thread.parentAuthorDisplayName,
      resolution: resolution,
    );
    return ListTile(
      onTap: () {
        // Captured before the pop disposes this sheet's ref: the app container and router outlive it, so the thread can dock (expanded) or push its modal route (compact) after.
        final container = ProviderScope.containerOf(context, listen: false);
        final width = MediaQuery.sizeOf(context).width;
        Navigator.of(context).pop();
        if (LayoutClass.fromWidth(width).fitsThreadPane(width)) {
          dockThread(container, thread.id);
        } else {
          router.push(Routes.thread(thread.id));
        }
      },
      leading: UserAvatar(
        userId: thread.parentAuthorId,
        name: name,
        size: AppAvatarSize.s28,
      ),
      title: AuthorNameLine(
        name: name,
        profile: resolution.profile,
        style: TextStyle(
          fontWeight: thread.isUnread ? AppWeights.medium : AppWeights.regular,
        ),
      ),
      subtitle: Text(
        thread.parentContent,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: _ReplyCount(thread: thread),
    );
  }
}

/// A thread's reply count, with the same small unread dot
/// `ThreadReplySummary` (`message_row_parts.dart`) uses beside a message -
/// one shape for "this thread has something new" rather than a second one
/// invented for this list.
class _ReplyCount extends StatelessWidget {
  const _ReplyCount({required this.thread});

  final api.ThreadListItem thread;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final label = thread.replyCount == 1
        ? '1 reply'
        : '${thread.replyCount} replies';
    return Semantics(
      label: thread.isUnread ? '$label, unread' : label,
      child: ExcludeSemantics(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: AppText.caption.copyWith(color: tokens.textSecondary),
            ),
            if (thread.isUnread) ...[
              const SizedBox(width: AppSpacing.s4),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: tokens.accent,
                  borderRadius: BorderRadius.circular(AppRadii.full),
                ),
                child: const SizedBox(width: 6, height: 6),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
