// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The body of the who-reacted surface: a title with the emoji and its count,
/// then the people, paged. Shared by the phone sheet and the desktop popover,
/// so the two differ only in the frame around them.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../providers/presence_view.dart';
import '../providers/reaction_users.dart';
import '../providers/user_profiles.dart';
import 'author_label.dart';
import 'custom_emoji_image.dart';
import 'sheet_item_list.dart';
import 'standard_emoji.dart';
import 'user_avatar.dart';

/// "Ada", "Ada and Bob", "Ada, Bob and Cy", then "Ada, Bob and 3 others": the
/// first names, and how many more there are, for a hover summary.
///
/// [total] is the count the chip shows; [names] is however many have loaded.
String reactionSummaryLine(List<String> names, int total) {
  if (names.isEmpty) return total == 1 ? '1 person' : '$total people';
  if (total <= 3 && names.length >= total) {
    final shown = names.take(total).toList();
    if (shown.length == 1) return shown.first;
    return '${shown.sublist(0, shown.length - 1).join(', ')} and ${shown.last}';
  }
  final named = names.take(2).toList();
  final others = total - named.length;
  final noun = others == 1 ? 'other' : 'others';
  return '${named.join(', ')} and $others $noun';
}

/// The loaded names of [userIds], in order, for [reactionSummaryLine].
List<String> reactionUserNames(
  List<String> userIds,
  Map<String, api.UserProfile?> profiles,
) => [
  for (final id in userIds)
    authorLabel(authorId: id, cachedDisplayName: null, profiles: profiles),
];

class ReactionUsersBody extends ConsumerWidget {
  const ReactionUsersBody({
    super.key,
    required this.messageId,
    required this.reaction,
    this.customEmoji = const {},
  });

  final String messageId;
  final api.ReactionSummary reaction;
  final Map<String, String> customEmoji;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final key = (messageId: messageId, emoji: reaction.emoji);
    final state = ref.watch(reactionUsersProvider(key));
    final controller = ref.read(reactionUsersProvider(key).notifier);
    final ids = state.userIds;
    if (ids != null) resolveAuthorProfiles(ref, ids);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Title(reaction: reaction, customEmoji: customEmoji),
        if (ids == null)
          SizedBox(
            height: 160,
            child: AppAsyncView<List<String>>(
              value: AppAsyncState(error: state.failed ? true : null),
              data: (context, _) => const SizedBox.shrink(),
              errorMessage: 'Could not load who reacted.',
              onRetry: controller.refresh,
            ),
          )
        else if (ids.isEmpty)
          const SizedBox(height: 96, child: _Empty())
        else
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.5,
            ),
            child: SheetItemList(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.s8,
                0,
                AppSpacing.s8,
                AppSpacing.s8,
              ),
              itemCount: ids.length + (state.hasMore || state.failed ? 1 : 0),
              itemBuilder: (context, i) {
                if (i < ids.length) {
                  // A failed page waits for Retry; loading it again from here is a loop.
                  if (i == ids.length - 1 && state.hasMore && !state.failed) {
                    scheduleMicrotask(controller.loadMore);
                  }
                  return ReactionUserRow(userId: ids[i]);
                }
                return state.failed
                    ? Padding(
                        padding: const EdgeInsets.all(AppSpacing.s8),
                        child: AppErrorState(
                          message: 'Could not load more.',
                          onRetry: controller.loadMore,
                        ),
                      )
                    : const _LoadingMore();
              },
            ),
          ),
      ],
    );
  }
}

class _Title extends StatelessWidget {
  const _Title({required this.reaction, required this.customEmoji});

  final api.ReactionSummary reaction;
  final Map<String, String> customEmoji;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final customId = customEmojiIdFor(reaction.emoji, customEmoji);
    final count = reaction.count;
    final words = '$count ${count == 1 ? 'person' : 'people'}';
    return Semantics(
      header: true,
      label: '${reaction.emoji}, $words',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.s16,
          0,
          AppSpacing.s16,
          AppSpacing.s8,
        ),
        child: Row(
          children: [
            if (customId != null)
              CustomEmojiImage(emojiId: customId, size: AppSizes.icon20)
            else
              Text(
                standardEmojiFor(reaction.emoji) ?? reaction.emoji,
                style: AppText.heading,
              ),
            const SizedBox(width: AppSpacing.s8),
            Text(
              words,
              style: AppText.body.copyWith(
                color: tokens.textSecondary,
                fontWeight: AppWeights.semi,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Center(
      child: Text(
        'No one has this reaction now.',
        style: AppText.body.copyWith(color: tokens.textSecondary),
      ),
    );
  }
}

class _LoadingMore extends StatelessWidget {
  const _LoadingMore();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.all(AppSpacing.s12),
    child: Center(
      child: SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
    ),
  );
}

/// One person: the shared avatar with presence, their name, and the Bot badge
/// a bot wears everywhere else. Selects only its own slice of the profile
/// cache, so another person resolving does not rebuild every row.
class ReactionUserRow extends ConsumerWidget {
  const ReactionUserRow({super.key, required this.userId});

  final String userId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final resolution = ref.watch(
      batchProfilesControllerProvider.select(
        (m) => authorResolution(m, userId),
      ),
    );
    final status = ref.watch(presenceForProvider(userId));
    final name = authorLabelResolved(
      authorId: userId,
      cachedDisplayName: null,
      resolution: resolution,
    );
    return AppListRow(
      label: name,
      leading: UserAvatar(
        userId: userId,
        name: name,
        size: AppAvatarSize.s28,
        presence: true,
      ),
      muted: status == AppPresence.offline,
      trailing: (resolution.profile?.isBot ?? false)
          ? const AppBadge(variant: AppBadgeVariant.tag, label: 'Bot')
          : null,
    );
  }
}
