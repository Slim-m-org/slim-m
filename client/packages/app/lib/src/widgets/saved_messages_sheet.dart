// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The sheet the Space menu's "Saved messages" item opens: everything the
/// caller has kept, newest save first, with a remove action.
///
/// Removing lives here rather than on the message row, unlike unpinning.
/// A saved list is private, so a transcript has no idea what is in it and
/// would need a request per row to draw a toggled state; the one place the
/// state is already on screen is this list, so that is where it can be
/// changed.
///
/// The list spans channels, so each row says which one it came from - the
/// pinned sheet can leave that out because everything in it is from the
/// channel you are already looking at.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../providers/channel_by_id_provider.dart';
import '../providers/providers.dart';
import '../providers/saved_messages_controller.dart';
import '../providers/user_profiles.dart';
import 'author_label.dart';
import 'channel_label.dart';
import 'channel_rail.dart' show selectedChannelId;
import 'message_jump.dart';
import 'reply_target_summary.dart' show previewLine;
import 'run_guarded.dart';
import 'sheet_item_list.dart';
import 'user_avatar.dart';

/// Marks the sizing box around the sheet's body, so a test can measure it
/// directly rather than inferring the fix from a screenshot - the same
/// technique `pinnedMessagesBodyBoxKey` uses.
const savedMessagesBodyBoxKey = Key('saved_messages_body_box');

/// The router and current channel are captured here for the reason
/// `showPinnedMessagesSheet` records: `GoRouterState.of` only resolves inside
/// a route's own builder subtree, and a sheet is pushed outside all of them.
Future<void> showSavedMessagesSheet(BuildContext context) {
  final router = GoRouter.of(context);
  final currentChannelId = selectedChannelId(context);
  return showAppSheet<void>(
    context,
    maxWidth: 560,
    scrolls: true,
    builder: (context) =>
        _SavedMessagesSheet(router: router, currentChannelId: currentChannelId),
  );
}

class _SavedMessagesSheet extends ConsumerWidget {
  const _SavedMessagesSheet({
    required this.router,
    required this.currentChannelId,
  });

  final GoRouter router;
  final String? currentChannelId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final saved = ref.watch(savedMessagesProvider);
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(
              AppSpacing.s16,
              0,
              AppSpacing.s16,
              AppSpacing.s8,
            ),
            child: Text('Saved messages', style: AppText.heading),
          ),
          ConstrainedBox(
            key: savedMessagesBodyBoxKey,
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.5,
            ),
            child: AppAsyncView(
              value: AppAsyncState(data: saved.valueOrNull, error: saved.error),
              errorMessage: 'Could not load your saved messages.',
              onRetry: () => ref.invalidate(savedMessagesProvider),
              emptyMessage:
                  'Nothing saved yet. Save a message from its menu to keep it '
                  'here.',
              isEmpty: (list) => list.isEmpty,
              data: (context, list) {
                resolveAuthorProfiles(ref, list.map((s) => s.message.authorId));
                return SheetItemList(
                  itemCount: list.length,
                  itemBuilder: (context, i) => SavedMessageRow(
                    saved: list[i],
                    router: router,
                    currentChannelId: currentChannelId,
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

/// One saved-message row: selects only its own author's slice of
/// [batchProfilesControllerProvider], so an unrelated author resolving does
/// not rebuild every row - see `message_row_identity.dart`.
class SavedMessageRow extends ConsumerStatefulWidget {
  const SavedMessageRow({
    super.key,
    required this.saved,
    required this.router,
    required this.currentChannelId,
  });

  final api.SavedMessage saved;
  final GoRouter router;
  final String? currentChannelId;

  @override
  ConsumerState<SavedMessageRow> createState() => _SavedMessageRowState();
}

class _SavedMessageRowState extends ConsumerState<SavedMessageRow>
    with GuardedActionState<SavedMessageRow> {
  Future<void> _remove() async {
    await guard(
      whatFailed: 'remove the saved message',
      action: () async {
        await ref.read(apiProvider).unsaveMessage(widget.saved.message.id);
        ref.invalidate(savedMessagesProvider);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final message = widget.saved.message;
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final resolution = ref.watch(
      batchProfilesControllerProvider.select(
        (m) => authorResolution(m, message.authorId ?? ''),
      ),
    );
    final name = authorLabelResolved(
      authorId: message.authorId,
      cachedDisplayName: message.authorDisplayName,
      resolution: resolution,
    );
    // The channel it came from; always held locally, since the server only lists what the reader can see.
    final channel = ref
        .watch(channelByIdProvider(message.channelId))
        .valueOrNull;
    final where = channelDisplayLabel(channel);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
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
        ListTile(
          onTap: () {
            final read = ref.read;
            Navigator.of(context).pop();
            jumpToMessage(
              widget.router,
              read,
              currentChannelId: widget.currentChannelId,
              channelId: message.channelId,
              messageId: message.id,
            );
          },
          leading: UserAvatar(
            userId: message.authorId,
            name: name,
            size: AppAvatarSize.s28,
          ),
          title: AuthorNameLine(
            name: name,
            profile: resolution.profile,
            secondary: where == null ? null : '·  $where',
          ),
          subtitle: Text(
            previewLine(message.content, message.attachments),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: tokens.textSecondary),
          ),
          trailing: AppIconButton(
            icon: AppIcons.removeFromList,
            semanticLabel: 'Remove from saved',
            size: AppIconButtonSize.sm,
            onPressed: () => _remove(),
          ),
        ),
      ],
    );
  }
}
