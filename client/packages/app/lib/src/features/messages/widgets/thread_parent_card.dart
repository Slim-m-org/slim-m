// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The message a thread hangs off, shown as the transcript's first item so a
/// thread never reads as a conversation with no visible subject.
///
/// Laid out like an ordinary message row (the pane gutter, the density's
/// avatar, the author and time line over the text) so the original reads as
/// the start of the conversation and the first reply sits directly under it.
/// It is not a [MessageRow]: the thread-parent payload carries no timestamp
/// or reactions to give one, so the time is read from the message's UUIDv7 id.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_data/data.dart' show Message;
import 'package:slimm_design_system/design_system.dart';

import '../../../ids.dart';
import '../../../message_preview.dart';
import '../../channels/providers/threads.dart';
import '../../settings/providers/display_density.dart';
import '../../emoji/providers/emoji_catalog_provider.dart';
import '../../members/providers/blocks_controller.dart';
import '../../members/providers/known_mention_names.dart';
import '../../members/providers/member_presence.dart';
import '../../members/providers/mention_names.dart';
import '../../members/providers/user_profiles.dart';
import '../../../routing/breakpoints.dart';
import 'attachment_view.dart';
import 'author_label.dart';
import 'bounded_fade_box.dart';
import 'message_inline.dart' show rewriteMentions;
import 'message_jump.dart';
import 'message_row_identity.dart';
import 'message_text.dart';
import '../../members/widgets/role_color.dart';
import '../../members/widgets/user_avatar.dart';

/// How much of the parent's own text is shown before it is cut off.
const int _snippetMaxRunes = 600;

/// How tall the parent's body grows before it fades out; the original is one tap away.
const double threadParentMaxBodyHeight = 160;

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
    final density = ref.watch(messageDensityControllerProvider);

    final blocked = ref.watch(
      blocksProvider.select((s) => s.contains(parent.parentAuthorId)),
    );
    final Widget body;
    final String semanticLabel;
    if (blocked) {
      body = Row(
        children: [
          Icon(AppIcons.shieldOff, size: 13, color: tokens.textSecondary),
          const SizedBox(width: AppSpacing.s4),
          Text(
            'Message from someone you blocked.',
            style: AppText.caption.copyWith(
              color: tokens.textSecondary,
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
      );
      semanticLabel = 'Thread on a message from someone you blocked';
    } else if (parent.parentDeleted) {
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
      final content = parent.parentContent ?? '';
      final hasText = plainPreview(content).isNotEmpty;
      final members = ref.watch(membersProvider);
      final snippet = previewSnippet(
        rewriteMentions(content, ref.watch(mentionNamesProvider)),
        maxRunes: _snippetMaxRunes,
      );
      body = Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          UserAvatar(
            name: name,
            userId: parent.parentAuthorId,
            size: density.avatarSize,
          ),
          const SizedBox(width: AppSpacing.s12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _header(name, resolution.profile, tokens),
                if (hasText)
                  BoundedFadeBox(
                    key: const ValueKey('thread-parent-body'),
                    maxHeight: threadParentMaxBodyHeight,
                    fadeColor: tokens.surfaceBase,
                    child: MessageBody(
                      content: content,
                      knownUsernames: knownUsernamesFrom(members),
                      knownRoleNames: knownRoleNamesFrom(members),
                      customEmoji: ref.watch(customEmojiIndexProvider),
                      runnable: false,
                    ),
                  )
                else
                  Text(
                    snippet,
                    style: AppText.body.copyWith(color: tokens.textPrimary),
                  ),
                for (final attachment in parent.parentAttachments)
                  Padding(
                    padding: const EdgeInsets.only(top: AppSpacing.s4),
                    child: AttachmentView(
                      attachment: attachment,
                      siblings: openableImages(parent.parentAttachments),
                      messageId: parent.parentMessageId,
                    ),
                  ),
              ],
            ),
          ),
        ],
      );
      final count = parent.parentAttachments.length;
      final attached = switch (count) {
        0 => '',
        1 => ', with an attachment',
        _ => ', with $count attachments',
      };
      semanticLabel = 'Thread on $name: $snippet$attached';
    }

    final canJump =
        !blocked &&
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
        density.listRowGap - ringInset,
        gutter - ringInset,
        0,
      ),
      child: Semantics(
        button: onJump != null,
        label: onJump != null
            ? '$semanticLabel, go to the original'
            : semanticLabel,
        child: ExcludeSemantics(child: IgnorePointer(child: body)),
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

  /// The channel row's own name-then-time line; the time is left off when the id carries none.
  Widget _header(String name, api.UserProfile? profile, AppTokens tokens) {
    final sentAt = uuidV7Time(parent.parentMessageId);
    final nameStyle = AppText.body.copyWith(
      color: memberNameColor(profile, tokens.surfaceBase) ?? tokens.textPrimary,
      fontWeight: AppWeights.semi,
    );
    if (sentAt == null) {
      return AuthorNameLine(name: name, profile: profile, style: nameStyle);
    }
    return MessageRowHeader(
      key: MessageRowHeader.headerKey,
      message: Message(
        id: parent.parentMessageId!,
        channelId: parent.parentChannelId ?? '',
        authorId: parent.parentAuthorId,
        authorDisplayName: parent.parentAuthorDisplayName,
        seq: 0,
        content: '',
        createdAt: sentAt.millisecondsSinceEpoch,
        pending: false,
        failed: false,
      ),
    );
  }
}
