// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The sheet the channel header's pin pill opens: every message currently
/// pinned in this channel, newest pin first, with an unpin action for
/// whoever the server lets use it (a failed attempt is just left in place -
/// the button that caused it is still right there to retry).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../providers/pins_controller.dart';
import '../providers/user_profiles.dart';
import 'author_label.dart';
import 'channel_rail.dart' show selectedChannelId;
import 'message_jump.dart';
import 'reply_target_summary.dart' show previewLine;
import 'sheet_item_list.dart';
import 'user_avatar.dart';

/// Marks the sizing box around the sheet's body, so a test can measure it
/// directly rather than inferring the fix from a screenshot.
const pinnedMessagesBodyBoxKey = Key('pinned_messages_body_box');

/// The router and current channel are captured here, not inside the sheet:
/// `GoRouterState.of` (which [selectedChannelId] needs) only resolves inside
/// a route's own builder subtree, and the sheet's own context is a dialog
/// pushed straight onto the Navigator, outside all of them.
Future<void> showPinnedMessagesSheet(BuildContext context, String channelId) {
  final router = GoRouter.of(context);
  final currentChannelId = selectedChannelId(context);
  return showAppSheet<void>(
    context,
    maxWidth: 560,
    scrolls: true,
    builder: (context) => _PinnedMessagesSheet(
      channelId: channelId,
      router: router,
      currentChannelId: currentChannelId,
    ),
  );
}

class _PinnedMessagesSheet extends ConsumerWidget {
  const _PinnedMessagesSheet({
    required this.channelId,
    required this.router,
    required this.currentChannelId,
  });

  final String channelId;
  final GoRouter router;
  final String? currentChannelId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final pins = ref.watch(pinsControllerProvider(channelId));
    final body = _Body(
      channelId: channelId,
      pins: pins,
      router: router,
      currentChannelId: currentChannelId,
    );
    // Only a real, scrollable list earns the tall box; an empty or loading state is one centred line.
    final hasList = pins.pinned != null && pins.pinned!.isNotEmpty;

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
                AppIcons.pin,
                size: AppSizes.icon16,
                color: tokens.textSecondary,
              ),
              const SizedBox(width: AppSpacing.s8),
              Text(
                'Pinned messages',
                style: AppText.body.copyWith(
                  color: tokens.textPrimary,
                  fontWeight: AppWeights.semi,
                ),
              ),
            ],
          ),
        ),
        ConstrainedBox(
          key: pinnedMessagesBodyBoxKey,
          // A ceiling for a real list, via `body`'s own shrinkWrap ListView; an empty or loading state keeps a modest fixed box instead.
          constraints: hasList
              ? BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height * 0.6,
                )
              : const BoxConstraints.tightFor(height: 160),
          child: body,
        ),
      ],
    );
  }
}

class _Body extends ConsumerWidget {
  const _Body({
    required this.channelId,
    required this.pins,
    required this.router,
    required this.currentChannelId,
  });

  final String channelId;
  final PinsState pins;
  final GoRouter router;
  final String? currentChannelId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final list = pins.pinned;

    // A failed refresh with an older list on hand falls through to that list
    // below instead: it is stale, not wrong, and the live events correct it.
    if (list == null && pins.failed) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.s16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                pins.forbidden
                    ? 'You do not have permission to see pins here.'
                    : 'Could not load pinned messages.',
                style: TextStyle(color: tokens.textSecondary),
                textAlign: TextAlign.center,
              ),
              if (!pins.forbidden) ...[
                const SizedBox(height: AppSpacing.s12),
                TextButton(
                  onPressed: () => ref
                      .read(pinsControllerProvider(channelId).notifier)
                      .refresh(),
                  child: const Text('Retry'),
                ),
              ],
            ],
          ),
        ),
      );
    }
    if (list == null) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (list.isEmpty) {
      return Center(
        child: Text(
          'Nothing pinned yet.',
          style: TextStyle(color: tokens.textSecondary),
        ),
      );
    }

    resolveAuthorProfiles(ref, list.map((p) => p.message.authorId));

    return SheetItemList(
      itemCount: list.length,
      itemBuilder: (context, i) => PinnedMessageRow(
        channelId: channelId,
        pin: list[i],
        router: router,
        currentChannelId: currentChannelId,
      ),
    );
  }
}

/// One pinned-message row: selects only its own author's slice of
/// [batchProfilesControllerProvider], so an unrelated author resolving does
/// not rebuild every row in the list - see `message_row_identity.dart`.
class PinnedMessageRow extends ConsumerWidget {
  const PinnedMessageRow({
    super.key,
    required this.channelId,
    required this.pin,
    required this.router,
    required this.currentChannelId,
  });

  final String channelId;
  final api.PinnedMessage pin;
  final GoRouter router;
  final String? currentChannelId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final resolution = ref.watch(
      batchProfilesControllerProvider.select(
        (m) => authorResolution(m, pin.message.authorId ?? ''),
      ),
    );
    final name = authorLabelResolved(
      authorId: pin.message.authorId,
      cachedDisplayName: pin.message.authorDisplayName,
      resolution: resolution,
    );
    return ListTile(
      onTap: () {
        final read = ref.read;
        Navigator.of(context).pop();
        jumpToMessage(
          router,
          read,
          currentChannelId: currentChannelId,
          channelId: pin.message.channelId,
          messageId: pin.message.id,
        );
      },
      leading: UserAvatar(
        userId: pin.message.authorId,
        name: name,
        size: AppAvatarSize.s28,
      ),
      title: AuthorNameLine(name: name, profile: resolution.profile),
      subtitle: Text(
        previewLine(pin.message.content, pin.message.attachments),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: AppIconButton(
        icon: AppIcons.pin,
        semanticLabel: 'Unpin this message',
        tooltip: 'Unpin',
        onPressed: () => ref
            .read(pinsControllerProvider(channelId).notifier)
            .unpin(pin.message.id),
      ),
    );
  }
}
