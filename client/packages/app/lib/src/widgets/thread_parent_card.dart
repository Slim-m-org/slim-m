// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The message a thread hangs off, shown as the transcript's first item so a
/// thread never reads as a conversation with no visible subject.
///
/// Laid out like an ordinary message row (the pane gutter, a 36px avatar, the
/// author line over the text) rather than as a boxed quote, so the original
/// reads as the start of the conversation and the first reply sits directly
/// under it. It is not a [MessageRow]: the thread-parent payload carries no
/// timestamp or attachments to give one, and the row's own redesign is in
/// flight. A hairline under it separates the original from the replies.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../message_preview.dart';
import '../providers/threads.dart';
import '../providers/user_profiles.dart';
import '../routing/breakpoints.dart';
import 'author_label.dart';
import 'message_jump.dart';
import 'user_avatar.dart';

/// How much of the parent's own text is shown before it is cut off.
const int _snippetMaxRunes = 600;

/// The parent's author avatar, the size a message row uses.
const double _avatarSize = AppAvatarSize.s40;

/// Resolves [threadParentProvider] for [channelId] and shows the parent once
/// it is known; nothing before then or for a channel that is not a thread, so
/// the transcript's top slot is always present and never shifts the list.
class ThreadParentSlot extends ConsumerWidget {
  const ThreadParentSlot({super.key, required this.channelId});

  final String channelId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final parent = ref.watch(threadParentProvider(channelId)).valueOrNull;
    if (parent == null || !parent.isThread) return const SizedBox.shrink();
    return ThreadParentCard(parent: parent, threadChannelId: channelId);
  }
}

class ThreadParentCard extends ConsumerWidget {
  const ThreadParentCard({
    super.key,
    required this.parent,
    required this.threadChannelId,
  });

  final api.ThreadParent parent;

  /// This thread's own channel id, so a tap that jumps to the parent (which
  /// always lives somewhere else) knows what it is jumping away from.
  final String threadChannelId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    resolveAuthorProfiles(ref, [parent.parentAuthorId]);

    final gutter = paneGutterOf(context);

    final Widget body;
    final String semanticLabel;
    if (parent.parentDeleted) {
      body = Row(
        children: [
          Icon(AppIcons.delete, size: 13, color: tokens.textSecondary),
          const SizedBox(width: AppSpacing.s4),
          Text(
            'This message was deleted.',
            style: AppText.caption.copyWith(
              color: tokens.textSecondary,
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
      );
      semanticLabel = 'Thread on a message that was deleted';
    } else {
      final resolution = ref.watch(
        batchProfilesControllerProvider.select(
          (m) => authorResolution(m, parent.parentAuthorId ?? ''),
        ),
      );
      final name = authorLabelResolved(
        authorId: parent.parentAuthorId,
        cachedDisplayName: parent.parentAuthorDisplayName,
        resolution: resolution,
      );
      final snippet = previewSnippet(
        parent.parentContent ?? '',
        maxRunes: _snippetMaxRunes,
      );
      body = Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          UserAvatar(
            name: name,
            userId: parent.parentAuthorId,
            size: _avatarSize,
          ),
          const SizedBox(width: AppSpacing.s12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                AuthorNameLine(
                  name: name,
                  profile: resolution.profile,
                  style: AppText.body.copyWith(
                    color: tokens.textPrimary,
                    fontWeight: AppWeights.semi,
                  ),
                ),
                Text(
                  snippet,
                  maxLines: 8,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.body.copyWith(color: tokens.textPrimary),
                ),
              ],
            ),
          ),
        ],
      );
      semanticLabel = 'Thread on $name: $snippet';
    }

    final canJump =
        !parent.parentDeleted &&
        parent.parentChannelId != null &&
        parent.parentMessageId != null;
    // On tap, not on build: eager lookup would demand a router from every surface a message renders on. Mirrors ForwardedMessageCard.
    final onJump = !canJump
        ? null
        : () => jumpToMessage(
            GoRouter.of(context),
            ref.read,
            currentChannelId: threadChannelId,
            channelId: parent.parentChannelId!,
            messageId: parent.parentMessageId!,
          );

    // The focus ring reserves its own space around a jumpable card; take it out of the padding so the avatar still lines up with the replies' gutter.
    final ringInset = onJump == null ? 0.0 : focusRingGap + focusRingWidth;
    final padded = Padding(
      padding: EdgeInsets.fromLTRB(
        gutter - ringInset,
        AppSpacing.s12 - ringInset,
        gutter - ringInset,
        0,
      ),
      child: Semantics(
        button: onJump != null,
        label: onJump != null
            ? '$semanticLabel, go to the original'
            : semanticLabel,
        child: ExcludeSemantics(
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: tokens.borderSubtle)),
            ),
            child: Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.s12),
              child: body,
            ),
          ),
        ),
      ),
    );

    if (onJump == null) return padded;
    return AppFocusRing(
      radius: AppRadii.control,
      builder: (context, onFocusChange) => InkWell(
        onTap: onJump,
        // AppFocusRing replaces this overlay; see ForwardedMessageCard's own copy.
        focusColor: Colors.transparent,
        onFocusChange: onFocusChange,
        borderRadius: BorderRadius.circular(AppRadii.control),
        child: padded,
      ),
    );
  }
}
